import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:vosk_flutter_service/vosk_flutter.dart';

@visibleForTesting
String extractVoskTranscript(String rawResult) {
  final trimmed = rawResult.trim();
  if (trimmed.isEmpty) {
    return '';
  }

  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map) {
      final text = decoded['text'];
      if (text is String) {
        return text;
      }

      final partial = decoded['partial'];
      if (partial is String) {
        return partial;
      }

      final result = decoded['result'];
      if (result is List) {
        final words = result
            .whereType<Map>()
            .map((entry) => entry['word'])
            .whereType<String>()
            .toList();
        if (words.isNotEmpty) {
          return words.join(' ');
        }
      }
    }
  } catch (_) {
    // Fall back to parsing the raw string below.
  }

  final parsedField = RegExp(
    r'"?(?:text|partial)"?\s*:\s*([^,}]*)',
  ).firstMatch(trimmed);
  if (parsedField != null) {
    return parsedField.group(1)?.trim().replaceAll(RegExp(r'^"|"$'), '') ?? '';
  }

  return trimmed;
}

class SpeechRecognitionError {
  const SpeechRecognitionError(this.errorMsg, [this.permanent = true]);

  final String errorMsg;
  final bool permanent;
}

class SpeechRecognitionResult {
  const SpeechRecognitionResult({
    required this.recognizedWords,
    required this.finalResult,
  });

  final String recognizedWords;
  final bool finalResult;
}

abstract class SpeechRecognitionService {
  Future<bool> initialize({
    required void Function(String status) onStatus,
    required void Function(SpeechRecognitionError error) onError,
    bool debugLogging = false,
  });

  Future<bool> listen({
    required void Function(SpeechRecognitionResult result) onResult,
    bool partialResults = true,
    bool cancelOnError = true,
    String? localeId,
  });

  Future<void> stop();

  Future<void> cancel();

  Future<void> dispose();

  bool get isAvailable;

  bool get isListening;
}

class VoskSpeechRecognitionService implements SpeechRecognitionService {
  VoskSpeechRecognitionService({
    VoskFlutterPlugin? plugin,
    ModelLoader? modelLoader,
    String modelAsset = _defaultModelAsset,
    int sampleRate = _sampleRate,
  }) : _plugin = plugin ?? VoskFlutterPlugin.instance(),
       _modelLoader = modelLoader ?? ModelLoader(),
       _modelAsset = modelAsset,
       _configuredSampleRate = sampleRate;

  static const String _defaultModelAsset =
      'assets/models/vosk-model-small-en-us-0.15.zip';
  static const int _sampleRate = 16000;

  final VoskFlutterPlugin _plugin;
  final ModelLoader _modelLoader;
  final String _modelAsset;
  final int _configuredSampleRate;

  Model? _model;
  Recognizer? _recognizer;
  SpeechService? _speechService;
  StreamSubscription<String>? _partialSubscription;
  StreamSubscription<String>? _resultSubscription;

  void Function(SpeechRecognitionError error)? _onError;
  void Function(SpeechRecognitionResult result)? _onResult;

  bool _initialized = false;
  bool _available = false;
  bool _listening = false;

  @override
  bool get isAvailable => _available;

  @override
  bool get isListening => _listening;

  @override
  Future<bool> initialize({
    required void Function(String status) onStatus,
    required void Function(SpeechRecognitionError error) onError,
    bool debugLogging = false,
  }) async {
    _onError = onError;

    if (_initialized) {
      return _available;
    }
    _initialized = true;

    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      _available = false;
      onStatus('Speech recognition is only available on Android and iOS.');
      return false;
    }

    try {
      final modelPath = await _modelLoader.loadFromAssets(_modelAsset);
      _model = await _plugin.createModel(modelPath);
      _recognizer = await _plugin.createRecognizer(
        model: _model!,
        sampleRate: _configuredSampleRate,
      );
      _speechService = await _plugin.initSpeechService(_recognizer!);
      _available = true;
      onStatus('Ready to listen.');
      return true;
    } on MicrophoneAccessDeniedException {
      _available = false;
      onError(const SpeechRecognitionError('error_permission'));
      onStatus('Microphone access is required for speech recognition.');
      return false;
    } catch (error) {
      _available = false;
      onError(SpeechRecognitionError(_describeInitializationError(error)));
      onStatus('Unable to initialize speech recognition.');
      return false;
    }
  }

  @override
  Future<bool> listen({
    required void Function(SpeechRecognitionResult result) onResult,
    bool partialResults = true,
    bool cancelOnError = true,
    String? localeId,
  }) async {
    final speechService = _speechService;
    if (speechService == null) {
      return false;
    }

    _onResult = onResult;
    await _partialSubscription?.cancel();
    await _resultSubscription?.cancel();
    _partialSubscription = null;
    _resultSubscription = null;

    if (partialResults) {
      _partialSubscription = speechService.onPartial().listen(
        _handlePartialResult,
        onError: _handleStreamError,
      );
    }

    _resultSubscription = speechService.onResult().listen(
      _handleFinalResult,
      onError: _handleStreamError,
    );

    await speechService.reset();
    final dynamic started = await speechService.start(
      onRecognitionError: _handleRecognitionError,
    );

    _listening = started == true;
    if (!_listening) {
      await _partialSubscription?.cancel();
      await _resultSubscription?.cancel();
      _partialSubscription = null;
      _resultSubscription = null;
    }
    return _listening;
  }

  @override
  Future<void> stop() async {
    final speechService = _speechService;
    if (speechService == null) {
      return;
    }

    await speechService.stop();
    _listening = false;
  }

  @override
  Future<void> cancel() async {
    final speechService = _speechService;
    if (speechService == null) {
      return;
    }

    await speechService.cancel();
    _listening = false;
  }

  @override
  Future<void> dispose() async {
    await _partialSubscription?.cancel();
    await _resultSubscription?.cancel();
    _partialSubscription = null;
    _resultSubscription = null;

    await _speechService?.dispose();
    _speechService = null;
    _recognizer?.dispose();
    _recognizer = null;
    _model?.dispose();
    _model = null;
    _available = false;
    _listening = false;
  }

  void _handlePartialResult(String rawResult) {
    _emitResult(rawResult, finalResult: false);
  }

  void _handleFinalResult(String rawResult) {
    _emitResult(rawResult, finalResult: true);
  }

  void _emitResult(String rawResult, {required bool finalResult}) {
    final callback = _onResult;
    if (callback == null) {
      return;
    }

    callback(
      SpeechRecognitionResult(
        recognizedWords: extractVoskTranscript(rawResult),
        finalResult: finalResult,
      ),
    );
  }

  void _handleRecognitionError(Object? error) {
    _listening = false;
    _onError?.call(_mapRecognitionError(error));
  }

  void _handleStreamError(Object error) {
    _listening = false;
    _onError?.call(_mapRecognitionError(error));
  }

  SpeechRecognitionError _mapRecognitionError(Object? error) {
    if (error is MicrophoneAccessDeniedException) {
      return const SpeechRecognitionError('error_permission');
    }

    final message = error?.toString() ?? 'recognition_error';
    if (message.toLowerCase().contains('permission') ||
        message.toLowerCase().contains('microphone')) {
      return const SpeechRecognitionError('error_permission');
    }

    return SpeechRecognitionError(message);
  }

  String _describeInitializationError(Object error) {
    final message = error.toString().toLowerCase();
    if (message.contains('permission') || message.contains('microphone')) {
      return 'Microphone access is required for speech recognition.';
    }
    return 'Unable to load the Vosk speech model.';
  }
}
