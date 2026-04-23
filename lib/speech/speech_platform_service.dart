import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

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

  bool get isAvailable;

  bool get isListening;
}

class SpeechToTextSpeechRecognitionService implements SpeechRecognitionService {
  final SpeechToText _speechToText = SpeechToText();

  @override
  bool get isAvailable => _speechToText.isAvailable;

  @override
  bool get isListening => _speechToText.isListening;

  @override
  Future<bool> initialize({
    required void Function(String status) onStatus,
    required void Function(SpeechRecognitionError error) onError,
    bool debugLogging = false,
  }) async {
    final dynamic initialized = await _speechToText.initialize(
      onStatus: onStatus,
      onError: onError,
      debugLogging: debugLogging,
    );
    return initialized == true;
  }

  @override
  Future<bool> listen({
    required void Function(SpeechRecognitionResult result) onResult,
    bool partialResults = true,
    bool cancelOnError = true,
    String? localeId,
  }) async {
    final dynamic started = await _speechToText.listen(
      onResult: onResult,
      listenOptions: SpeechListenOptions(
        autoPunctuation: true,          // Specific to iOS
        partialResults: partialResults,
        cancelOnError: cancelOnError,
        localeId: localeId,
      ),
    );
    return started == true;
  }

  @override
  Future<void> stop() => _speechToText.stop();

  @override
  Future<void> cancel() => _speechToText.cancel();
}
