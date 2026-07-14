import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Secure Tunnel Client for DelovaHome
/// Provides E2E encrypted remote access via zero-knowledge relay
class SecureTunnelClient {
  final String hubId;
  final String accessToken;
  final String relayUrl;

  WebSocketChannel? _channel;
  Uint8List? _sessionKey;
  String? _clientId;
  bool _isConnected = false;
  final _responseController = StreamController<Map<String, dynamic>>.broadcast();
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};

  SecureTunnelClient({
    required this.hubId,
    required this.accessToken,
    this.relayUrl = 'wss://relay.delovahome.com',
  });

  /// Connect to relay and establish E2E encrypted session with hub
  Future<bool> connect() async {
    try {
      print('[Tunnel] Connecting to relay: $relayUrl');

      // Generate client ID
      _clientId = _generateClientId();

      // Connect WebSocket
      _channel = WebSocketChannel.connect(Uri.parse(relayUrl));

      // Listen to messages
      _channel!.stream.listen(
        _handleMessage,
        onError: (error) {
          print('[Tunnel] WebSocket error: $error');
          _isConnected = false;
        },
        onDone: () {
          print('[Tunnel] Connection closed');
          _isConnected = false;
        },
      );

      // Perform key exchange
      await _performKeyExchange();

      _isConnected = true;
      print('[Tunnel] Connected and encrypted session established');
      return true;
    } catch (e) {
      print('[Tunnel] Connection failed: $e');
      return false;
    }
  }

  /// Perform ECDH key exchange with hub
  Future<void> _performKeyExchange() async {
    // Generate ECDH keypair
    final ecParams = ECDomainParameters('secp256k1');
    final keyGen = ECKeyGenerator();
    keyGen.init(ParametersWithRandom(
      ECKeyGeneratorParameters(ecParams),
      SecureRandom('Fortuna')..seed(KeyParameter(_generateSeed())),
    ));
    
    final keyPair = keyGen.generateKeyPair();
    final publicKey = keyPair.publicKey;
    final privateKey = keyPair.privateKey;

    // Encode public key
    final publicKeyBytes = _encodePublicKey(publicKey);

    // Send session_init to relay
    final initMessage = {
      'type': 'session_init',
      'clientId': _clientId,
      'hubId': hubId,
      'publicKey': base64Encode(publicKeyBytes),
      'accessToken': accessToken,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

    _channel!.sink.add(jsonEncode(initMessage));

    // Wait for hub's public key
    final response = await _responseController.stream
        .firstWhere((msg) => msg['type'] == 'session_init_response');

    // Decode hub public key
    final hubPublicKeyBytes = base64Decode(response['publicKey']);
    final hubPublicKey = _decodePublicKey(hubPublicKeyBytes, ecParams);

    // Compute shared secret
    final sharedSecret = _computeSharedSecret(privateKey, hubPublicKey);

    // Derive session key using PBKDF2
    _sessionKey = _deriveSessionKey(sharedSecret);

    print('[Tunnel] Session key established');
  }

  /// Send encrypted request to hub
  Future<Map<String, dynamic>> request({
    required String method,
    required String path,
    Map<String, String>? headers,
    dynamic body,
  }) async {
    if (!_isConnected || _sessionKey == null) {
      throw Exception('Not connected or session not established');
    }

    final requestId = _generateRequestId();

    // Build request
    final request = {
      'method': method,
      'path': path,
      'headers': headers ?? {},
      'body': body,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

    // Encrypt request
    final encrypted = _encrypt(jsonEncode(request), _sessionKey!);

    // Send to relay
    final message = {
      'type': 'request',
      'clientId': _clientId,
      'hubId': hubId,
      'requestId': requestId,
      'encrypted': encrypted,
    };

    _channel!.sink.add(jsonEncode(message));

    // Wait for response
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[requestId] = completer;

    // Timeout after 30 seconds
    Timer(const Duration(seconds: 30), () {
      if (!completer.isCompleted) {
        _pendingRequests.remove(requestId);
        completer.completeError(TimeoutException('Request timeout'));
      }
    });

    return completer.future;
  }

  /// Handle incoming WebSocket messages
  void _handleMessage(dynamic data) {
    try {
      final message = jsonDecode(data.toString()) as Map<String, dynamic>;

      switch (message['type']) {
        case 'session_init_response':
          _responseController.add(message);
          break;

        case 'hub_response':
          final requestId = message['requestId'];
          final completer = _pendingRequests.remove(requestId);

          if (completer != null) {
            if (message.containsKey('error')) {
              completer.completeError(Exception(message['error']));
            } else {
              // Decrypt response
              final decrypted = _decrypt(message['encrypted'], _sessionKey!);
              final response = jsonDecode(decrypted) as Map<String, dynamic>;
              completer.complete(response);
            }
          }
          break;

        case 'error':
          print('[Tunnel] Relay error: ${message['error']}');
          break;

        case 'hub_disconnected':
          print('[Tunnel] Hub disconnected');
          _isConnected = false;
          break;
      }
    } catch (e) {
      print('[Tunnel] Message handling error: $e');
    }
  }

  /// Encrypt data with AES-256-GCM
  Map<String, dynamic> _encrypt(String data, Uint8List key) {
    // Generate random IV
    final iv = _generateRandomBytes(16);

    // Create cipher
    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(KeyParameter(key), 128, iv, Uint8List(0));
    cipher.init(true, params);

    // Encrypt
    final plaintext = Uint8List.fromList(utf8.encode(data));
    final ciphertext = cipher.process(plaintext);

    // Split ciphertext and auth tag
    final encrypted = ciphertext.sublist(0, ciphertext.length - 16);
    final authTag = ciphertext.sublist(ciphertext.length - 16);

    return {
      'iv': base64Encode(iv),
      'encrypted': base64Encode(encrypted),
      'authTag': base64Encode(authTag),
    };
  }

  /// Decrypt data with AES-256-GCM
  String _decrypt(Map<String, dynamic> data, Uint8List key) {
    final iv = base64Decode(data['iv']);
    final encrypted = base64Decode(data['encrypted']);
    final authTag = base64Decode(data['authTag']);

    // Combine encrypted + authTag
    final ciphertext = Uint8List.fromList([...encrypted, ...authTag]);

    // Create cipher
    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(KeyParameter(key), 128, iv, Uint8List(0));
    cipher.init(false, params);

    // Decrypt
    final plaintext = cipher.process(ciphertext);

    return utf8.decode(plaintext);
  }

  /// Compute shared secret from ECDH
  Uint8List _computeSharedSecret(ECPrivateKey privateKey, ECPublicKey publicKey) {
    final agreement = ECDHBasicAgreement();
    agreement.init(privateKey);
    final shared = agreement.calculateAgreement(publicKey);
    return _bigIntToBytes(shared);
  }

  /// Derive session key from shared secret using PBKDF2
  Uint8List _deriveSessionKey(Uint8List sharedSecret) {
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64));
    pbkdf2.init(Pbkdf2Parameters(
      utf8.encode('delovahome-session'),
      100000,
      32,
    ));
    return pbkdf2.process(sharedSecret);
  }

  /// Encode EC public key to bytes
  Uint8List _encodePublicKey(ECPublicKey publicKey) {
    final x = _bigIntToBytes(publicKey.Q!.x!.toBigInteger()!);
    final y = _bigIntToBytes(publicKey.Q!.y!.toBigInteger()!);
    return Uint8List.fromList([0x04, ...x, ...y]); // Uncompressed format
  }

  /// Decode EC public key from bytes
  ECPublicKey _decodePublicKey(Uint8List bytes, ECDomainParameters params) {
    if (bytes[0] != 0x04) throw Exception('Invalid public key format');
    
    final keyLength = (bytes.length - 1) ~/ 2;
    final x = _bytesToBigInt(bytes.sublist(1, 1 + keyLength));
    final y = _bytesToBigInt(bytes.sublist(1 + keyLength));

    final point = params.curve.createPoint(x, y);
    return ECPublicKey(point, params);
  }

  /// Helper: BigInt to bytes
  Uint8List _bigIntToBytes(BigInt number) {
    final bytes = <int>[];
    var n = number;
    while (n > BigInt.zero) {
      bytes.insert(0, (n & BigInt.from(0xff)).toInt());
      n = n >> 8;
    }
    // Pad to 32 bytes
    while (bytes.length < 32) {
      bytes.insert(0, 0);
    }
    return Uint8List.fromList(bytes);
  }

  /// Helper: bytes to BigInt
  BigInt _bytesToBigInt(Uint8List bytes) {
    BigInt result = BigInt.zero;
    for (var byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }

  /// Generate random bytes
  Uint8List _generateRandomBytes(int length) {
    final random = SecureRandom('Fortuna');
    random.seed(KeyParameter(_generateSeed()));
    return random.nextBytes(length);
  }

  /// Generate seed for RNG
  Uint8List _generateSeed() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final random = List.generate(32, (i) => (now + i) % 256);
    return Uint8List.fromList(random);
  }

  String _generateClientId() {
    return 'client_${DateTime.now().millisecondsSinceEpoch}_${_generateRandomBytes(8).map((b) => b.toRadixString(16)).join()}';
  }

  String _generateRequestId() {
    return 'req_${DateTime.now().millisecondsSinceEpoch}_${_generateRandomBytes(4).map((b) => b.toRadixString(16)).join()}';
  }

  /// Disconnect from relay
  void disconnect() {
    _channel?.sink.close();
    _isConnected = false;
    _sessionKey = null;
    print('[Tunnel] Disconnected');
  }

  bool get isConnected => _isConnected;
}

/// Hub credentials storage
class TunnelCredentialsStorage {
  static const _keyHubId = 'tunnel_hub_id';
  static const _keyAccessToken = 'tunnel_access_token';
  static const _keyRelayUrl = 'tunnel_relay_url';

  static Future<void> saveCredentials({
    required String hubId,
    required String accessToken,
    String relayUrl = 'wss://relay.delovahome.com',
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyHubId, hubId);
    await prefs.setString(_keyAccessToken, accessToken);
    await prefs.setString(_keyRelayUrl, relayUrl);
  }

  static Future<Map<String, String>?> loadCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final hubId = prefs.getString(_keyHubId);
    final accessToken = prefs.getString(_keyAccessToken);
    final relayUrl = prefs.getString(_keyRelayUrl) ?? 'wss://relay.delovahome.com';

    if (hubId == null || accessToken == null) return null;

    return {
      'hubId': hubId,
      'accessToken': accessToken,
      'relayUrl': relayUrl,
    };
  }

  static Future<void> clearCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyHubId);
    await prefs.remove(_keyAccessToken);
    await prefs.remove(_keyRelayUrl);
  }
}
