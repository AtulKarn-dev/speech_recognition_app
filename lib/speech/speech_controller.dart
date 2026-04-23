import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'speech_platform_service.dart';

class SpeechController extends ChangeNotifier {
  SpeechController({
    required SpeechPlatformService service,
    this.locale = 'en-US',
    this.preferredMode = SpeechRecognizerMode.auto,
    this.isSupportedPlatformOverride,
  }) : _service = service;

  final SpeechPlatformService _service;
  final String locale;
  final SpeechRecognizerMode preferredMode;
  final bool? isSupportedPlatformOverride;

  final String sessionId = 'speech-${DateTime.now().microsecondsSinceEpoch}';

  StreamSubscription<SpeechPlatformEvent>? _eventsSubscription;
  int _lastSequence = -1;
  bool _disposed = false;

  SpeechFeatureStatus availabilityStatus = SpeechFeatureStatus.unavailable;
  SpeechRecognizerMode resolvedMode = SpeechRecognizerMode.auto;
  bool isChecking = false;
  bool isDownloading = false;
  bool isListening = false;
  bool permissionDenied = false;
  String unsupportedReason = '';
  String errorMessage = '';
  String finalTranscript = '';
  String livePartialTranscript = '';
  int? downloadProgress;

  bool get isSupportedPlatform =>
      isSupportedPlatformOverride ?? (!kIsWeb && Platform.isAndroid);

  bool get hasTranscript => displayTranscript.trim().isNotEmpty;

  String get displayTranscript {
    if (finalTranscript.isEmpty) {
      return livePartialTranscript;
    }
    if (livePartialTranscript.isEmpty) {
      return finalTranscript;
    }
    return '$finalTranscript\n$livePartialTranscript';
  }

  String get statusCopy {
    if (unsupportedReason.isNotEmpty) {
      return unsupportedReason;
    }
    if (errorMessage.isNotEmpty) {
      return errorMessage;
    }
    if (permissionDenied) {
      return 'Microphone access is required before voice search can begin.';
    }
    if (isChecking) {
      return 'Checking on-device speech availability.';
    }
    if (isDownloading) {
      if (downloadProgress != null) {
        return 'Preparing speech model: $downloadProgress% complete.';
      }
      return 'Preparing the on-device speech model.';
    }
    if (isListening) {
      return 'Listening now. Live words appear as you speak.';
    }
    switch (availabilityStatus) {
      case SpeechFeatureStatus.available:
        return hasTranscript
            ? 'Speech captured. Clear it or start listening again.'
            : 'Ready for voice search on this device.';
      case SpeechFeatureStatus.downloadable:
        return 'This device can prepare the speech model before recording.';
      case SpeechFeatureStatus.downloading:
        return 'The speech model is still downloading.';
      case SpeechFeatureStatus.unavailable:
        return 'Speech recognition is not available on this device yet.';
    }
  }

  Future<void> initialize() async {
    _eventsSubscription ??= _service.events.listen(_handleEvent);

    if (!isSupportedPlatform) {
      unsupportedReason =
          'Live speech recognition is currently available on Android only.';
      notifyListeners();
      return;
    }

    await refreshAvailability();
  }

  Future<void> refreshAvailability() async {
    if (!isSupportedPlatform) {
      return;
    }

    isChecking = true;
    errorMessage = '';
    notifyListeners();

    try {
      final availability = await _service.checkStatus(
        sessionId: sessionId,
        locale: locale,
        preferredMode: preferredMode,
      );

      availabilityStatus = availability.status;
      resolvedMode = availability.resolvedMode;

      if (!availability.supported ||
          availability.status == SpeechFeatureStatus.unavailable) {
        unsupportedReason =
            availability.message ??
            'This Android device does not currently support ML Kit speech recognition.';
      } else {
        unsupportedReason = '';
      }
    } on PlatformException catch (error) {
      errorMessage =
          error.message ?? 'Failed to check speech recognition availability.';
    } finally {
      isChecking = false;
      _notifyIfAlive();
    }
  }

  Future<void> downloadModel() async {
    if (!isSupportedPlatform || isDownloading) {
      return;
    }

    isDownloading = true;
    errorMessage = '';
    downloadProgress = null;
    notifyListeners();

    try {
      await _service.downloadModel(
        sessionId: sessionId,
        locale: locale,
        preferredMode: preferredMode,
      );
    } on PlatformException catch (error) {
      isDownloading = false;
      errorMessage = error.message ?? 'Failed to start speech model download.';
      _notifyIfAlive();
    }
  }

  Future<void> startListening() async {
    if (!isSupportedPlatform || isChecking || isDownloading || isListening) {
      return;
    }

    errorMessage = '';

    final permissionStatus = await Permission.microphone.request();
    permissionDenied = !permissionStatus.isGranted;
    if (permissionDenied) {
      _notifyIfAlive();
      return;
    }

    if (availabilityStatus == SpeechFeatureStatus.downloadable) {
      await downloadModel();
      return;
    }

    if (availabilityStatus != SpeechFeatureStatus.available) {
      await refreshAvailability();
      if (availabilityStatus != SpeechFeatureStatus.available) {
        return;
      }
    }

    finalTranscript = '';
    livePartialTranscript = '';
    _lastSequence = -1;
    isListening = true;
    _notifyIfAlive();

    try {
      await _service.startRecognition(
        sessionId: sessionId,
        locale: locale,
        preferredMode: preferredMode,
      );
    } on PlatformException catch (error) {
      isListening = false;
      errorMessage =
          error.message ?? 'Failed to start live speech recognition.';
      _notifyIfAlive();
    }
  }

  Future<void> stopListening() async {
    if (!isListening) {
      return;
    }

    isListening = false;
    _notifyIfAlive();

    try {
      await _service.stopRecognition(sessionId: sessionId);
    } on PlatformException catch (error) {
      errorMessage = error.message ?? 'Failed to stop live speech recognition.';
      _notifyIfAlive();
    }
  }

  void clearTranscript() {
    finalTranscript = '';
    livePartialTranscript = '';
    errorMessage = '';
    _notifyIfAlive();
  }

  void _handleEvent(SpeechPlatformEvent event) {
    if (event.sessionId != sessionId) {
      return;
    }

    if (event is SpeechStateEvent) {
      switch (event.state) {
        case 'checking':
          isChecking = true;
          break;
        case 'ready':
          isChecking = false;
          isDownloading = false;
          availabilityStatus = SpeechFeatureStatus.available;
          break;
        case 'downloading':
          isDownloading = true;
          break;
        case 'starting':
        case 'listening':
          isChecking = false;
          isListening = true;
          break;
        case 'completed':
        case 'stopped':
          isListening = false;
          livePartialTranscript = '';
          break;
        case 'permissionDenied':
          permissionDenied = true;
          isListening = false;
          break;
        case 'unsupported':
          isListening = false;
          break;
      }
    } else if (event is SpeechDownloadEvent) {
      switch (event.phase) {
        case 'started':
          isDownloading = true;
          downloadProgress = 0;
          break;
        case 'progress':
          final downloadedBytes = event.downloadedBytes;
          final totalBytes = event.totalBytes;
          if (downloadedBytes != null && totalBytes != null && totalBytes > 0) {
            downloadProgress = ((downloadedBytes / totalBytes) * 100).round();
          }
          break;
        case 'completed':
          isDownloading = false;
          availabilityStatus = SpeechFeatureStatus.available;
          downloadProgress = 100;
          unawaited(refreshAvailability());
          break;
        case 'failed':
          isDownloading = false;
          errorMessage = event.message ?? 'Speech model download failed.';
          break;
      }
    } else if (event is SpeechTranscriptEvent) {
      if (event.sequence < _lastSequence) {
        return;
      }

      _lastSequence = event.sequence;
      if (event.isFinal) {
        final trimmed = event.text.trim();
        if (trimmed.isNotEmpty) {
          finalTranscript = finalTranscript.isEmpty
              ? trimmed
              : '$finalTranscript\n$trimmed';
        }
        livePartialTranscript = '';
      } else {
        livePartialTranscript = event.text;
      }
    } else if (event is SpeechErrorEvent) {
      isListening = false;
      isDownloading = false;
      errorMessage = event.message;
      if (event.code == 'PERMISSION_DENIED') {
        permissionDenied = true;
      }
      if (event.code == 'UNSUPPORTED_DEVICE') {
        unsupportedReason = event.message;
      }
    }

    _notifyIfAlive();
  }

  void _notifyIfAlive() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _eventsSubscription?.cancel();
    unawaited(_service.close(sessionId: sessionId));
    super.dispose();
  }
}
