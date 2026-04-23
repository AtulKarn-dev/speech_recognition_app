import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'speech/speech_controller.dart';
import 'speech/speech_platform_service.dart';

void main() {
  runApp(const SpeechRecognitionApp());
}

class SpeechRecognitionApp extends StatelessWidget {
  const SpeechRecognitionApp({
    super.key,
    SpeechPlatformService? service,
    this.debugIsSupportedPlatformOverride,
  }) : _service = service ?? const MethodChannelSpeechPlatformService();

  final SpeechPlatformService _service;
  final bool? debugIsSupportedPlatformOverride;

  @override
  Widget build(BuildContext context) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF0F6BFF),
        brightness: Brightness.light,
      ),
    );

    return MaterialApp(
      title: 'Voice Search',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: const Color(0xFFF7F8FC),
        textTheme: GoogleFonts.plusJakartaSansTextTheme(base.textTheme),
      ),
      home: SpeechRecognitionScreen(
        service: _service,
        debugIsSupportedPlatformOverride: debugIsSupportedPlatformOverride,
      ),
    );
  }
}

class SpeechRecognitionScreen extends StatefulWidget {
  const SpeechRecognitionScreen({
    super.key,
    required this.service,
    this.debugIsSupportedPlatformOverride,
  });

  final SpeechPlatformService service;
  final bool? debugIsSupportedPlatformOverride;

  @override
  State<SpeechRecognitionScreen> createState() =>
      _SpeechRecognitionScreenState();
}

class _SpeechRecognitionScreenState extends State<SpeechRecognitionScreen> {
  late final SpeechController _controller;

  @override
  void initState() {
    super.initState();
    _controller =
        SpeechController(
            service: widget.service,
            isSupportedPlatformOverride:
                widget.debugIsSupportedPlatformOverride,
          )
          ..addListener(_onControllerChanged)
          ..initialize();
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onControllerChanged)
      ..dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasTranscript = _controller.hasTranscript;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.mic_none_rounded,
                      color: Color(0xFF0F6BFF),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Voice Search',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: const Color(0xFF10203B),
                          ),
                        ),
                        Text(
                          _controller.isListening
                              ? 'Listening for your search'
                              : 'Tap the mic and say your query',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: const Color(0xFF607089),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh speech status',
                    onPressed: _controller.isChecking
                        ? null
                        : _controller.refreshAvailability,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x110D1B2A),
                      blurRadius: 24,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: _controller.isListening
                                ? const Color(0xFFFF4F5E)
                                : const Color(0xFFD3DBE8),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          _controller.isListening
                              ? 'Listening now'
                              : 'Recognized speech',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: const Color(0xFF10203B),
                          ),
                        ),
                        const Spacer(),
                        if (hasTranscript)
                          TextButton.icon(
                            onPressed: _controller.clearTranscript,
                            icon: const Icon(Icons.close_rounded),
                            label: const Text('Clear text'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: double.infinity,
                      constraints: const BoxConstraints(minHeight: 260),
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        color: hasTranscript
                            ? const Color(0xFFF2F6FF)
                            : const Color(0xFFF8FAFD),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: hasTranscript
                              ? const Color(0xFFD5E3FF)
                              : const Color(0xFFE3E8F0),
                        ),
                      ),
                      child: hasTranscript
                          ? _TranscriptText(controller: _controller)
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  'Say a search out loud',
                                  style: theme.textTheme.headlineSmall
                                      ?.copyWith(
                                        fontWeight: FontWeight.w800,
                                        color: const Color(0xFF10203B),
                                      ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'Your speech appears here in real time, with partial text updating as you talk and finalized text staying on screen until you clear it.',
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    height: 1.6,
                                    color: const Color(0xFF627086),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 28),
              Center(
                child: Column(
                  children: [
                    SizedBox(
                      width: 104,
                      height: 104,
                      child: FilledButton(
                        onPressed:
                            _controller.isChecking ||
                                _controller.isDownloading ||
                                _controller.unsupportedReason.isNotEmpty
                            ? null
                            : () {
                                if (_controller.isListening) {
                                  _controller.stopListening();
                                } else if (_controller.availabilityStatus ==
                                    SpeechFeatureStatus.downloadable) {
                                  _controller.downloadModel();
                                } else {
                                  _controller.startListening();
                                }
                              },
                        style: FilledButton.styleFrom(
                          backgroundColor: _controller.isListening
                              ? const Color(0xFFFF4F5E)
                              : const Color(0xFF0F6BFF),
                          disabledBackgroundColor: const Color(0xFFB7C7E6),
                          shape: const CircleBorder(),
                        ),
                        child: Icon(
                          _controller.availabilityStatus ==
                                      SpeechFeatureStatus.downloadable &&
                                  !_controller.isListening
                              ? Icons.download_rounded
                              : _controller.isListening
                              ? Icons.stop_rounded
                              : Icons.mic_rounded,
                          size: 36,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      _primaryLabel(_controller),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: const Color(0xFF10203B),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _primaryLabel(SpeechController controller) {
    if (controller.availabilityStatus == SpeechFeatureStatus.downloadable &&
        !controller.isListening) {
      return 'Prepare speech model';
    }
    if (controller.isListening) {
      return 'Stop listening';
    }
    return 'Start voice search';
  }

  String _modeLabel(SpeechRecognizerMode mode) {
    switch (mode) {
      case SpeechRecognizerMode.auto:
        return 'Auto mode';
      case SpeechRecognizerMode.basic:
        return 'Basic mode';
      case SpeechRecognizerMode.advanced:
        return 'Advanced mode';
    }
  }
}

class _TranscriptText extends StatelessWidget {
  const _TranscriptText({required this.controller});

  final SpeechController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Text.rich(
      TextSpan(
        children: [
          if (controller.finalTranscript.isNotEmpty)
            TextSpan(
              text: controller.finalTranscript,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: const Color(0xFF10203B),
                height: 1.35,
              ),
            ),
          if (controller.finalTranscript.isNotEmpty &&
              controller.livePartialTranscript.isNotEmpty)
            const TextSpan(text: '\n'),
          if (controller.livePartialTranscript.isNotEmpty)
            TextSpan(
              text: controller.livePartialTranscript,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: const Color(0xFF6A7890),
                fontStyle: FontStyle.italic,
                height: 1.35,
              ),
            ),
        ],
      ),
    );
  }
}
