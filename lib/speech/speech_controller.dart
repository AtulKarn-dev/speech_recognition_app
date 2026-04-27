import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';

import 'speech_platform_service.dart';
import 'speech_session_store.dart';

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
  SpeechController({
    required SpeechRecognitionService service,
    required SpeechSessionStore sessionStore,
  }) : _service = service,
       _sessionStore = sessionStore;

  final SpeechRecognitionService _service;
  final SpeechSessionStore _sessionStore;

  bool _initialized = false;
  bool _speechEnabled = false;
  bool _isListening = false;
  bool _shouldBeListening = false;
  bool _isStarting = false;
  bool _restartQueued = false;
  bool _isDisposed = false;
  bool _sessionStored = false;
  bool _isPersistingSession = false;
  String _committedText = '';
  String _liveText = '';
  String _statusMessage = 'Checking speech recognition...';
  String _errorMessage = '';
  SpeechLanguageMode _selectedLanguage = SpeechLanguageMode.english;

  bool get speechEnabled => _speechEnabled;

  bool get isListening => _isListening || _shouldBeListening || _isStarting;

  String get recognizedText => _joinTranscript(_committedText, _liveText);

  String get statusMessage => _statusMessage;

  String get errorMessage => _errorMessage;

  SpeechLanguageMode get selectedLanguage => _selectedLanguage;

  bool get canStartListening =>
      _speechEnabled && !_isListening && !_shouldBeListening && !_isStarting;

  bool get hasTranscript => recognizedText.trim().isNotEmpty;

  List<SpeechLanguageMode> get supportedLanguages => SpeechLanguageMode.values;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    _statusMessage = 'Checking speech recognition...';
    _notifyListeners();

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

    _notifyListeners();
  }

  Future<void> startListening() async {
    if (!_initialized) {
      await initialize();
    }
    if (!_speechEnabled || _isListening || _shouldBeListening || _isStarting) {
      return;
    }

    _committedText = '';
    _liveText = '';
    _shouldBeListening = true;
    _sessionStored = false;
    _errorMessage = '';
    _statusMessage = 'Starting speech recognition...';
    _notifyListeners();

    await _startRecognitionCycle();
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
    _notifyListeners();
  }

  Future<void> stopListening() async {
    if (!_shouldBeListening && !_isListening && !_isStarting) {
      return;
    }

    _shouldBeListening = false;
    _restartQueued = false;
    _commitLiveText();
    if (_isListening || _service.isListening) {
      await _service.stop();
    }
    _isListening = false;
    _statusMessage = hasTranscript
        ? 'Ready for another search.'
        : 'Ready to listen.';
    _notifyListeners();
    unawaited(_persistCurrentSession());
  }

  Future<void> cancelListening() async {
    if (!_shouldBeListening && !_isListening && !_isStarting) {
      return;
    }

    _shouldBeListening = false;
    _restartQueued = false;
    _commitLiveText();
    if (_isListening || _service.isListening) {
      await _service.cancel();
    }
    _isListening = false;
    _statusMessage = hasTranscript
        ? 'Ready for another search.'
        : 'Ready to listen.';
    _notifyListeners();
    unawaited(_persistCurrentSession());
  }

  void clearTranscript() {
    _committedText = '';
    _liveText = '';
    _errorMessage = '';
    _statusMessage = _speechEnabled
        ? 'Ready to listen.'
        : 'Speech recognition unavailable on this device.';
    _notifyListeners();
  }

  void _handleStatus(String status) {
    if (status == 'listening') {
      _isStarting = false;
      _isListening = true;
      _statusMessage = 'Listening...';
    } else if (status == 'notListening' ||
        status == 'done' ||
        status == 'doneNoResult') {
      _commitLiveText();
      _isStarting = false;
      _isListening = false;
      if (_shouldBeListening) {
        _statusMessage = hasTranscript
            ? 'Listening...'
            : 'Starting speech recognition...';
        _scheduleRestart();
      } else {
        _statusMessage = hasTranscript
            ? 'Ready for another search.'
            : 'Ready to listen.';
        unawaited(_persistCurrentSession());
      }
    } else {
      _statusMessage = status;
    }
    _notifyListeners();
  }

  void _handleResult(SpeechRecognitionResult result) {
    final incomingText = _normalizeText(result.recognizedWords);
    final mergedChunk = _mergeLiveChunk(
      committedText: _committedText,
      liveText: _liveText,
      incomingText: incomingText,
    );

    if (result.finalResult) {
      if (mergedChunk.isNotEmpty) {
        _committedText = _joinTranscript(_committedText, mergedChunk);
      }
      _liveText = '';
      _isListening = false;
      if (_shouldBeListening) {
        _statusMessage = hasTranscript
            ? 'Listening...'
            : 'Starting speech recognition...';
        _scheduleRestart();
      } else {
        _statusMessage = hasTranscript
            ? 'Ready for another search.'
            : 'Ready to listen.';
        unawaited(_persistCurrentSession());
      }
      _notifyListeners();
      return;
    } else {
      _liveText = mergedChunk;
      _statusMessage = 'Listening...';
    }

    _notifyListeners();
  }

  void _handleError(SpeechRecognitionError error) {
    _errorMessage = _describeError(error);
    if (error.permanent) {
      _shouldBeListening = false;
      _isStarting = false;
      _restartQueued = false;
      _isListening = false;
      _commitLiveText();
      unawaited(_persistCurrentSession());
    }
    _statusMessage = _errorMessage;
    _notifyListeners();
  }

  Future<void> _persistCurrentSession() async {
    if (_sessionStored || _isPersistingSession) {
      return;
    }

    final transcript = recognizedText.trim();
    if (transcript.isEmpty) {
      _sessionStored = true;
      return;
    }

    _sessionStored = true;
    _isPersistingSession = true;

    try {
      await _sessionStore.saveSession(
        transcript: transcript,
        languageLabel: _selectedLanguage.label,
        localeId: _selectedLanguage.localeId,
      );
    } catch (_) {
      _sessionStored = false;
      _errorMessage = 'Unable to save this speech session locally.';
      _notifyListeners();
    } finally {
      _isPersistingSession = false;
    }
  }

  void _commitLiveText() {
    if (_liveText.trim().isEmpty) {
      return;
    }

    _committedText = _joinTranscript(_committedText, _liveText);
    _liveText = '';
  }

  String _normalizeText(String text) {
    return text.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  String _joinTranscript(String committedText, String incomingText) {
    final committed = _normalizeText(committedText);
    final incoming = _normalizeText(incomingText);

    if (committed.isEmpty) {
      return incoming;
    }
    if (incoming.isEmpty) {
      return committed;
    }

    return '$committed $incoming';
  }

  String _mergeLiveChunk({
    required String committedText,
    required String liveText,
    required String incomingText,
  }) {
    final incomingWithoutCommitted = _stripOverlap(committedText, incomingText);
    final existingLive = _normalizeText(liveText);

    if (incomingWithoutCommitted.isEmpty) {
      return existingLive;
    }
    if (existingLive.isEmpty) {
      return incomingWithoutCommitted;
    }
    if (incomingWithoutCommitted.startsWith(existingLive)) {
      return incomingWithoutCommitted;
    }
    if (existingLive.startsWith(incomingWithoutCommitted)) {
      return existingLive;
    }

    final appendedText = _stripOverlap(existingLive, incomingWithoutCommitted);
    if (appendedText.isEmpty) {
      return existingLive;
    }

    return _joinTranscript(existingLive, appendedText);
  }

  String _stripOverlap(String committedText, String incomingText) {
    final committed = _normalizeText(committedText);
    final incoming = _normalizeText(incomingText);

    if (committed.isEmpty || incoming.isEmpty) {
      return incoming;
    }

    final committedWords = committed.split(' ');
    final incomingWords = incoming.split(' ');
    final maxOverlap = committedWords.length < incomingWords.length
        ? committedWords.length
        : incomingWords.length;

    for (var overlap = maxOverlap; overlap > 0; overlap -= 1) {
      final committedTail = committedWords.sublist(
        committedWords.length - overlap,
      );
      final incomingHead = incomingWords.sublist(0, overlap);
      if (listEquals(committedTail, incomingHead)) {
        return incomingWords.sublist(overlap).join(' ');
      }
    }

    return incoming;
  }

  Future<void> _startRecognitionCycle() async {
    if (_isDisposed ||
        !_speechEnabled ||
        !_shouldBeListening ||
        _isListening ||
        _isStarting) {
      return;
    }

    _isStarting = true;
    _statusMessage = hasTranscript
        ? 'Listening...'
        : 'Starting speech recognition...';
    _notifyListeners();

    final started = await _service.listen(
      onResult: _handleResult,
      partialResults: true,
      cancelOnError: true,
      localeId: _selectedLanguage.localeId,
    );

    _isStarting = false;
    if (!_shouldBeListening || _isDisposed) {
      if (started && (_isListening || _service.isListening)) {
        await _service.stop();
      }
      return;
    }

    if (started) {
      _isListening = true;
      _statusMessage = 'Listening...';
    } else {
      _shouldBeListening = false;
      _statusMessage = hasTranscript
          ? 'Ready for another search.'
          : 'Unable to start listening.';
      unawaited(_persistCurrentSession());
    }
    _notifyListeners();
  }

  void _scheduleRestart() {
    if (_restartQueued || !_shouldBeListening || _isDisposed) {
      return;
    }

    _restartQueued = true;
    scheduleMicrotask(() {
      _restartQueued = false;
      if (_isDisposed || !_shouldBeListening || _isListening || _isStarting) {
        return;
      }
      unawaited(_startRecognitionCycle());
    });
  }

  void _notifyListeners() {
    if (_isDisposed) {
      return;
    }

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
    _isDisposed = true;
    if (_service.isListening) {
      unawaited(_service.cancel());
    }
    unawaited(_sessionStore.close());
    super.dispose();
  }
}
