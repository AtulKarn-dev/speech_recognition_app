import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'speech/speech_controller.dart';
import 'speech/speech_platform_service.dart';
import 'speech/speech_session_store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SpeechRecognitionApp());
}

class SpeechRecognitionApp extends StatelessWidget {
  const SpeechRecognitionApp({super.key, this.service, this.sessionStore});

  final SpeechRecognitionService? service;
  final SpeechSessionStore? sessionStore;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Voice Search',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0F766E),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF6F1E8),
        textTheme: GoogleFonts.manropeTextTheme(),
      ),
      home: SpeechRecognitionScreen(
        service: service,
        sessionStore: sessionStore,
      ),
    );
  }
}

class SpeechRecognitionScreen extends StatefulWidget {
  const SpeechRecognitionScreen({super.key, this.service, this.sessionStore});

  final SpeechRecognitionService? service;
  final SpeechSessionStore? sessionStore;

  @override
  State<SpeechRecognitionScreen> createState() =>
      _SpeechRecognitionScreenState();
}

class _SpeechRecognitionScreenState extends State<SpeechRecognitionScreen> {
  late final SpeechController _controller;

  @override
  void initState() {
    super.initState();
    _controller = SpeechController(
      service: widget.service ?? SpeechToTextSpeechRecognitionService(),
      sessionStore: widget.sessionStore ?? SqfliteSpeechSessionStore(),
    );
    _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final theme = Theme.of(context);
        return Scaffold(
          body: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFFFFBF4), Color(0xFFE8F4F1)],
              ),
            ),
            child: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 12),
                        Text(
                          'Voice Search',
                          style: theme.textTheme.displaySmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: -1.0,
                            color: const Color(0xFF123B36),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Tap the microphone, speak naturally, and the text appears below like a search box.',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: const Color(0xFF4D625F),
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 20),
                        _LanguageModeSelector(controller: _controller),
                        const SizedBox(height: 24),
                        _StatusCard(controller: _controller),
                        const SizedBox(height: 16),
                        Expanded(
                          child: _TranscriptPanel(controller: _controller),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _controller.canStartListening
                                    ? _controller.startListening
                                    : (_controller.isListening
                                          ? _controller.stopListening
                                          : null),
                                icon: Icon(
                                  _controller.isListening
                                      ? Icons.stop_rounded
                                      : Icons.mic_rounded,
                                ),
                                label: Text(
                                  _controller.isListening
                                      ? 'Stop listening'
                                      : 'Start listening',
                                ),
                                style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 18,
                                    horizontal: 18,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            OutlinedButton(
                              onPressed:
                                  _controller.hasTranscript ||
                                      _controller.errorMessage.isNotEmpty
                                  ? _controller.clearTranscript
                                  : null,
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 18,
                                  horizontal: 18,
                                ),
                              ),
                              child: const Text('Clear text'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LanguageModeSelector extends StatelessWidget {
  const _LanguageModeSelector({required this.controller});

  final SpeechController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Language mode',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
            color: const Color(0xFF123B36),
          ),
        ),
        const SizedBox(height: 10),
        SegmentedButton<SpeechLanguageMode>(
          showSelectedIcon: false,
          multiSelectionEnabled: false,
          emptySelectionAllowed: false,
          segments: controller.supportedLanguages
              .map(
                (language) => ButtonSegment<SpeechLanguageMode>(
                  value: language,
                  label: Text(language.label),
                ),
              )
              .toList(),
          selected: {controller.selectedLanguage},
          onSelectionChanged: controller.isListening
              ? null
              : (selection) {
                  controller.selectLanguage(selection.first);
                },
        ),
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.controller});

  final SpeechController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = controller.speechEnabled
        ? const Color(0xFF0F766E)
        : const Color(0xFF9A3412);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: accent.withValues(alpha: 0.12)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 24,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              controller.statusMessage,
              style: theme.textTheme.titleMedium?.copyWith(
                color: const Color(0xFF173A36),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TranscriptPanel extends StatelessWidget {
  const _TranscriptPanel({required this.controller});

  final SpeechController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final transcript = controller.recognizedText.trim().isEmpty
        ? 'Your spoken text will appear here.'
        : controller.recognizedText;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Transcript',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
            color: const Color(0xFF123B36),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFFF9FFFE),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: const Color(0xFFB9D8D3)),
            ),
            child: SingleChildScrollView(
              child: Text(
                transcript,
                style: theme.textTheme.headlineSmall?.copyWith(
                  height: 1.35,
                  color: controller.recognizedText.trim().isEmpty
                      ? const Color(0xFF7D8E8B)
                      : const Color(0xFF102C28),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
        if (controller.errorMessage.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            controller.errorMessage,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: const Color(0xFFB42318),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}
