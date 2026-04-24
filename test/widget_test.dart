import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:speech_recognition_app/main.dart';
import 'package:speech_recognition_app/speech/speech_platform_service.dart';

void main() {
  test('extracts empty Vosk partial payload as empty text', () {
    expect(extractVoskTranscript('{"partial": ""}'), isEmpty);
    expect(extractVoskTranscript('{"partial": "hello"}'), 'hello');
  });

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

  testWidgets('start button waits for initialization to finish', (
    tester,
  ) async {
    final initializeBarrier = Completer<void>();
    final service = FakeSpeechRecognitionService(
      initializeBarrier: initializeBarrier,
    );

    await tester.pumpWidget(SpeechRecognitionApp(service: service));
    await tester.pump();

    await tester.tap(find.text('Start listening'));
    await tester.pump();

    expect(service.listenCalls, 0);

    initializeBarrier.complete();
    await tester.pumpAndSettle();

    expect(service.listenCalls, 1);
    expect(find.text('Stop listening'), findsOneWidget);
  });

  testWidgets('keeps listening across Vosk segment results', (tester) async {
    final service = FakeSpeechRecognitionService();

    await tester.pumpWidget(SpeechRecognitionApp(service: service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start listening'));
    await tester.pumpAndSettle();

    service.emitResult('hello world', finalResult: true, emitDoneStatus: false);
    await tester.pump();

    service.emitResult('again', finalResult: false);
    await tester.pumpAndSettle();

    expect(find.text('Stop listening'), findsOneWidget);
    expect(find.text('hello world again'), findsOneWidget);
  });
}

class FakeSpeechRecognitionService implements SpeechRecognitionService {
  FakeSpeechRecognitionService({this.initializeBarrier});

  final Completer<void>? initializeBarrier;

  bool available = true;
  bool listening = false;
  int listenCalls = 0;
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
    final barrier = initializeBarrier;
    if (barrier != null && !barrier.isCompleted) {
      await barrier.future;
    }
    return available;
  }

  @override
  Future<bool> listen({
    required void Function(SpeechRecognitionResult result) onResult,
    bool partialResults = true,
    bool cancelOnError = true,
    String? localeId,
  }) async {
    listenCalls += 1;
    listening = true;
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

  @override
  Future<void> dispose() async {}

  void emitResult(
    String words, {
    bool finalResult = false,
    bool emitDoneStatus = true,
  }) {
    final result = SpeechRecognitionResult(
      recognizedWords: words,
      finalResult: finalResult,
    );
    _onResult?.call(result);
    if (finalResult && emitDoneStatus) {
      listening = false;
      _onStatus?.call('done');
    }
  }

  void emitError(String message, {bool permanent = true}) {
    _onError?.call(SpeechRecognitionError(message, permanent));
  }
}
