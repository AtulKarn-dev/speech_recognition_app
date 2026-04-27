import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';

import 'package:speech_recognition_app/main.dart';
import 'package:speech_recognition_app/speech/speech_platform_service.dart';
import 'package:speech_recognition_app/speech/speech_session_store.dart';

void main() {
  testWidgets('merges all chunks from one spoken session before saving', (
    tester,
  ) async {
    final service = FakeSpeechRecognitionService();
    final sessionStore = FakeSpeechSessionStore();

    await tester.pumpWidget(
      SpeechRecognitionApp(service: service, sessionStore: sessionStore),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start listening'));
    await tester.pumpAndSettle();

    service.emitResult('hello from', finalResult: true);
    await tester.pumpAndSettle();

    service.emitResult('voice search app', finalResult: true);
    await tester.pumpAndSettle();

    expect(find.text('hello from voice search app'), findsOneWidget);
    expect(service.listenCallCount, greaterThanOrEqualTo(3));
    expect(sessionStore.savedSessions, isEmpty);

    await tester.tap(find.text('Stop listening'));
    await tester.pumpAndSettle();

    expect(sessionStore.savedSessions, hasLength(1));
    expect(
      sessionStore.savedSessions.single.transcript,
      'hello from voice search app',
    );
  });

  testWidgets('stores finalized speech after the session stops', (
    tester,
  ) async {
    final service = FakeSpeechRecognitionService();
    final sessionStore = FakeSpeechSessionStore();

    await tester.pumpWidget(
      SpeechRecognitionApp(service: service, sessionStore: sessionStore),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start listening'));
    await tester.pump();

    service.emitResult('hello from voice search', finalResult: true);
    await tester.pumpAndSettle();

    expect(find.text('hello from voice search'), findsOneWidget);
    expect(find.text('Stop listening'), findsOneWidget);
    expect(sessionStore.savedSessions, isEmpty);

    await tester.tap(find.text('Stop listening'));
    await tester.pumpAndSettle();

    expect(sessionStore.savedSessions, hasLength(1));
    expect(
      sessionStore.savedSessions.single.transcript,
      'hello from voice search',
    );
  });

  testWidgets('clear text removes the current transcript', (tester) async {
    final service = FakeSpeechRecognitionService();
    final sessionStore = FakeSpeechSessionStore();

    await tester.pumpWidget(
      SpeechRecognitionApp(service: service, sessionStore: sessionStore),
    );
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
    expect(sessionStore.savedSessions, isEmpty);
  });

  testWidgets('passes the selected language locale into listen', (
    tester,
  ) async {
    final service = FakeSpeechRecognitionService();
    final sessionStore = FakeSpeechSessionStore();

    await tester.pumpWidget(
      SpeechRecognitionApp(service: service, sessionStore: sessionStore),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Hindi'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start listening'));
    await tester.pump();

    expect(service.lastLocaleId, 'hi-IN');

    service.emitResult('नमस्ते', finalResult: true);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Stop listening'));
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
  int listenCallCount = 0;
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
    listenCallCount += 1;
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

class FakeSpeechSessionStore implements SpeechSessionStore {
  final List<SpeechSessionEntry> savedSessions = <SpeechSessionEntry>[];

  @override
  Future<void> close() async {}

  @override
  Future<void> saveSession({
    required String transcript,
    required String languageLabel,
    required String localeId,
    DateTime? createdAt,
  }) async {
    final session = SpeechSessionEntry(
      transcript: transcript,
      languageLabel: languageLabel,
      localeId: localeId,
      createdAt: createdAt ?? DateTime(2026, 4, 27, 9, 30),
    );
    savedSessions.insert(0, session);
  }
}
