import 'package:http/http.dart' as http;
import 'secure_tunnel_client.dart';

/// Connection Manager - Automatisch switchen tussen lokaal en remote (tunnel)
class ConnectionManager {
    static SecureTunnelClient? _tunnel;
    static String? _localUrl;
    static final bool _preferLocal = true;

    /// Initialize connection manager
    static Future<void> initialize() async {
      // Try to load tunnel credentials
      final credentials = await TunnelCredentialsStorage.loadCredentials();
      
      if (credentials != null) {
        _tunnel = SecureTunnelClient(
          hubId: credentials['hubId']!,
          accessToken: credentials['accessToken']!,
          relayUrl: credentials['relayUrl']!,
        );
        
        // Connect tunnel in background
        _tunnel!.connect().catchError((e) {
          print('[ConnectionManager] Tunnel connection failed: $e');
          return false;
        });
      }
    }

    /// Set local URL (from mDNS discovery or manual input)
    static void setLocalUrl(String url) {
      _localUrl = url;
    }

    /// Check if local hub is reachable
    static Future<bool> isLocalAvailable(String ip) async {
       try {
          final uri = Uri.parse(ip.startsWith('http') ? '$ip/api/health' : 'https://$ip:3000/api/health');
          final response = await http.get(uri).timeout(const Duration(seconds: 2));
          return response.statusCode == 200;
       } catch (e) {
          return false;
       }
    }

    /// Make API request (auto-route via local or tunnel)
    static Future<http.Response> request({
      required String method,
      required String path,
      Map<String, String>? headers,
      dynamic body,
    }) async {
      // Try local first (if available and preferred)
      if (_preferLocal && _localUrl != null) {
        try {
          final localAvailable = await isLocalAvailable(_localUrl!);
          if (localAvailable) {
            return await _makeLocalRequest(
              method: method,
              path: path,
              headers: headers,
              body: body,
            );
          }
        } catch (e) {
          print('[ConnectionManager] Local request failed: $e');
        }
      }

      // Fallback to tunnel
      if (_tunnel != null && _tunnel!.isConnected) {
        return await _makeTunnelRequest(
          method: method,
          path: path,
          headers: headers,
          body: body,
        );
      }

      throw Exception('No connection available (local or tunnel)');
    }

    /// Make local HTTP request
    static Future<http.Response> _makeLocalRequest({
      required String method,
      required String path,
      Map<String, String>? headers,
      dynamic body,
    }) async {
      final url = '$_localUrl$path';
      
      switch (method.toUpperCase()) {
        case 'GET':
          return await http.get(Uri.parse(url), headers: headers);
        case 'POST':
          return await http.post(Uri.parse(url), headers: headers, body: body);
        case 'PUT':
          return await http.put(Uri.parse(url), headers: headers, body: body);
        case 'DELETE':
          return await http.delete(Uri.parse(url), headers: headers);
        default:
          throw Exception('Unsupported method: $method');
      }
    }

    /// Make request via encrypted tunnel
    static Future<http.Response> _makeTunnelRequest({
      required String method,
      required String path,
      Map<String, String>? headers,
      dynamic body,
    }) async {
      final response = await _tunnel!.request(
        method: method,
        path: path,
        headers: headers,
        body: body,
      );

      // Convert tunnel response to http.Response
      return http.Response(
        response['body'],
        response['status'],
        headers: Map<String, String>.from(response['headers'] ?? {}),
      );
    }

    /// Get current connection type
    static Future<String> getConnectionType() async {
      if (_localUrl != null) {
        final available = await isLocalAvailable(_localUrl!);
        if (available) return 'local';
      }
      
      if (_tunnel != null && _tunnel!.isConnected) {
        return 'tunnel';
      }
      
      return 'none';
    }

    /// Disconnect tunnel
    static void disconnect() {
      _tunnel?.disconnect();
      _tunnel = null;
    }

    /// Check if any connection is available
    static Future<bool> isConnected() async {
      final type = await getConnectionType();
      return type != 'none';
    }
}

