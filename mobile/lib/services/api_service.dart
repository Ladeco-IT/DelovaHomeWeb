import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/device.dart';
import 'connection_manager.dart';

class ApiService {
  static const String _port = '3000';

  Future<String> getBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final ip = prefs.getString('hub_ip'); // Local IP
    final port = prefs.getString('hub_port') ?? _port;
    final cloudUrl = prefs.getString('cloud_url'); // Cloud Proxy URL (if available)

    if (ip == null && cloudUrl == null) {
      throw Exception('Hub not connected');
    }

    // Smart Switching Logic
    if (ip != null) {
        // Construct Local URL
        String localUrl = ip.startsWith('http') ? ip : 'https://$ip:$port';
        if (localUrl.endsWith('/')) localUrl = localUrl.substring(0, localUrl.length - 1);

        // Check availability (Cached mostly)
        bool isLocal = await ConnectionManager.isLocalAvailable(localUrl);
        if (isLocal) {
             debugPrint("Using Local Connection: $localUrl");
             return localUrl;
        }
    }

    // Fallback to Cloud
    if (cloudUrl != null && cloudUrl.isNotEmpty) {
        debugPrint("Using Cloud Connection: $cloudUrl");
        return cloudUrl.endsWith('/') ? cloudUrl.substring(0, cloudUrl.length - 1) : cloudUrl;
    }

    // Default back to local if cloud fails or not set (hoping for the best)
    return ip!.startsWith('http') ? ip : 'https://$ip:$port';
  }

  Future<Map<String, String>> getHeaders() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('cloud_token');
    final hubId = prefs.getString('hub_id');
    final username = prefs.getString('username');
    
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (token != null) {
      headers['Authorization'] = 'Bearer $token';
    }
    if (hubId != null) {
      headers['x-hub-id'] = hubId;
    }
    if (username != null) {
      headers['x-delova-username'] = username;
    }
    return headers;
  }

  Future<void> registerPushToken(String token) async {
    final baseUrl = await getBaseUrl();
    final headers = await getHeaders();

    final response = await http.post(
      Uri.parse('$baseUrl/api/notifications/register-token'),
      headers: headers,
      body: jsonEncode({'token': token, 'platform': defaultTargetPlatform.toString()}),
    );
    
    if (response.statusCode != 200) {
      debugPrint('Failed to register token: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> getSystemInfo() async {
    final baseUrl = await getBaseUrl();
    final response = await http.get(
      Uri.parse('$baseUrl/api/system/info'),
      headers: await getHeaders(),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to load system info');
    }
  }

  Future<void> setHubIp(String ip) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('hub_ip', ip);
  }

  Future<List<Device>> getDevices() async {
    final baseUrl = await getBaseUrl();
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/api/devices'),
        headers: await getHeaders(),
      );
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        return data.map((json) => Device.fromJson(json)).toList();
      } else {
        throw Exception('Failed to load devices');
      }
    } catch (e) {
      throw Exception('Connection error: $e');
    }
  }

  Future<void> sendCommand(String deviceId, String command, [Map<String, dynamic>? params]) async {
    final baseUrl = await getBaseUrl();
    // Corrected URL to match server.js: /api/devices/:id/command
    final url = Uri.parse('$baseUrl/api/devices/$deviceId/command');
    
    // Corrected Body to match server.js expectation: { command, value }
    final body = {
      'command': command,
      'value': params?['value'],
    };

    try {
      await http.post(
        url,
        headers: await getHeaders(),
        body: json.encode(body),
      );
    } catch (e) {
      debugPrint('Error sending command: $e');
    }
  }

  Future<void> activateScene(String sceneName) async {
    final baseUrl = await getBaseUrl();
    final url = Uri.parse('$baseUrl/api/scenes/$sceneName');
    try {
      await http.post(
        url,
        headers: await getHeaders(),
      );
    } catch (e) {
      debugPrint('Error activating scene: $e');
    }
  }


  Future<Map<String, dynamic>> checkUpdate() async {
    final baseUrl = await getBaseUrl();
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/api/system/check-update'),
        headers: await getHeaders(),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        throw Exception('Failed to check for updates');
      }
    } catch (e) {
      throw Exception('Connection error: $e');
    }
  }

  Future<Map<String, dynamic>> updateSystem() async {
    final baseUrl = await getBaseUrl();
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/system/update'),
        headers: await getHeaders(),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        throw Exception('Failed to update system');
      }
    } catch (e) {
      throw Exception('Connection error: $e');
    }
  }

  Future<void> updateLocation(double latitude, double longitude) async {
    final baseUrl = await getBaseUrl();
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('userId');
    
    if (userId == null) {
        debugPrint('Cannot update location: No userId found');
        return;
    }

    // Prevent sending Cloud UUIDs as location updates. 
    // We must wait for Hub Login to get the Local User ID.
    if (userId.length > 10 && int.tryParse(userId) == null) {
        debugPrint('Skipping location update: userId is Cloud UUID ($userId). Waiting for Hub Login.');
        return;
    }

    try {
      await http.post(
        Uri.parse('$baseUrl/api/presence/location'),
        headers: await getHeaders(),
        body: json.encode({
          'userId': userId,
          'latitude': latitude,
          'longitude': longitude,
          'source': 'mobile_background',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
      );
    } catch (e) {
      debugPrint('Error updating location: $e');
    }
  }

  Future<void> setHomeLocation(double latitude, double longitude, double radius) async {
    final baseUrl = await getBaseUrl();
    try {
      await http.post(
        Uri.parse('$baseUrl/api/presence/home-location'),
        headers: await getHeaders(),
        body: json.encode({
          'latitude': latitude,
          'longitude': longitude,
          'radius': radius,
        }),
      );
    } catch (e) {
      debugPrint('Error setting home location: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> getEnergyData() async {
    final baseUrl = await getBaseUrl();
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/api/energy'),
        headers: await getHeaders(),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
    } catch (e) {
      debugPrint('Error fetching energy data: $e');
    }
    return {};
  }

  Future<Map<String, dynamic>> getPresenceData() async {
    final baseUrl = await getBaseUrl();
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/api/presence'),
        headers: await getHeaders(),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
    } catch (e) {
      debugPrint('Error fetching presence data: $e');
    }
    return {'people': []};
  }

  Future<Map<String, dynamic>> sendAICommand(String text) async {
    final baseUrl = await getBaseUrl();
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/ai/command'),
        headers: await getHeaders(),
        body: json.encode({'text': text}),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
    } catch (e) {
      debugPrint('Error sending AI command: $e');
    }
    return {'ok': false, 'message': 'Connection error'};
  }

  Future<List<dynamic>> getSpotifyDevices() async {
    final baseUrl = await getBaseUrl();
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('userId');
      final username = prefs.getString('username');
      
      String url = '$baseUrl/api/spotify/devices';
      final params = <String>[];
      if (userId != null) params.add('userId=$userId');
      if (username != null) params.add('username=$username');
      if (params.isNotEmpty) url += '?${params.join('&')}';

      final response = await http.get(
        Uri.parse(url),
        headers: await getHeaders(),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        return [];
      }
    } catch (e) {
      return [];
    }
  }

  Future<Map<String, dynamic>> getSpotifyStatus() async {
    final baseUrl = await getBaseUrl();
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('userId');
      final url = userId != null ? '$baseUrl/api/spotify/status?userId=$userId' : '$baseUrl/api/spotify/status';
      final response = await http.get(
        Uri.parse(url),
        headers: await getHeaders(),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
    } catch (e) {
      debugPrint('Error fetching spotify status: $e');
    }
    return {'is_playing': false};
  }

  Future<List<dynamic>> getSpotifyPlaylists() async {
    final baseUrl = await getBaseUrl();
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('userId');
      final url = userId != null ? '$baseUrl/api/spotify/playlists?userId=$userId' : '$baseUrl/api/spotify/playlists';
      final response = await http.get(
        Uri.parse(url),
        headers: await getHeaders(),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
    } catch (e) {
      debugPrint('Error fetching playlists: $e');
    }
    return [];
  }

  Future<List<dynamic>> getSpotifyAlbums() async {
    final baseUrl = await getBaseUrl();
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('userId');
      final url = userId != null ? '$baseUrl/api/spotify/albums?userId=$userId' : '$baseUrl/api/spotify/albums';
      final response = await http.get(
        Uri.parse(url),
        headers: await getHeaders(),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
    } catch (e) {
      debugPrint('Error fetching albums: $e');
    }
    return [];
  }

  Future<Map<String, dynamic>> searchSpotify(String q) async {
    final baseUrl = await getBaseUrl();
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('userId');
      final userPart = userId != null ? '&userId=$userId' : '';
      final response = await http.get(
        Uri.parse('$baseUrl/api/spotify/search?q=${Uri.encodeComponent(q)}$userPart'),
        headers: await getHeaders(),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
    } catch (e) {
      debugPrint('Error searching spotify: $e');
    }
    return {'tracks': [], 'artists': []};
  }

  Future<Map<String, dynamic>> getSpotifyMe() async {
    final baseUrl = await getBaseUrl();
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('userId');
      final url = userId != null ? '$baseUrl/api/spotify/me?userId=$userId' : '$baseUrl/api/spotify/me';
      final response = await http.get(
        Uri.parse(url),
        headers: await getHeaders(),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
    } catch (e) {
      debugPrint('Error getting spotify me: $e');
    }
    return {'available': false, 'device': null};
  }

  Future<void> spotifyControl(String command, [dynamic value]) async {
    final baseUrl = await getBaseUrl();
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('userId');
      final username = prefs.getString('username');
      final body = {
        'command': command,
        'value': value,
        'userId': ?userId,
        'username': ?username,
      };
      await http.post(
        Uri.parse('$baseUrl/api/spotify/control'),
        headers: await getHeaders(),
        body: json.encode(body),
      );
    } catch (e) {
      debugPrint('Error sending spotify control: $e');
    }
  }

  Future<bool> transferSpotifyPlayback(String deviceId) async {
    final baseUrl = await getBaseUrl();
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('userId');
      final username = prefs.getString('username');
      final body = {
        'deviceId': deviceId,
        'userId': ?userId,
        'username': ?username,
      };
      final response = await http.post(
        Uri.parse('$baseUrl/api/spotify/transfer-or-sonos'),
        headers: await getHeaders(),
        body: json.encode(body),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['ok'] == true;
      }
    } catch (e) {
      debugPrint('Error transferring playback (transfer-or-sonos): $e');
    }
    return false;
  }

  Future<List<dynamic>> getSonosDevices() async {
    final baseUrl = await getBaseUrl();
    try {
      final response = await http.get(Uri.parse('$baseUrl/api/sonos/devices'));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data is Map && data['ok'] == true) return data['devices'] ?? [];
      }
    } catch (e) {
      debugPrint('Error fetching Sonos devices: $e');
    }
    return [];
  }

  Future<Map<String, dynamic>> getSonosPlaybackState(String uuid) async {
    final baseUrl = await getBaseUrl();
    try {
      final response = await http.get(Uri.parse('$baseUrl/api/sonos/$uuid/state'));
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
    } catch (e) {
      debugPrint('Error fetching Sonos state for $uuid: $e');
    }
    return {'status': 'UNKNOWN'};
  }

  Future<void> sonosControl(String uuid, String command, [dynamic value]) async {
    final baseUrl = await getBaseUrl();
    try {
      final body = {'command': command, 'value': value};
      await http.post(
        Uri.parse('$baseUrl/api/sonos/$uuid/command'),
        headers: await getHeaders(),
        body: json.encode(body),
      );
    } catch (e) {
      debugPrint('Error sending Sonos command: $e');
    }
  }

  Future<bool> playOnSonos(String uuid, String spotifyUri, {String? metadata}) async {
    final baseUrl = await getBaseUrl();
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/sonos/$uuid/play-spotify'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'spotifyUri': spotifyUri, 'metadata': ?metadata}),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['ok'] == true;
      }
    } catch (e) {
      debugPrint('Error requesting Sonos play: $e');
    }
    return false;
  }

  Future<Map<String, dynamic>> startPairing(String ip) async {
    final baseUrl = await getBaseUrl();
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/pair/start'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'ip': ip}),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        throw Exception('Failed to start pairing');
      }
    } catch (e) {
      throw Exception('Connection error: $e');
    }
  }

  Future<Map<String, dynamic>> submitPairingPin(String pin) async {
    final baseUrl = await getBaseUrl();
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/pair/pin'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'pin': pin}),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        throw Exception('Failed to submit PIN');
      }
    } catch (e) {
      throw Exception('Connection error: $e');
    }
  }

  Future<Map<String, dynamic>> pairDevice(String ip, String pin) async {
    final baseUrl = await getBaseUrl();
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/device/pair'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'ip': ip, 'pin': pin}),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        try {
            return json.decode(response.body);
        } catch (_) {
            throw Exception('Failed to pair device');
        }
      }
    } catch (e) {
      throw Exception('Connection error: $e');
    }
  }

  Future<Map<String, dynamic>> addNas(Map<String, dynamic> data) async {
    final baseUrl = await getBaseUrl();
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/nas'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(data),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        throw Exception('Failed to add NAS');
      }
    } catch (e) {
      throw Exception('Connection error: $e');
    }
  }

  Future<List<dynamic>> getNasDevices() async {
    final baseUrl = await getBaseUrl();
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/api/nas'),
        headers: await getHeaders(),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data is List) return data;
        if (data is Map && data['nas'] is List) return data['nas'];
        return [];
      }
    } catch (e) {
      debugPrint('Error fetching NAS devices: $e');
    }
    return [];
  }

  Future<List<dynamic>> getNasFiles(String nasId, [String path = '/']) async {
    final baseUrl = await getBaseUrl();
    try {
      final encodedPath = Uri.encodeComponent(path);
      final response = await http.get(
        Uri.parse('$baseUrl/api/nas/$nasId/files?path=$encodedPath'),
        headers: await getHeaders(),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data is List) return data;
        if (data is Map && data['files'] is List) return data['files'];
        return [];
      }
    } catch (e) {
      debugPrint('Error fetching NAS files: $e');
    }
    return [];
  }

  Future<void> updateKnxConfig(String ip, String port, String physAddr) async {
    final baseUrl = await getBaseUrl();
    final url = Uri.parse('$baseUrl/api/knx/config');
    final body = {
      'ip': ip,
      'port': int.tryParse(port) ?? 3671,
      'physAddr': physAddr,
    };
    
    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode(body),
      );
      if (response.statusCode != 200) {
        throw Exception('Failed to update KNX config: ${response.body}');
      }
    } catch (e) {
      throw Exception('Connection error: $e');
    }
  }


  Future<void> wakePs5(String id) async {
    final baseUrl = await getBaseUrl();
    final response = await http.post(
      Uri.parse('$baseUrl/api/ps5/$id/wake'),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to wake PS5');
    }
  }

  Future<void> standbyPs5(String id) async {
    final baseUrl = await getBaseUrl();
    final response = await http.post(
      Uri.parse('$baseUrl/api/ps5/$id/standby'),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to standby PS5');
    }
  }

  Future<void> disconnectSpotify(int userId) async {
    final baseUrl = await getBaseUrl();
    final response = await http.post(
      Uri.parse('$baseUrl/api/spotify/logout'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'userId': userId}),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to disconnect Spotify');
    }
  }

  // --- Automations ---

  Future<List<dynamic>> getAutomations() async {
    final baseUrl = await getBaseUrl();
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/api/automations'),
        headers: await getHeaders(),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
    } catch (e) {
      debugPrint('Error fetching automations: $e');
    }
    return [];
  }

  Future<void> addAutomation(Map<String, dynamic> automation) async {
    final baseUrl = await getBaseUrl();
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/automations'),
        headers: await getHeaders(),
        body: json.encode(automation),
      );
      if (response.statusCode != 200) {
        throw Exception('Failed to add automation');
      }
    } catch (e) {
      throw Exception('Connection error: $e');
    }
  }

  Future<void> updateAutomation(String id, Map<String, dynamic> automation) async {
    final baseUrl = await getBaseUrl();
    try {
      final response = await http.put(
        Uri.parse('$baseUrl/api/automations/$id'),
        headers: await getHeaders(),
        body: json.encode(automation),
      );
      if (response.statusCode != 200) {
        throw Exception('Failed to update automation');
      }
    } catch (e) {
      throw Exception('Connection error: $e');
    }
  }

  Future<void> deleteAutomation(String id) async {
    final baseUrl = await getBaseUrl();
    try {
      final response = await http.delete(
        Uri.parse('$baseUrl/api/automations/$id'),
        headers: await getHeaders(),
      );
      if (response.statusCode != 200) {
        throw Exception('Failed to delete automation');
      }
    } catch (e) {
      throw Exception('Connection error: $e');
    }
  }

  // --- Localization ---
  Future<Map<String, dynamic>?> fetchLocales() async {
    try {
      final baseUrl = await getBaseUrl();
      // Directly fetch from 'data/locales.json' served by express.static
      final url = Uri.parse('$baseUrl/data/locales.json');
      
      // Use standard http without custom headers as this is a static file
      final response = await http.get(url);
      
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
    } catch (e) {
      if (kDebugMode) print('Error fetching locales: $e');
    }
    return null;
  }
}
