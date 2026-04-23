import 'dart:async';

import 'package:flutter/services.dart';

enum SpeechFeatureStatus { unavailable, downloadable, downloading, available }

enum SpeechRecognizerMode { auto, basic, advanced }

class SpeechAvailability {
  const SpeechAvailability({
    required this.status,
    required this.supported,
    required this.requiresDownload,
    required this.resolvedMode,
    this.message,
  });

  final SpeechFeatureStatus status;
  final bool supported;
  final bool requiresDownload;
  final SpeechRecognizerMode resolvedMode;
  final String? message;

  factory SpeechAvailability.fromMap(Map<Object?, Object?> map) {
    final statusIndex = (map['statusIndex'] as num?)?.toInt() ?? 0;
    final safeStatusIndex =
        statusIndex >= 0 && statusIndex < SpeechFeatureStatus.values.length
        ? statusIndex
        : 0;
    final resolvedModeRaw = (map['resolvedMode'] as String?) ?? 'auto';

    return SpeechAvailability(
      status: SpeechFeatureStatus.values[safeStatusIndex],
      supported: map['supported'] as bool? ?? true,
      requiresDownload: map['requiresDownload'] as bool? ?? false,
      resolvedMode: SpeechRecognizerMode.values.firstWhere(
        (value) => value.name == resolvedModeRaw,
        orElse: () => SpeechRecognizerMode.auto,
      ),
      message: map['message'] as String?,
    );
  }
}

abstract class SpeechPlatformEvent {
  const SpeechPlatformEvent();

  String get sessionId;
}

class SpeechStateEvent extends SpeechPlatformEvent {
  const SpeechStateEvent({required this.sessionId, required this.state});

  @override
  final String sessionId;

  final String state;
}

class SpeechDownloadEvent extends SpeechPlatformEvent {
  const SpeechDownloadEvent({
    required this.sessionId,
    required this.phase,
    this.downloadedBytes,
    this.totalBytes,
    this.message,
  });

  @override
  final String sessionId;

  final String phase;
  final int? downloadedBytes;
  final int? totalBytes;
  final String? message;
}

class SpeechTranscriptEvent extends SpeechPlatformEvent {
  const SpeechTranscriptEvent({
    required this.sessionId,
    required this.text,
    required this.isFinal,
    required this.sequence,
    this.locale,
    this.mode,
    this.timestampMs,
  });

  @override
  final String sessionId;

  final String text;
  final bool isFinal;
  final int sequence;
  final String? locale;
  final String? mode;
  final int? timestampMs;
}

class SpeechErrorEvent extends SpeechPlatformEvent {
  const SpeechErrorEvent({
    required this.sessionId,
    required this.code,
    required this.message,
    required this.recoverable,
  });

  @override
  final String sessionId;

  final String code;
  final String message;
  final bool recoverable;
}

abstract class SpeechPlatformService {
  Stream<SpeechPlatformEvent> get events;

  Future<SpeechAvailability> checkStatus({
    required String sessionId,
    required String locale,
    required SpeechRecognizerMode preferredMode,
  });

  Future<void> downloadModel({
    required String sessionId,
    required String locale,
    required SpeechRecognizerMode preferredMode,
  });

  Future<void> startRecognition({
    required String sessionId,
    required String locale,
    required SpeechRecognizerMode preferredMode,
  });

  Future<void> stopRecognition({required String sessionId});

  Future<void> close({required String sessionId});
}

class MethodChannelSpeechPlatformService implements SpeechPlatformService {
  const MethodChannelSpeechPlatformService();

  static const MethodChannel _methodChannel = MethodChannel(
    'speech_recognition_app/speech/methods',
  );
  static const EventChannel _eventChannel = EventChannel(
    'speech_recognition_app/speech/events',
  );

  static Stream<SpeechPlatformEvent>? _cachedEvents;

  @override
  Stream<SpeechPlatformEvent> get events {
    return _cachedEvents ??= _eventChannel
        .receiveBroadcastStream()
        .map((dynamic event) {
          final map = Map<Object?, Object?>.from(
            event as Map<dynamic, dynamic>,
          );
          return _eventFromMap(map);
        })
        .where((event) => event != null)
        .cast<SpeechPlatformEvent>();
  }

  @override
  Future<SpeechAvailability> checkStatus({
    required String sessionId,
    required String locale,
    required SpeechRecognizerMode preferredMode,
  }) async {
    final result = await _methodChannel.invokeMethod<Map<Object?, Object?>>(
      'genai#checkStatus',
      _payload(
        sessionId: sessionId,
        locale: locale,
        preferredMode: preferredMode,
      ),
    );

    return SpeechAvailability.fromMap(result ?? <Object?, Object?>{});
  }

  @override
  Future<void> downloadModel({
    required String sessionId,
    required String locale,
    required SpeechRecognizerMode preferredMode,
  }) {
    return _methodChannel.invokeMethod<void>(
      'genai#downloadModel',
      _payload(
        sessionId: sessionId,
        locale: locale,
        preferredMode: preferredMode,
      ),
    );
  }

  @override
  Future<void> startRecognition({
    required String sessionId,
    required String locale,
    required SpeechRecognizerMode preferredMode,
  }) {
    return _methodChannel
        .invokeMethod<void>('genai#startRecognition', <String, Object?>{
          ..._payload(
            sessionId: sessionId,
            locale: locale,
            preferredMode: preferredMode,
          ),
          'audioSource': 'mic',
          'emitPartials': true,
        });
  }

  @override
  Future<void> stopRecognition({required String sessionId}) {
    return _methodChannel.invokeMethod<void>('genai#stopRecognition', {
      'id': sessionId,
    });
  }

  @override
  Future<void> close({required String sessionId}) {
    return _methodChannel.invokeMethod<void>('genai#closeSpeechRecognizer', {
      'id': sessionId,
    });
  }

  Map<String, Object?> _payload({
    required String sessionId,
    required String locale,
    required SpeechRecognizerMode preferredMode,
  }) {
    return <String, Object?>{
      'id': sessionId,
      'locale': locale,
      'preferredMode': preferredMode.name,
    };
  }

  SpeechPlatformEvent? _eventFromMap(Map<Object?, Object?> map) {
    final type = map['type'] as String?;
    final sessionId = map['id'] as String?;
    if (type == null || sessionId == null) {
      return null;
    }

    switch (type) {
      case 'state':
        return SpeechStateEvent(
          sessionId: sessionId,
          state: (map['state'] as String?) ?? 'unknown',
        );
      case 'download':
        return SpeechDownloadEvent(
          sessionId: sessionId,
          phase: (map['phase'] as String?) ?? 'unknown',
          downloadedBytes:
              (map['downloadedBytes'] as num?)?.toInt() ??
              (map['totalBytesDownloaded'] as num?)?.toInt(),
          totalBytes: (map['totalBytes'] as num?)?.toInt(),
          message: map['message'] as String?,
        );
      case 'transcript':
        return SpeechTranscriptEvent(
          sessionId: sessionId,
          text: (map['text'] as String?) ?? '',
          isFinal: map['isFinal'] as bool? ?? false,
          sequence: (map['sequence'] as num?)?.toInt() ?? 0,
          locale: map['locale'] as String?,
          mode: map['mode'] as String?,
          timestampMs: (map['timestampMs'] as num?)?.toInt(),
        );
      case 'error':
        return SpeechErrorEvent(
          sessionId: sessionId,
          code: (map['code'] as String?) ?? 'unknown',
          message: (map['message'] as String?) ?? 'Something went wrong.',
          recoverable: map['recoverable'] as bool? ?? false,
        );
      default:
        return null;
    }
  }
}
