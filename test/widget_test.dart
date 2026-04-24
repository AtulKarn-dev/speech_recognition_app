import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';

import 'package:speech_recognition_app/main.dart';
import 'package:speech_recognition_app/speech/speech_platform_service.dart';

void main() {
  testWidgets('renders recognized speech from the service', (tester) async {
    final service = FakeSpeechRecognitionService();

    await tester.pumpWidget(SpeechRecognitionApp(service: service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start listening'));
    await tester.pump();

    service.emitResult('hello from voice search', finalResult: true);
    await tester.pumpAndSettle();

    expect(find.text('hello from voice search'), findsOneWidget);
    expect(find.text('Listening...'), findsNothing);
  });

  testWidgets('clear text removes the current transcript', (tester) async {
    final service = FakeSpeechRecognitionService();

    await tester.pumpWidget(SpeechRecognitionApp(service: service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start listening'));
    await tester.pump();

    service.emitResult('clear me later', finalResult: true);
    await tester.pumpAndSettle();

    expect(find.text('clear me later'), findsOneWidget);

    await tester.tap(find.text('Clear text'));
    await tester.pumpAndSettle();

    expect(find.text('clear me later'), findsNothing);
    expect(find.text('Your spoken text will appear here.'), findsOneWidget);
  });

  testWidgets('passes the selected language locale into listen', (
    tester,
  ) async {
    final service = FakeSpeechRecognitionService();

    await tester.pumpWidget(SpeechRecognitionApp(service: service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Hindi'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start listening'));
    await tester.pump();

    expect(service.lastLocaleId, 'hi-IN');

    service.emitResult('नमस्ते', finalResult: true);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Nepali'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start listening'));
    await tester.pump();

    expect(service.lastLocaleId, 'ne-NP');
  });
}

class FakeSpeechRecognitionService implements SpeechRecognitionService {
  bool available = true;
  bool listening = false;
  String? lastLocaleId;
  void Function(String status)? _onStatus;
  void Function(SpeechRecognitionError error)? _onError;
  void Function(SpeechRecognitionResult result)? _onResult;

  @override
  bool get isAvailable => available;

  @override
  bool get isListening => listening;

  @override
  Future<bool> initialize({
    required void Function(String status) onStatus,
    required void Function(SpeechRecognitionError error) onError,
    bool debugLogging = false,
  }) async {
    _onStatus = onStatus;
    _onError = onError;
    return available;
  }

  @override
  Future<bool> listen({
    required void Function(SpeechRecognitionResult result) onResult,
    bool partialResults = true,
    bool cancelOnError = true,
    String? localeId,
  }) async {
    listening = true;
    lastLocaleId = localeId;
    _onResult = onResult;
    _onStatus?.call('listening');
    return true;
  }

  @override
  Future<void> stop() async {
    listening = false;
    _onStatus?.call('notListening');
  }

  @override
  Future<void> cancel() async {
    listening = false;
    _onStatus?.call('notListening');
  }

  void emitResult(String words, {bool finalResult = false}) {
    final result = SpeechRecognitionResult.init([
      SpeechRecognitionWords(
        words,
        null,
        SpeechRecognitionWords.missingConfidence,
      ),
    ], finalResult ? ResultType.finalResult : ResultType.partial);
    _onResult?.call(result);
    if (finalResult) {
      listening = false;
      _onStatus?.call('done');
    }
  }

  void emitError(String message, {bool permanent = true}) {
    _onError?.call(SpeechRecognitionError(message, permanent));
  }
}
