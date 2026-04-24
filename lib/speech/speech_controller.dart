import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';

import 'speech_platform_service.dart';

enum SpeechLanguageMode { english, hindi, nepali }

extension SpeechLanguageModeDetails on SpeechLanguageMode {
  String get label {
    switch (this) {
      case SpeechLanguageMode.english:
        return 'English';
      case SpeechLanguageMode.hindi:
        return 'Hindi';
      case SpeechLanguageMode.nepali:
        return 'Nepali';
    }
  }

  String get localeId {
    switch (this) {
      case SpeechLanguageMode.english:
        return 'en-US';
      case SpeechLanguageMode.hindi:
        return 'hi-IN';
      case SpeechLanguageMode.nepali:
        return 'ne-NP';
    }
  }
}

class SpeechController extends ChangeNotifier {
  SpeechController({required SpeechRecognitionService service})
    : _service = service;

  final SpeechRecognitionService _service;

  bool _initialized = false;
  bool _speechEnabled = false;
  bool _isListening = false;
  String _recognizedText = '';
  String _statusMessage = 'Checking speech recognition...';
  String _errorMessage = '';
  SpeechLanguageMode _selectedLanguage = SpeechLanguageMode.english;

  bool get speechEnabled => _speechEnabled;

  bool get isListening => _isListening;

  String get recognizedText => _recognizedText;

  String get statusMessage => _statusMessage;

  String get errorMessage => _errorMessage;

  SpeechLanguageMode get selectedLanguage => _selectedLanguage;

  bool get canStartListening => _speechEnabled && !_isListening;

  bool get hasTranscript => _recognizedText.trim().isNotEmpty;

  List<SpeechLanguageMode> get supportedLanguages => SpeechLanguageMode.values;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    _statusMessage = 'Checking speech recognition...';
    notifyListeners();

    try {
      _speechEnabled = await _service.initialize(
        onStatus: _handleStatus,
        onError: _handleError,
      );
      _statusMessage = _speechEnabled
          ? 'Ready to listen.'
          : 'Speech recognition unavailable on this device.';
    } catch (_) {
      _speechEnabled = false;
      _errorMessage = 'Unable to initialize speech recognition.';
      _statusMessage = _errorMessage;
    }

    notifyListeners();
  }

  Future<void> startListening() async {
    if (!_initialized) {
      await initialize();
    }
    if (!_speechEnabled || _isListening) {
      return;
    }

    _recognizedText = '';
    _errorMessage = '';
    _statusMessage = 'Starting speech recognition...';
    notifyListeners();

    final started = await _service.listen(
      onResult: _handleResult,
      partialResults: true,
      cancelOnError: true,
      localeId: _selectedLanguage.localeId,
    );

    if (started) {
      _isListening = true;
      _statusMessage = 'Listening...';
    } else {
      _statusMessage = 'Unable to start listening.';
    }
    notifyListeners();
  }

  void selectLanguage(SpeechLanguageMode language) {
    if (_selectedLanguage == language || _isListening) {
      return;
    }

    _selectedLanguage = language;
    _errorMessage = '';
    if (_speechEnabled) {
      _statusMessage = 'Ready to listen.';
    }
    notifyListeners();
  }

  Future<void> stopListening() async {
    if (!_isListening) {
      return;
    }

    await _service.stop();
    _isListening = false;
    _statusMessage = _recognizedText.isEmpty
        ? 'Ready to listen.'
        : 'Ready for another search.';
    notifyListeners();
  }

  Future<void> cancelListening() async {
    if (!_isListening) {
      return;
    }

    await _service.cancel();
    _isListening = false;
    _statusMessage = _recognizedText.isEmpty
        ? 'Ready to listen.'
        : 'Ready for another search.';
    notifyListeners();
  }

  void clearTranscript() {
    _recognizedText = '';
    _errorMessage = '';
    _statusMessage = _speechEnabled
        ? 'Ready to listen.'
        : 'Speech recognition unavailable on this device.';
    notifyListeners();
  }

  void _handleStatus(String status) {
    if (status == 'listening') {
      _isListening = true;
      _statusMessage = 'Listening...';
    } else if (status == 'notListening' ||
        status == 'done' ||
        status == 'doneNoResult') {
      _isListening = false;
      _statusMessage = _recognizedText.isEmpty
          ? 'Ready to listen.'
          : 'Ready for another search.';
    } else {
      _statusMessage = status;
    }
    notifyListeners();
  }

  void _handleResult(SpeechRecognitionResult result) {
    _recognizedText = result.recognizedWords;
    if (result.finalResult) {
      _isListening = false;
      _statusMessage = _recognizedText.isEmpty
          ? 'Ready to listen.'
          : 'Ready for another search.';
    } else {
      _statusMessage = 'Listening...';
    }
    notifyListeners();
  }

  void _handleError(SpeechRecognitionError error) {
    _errorMessage = _describeError(error);
    if (error.permanent) {
      _isListening = false;
    }
    _statusMessage = _errorMessage;
    notifyListeners();
  }

  String _describeError(SpeechRecognitionError error) {
    switch (error.errorMsg) {
      case 'error_permission':
        return 'Microphone permission is required for speech recognition.';
      case 'error_speech_recognizer_disabled':
        return 'Speech recognition is disabled on this device.';
      case 'error_language_not_supported':
        return 'The selected language is not supported on this device.';
      case 'error_language_unavailable':
        return 'The selected language is unavailable right now.';
      case 'speech_not_supported':
      case 'not supported':
        return 'Speech recognition is not supported on this platform.';
      default:
        return 'Speech recognition error: ${error.errorMsg.replaceAll('_', ' ')}';
    }
  }

  @override
  void dispose() {
    if (_service.isListening) {
      unawaited(_service.cancel());
    }
    super.dispose();
  }
}
