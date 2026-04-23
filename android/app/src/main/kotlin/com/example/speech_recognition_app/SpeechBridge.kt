package com.example.speech_recognition_app

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Build
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer as AndroidSpeechRecognizer
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.audio.AudioSource
import com.google.mlkit.genai.speechrecognition.SpeechRecognition
import com.google.mlkit.genai.speechrecognition.SpeechRecognizer as MlKitSpeechRecognizer
import com.google.mlkit.genai.speechrecognition.SpeechRecognizerOptions
import com.google.mlkit.genai.speechrecognition.SpeechRecognizerResponse
import com.google.mlkit.genai.speechrecognition.speechRecognizerOptions
import com.google.mlkit.genai.speechrecognition.speechRecognizerRequest
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class SpeechBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL_NAME)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL_NAME)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val sessions = mutableMapOf<String, SpeechSession>()

    private var eventSink: EventChannel.EventSink? = null

    init {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    override fun onMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            CHECK_STATUS -> handleCheckStatus(call, result)
            DOWNLOAD_MODEL -> handleDownloadModel(call, result)
            START_RECOGNITION -> handleStartRecognition(call, result)
            STOP_RECOGNITION -> handleStopRecognition(call, result)
            CLOSE -> handleClose(call, result)
            else -> result.notImplemented()
        }
    }

    override fun onListen(
        arguments: Any?,
        events: EventChannel.EventSink?,
    ) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun dispose() {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)

        sessions.values.toList().forEach(::closeSession)
        sessions.clear()
        scope.cancel()
        eventSink = null
    }

    private fun handleCheckStatus(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val session = getOrCreateSession(call)
        emitState(session.id, "checking")

        scope.launch {
            val availability =
                runCatching {
                    resolveAvailability(session)
                }.getOrElse { throwable ->
                    fallbackAvailability(session, throwable.message)
                }

            if ((availability[STATUS_INDEX_KEY] as Int) == STATUS_AVAILABLE_INDEX) {
                emitState(session.id, "ready")
            }
            result.success(availability)
        }
    }

    private fun handleDownloadModel(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val session = getOrCreateSession(call)
        val recognizer = session.mlKitRecognizer
        if (session.backend == BACKEND_PLATFORM || recognizer == null) {
            result.success(mapOf("accepted" to false))
            return
        }

        session.downloadJob?.cancel()
        session.downloadJob =
            scope.launch {
                var totalBytes = 0L
                emitState(session.id, "downloading")

                runCatching {
                    recognizer.download().collect { downloadStatus ->
                        when (downloadStatus) {
                            is DownloadStatus.DownloadStarted -> {
                                totalBytes = downloadStatus.bytesToDownload
                                emitDownload(
                                    id = session.id,
                                    phase = "started",
                                    downloadedBytes = 0L,
                                    totalBytes = totalBytes,
                                )
                            }

                            is DownloadStatus.DownloadProgress -> {
                                emitDownload(
                                    id = session.id,
                                    phase = "progress",
                                    downloadedBytes = downloadStatus.totalBytesDownloaded,
                                    totalBytes = totalBytes,
                                )
                            }

                            is DownloadStatus.DownloadCompleted -> {
                                emitDownload(
                                    id = session.id,
                                    phase = "completed",
                                    downloadedBytes = totalBytes,
                                    totalBytes = totalBytes,
                                )
                                emitState(session.id, "ready")
                            }

                            is DownloadStatus.DownloadFailed -> {
                                emitDownload(
                                    id = session.id,
                                    phase = "failed",
                                    message = downloadStatus.e.message,
                                )
                                emitError(
                                    id = session.id,
                                    code = mapErrorCode(downloadStatus.e.message, "AICORE_DOWNLOAD_ERROR"),
                                    message = downloadStatus.e.message ?: "Speech model download failed.",
                                    recoverable = true,
                                )
                            }
                        }
                    }
                }.onFailure { throwable ->
                    emitDownload(
                        id = session.id,
                        phase = "failed",
                        message = throwable.message,
                    )
                    emitError(
                        id = session.id,
                        code = mapErrorCode(throwable.message, "AICORE_DOWNLOAD_ERROR"),
                        message = throwable.message ?: "Speech model download failed.",
                        recoverable = true,
                    )
                }
            }

        result.success(mapOf("accepted" to true))
    }

    private fun handleStartRecognition(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val session = getOrCreateSession(call)
        session.recognitionJob?.cancel()
        session.sequence = 0

        if (session.backend == BACKEND_PLATFORM) {
            session.stopRequested = false

            runCatching {
                emitState(session.id, "starting")
                platformRecognizer(session).startListening(platformRecognizerIntent(session.localeTag))
                result.success(mapOf("started" to true))
            }.onFailure { throwable ->
                result.error(
                    "START_FAILED",
                    throwable.message ?: "Failed to start speech recognition.",
                    null,
                )
            }
            return
        }

        val recognizer = session.mlKitRecognizer
        if (recognizer == null) {
            val availability = fallbackAvailability(session, "Speech recognition is unavailable.")
            result.error(
                "UNSUPPORTED_DEVICE",
                availability[MESSAGE_KEY] as String? ?: "Speech recognition is unavailable.",
                null,
            )
            return
        }

        session.recognitionJob =
            scope.launch {
                emitState(session.id, "starting")

                runCatching {
                    val request = speechRecognizerRequest { audioSource = AudioSource.fromMic() }
                    emitState(session.id, "listening")

                    recognizer.startRecognition(request).collect { response ->
                        when (response) {
                            is SpeechRecognizerResponse.PartialTextResponse -> {
                                emitTranscript(session, response.text, false)
                            }

                            is SpeechRecognizerResponse.FinalTextResponse -> {
                                emitTranscript(session, response.text, true)
                            }

                            is SpeechRecognizerResponse.CompletedResponse -> {
                                emitState(session.id, "completed")
                            }

                            is SpeechRecognizerResponse.ErrorResponse -> {
                                emitError(
                                    id = session.id,
                                    code = mapErrorCode(response.e.message, "STREAM_FAILED"),
                                    message = response.e.message
                                        ?: "Speech recognition failed.",
                                    recoverable = false,
                                )
                                emitState(session.id, "stopped")
                            }
                        }
                    }
                }.onFailure { throwable ->
                    emitError(
                        id = session.id,
                        code = mapErrorCode(throwable.message, "START_FAILED"),
                        message = throwable.message ?: "Failed to start speech recognition.",
                        recoverable = false,
                    )
                    emitState(session.id, "stopped")
                }

                session.recognitionJob = null
            }

        result.success(mapOf("started" to true))
    }

    private fun handleStopRecognition(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val id = call.argument<String>(ID_KEY) ?: return result.success(mapOf("stopped" to true))
        val session = sessions[id] ?: return result.success(mapOf("stopped" to true))

        scope.launch {
            session.stopRequested = true
            runCatching {
                if (session.backend == BACKEND_PLATFORM) {
                    platformRecognizer(session).stopListening()
                } else {
                    session.mlKitRecognizer?.stopRecognition()
                }
            }
            session.recognitionJob?.cancel()
            session.recognitionJob = null
            emitState(session.id, "stopped")
            result.success(mapOf("stopped" to true))
        }
    }

    private fun handleClose(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val id = call.argument<String>(ID_KEY)
        if (id != null) {
            sessions.remove(id)?.let(::closeSession)
        }
        result.success(mapOf("closed" to true))
    }

    private fun getOrCreateSession(call: MethodCall): SpeechSession {
        val id = call.argument<String>(ID_KEY) ?: error("Missing speech session id.")
        val localeTag = call.argument<String>(LOCALE_KEY) ?: DEFAULT_LOCALE
        val preferredMode = call.argument<String>(PREFERRED_MODE_KEY) ?: MODE_AUTO
        val resolvedMode = resolveMode(preferredMode)

        val existing = sessions[id]
        if (
            existing != null &&
            existing.localeTag == localeTag &&
            existing.preferredMode == preferredMode
        ) {
            return existing
        }

        existing?.let(::closeSession)

        return SpeechSession(
            id = id,
            localeTag = localeTag,
            preferredMode = preferredMode,
            resolvedMode = resolvedMode,
            mlKitRecognizer = createMlKitSpeechRecognizer(localeTag, resolvedMode),
        ).also { sessions[id] = it }
    }

    private fun createMlKitSpeechRecognizer(
        localeTag: String,
        resolvedMode: String,
    ): MlKitSpeechRecognizer? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            return null
        }

        val locale = Locale.forLanguageTag(localeTag.ifBlank { DEFAULT_LOCALE })
        val mode =
            when (resolvedMode) {
                MODE_ADVANCED -> SpeechRecognizerOptions.Mode.MODE_ADVANCED
                else -> SpeechRecognizerOptions.Mode.MODE_BASIC
            }

        val options = speechRecognizerOptions {
            this.locale = locale
            preferredMode = mode
        }
        return SpeechRecognition.getClient(options)
    }

    private suspend fun resolveAvailability(session: SpeechSession): Map<String, Any?> {
        val recognizer = session.mlKitRecognizer
        if (recognizer != null) {
            val status = recognizer.checkStatus()
            if (status != FeatureStatus.UNAVAILABLE) {
                session.backend = BACKEND_ML_KIT
                return availabilityMap(
                    status = status,
                    resolvedMode = session.resolvedMode,
                )
            }
        }

        return fallbackAvailability(session, null)
    }

    private fun fallbackAvailability(
        session: SpeechSession,
        failureMessage: String?,
    ): Map<String, Any?> {
        if (AndroidSpeechRecognizer.isRecognitionAvailable(context)) {
            session.backend = BACKEND_PLATFORM
            return availabilityMap(
                status = FeatureStatus.AVAILABLE,
                resolvedMode = MODE_BASIC,
            )
        }

        session.backend = BACKEND_ML_KIT
        return unsupportedAvailability(
            preferredMode = session.resolvedMode,
            message = failureMessage ?: "Speech recognition is unavailable on this device.",
        )
    }

    private fun platformRecognizer(session: SpeechSession): AndroidSpeechRecognizer {
        session.platformRecognizer?.let { return it }

        val recognizer = AndroidSpeechRecognizer.createSpeechRecognizer(context)
        recognizer.setRecognitionListener(
            object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {
                    emitState(session.id, "listening")
                }

                override fun onBeginningOfSpeech() = Unit

                override fun onRmsChanged(rmsdB: Float) = Unit

                override fun onBufferReceived(buffer: ByteArray?) = Unit

                override fun onEndOfSpeech() = Unit

                override fun onError(error: Int) {
                    if (session.stopRequested && error == AndroidSpeechRecognizer.ERROR_CLIENT) {
                        session.stopRequested = false
                        emitState(session.id, "stopped")
                        return
                    }

                    session.stopRequested = false
                    emitError(
                        id = session.id,
                        code = platformErrorCode(error),
                        message = platformErrorMessage(error),
                        recoverable = error == AndroidSpeechRecognizer.ERROR_NO_MATCH ||
                            error == AndroidSpeechRecognizer.ERROR_SPEECH_TIMEOUT,
                    )
                    emitState(session.id, "stopped")
                }

                override fun onResults(results: Bundle?) {
                    session.stopRequested = false
                    transcriptFromBundle(results)?.let { emitTranscript(session, it, true) }
                    emitState(session.id, "completed")
                }

                override fun onPartialResults(partialResults: Bundle?) {
                    transcriptFromBundle(partialResults)?.let { emitTranscript(session, it, false) }
                }

                override fun onEvent(
                    eventType: Int,
                    params: Bundle?,
                ) = Unit
            },
        )
        session.platformRecognizer = recognizer
        return recognizer
    }

    private fun platformRecognizerIntent(localeTag: String): Intent {
        val languageTag = Locale.forLanguageTag(localeTag.ifBlank { DEFAULT_LOCALE }).toLanguageTag()
        return Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, languageTag)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, languageTag)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, MINIMUM_LISTENING_MILLIS)
            putExtra(
                RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS,
                COMPLETE_SILENCE_MILLIS,
            )
            putExtra(
                RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS,
                POSSIBLY_COMPLETE_SILENCE_MILLIS,
            )
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
        }
    }

    private fun transcriptFromBundle(results: Bundle?): String? {
        return results
            ?.getStringArrayList(AndroidSpeechRecognizer.RESULTS_RECOGNITION)
            ?.firstOrNull()
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
    }

    private fun platformErrorCode(error: Int): String {
        return when (error) {
            AndroidSpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "PERMISSION_DENIED"
            AndroidSpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED,
            AndroidSpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "UNSUPPORTED_DEVICE"
            else -> "STREAM_FAILED"
        }
    }

    private fun platformErrorMessage(error: Int): String {
        return when (error) {
            AndroidSpeechRecognizer.ERROR_AUDIO -> "Audio recording failed while starting speech recognition."
            AndroidSpeechRecognizer.ERROR_CLIENT -> "Speech recognition was stopped before it could finish."
            AndroidSpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Microphone permission is required before voice search can begin."
            AndroidSpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> "Nepali recognition is not supported by the installed speech service."
            AndroidSpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "Nepali recognition is currently unavailable in the installed speech service."
            AndroidSpeechRecognizer.ERROR_NETWORK,
            AndroidSpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "A network error interrupted speech recognition."
            AndroidSpeechRecognizer.ERROR_NO_MATCH -> "No speech was recognized. Try again and speak more clearly."
            AndroidSpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "Speech recognition is busy. Stop the current session and try again."
            AndroidSpeechRecognizer.ERROR_SERVER -> "The speech recognition service failed to process the request."
            AndroidSpeechRecognizer.ERROR_SERVER_DISCONNECTED -> "The speech recognition service disconnected unexpectedly."
            AndroidSpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "No speech was detected. Try again and speak sooner."
            else -> "Speech recognition failed to start."
        }
    }

    private fun availabilityMap(
        status: Int,
        resolvedMode: String,
    ): Map<String, Any?> {
        val statusIndex =
            when (status) {
                FeatureStatus.UNAVAILABLE -> 0
                FeatureStatus.DOWNLOADABLE -> 1
                FeatureStatus.DOWNLOADING -> 2
                FeatureStatus.AVAILABLE -> 3
                else -> 0
            }

        return mapOf(
            STATUS_INDEX_KEY to statusIndex,
            STATUS_KEY to statusName(statusIndex),
            RESOLVED_MODE_KEY to resolvedMode,
            SUPPORTED_KEY to (statusIndex != 0),
            REQUIRES_DOWNLOAD_KEY to (statusIndex == 1),
            MESSAGE_KEY to if (statusIndex == 0) {
                "Speech recognition is not currently available on this device."
            } else {
                null
            },
        )
    }

    private fun unsupportedAvailability(
        preferredMode: String,
        message: String,
    ): Map<String, Any?> {
        return mapOf(
            STATUS_INDEX_KEY to 0,
            STATUS_KEY to statusName(0),
            RESOLVED_MODE_KEY to resolveMode(preferredMode),
            SUPPORTED_KEY to false,
            REQUIRES_DOWNLOAD_KEY to false,
            MESSAGE_KEY to message,
        )
    }

    private fun closeSession(session: SpeechSession) {
        session.downloadJob?.cancel()
        session.recognitionJob?.cancel()
        session.platformRecognizer?.let { recognizer ->
            runCatching {
                recognizer.cancel()
                recognizer.destroy()
            }
        }
        session.platformRecognizer = null
        session.stopRequested = false
        session.mlKitRecognizer?.let { recognizer ->
            runCatching { recognizer.close() }
        }
    }

    private fun resolveMode(preferredMode: String): String {
        return when (preferredMode) {
            MODE_ADVANCED -> MODE_ADVANCED
            MODE_BASIC -> MODE_BASIC
            else -> MODE_BASIC
        }
    }

    private fun emitState(
        id: String,
        state: String,
    ) {
        emit(
            mapOf(
                TYPE_KEY to STATE_TYPE,
                ID_KEY to id,
                STATE_KEY to state,
            ),
        )
    }

    private fun emitDownload(
        id: String,
        phase: String,
        downloadedBytes: Long? = null,
        totalBytes: Long? = null,
        message: String? = null,
    ) {
        emit(
            mapOf(
                TYPE_KEY to DOWNLOAD_TYPE,
                ID_KEY to id,
                PHASE_KEY to phase,
                DOWNLOADED_BYTES_KEY to downloadedBytes,
                TOTAL_BYTES_KEY to totalBytes,
                MESSAGE_KEY to message,
            ),
        )
    }

    private fun emitTranscript(
        session: SpeechSession,
        text: String,
        isFinal: Boolean,
    ) {
        val sequence = session.sequence++
        emit(
            mapOf(
                TYPE_KEY to TRANSCRIPT_TYPE,
                ID_KEY to session.id,
                TEXT_KEY to text,
                IS_FINAL_KEY to isFinal,
                SEQUENCE_KEY to sequence,
                LOCALE_KEY to session.localeTag,
                MODE_KEY to session.resolvedMode,
                TIMESTAMP_MS_KEY to System.currentTimeMillis(),
            ),
        )
    }

    private fun emitError(
        id: String,
        code: String,
        message: String,
        recoverable: Boolean,
    ) {
        emit(
            mapOf(
                TYPE_KEY to ERROR_TYPE,
                ID_KEY to id,
                CODE_KEY to code,
                MESSAGE_KEY to message,
                RECOVERABLE_KEY to recoverable,
            ),
        )
    }

    private fun emit(payload: Map<String, Any?>) {
        eventSink?.success(payload)
    }

    private fun statusName(statusIndex: Int): String {
        return when (statusIndex) {
            1 -> "downloadable"
            2 -> "downloading"
            3 -> "available"
            else -> "unavailable"
        }
    }

    private fun mapErrorCode(
        message: String?,
        fallback: String,
    ): String {
        val normalized = message?.uppercase(Locale.US).orEmpty()
        return when {
            normalized.contains("PERMISSION") -> "PERMISSION_DENIED"
            normalized.contains("BINDING_FAILURE") -> "AICORE_BINDING_FAILURE"
            normalized.contains("FEATURE_NOT_FOUND") ||
                normalized.contains("NOT AVAILABLE") ||
                normalized.contains("UNAVAILABLE") ||
                normalized.contains("ANDROID 12") -> "UNSUPPORTED_DEVICE"
            normalized.contains("DOWNLOAD_ERROR") ||
                normalized.contains("RESOLVE HOST") -> "AICORE_DOWNLOAD_ERROR"
            else -> fallback
        }
    }

    private data class SpeechSession(
        val id: String,
        val localeTag: String,
        val preferredMode: String,
        val resolvedMode: String,
        val mlKitRecognizer: MlKitSpeechRecognizer?,
        var backend: String = BACKEND_ML_KIT,
        var platformRecognizer: AndroidSpeechRecognizer? = null,
        var recognitionJob: Job? = null,
        var downloadJob: Job? = null,
        var stopRequested: Boolean = false,
        var sequence: Int = 0,
    )

    companion object {
        private const val METHOD_CHANNEL_NAME = "speech_recognition_app/speech/methods"
        private const val EVENT_CHANNEL_NAME = "speech_recognition_app/speech/events"

        private const val CHECK_STATUS = "genai#checkStatus"
        private const val DOWNLOAD_MODEL = "genai#downloadModel"
        private const val START_RECOGNITION = "genai#startRecognition"
        private const val STOP_RECOGNITION = "genai#stopRecognition"
        private const val CLOSE = "genai#closeSpeechRecognizer"

        private const val MODE_AUTO = "auto"
        private const val MODE_BASIC = "basic"
        private const val MODE_ADVANCED = "advanced"
        private const val BACKEND_ML_KIT = "mlkit"
        private const val BACKEND_PLATFORM = "platform"
        private const val DEFAULT_LOCALE = "ne-NP"
        private const val STATUS_AVAILABLE_INDEX = 3
        private const val MINIMUM_LISTENING_MILLIS = 4_000L
        private const val COMPLETE_SILENCE_MILLIS = 1_800L
        private const val POSSIBLY_COMPLETE_SILENCE_MILLIS = 1_200L

        private const val TYPE_KEY = "type"
        private const val ID_KEY = "id"
        private const val STATE_KEY = "state"
        private const val PHASE_KEY = "phase"
        private const val TEXT_KEY = "text"
        private const val CODE_KEY = "code"
        private const val MESSAGE_KEY = "message"
        private const val RECOVERABLE_KEY = "recoverable"
        private const val STATUS_KEY = "status"
        private const val STATUS_INDEX_KEY = "statusIndex"
        private const val SUPPORTED_KEY = "supported"
        private const val REQUIRES_DOWNLOAD_KEY = "requiresDownload"
        private const val RESOLVED_MODE_KEY = "resolvedMode"
        private const val DOWNLOADED_BYTES_KEY = "downloadedBytes"
        private const val TOTAL_BYTES_KEY = "totalBytes"
        private const val IS_FINAL_KEY = "isFinal"
        private const val SEQUENCE_KEY = "sequence"
        private const val TIMESTAMP_MS_KEY = "timestampMs"
        private const val PREFERRED_MODE_KEY = "preferredMode"
        private const val LOCALE_KEY = "locale"
        private const val MODE_KEY = "mode"

        private const val STATE_TYPE = "state"
        private const val DOWNLOAD_TYPE = "download"
        private const val TRANSCRIPT_TYPE = "transcript"
        private const val ERROR_TYPE = "error"
    }
}