import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';
import '../services/api_service.dart';
import '../utils/app_translations.dart';

class AIAssistantWidget extends StatefulWidget {
  const AIAssistantWidget({super.key});

  @override
  State<AIAssistantWidget> createState() => _AIAssistantWidgetState();
}

class _AIAssistantWidgetState extends State<AIAssistantWidget> {
  final TextEditingController _controller = TextEditingController();
  final ApiService _apiService = ApiService();
  final stt.SpeechToText _speech = stt.SpeechToText();
  
  bool _isLoading = false;
  bool _isListening = false;
  bool _speechEnabled = false;
  String _lang = 'nl';

  @override
  void initState() {
    super.initState();
    _loadLanguage();
    _initSpeech();
  }
  
  void _initSpeech() async {
    try {
      _speechEnabled = await _speech.initialize(
        onError: (e) => setState(() => _isListening = false),
        onStatus: (status) {
          if (mounted) {
             setState(() => _isListening = status == 'listening');
          }
        },
      );
    } catch (e) {
      debugPrint('Speech initialization error: $e');
    }
  }

  Future<void> _loadLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _lang = prefs.getString('language') ?? 'nl';
      });
    }
  }
  
  void _listen() async {
    // 1. Check Permissions First
    var micStatus = await Permission.microphone.status;
    var speechStatus = await Permission.speech.status;

    if (!micStatus.isGranted || !speechStatus.isGranted) {
      Map<Permission, PermissionStatus> statuses = await [
        Permission.microphone,
        Permission.speech,
      ].request();

      if (statuses[Permission.microphone] != PermissionStatus.granted || 
          statuses[Permission.speech] != PermissionStatus.granted) {
         if (mounted) {
           ScaffoldMessenger.of(context).showSnackBar(SnackBar(
             content: Text('Permissions missing: Mic=${statuses[Permission.microphone]}, Speech=${statuses[Permission.speech]}')
           ));
         }
         return;
      }
    }

    // 2. Initialize if not ready
    if (!_speechEnabled) {
      bool available = await _speech.initialize(
        onError: (e) {
          debugPrint('Speech error: $e');
          if (mounted) setState(() => _isListening = false);
        },
        onStatus: (status) {
          debugPrint('Speech status: $status');
          if (mounted) {
             setState(() => _isListening = status == 'listening');
          }
        },
      );
      
      if (mounted) {
        setState(() => _speechEnabled = available);
      }
      
      if (!available) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Speech recognition not available')));
        return;
      }
    }

    // 3. Toggle Listening
    if (_isListening) {
      await _speech.stop();
    } else {
      await _speech.listen(
        onResult: (result) {
          setState(() {
            _controller.text = result.recognizedWords;
          });
          
          if (result.finalResult) {
            // Fix common speech-to-text concatenation artifacts
            if (_controller.text.toLowerCase().startsWith('turnlights')) {
               _controller.text = _controller.text.replaceFirst(RegExp('Turnlights', caseSensitive: false), 'Turn lights');
            }
            
            _sendCommand();
          }
        },
        listenOptions: stt.SpeechListenOptions(
          cancelOnError: true,
          localeId: _lang == 'en' ? 'en_US' : 'nl_NL',
        ),
      );
    }
  }

  String t(String key) => AppTranslations.get(key, lang: _lang);

  Future<void> _sendCommand() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    setState(() => _isLoading = true);
    try {
      final result = await _apiService.sendAICommand(text);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['message'] ?? 'Command sent'),
            backgroundColor: result['ok'] == true ? Colors.green : Colors.red,
          ),
        );
        if (result['ok'] == true) {
          _controller.clear();
        }
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final hintColor = isDark ? Colors.white54 : Colors.black54;
    final bgColor = isDark ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.05);
    final borderColor = isDark ? Colors.white.withValues(alpha: 0.2) : Colors.black.withValues(alpha: 0.1);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          const Icon(Icons.auto_awesome, color: Color(0xFF3B82F6)), // Blue
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _controller,
              style: TextStyle(color: textColor),
              decoration: InputDecoration(
                hintText: t('ask_ai'),
                hintStyle: TextStyle(color: hintColor),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              onSubmitted: (_) => _sendCommand(),
            ),
          ),
          IconButton(
            icon: Icon(
              _isListening ? Icons.mic : Icons.mic_none,
              color: _isListening ? Colors.redAccent : const Color(0xFF3B82F6),
            ),
            onPressed: _listen,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: _isLoading 
              ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: textColor))
              : const Icon(Icons.send, color: Color(0xFF3B82F6)),
            onPressed: _isLoading ? null : _sendCommand,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}
