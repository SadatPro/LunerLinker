// Enhanced LunerLinker Flutter App with Simplified Location Sharing
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:crypto/crypto.dart';

void main() {
  runApp(const MyApp());
}

// Simple encryption class
class MessageEncryption {
  static const String _appKey = "LunerLinker2024SecretKey";

  static String encrypt(String message) {
    List<int> bytes = utf8.encode(message);
    List<int> keyBytes = utf8.encode(_appKey);

    for (int i = 0; i < bytes.length; i++) {
      bytes[i] ^= keyBytes[i % keyBytes.length];
    }

    return base64.encode(bytes);
  }

  static String decrypt(String encryptedMessage) {
    try {
      List<int> bytes = base64.decode(encryptedMessage);
      List<int> keyBytes = utf8.encode(_appKey);

      for (int i = 0; i < bytes.length; i++) {
        bytes[i] ^= keyBytes[i % keyBytes.length];
      }

      return utf8.decode(bytes);
    } catch (e) {
      return encryptedMessage; // Return original if decryption fails
    }
  }

  static String encryptGhost(String message, String ghostCode) {
    List<int> bytes = utf8.encode(message);
    List<int> keyBytes = utf8.encode(ghostCode + _appKey);

    for (int i = 0; i < bytes.length; i++) {
      bytes[i] ^= keyBytes[i % keyBytes.length];
    }

    return "GHOST:" + base64.encode(bytes);
  }

  static String? decryptGhost(String encryptedMessage, String ghostCode) {
    try {
      if (!encryptedMessage.startsWith("GHOST:")) return null;

      String encrypted = encryptedMessage.substring(6);
      List<int> bytes = base64.decode(encrypted);
      List<int> keyBytes = utf8.encode(ghostCode + _appKey);

      for (int i = 0; i < bytes.length; i++) {
        bytes[i] ^= keyBytes[i % keyBytes.length];
      }

      return utf8.decode(bytes);
    } catch (e) {
      return null;
    }
  }
}

class LoRaMessage {
  final String content;
  final String originalContent;
  final DateTime timestamp;
  final bool isSent;
  final int? rssi;
  final bool isEncrypted;
  final bool isGhost;
  final bool canDecrypt;

  LoRaMessage({
    required this.content,
    required this.originalContent,
    required this.timestamp,
    required this.isSent,
    this.rssi,
    this.isEncrypted = false,
    this.isGhost = false,
    this.canDecrypt = true,
  });
}

class GPSData {
  final double latitude;
  final double longitude;
  final double? accuracy;
  final double? altitude;
  final DateTime timestamp;

  GPSData({
    required this.latitude,
    required this.longitude,
    this.accuracy,
    this.altitude,
    required this.timestamp,
  });

  String get formattedLocation =>
      '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}';
}

enum LocationFormat {
  coordinates,
  googleMapsLink,
  appleMapsLink,
  coordinatesWithAccuracy,
}

class LocationService {
  static final LocationService _instance = LocationService._internal();
  factory LocationService() => _instance;
  LocationService._internal();

  Future<bool> requestPermissions() async {
    try {
      final status = await Permission.location.request();
      print('[Location] Permission status: $status');
      return status == PermissionStatus.granted;
    } catch (e) {
      print('[Location] Permission request error: $e');
      return false;
    }
  }

  Future<GPSData?> getCurrentLocation() async {
    try {
      print('[Location] Getting current location...');

      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        print('[Location] Location services disabled');
        throw Exception('Location services are disabled');
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          print('[Location] Permissions denied');
          throw Exception('Location permissions are denied');
        }
      }

      if (permission == LocationPermission.deniedForever) {
        print('[Location] Permissions permanently denied');
        throw Exception('Location permissions are permanently denied');
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 15),
      );

      final gps = GPSData(
        latitude: position.latitude,
        longitude: position.longitude,
        accuracy: position.accuracy,
        altitude: position.altitude,
        timestamp: position.timestamp ?? DateTime.now(),
      );

      print('[Location] Got location: ${gps.formattedLocation} (±${gps.accuracy?.toStringAsFixed(0)}m)');
      return gps;
    } catch (e) {
      print('[Location] Error: $e');
      return null;
    }
  }
}

class ESP32Service {
  static final ESP32Service _instance = ESP32Service._internal();
  factory ESP32Service() => _instance;
  ESP32Service._internal();

  final String _esp32Ip = '192.168.4.1';
  bool _isConnected = false;
  int _connectionRetries = 0;
  static const int _maxRetries = 3;
  List<String> _processedMessageIds = []; // Track processed messages

  bool get isConnected => _isConnected;

  Future<bool> connect() async {
    _connectionRetries = 0;

    while (_connectionRetries < _maxRetries) {
      try {
        print("[ESP32] Connection attempt ${_connectionRetries + 1} to $_esp32Ip");

        final client = http.Client();
        try {
          final response = await client.get(
            Uri.parse('http://$_esp32Ip/status'),
            headers: {
              'Connection': 'close',
              'Cache-Control': 'no-cache',
            },
          ).timeout(
            const Duration(seconds: 8),
            onTimeout: () {
              throw TimeoutException('Connection timeout');
            },
          );

          if (response.statusCode == 200) {
            try {
              final data = json.decode(response.body);
              if (data['status'] == 'ok') {
                _isConnected = true;
                print("[ESP32] Successfully connected");
                return true;
              }
            } catch (e) {
              print("[ESP32] JSON parse error: $e");
            }
          }
        } finally {
          client.close();
        }
      } catch (e) {
        print("[ESP32] Connection attempt ${_connectionRetries + 1} failed: $e");
      }

      _connectionRetries++;
      if (_connectionRetries < _maxRetries) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }

    _isConnected = false;
    return false;
  }

  Future<bool> sendMessage(String message) async {
    if (!_isConnected) {
      print('[ESP32] Not connected - cannot send message');
      return false;
    }

    final client = http.Client();
    try {
      final payload = <String, dynamic>{
        'content': message,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      final jsonPayload = json.encode(payload);
      print('[ESP32] Sending payload: $jsonPayload');

      final response = await client.post(
        Uri.parse('http://$_esp32Ip/sendMessage'),
        headers: {
          'Content-Type': 'application/json',
          'Connection': 'close',
          'Cache-Control': 'no-cache',
        },
        body: jsonPayload,
      ).timeout(const Duration(seconds: 10));

      print('[ESP32] Send response: ${response.statusCode}');
      if (response.body.isNotEmpty) {
        print('[ESP32] Response body: ${response.body}');
      }

      return response.statusCode == 200;
    } catch (e) {
      print("[ESP32] Send error: $e");
      return false;
    } finally {
      client.close();
    }
  }

  Future<List<LoRaMessage>> getMessages(String ghostCode) async {
    if (!_isConnected) return [];

    final client = http.Client();
    try {
      final response = await client.get(
        Uri.parse('http://$_esp32Ip/getMessages'),
        headers: {
          'Connection': 'close',
          'Cache-Control': 'no-cache',
        },
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        print('[ESP32] Raw response: ${response.body}');

        if (response.body.trim().isEmpty) {
          print('[ESP32] Empty response body');
          return [];
        }

        dynamic responseData;
        try {
          responseData = json.decode(response.body);
        } catch (e) {
          print('[ESP32] JSON decode error: $e');
          return [];
        }

        if (responseData is! List) {
          print('[ESP32] Response is not a list: ${responseData.runtimeType}');
          return [];
        }

        List<dynamic> messagesJson = responseData;
        print('[ESP32] Processing ${messagesJson.length} messages');

        List<LoRaMessage> newMessages = [];

        for (var json in messagesJson) {
          try {
            // Create unique ID for message deduplication
            final messageId = '${json['content']}_${json['timestamp']}';
            if (_processedMessageIds.contains(messageId)) {
              print('[ESP32] Skipping duplicate message: $messageId');
              continue;
            }

            final rawContent = json['content'] ?? '';
            print('[ESP32] Processing message: ${rawContent.substring(0, math.min(50, rawContent.length))}...');

            String displayContent = rawContent;
            bool isEncrypted = false;
            bool isGhost = false;
            bool canDecrypt = true;

            // Handle encryption
            if (rawContent.startsWith("GHOST:")) {
              isGhost = true;
              isEncrypted = true;
              final decrypted = MessageEncryption.decryptGhost(rawContent, ghostCode);
              if (decrypted != null) {
                displayContent = decrypted;
              } else {
                displayContent = "Ghost message (wrong code)";
                canDecrypt = false;
              }
            } else {
              final decrypted = MessageEncryption.decrypt(rawContent);
              if (decrypted != rawContent) {
                isEncrypted = true;
                displayContent = decrypted;
              }
            }

            final message = LoRaMessage(
              content: displayContent,
              originalContent: rawContent,
              timestamp: DateTime.fromMillisecondsSinceEpoch(
                  json['timestamp'] ?? DateTime.now().millisecondsSinceEpoch
              ),
              isSent: false,
              rssi: json['rssi'],
              isEncrypted: isEncrypted,
              isGhost: isGhost,
              canDecrypt: canDecrypt,
            );

            newMessages.add(message);
            _processedMessageIds.add(messageId);

            // Keep only recent message IDs to prevent memory leak
            if (_processedMessageIds.length > 100) {
              _processedMessageIds.removeRange(0, 50);
            }

            print('[ESP32] Created message: ${message.content}');
          } catch (e) {
            print('[ESP32] Error processing individual message: $e');
            continue;
          }
        }

        print('[ESP32] Returning ${newMessages.length} new messages');
        return newMessages;
      } else {
        print('[ESP32] HTTP error: ${response.statusCode}');
      }
    } catch (e) {
      print('[ESP32] Get messages error: $e');
      if (e.toString().contains('Connection refused') ||
          e.toString().contains('No route to host')) {
        _isConnected = false;
      }
    } finally {
      client.close();
    }
    return [];
  }

  Future<Map<String, dynamic>?> getStatus() async {
    if (!_isConnected) return null;

    final client = http.Client();
    try {
      final response = await client.get(
        Uri.parse('http://$_esp32Ip/status'),
        headers: {
          'Connection': 'close',
          'Cache-Control': 'no-cache',
        },
      ).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
    } catch (e) {
      print('[ESP32] Status check error: $e');
      _isConnected = false;
    } finally {
      client.close();
    }
    return null;
  }

  // Clear processed messages (useful for testing)
  void clearProcessedMessages() {
    _processedMessageIds.clear();
    print('[ESP32] Cleared processed messages cache');
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LunerLinker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0088CC),
          brightness: Brightness.light,
        ).copyWith(
          primary: const Color(0xFF0088CC),
          surface: const Color(0xFFF5F5F5),
          surfaceVariant: const Color(0xFFEFEFF3),
        ),
        fontFamily: 'SF Pro Text',
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          elevation: 0.5,
          backgroundColor: Color(0xFF0088CC),
          foregroundColor: Colors.white,
          titleTextStyle: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(25),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF8774E1),
          brightness: Brightness.dark,
        ).copyWith(
          primary: const Color(0xFF8774E1),
          surface: const Color(0xFF1C1C1E),
          surfaceVariant: const Color(0xFF2C2C2E),
          background: const Color(0xFF000000),
        ),
        fontFamily: 'SF Pro Text',
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          elevation: 0.5,
          backgroundColor: Color(0xFF1C1C1E),
          foregroundColor: Colors.white,
          titleTextStyle: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF2C2C2E),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(25),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      home: const ChatScreen(),
    );
  }
}

enum ChatMode { normal, ghost }

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with TickerProviderStateMixin {
  final ESP32Service _esp32Service = ESP32Service();
  final LocationService _locationService = LocationService();
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _ghostCodeController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  ChatMode _chatMode = ChatMode.normal;
  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isSending = false;
  bool _isGettingLocation = false;
  bool _encryptMessages = true;
  List<LoRaMessage> _messages = [];
  Timer? _messageTimer;
  Timer? _statusTimer;
  Map<String, dynamic>? _lastStatus;
  GPSData? _currentLocation;
  String _ghostCode = '';
  LocationFormat _selectedLocationFormat = LocationFormat.coordinates;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
    _animationController.forward();

    _connectToESP32();
    _requestLocationPermission();
  }

  @override
  void dispose() {
    _messageController.dispose();
    _ghostCodeController.dispose();
    _scrollController.dispose();
    _animationController.dispose();
    _messageTimer?.cancel();
    _statusTimer?.cancel();
    super.dispose();
  }

  Future<void> _requestLocationPermission() async {
    await _locationService.requestPermissions();
  }

  void _connectToESP32() async {
    if (_isConnecting) return;

    setState(() {
      _isConnecting = true;
    });

    final connected = await _esp32Service.connect();

    setState(() {
      _isConnected = connected;
      _isConnecting = false;
    });

    if (connected) {
      _startTimers();
      _showSnackBar('Connected to LunerLinker!', Colors.green);
    } else {
      _stopTimers();
      _showSnackBar('Connection failed. Check WiFi connection.', Colors.red);
    }
  }

  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  void _startTimers() {
    _messageTimer = Timer.periodic(const Duration(milliseconds: 2000), (timer) async {
      if (!_isConnected) {
        timer.cancel();
        return;
      }

      final newMessages = await _esp32Service.getMessages(_ghostCode);
      if (newMessages.isNotEmpty) {
        setState(() {
          _messages.addAll(newMessages);
        });
        _scrollToBottom();
      }
    });

    _statusTimer = Timer.periodic(const Duration(seconds: 15), (timer) async {
      if (!_isConnected) {
        timer.cancel();
        return;
      }

      final status = await _esp32Service.getStatus();
      if (status != null) {
        setState(() {
          _lastStatus = status;
        });
      } else {
        setState(() {
          _isConnected = false;
        });
        timer.cancel();
        _messageTimer?.cancel();
      }
    });
  }

  void _stopTimers() {
    _messageTimer?.cancel();
    _statusTimer?.cancel();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _getCurrentLocation() async {
    setState(() {
      _isGettingLocation = true;
    });

    try {
      final location = await _locationService.getCurrentLocation();
      setState(() {
        _currentLocation = location;
        _isGettingLocation = false;
      });

      if (location == null) {
        _showSnackBar('Failed to get location', Colors.orange);
      } else {
        _showSnackBar('Location updated: ±${location.accuracy?.toStringAsFixed(0)}m', Colors.green);
      }
    } catch (e) {
      setState(() {
        _isGettingLocation = false;
      });
      _showSnackBar('Location error', Colors.red);
    }
  }

  String _getSimpleLocationText() {
    if (_currentLocation == null) return '';

    switch (_selectedLocationFormat) {
      case LocationFormat.coordinates:
        return '${_currentLocation!.latitude.toStringAsFixed(6)}, ${_currentLocation!.longitude.toStringAsFixed(6)}';

      case LocationFormat.googleMapsLink:
        return 'https://www.google.com/maps?q=${_currentLocation!.latitude},${_currentLocation!.longitude}';

      case LocationFormat.appleMapsLink:
        return 'https://maps.apple.com/?q=${_currentLocation!.latitude},${_currentLocation!.longitude}';

      case LocationFormat.coordinatesWithAccuracy:
        final accuracy = _currentLocation!.accuracy?.toStringAsFixed(0) ?? '?';
        return '${_currentLocation!.latitude.toStringAsFixed(6)}, ${_currentLocation!.longitude.toStringAsFixed(6)} (±${accuracy}m)';

      default:
        return '${_currentLocation!.latitude.toStringAsFixed(6)}, ${_currentLocation!.longitude.toStringAsFixed(6)}';
    }
  }

  void _sendLocationOnly() async {
    if (!_isConnected || _currentLocation == null) return;

    setState(() {
      _isSending = true;
    });

    // Simple location text based on selected format
    final String locationText = _getSimpleLocationText();

    String messageToSend = locationText;
    if (_chatMode == ChatMode.ghost && _ghostCode.isNotEmpty) {
      messageToSend = MessageEncryption.encryptGhost(locationText, _ghostCode);
    } else if (_encryptMessages) {
      messageToSend = MessageEncryption.encrypt(locationText);
    }

    final sentMessage = LoRaMessage(
      content: locationText,
      originalContent: messageToSend,
      timestamp: DateTime.now(),
      isSent: true,
      isEncrypted: _encryptMessages || _chatMode == ChatMode.ghost,
      isGhost: _chatMode == ChatMode.ghost,
    );

    setState(() {
      _messages.add(sentMessage);
    });

    _scrollToBottom();

    // Send only the text, no GPS data object
    final success = await _esp32Service.sendMessage(messageToSend);

    setState(() {
      _isSending = false;
    });

    if (!success) {
      _showSnackBar('Failed to send location', Colors.red);
    }

    HapticFeedback.lightImpact();
  }

  void _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isSending) return;

    if (!_isConnected) {
      _showSnackBar('Not connected to LunerLinker', Colors.orange);
      return;
    }

    if (text.length > 200) {
      _showSnackBar('Message too long (max 200 chars)', Colors.orange);
      return;
    }

    setState(() {
      _isSending = true;
    });

    // Prepare message for sending
    String messageToSend = text;
    if (_chatMode == ChatMode.ghost) {
      if (_ghostCode.isEmpty) {
        _showSnackBar('Enter ghost code first', Colors.orange);
        setState(() {
          _isSending = false;
        });
        return;
      }
      messageToSend = MessageEncryption.encryptGhost(text, _ghostCode);
    } else if (_encryptMessages) {
      messageToSend = MessageEncryption.encrypt(text);
    }

    // Add message to UI immediately
    final sentMessage = LoRaMessage(
      content: text,
      originalContent: messageToSend,
      timestamp: DateTime.now(),
      isSent: true,
      isEncrypted: _encryptMessages || _chatMode == ChatMode.ghost,
      isGhost: _chatMode == ChatMode.ghost,
    );

    setState(() {
      _messages.add(sentMessage);
    });

    _messageController.clear();
    _scrollToBottom();

    // Send via ESP32
    final success = await _esp32Service.sendMessage(messageToSend);

    setState(() {
      _isSending = false;
    });

    if (!success) {
      _showSnackBar('Failed to send message', Colors.red);
    } else {
      print('[UI] Message sent successfully');
    }

    HapticFeedback.lightImpact();
  }

  void _showGhostCodeDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.visibility_off, color: Colors.purple),
            SizedBox(width: 8),
            Text('Secret Chat'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter a secret code to access ghost messages. Only users with the same code can see these messages.',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _ghostCodeController,
              decoration: const InputDecoration(
                labelText: 'Secret Code',
                prefixIcon: Icon(Icons.key),
              ),
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() {
                _ghostCode = _ghostCodeController.text;
              });
              Navigator.pop(context);
              _showSnackBar('Secret code set', Colors.purple);
            },
            child: const Text('Set Code'),
          ),
        ],
      ),
    );
  }

  void _clearMessages() {
    setState(() {
      _messages.clear();
    });
    _esp32Service.clearProcessedMessages();
    _showSnackBar('Messages cleared', Colors.blue);
  }

  Widget _buildSimpleLocationOptions(bool isDark) {
    if (_currentLocation == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          // Location format dropdown
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF2C2C2E) : const Color(0xFFF2F2F7),
              borderRadius: BorderRadius.circular(16),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<LocationFormat>(
                value: _selectedLocationFormat,
                isDense: true,
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white : Colors.black87,
                ),
                dropdownColor: isDark ? const Color(0xFF2C2C2E) : Colors.white,
                items: const [
                  DropdownMenuItem(
                    value: LocationFormat.coordinates,
                    child: Text('Coordinates'),
                  ),
                ],
                onChanged: (LocationFormat? newFormat) {
                  if (newFormat != null) {
                    setState(() {
                      _selectedLocationFormat = newFormat;
                    });
                  }
                },
              ),
            ),
          ),

          const SizedBox(width: 8),

          // Preview of what will be sent
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _getSimpleLocationText(),
                style: TextStyle(
                  fontSize: 11,
                  color: isDark ? Colors.white70 : Colors.black54,
                  fontFamily: 'monospace',
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),

          const SizedBox(width: 8),

          // Send location button
          GestureDetector(
            onTap: _sendLocationOnly,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF0088CC),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.send_outlined, size: 14, color: Colors.white),
                  SizedBox(width: 4),
                  Text(
                    'Send',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageContent(LoRaMessage message, bool isMe, bool isDark) {
    // Check if message is a location link
    if (message.content.startsWith('https://www.google.com/maps') ||
        message.content.startsWith('https://maps.apple.com/')) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.location_on,
                size: 16,
                color: isMe ? Colors.white : Colors.red,
              ),
              const SizedBox(width: 4),
              Text(
                'Shared Location',
                style: TextStyle(
                  color: isMe
                      ? Colors.white
                      : (isDark ? Colors.white : Colors.black87),
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          GestureDetector(
            onTap: () async {
              try {
                final Uri url = Uri.parse(message.content);
                if (await canLaunchUrl(url)) {
                  await launchUrl(url, mode: LaunchMode.externalApplication);
                } else {
                  _showSnackBar('Could not open map', Colors.red);
                }
              } catch (e) {
                _showSnackBar('Error opening map', Colors.red);
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.2),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.blue.withOpacity(0.3)),
              ),
              child: const Text(
                'Tap to open map',
                style: TextStyle(
                  color: Colors.blue,
                  fontSize: 13,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ),
        ],
      );
    }

    // Check if message contains coordinates
    final coordRegex = RegExp(r'^-?\d+\.\d+,\s*-?\d+\.\d+');
    if (coordRegex.hasMatch(message.content)) {
      final coords = message.content.split(',');
      if (coords.length >= 2) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.location_on,
                  size: 16,
                  color: isMe ? Colors.white : Colors.red,
                ),
                const SizedBox(width: 4),
                Text(
                  'Location',
                  style: TextStyle(
                    color: isMe
                        ? Colors.white
                        : (isDark ? Colors.white : Colors.black87),
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              message.content,
              style: TextStyle(
                color: isMe
                    ? Colors.white.withOpacity(0.9)
                    : (isDark ? Colors.white70 : Colors.black54),
                fontSize: 14,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 4),
            GestureDetector(
              onTap: () async {
                final lat = double.tryParse(coords[0].trim());
                final lng = double.tryParse(coords[1].trim());
                if (lat != null && lng != null) {
                  final url = 'https://www.google.com/maps?q=$lat,$lng';
                  final Uri uri = Uri.parse(url);
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.blue.withOpacity(0.3)),
                ),
                child: const Text(
                  'Open in Maps',
                  style: TextStyle(
                    color: Colors.blue,
                    fontSize: 13,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ),
          ],
        );
      }
    }

    // Regular text message
    return Text(
      message.content,
      style: TextStyle(
        color: isMe
            ? Colors.white
            : (isDark ? Colors.white : Colors.black87),
        fontSize: 16,
        fontWeight: FontWeight.w400,
        fontStyle: !message.canDecrypt ? FontStyle.italic : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _chatMode == ChatMode.ghost ? 'Secret Chat' : 'LunerLinker',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            Text(
              _isConnected ? 'online' : 'connecting...',
              style: TextStyle(
                fontSize: 13,
                color: Colors.white.withOpacity(0.8),
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
        backgroundColor: _chatMode == ChatMode.ghost
            ? Colors.purple
            : (isDark ? const Color(0xFF1C1C1E) : const Color(0xFF0088CC)),
        actions: [
          // Clear messages button
          IconButton(
            onPressed: _clearMessages,
            icon: const Icon(Icons.clear_all, size: 20),
            tooltip: 'Clear Messages',
          ),
          // Location button
          IconButton(
            onPressed: _isGettingLocation ? null : _getCurrentLocation,
            icon: _isGettingLocation
                ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
                : Icon(
              Icons.location_on,
              color: _currentLocation != null
                  ? Colors.white
                  : Colors.white.withOpacity(0.6),
            ),
            tooltip: _currentLocation != null
                ? 'Location: ${_currentLocation!.formattedLocation}'
                : 'Get Location',
          ),
          // Connection status
          IconButton(
            onPressed: _connectToESP32,
            icon: _isConnecting
                ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
                : Icon(
              _isConnected ? Icons.radio : Icons.radio_button_off,
              color: _isConnected ? Colors.white : Colors.white.withOpacity(0.6),
            ),
            tooltip: _isConnected ? 'Connected' : 'Not Connected',
          ),
        ],
      ),
      body: Column(
        children: [
          // Chat mode toggle bar
          Container(
            color: isDark ? const Color(0xFF2C2C2E) : Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      _buildModeButton(
                        'Normal Chat',
                        Icons.chat_bubble_outline,
                        ChatMode.normal,
                        isDark,
                      ),
                      const SizedBox(width: 8),
                      _buildModeButton(
                        'Secret Chat',
                        Icons.visibility_off,
                        ChatMode.ghost,
                        isDark,
                      ),
                    ],
                  ),
                ),
                if (_chatMode == ChatMode.ghost)
                  IconButton(
                    onPressed: _showGhostCodeDialog,
                    icon: Icon(
                      Icons.key,
                      color: _ghostCode.isNotEmpty ? Colors.purple : Colors.grey,
                      size: 20,
                    ),
                  ),
              ],
            ),
          ),

          // Status bar
          if (_isConnected && _currentLocation != null)
            Container(
              color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF0F0F0),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.location_on, size: 14, color: Colors.green),
                  const SizedBox(width: 4),
                  Text(
                    'Location: ±${_currentLocation!.accuracy?.toStringAsFixed(0) ?? "?"}m accuracy',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white70 : Colors.black54,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${_messages.length} messages',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white70 : Colors.black54,
                    ),
                  ),
                ],
              ),
            ),

          // Messages list
          Expanded(
            child: _messages.isEmpty
                ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _chatMode == ChatMode.ghost
                        ? Icons.visibility_off
                        : Icons.radio,
                    size: 64,
                    color: Colors.grey.withOpacity(0.5),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _isConnected
                        ? (_chatMode == ChatMode.ghost
                        ? 'Secret chat is active\nMessages are end-to-end encrypted'
                        : 'No messages here yet...\nSend your first LoRa message!')
                        : _isConnecting
                        ? 'Connecting to LunerLinker...'
                        : 'Connect to LunerLinker to start',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.grey.withOpacity(0.8),
                      fontSize: 15,
                    ),
                  ),
                  if (!_isConnected && !_isConnecting) ...[
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: _connectToESP32,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try Again'),
                    ),
                  ],
                ],
              ),
            )
                : ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                return _buildSimpleMessage(_messages[index], isDark);
              },
            ),
          ),

          // Input area
          _buildTelegramInputArea(isDark),
        ],
      ),
    );
  }

  Widget _buildModeButton(String text, IconData icon, ChatMode mode, bool isDark) {
    final isSelected = _chatMode == mode;

    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            _chatMode = mode;
          });
          if (mode == ChatMode.ghost && _ghostCode.isEmpty) {
            _showGhostCodeDialog();
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? (mode == ChatMode.ghost ? Colors.purple : const Color(0xFF0088CC))
                : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: isSelected
                    ? Colors.white
                    : (isDark ? Colors.white70 : Colors.black54),
              ),
              const SizedBox(width: 6),
              Text(
                text,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: isSelected
                      ? Colors.white
                      : (isDark ? Colors.white70 : Colors.black54),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSimpleMessage(LoRaMessage message, bool isDark) {
    final isMe = message.isSent;

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: EdgeInsets.only(
        left: isMe ? 64 : 8,
        right: isMe ? 8 : 64,
        bottom: 4,
      ),
      child: Column(
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Container(
            decoration: BoxDecoration(
              color: isMe
                  ? (message.isGhost ? Colors.purple : const Color(0xFF0088CC))
                  : (isDark ? const Color(0xFF2C2C2E) : Colors.white),
              borderRadius: BorderRadius.circular(18).copyWith(
                bottomLeft: Radius.circular(isMe ? 18 : 4),
                bottomRight: Radius.circular(isMe ? 4 : 18),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.08),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Message content with encryption indicators
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (message.isEncrypted)
                      Padding(
                        padding: const EdgeInsets.only(right: 6, top: 1),
                        child: Icon(
                          message.isGhost ? Icons.visibility_off : Icons.lock,
                          size: 12,
                          color: isMe
                              ? Colors.white.withOpacity(0.8)
                              : (isDark ? Colors.white70 : Colors.black54),
                        ),
                      ),
                    if (!message.canDecrypt)
                      Padding(
                        padding: const EdgeInsets.only(right: 6, top: 1),
                        child: const Icon(
                          Icons.help_outline,
                          size: 12,
                          color: Colors.orange,
                        ),
                      ),
                    Flexible(
                      child: _buildMessageContent(message, isMe, isDark),
                    ),
                  ],
                ),

                // Timestamp and metadata
                const SizedBox(height: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${message.timestamp.hour.toString().padLeft(2, '0')}:${message.timestamp.minute.toString().padLeft(2, '0')}',
                      style: TextStyle(
                        fontSize: 12,
                        color: isMe
                            ? Colors.white.withOpacity(0.7)
                            : (isDark ? Colors.white54 : Colors.black38),
                      ),
                    ),
                    if (message.rssi != null && !isMe) ...[
                      const SizedBox(width: 8),
                      Icon(
                        _getSignalIcon(message.rssi!),
                        size: 12,
                        color: _getSignalColor(message.rssi!),
                      ),
                      const SizedBox(width: 2),
                      Text(
                        '${message.rssi}dBm',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? Colors.white54 : Colors.black38,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                    if (isMe) ...[
                      const SizedBox(width: 6),
                      Icon(
                        Icons.done,
                        size: 14,
                        color: Colors.white.withOpacity(0.8),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTelegramInputArea(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
        border: Border(
          top: BorderSide(
            color: isDark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA),
            width: 0.5,
          ),
        ),
      ),
      child: Column(
        children: [
          // Simple location options
          _buildSimpleLocationOptions(isDark),

          if (_currentLocation != null) const SizedBox(height: 8),

          // Encryption toggle (only for normal mode when no location)
          if (_chatMode == ChatMode.normal && _currentLocation == null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _encryptMessages = !_encryptMessages;
                      });
                    },
                    child: Row(
                      children: [
                        Icon(
                          _encryptMessages ? Icons.lock : Icons.lock_open,
                          size: 18,
                          color: _encryptMessages ? Colors.green : Colors.grey,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Encrypt Messages',
                          style: TextStyle(
                            fontSize: 14,
                            color: _encryptMessages
                                ? Colors.green
                                : (isDark ? Colors.white70 : Colors.black54),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

          if (_chatMode == ChatMode.normal && _currentLocation == null)
            const SizedBox(height: 8),

          // Message input row
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Text input field
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 100),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF2C2C2E) : const Color(0xFFF2F2F7),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: TextField(
                    controller: _messageController,
                    maxLines: null,
                    maxLength: 200,
                    decoration: InputDecoration(
                      hintText: _isConnected
                          ? (_chatMode == ChatMode.ghost
                          ? 'Secret message...'
                          : 'Message')
                          : 'Connect to send messages',
                      hintStyle: TextStyle(
                        color: isDark ? Colors.white38 : Colors.black38,
                        fontSize: 16,
                      ),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      counterText: '',
                      suffixIcon: _messageController.text.isNotEmpty
                          ? IconButton(
                        onPressed: () {
                          _messageController.clear();
                          setState(() {});
                        },
                        icon: const Icon(
                          Icons.close,
                          color: Colors.grey,
                          size: 20,
                        ),
                      )
                          : null,
                    ),
                    style: TextStyle(
                      color: isDark ? Colors.white : Colors.black87,
                      fontSize: 16,
                    ),
                    onSubmitted: (_) => _sendMessage(),
                    onChanged: (_) => setState(() {}),
                    enabled: true,
                  ),
                ),
              ),

              const SizedBox(width: 8),

              // Send button
              GestureDetector(
                onTap: (_isConnected &&
                    !_isSending &&
                    _messageController.text.trim().isNotEmpty)
                    ? _sendMessage
                    : null,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: (_isConnected &&
                        !_isSending &&
                        _messageController.text.trim().isNotEmpty)
                        ? (_chatMode == ChatMode.ghost ? Colors.purple : const Color(0xFF0088CC))
                        : Colors.grey.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: _isSending
                      ? const Padding(
                    padding: EdgeInsets.all(9.0),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                      : const Icon(
                    Icons.send,
                    size: 18,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  IconData _getSignalIcon(int rssi) {
    if (rssi > -50) return Icons.signal_cellular_4_bar;
    if (rssi > -70) return Icons.signal_cellular_alt;
    if (rssi > -85) return Icons.signal_cellular_alt_1_bar;
    if (rssi > -100) return Icons.signal_cellular_alt_2_bar;
    return Icons.signal_cellular_0_bar;
  }

  Color _getSignalColor(int rssi) {
    if (rssi > -50) return Colors.green;
    if (rssi > -70) return Colors.orange;
    return Colors.red;
  }
}