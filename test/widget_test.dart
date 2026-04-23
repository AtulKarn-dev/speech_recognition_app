import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:speech_recognition_app/main.dart';
import 'package:speech_recognition_app/speech/speech_platform_service.dart';

void main() {
  testWidgets('renders recognized speech from platform events', (
    WidgetTester tester,
  ) async {
    final service = _FakeSpeechPlatformService(
      availability: const SpeechAvailability(
        status: SpeechFeatureStatus.available,
        supported: true,
        requiresDownload: false,
        resolvedMode: SpeechRecognizerMode.basic,
      ),
    );

    await tester.pumpWidget(
      SpeechRecognitionApp(
        service: service,
        debugIsSupportedPlatformOverride: true,
      ),
    );
    await tester.pumpAndSettle();

    final sessionId = service.lastSessionId!;
    service.emit(
      SpeechTranscriptEvent(
        sessionId: sessionId,
        text: 'search for coffee shops',
        isFinal: true,
        sequence: 0,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('search for coffee shops'), findsOneWidget);
    expect(find.text('Clear text'), findsOneWidget);
  });

  testWidgets('clear text removes the current transcript', (
    WidgetTester tester,
  ) async {
    final service = _FakeSpeechPlatformService(
      availability: const SpeechAvailability(
        status: SpeechFeatureStatus.available,
        supported: true,
        requiresDownload: false,
        resolvedMode: SpeechRecognizerMode.basic,
      ),
    );

    await tester.pumpWidget(
      SpeechRecognitionApp(
        service: service,
        debugIsSupportedPlatformOverride: true,
      ),
    );
    await tester.pumpAndSettle();

    final sessionId = service.lastSessionId!;
    service.emit(
      SpeechTranscriptEvent(
        sessionId: sessionId,
        text: 'weather tomorrow',
        isFinal: true,
        sequence: 0,
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('Clear text'));
    await tester.pump();

    expect(find.text('weather tomorrow'), findsNothing);
    expect(find.text('Say a search out loud'), findsOneWidget);
  });
}

class _FakeSpeechPlatformService implements SpeechPlatformService {
  _FakeSpeechPlatformService({required this.availability});

  final SpeechAvailability availability;
  final StreamController<SpeechPlatformEvent> _eventsController =
      StreamController<SpeechPlatformEvent>.broadcast();

  String? lastSessionId;

  @override
  Stream<SpeechPlatformEvent> get events => _eventsController.stream;

  @override
  Future<SpeechAvailability> checkStatus({
    required String sessionId,
    required String locale,
    required SpeechRecognizerMode preferredMode,
  }) async {
    lastSessionId = sessionId;
    return availability;
  }

  @override
  Future<void> close({required String sessionId}) async {
    await _eventsController.close();
  }

  @override
  Future<void> downloadModel({
    required String sessionId,
    required String locale,
    required SpeechRecognizerMode preferredMode,
  }) async {}

  void emit(SpeechPlatformEvent event) {
    _eventsController.add(event);
  }

  @override
  Future<void> startRecognition({
    required String sessionId,
    required String locale,
    required SpeechRecognizerMode preferredMode,
  }) async {}

  @override
  Future<void> stopRecognition({required String sessionId}) async {}
}
