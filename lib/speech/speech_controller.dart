import 'dart:async';

import 'package:flutter/foundation.dart';

import 'speech_platform_service.dart';

class SpeechController extends ChangeNotifier {
  SpeechController({required SpeechRecognitionService service})
    : _service = service;

  final SpeechRecognitionService _service;

  bool _initialized = false;
  bool _initializing = false;
  Completer<void>? _initializeCompleter;
  bool _speechEnabled = false;
  bool _isListening = false;
  String _committedText = '';
  String _partialText = '';
  String _statusMessage = 'Checking speech recognition...';
  String _errorMessage = '';

  bool get speechEnabled => _speechEnabled;

  bool get isListening => _isListening;

  String get recognizedText => _combinedTranscript;

  String get statusMessage => _statusMessage;

  String get errorMessage => _errorMessage;

  String get _combinedTranscript {
    if (_committedText.isEmpty) {
      return _partialText;
    }
    if (_partialText.isEmpty) {
      return _committedText;
    }
    return '$_committedText $_partialText';
  }

  bool get canStartListening => _speechEnabled && !_isListening;

  bool get hasTranscript => _combinedTranscript.trim().isNotEmpty;

  Future<void> initialize() async {
    if (_initializing) {
      await _initializeCompleter?.future;
      return;
    }
    if (_initialized && _speechEnabled) {
      return;
    }

    final initializeCompleter = Completer<void>();
    _initializing = true;
    _initializeCompleter = initializeCompleter;
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
          : _errorMessage.isNotEmpty
          ? _errorMessage
          : 'Speech recognition unavailable on this device.';
    } catch (_) {
      _speechEnabled = false;
      _errorMessage = 'Unable to initialize speech recognition.';
      _statusMessage = _errorMessage;
    } finally {
      _initializing = false;
      if (!initializeCompleter.isCompleted) {
        initializeCompleter.complete();
      }
      if (identical(_initializeCompleter, initializeCompleter)) {
        _initializeCompleter = null;
      }
    }

    notifyListeners();
  }

  Future<void> startListening() async {
    if (!_speechEnabled) {
      await initialize();
    }
    if (!_speechEnabled || _isListening) {
      return;
    }

    _committedText = '';
    _partialText = '';
    _errorMessage = '';
    _statusMessage = 'Starting speech recognition...';
    notifyListeners();

    final started = await _service.listen(
      onResult: _handleResult,
      partialResults: true,
      cancelOnError: true,
      localeId: 'ne-NP',
    );

    if (started) {
      _isListening = true;
      _statusMessage = 'Listening...';
    } else {
      _statusMessage = 'Unable to start listening.';
    }
    notifyListeners();
  }

  Future<void> stopListening() async {
    if (!_isListening) {
      return;
    }

    await _service.stop();
    _isListening = false;
    _statusMessage = _combinedTranscript.trim().isEmpty
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
    _statusMessage = _combinedTranscript.trim().isEmpty
        ? 'Ready to listen.'
        : 'Ready for another search.';
    notifyListeners();
  }

  void clearTranscript() {
    _committedText = '';
    _partialText = '';
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
      _statusMessage = _combinedTranscript.trim().isEmpty
          ? 'Ready to listen.'
          : 'Ready for another search.';
    } else {
      _statusMessage = status;
    }
    notifyListeners();
  }

  void _handleResult(SpeechRecognitionResult result) {
    if (result.finalResult) {
      _committedText = _appendTranscript(
        _committedText,
        result.recognizedWords,
      );
      _partialText = '';
    } else {
      _partialText = result.recognizedWords;
    }

    if (result.finalResult) {
      _statusMessage = _isListening
          ? 'Listening...'
          : _combinedTranscript.trim().isEmpty
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

  String _appendTranscript(String current, String next) {
    final trimmedNext = next.trim();
    if (trimmedNext.isEmpty) {
      return current;
    }
    final trimmedCurrent = current.trim();
    if (trimmedCurrent.isEmpty) {
      return trimmedNext;
    }
    return '$trimmedCurrent $trimmedNext';
  }

  @override
  void dispose() {
    if (_service.isListening) {
      unawaited(_service.cancel());
    }
    unawaited(_service.dispose());
    super.dispose();
  }
}
