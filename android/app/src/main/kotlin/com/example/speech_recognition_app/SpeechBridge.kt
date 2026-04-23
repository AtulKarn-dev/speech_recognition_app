package com.example.speech_recognition_app

import android.content.Context
import android.os.Build
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.audio.AudioSource
import com.google.mlkit.genai.speechrecognition.SpeechRecognition
import com.google.mlkit.genai.speechrecognition.SpeechRecognizer
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
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            result.success(
                unsupportedAvailability(
                    preferredMode = call.argument<String>(PREFERRED_MODE_KEY) ?: MODE_AUTO,
                    message = "Microphone recognition requires Android 12 or newer.",
                ),
            )
            return
        }

        val session = getOrCreateSession(call)
        emitState(session.id, "checking")

        scope.launch {
            val availability =
                runCatching {
                    availabilityMap(
                        status = session.recognizer.checkStatus(),
                        resolvedMode = session.resolvedMode,
                    )
                }.getOrElse { throwable ->
                    unsupportedAvailability(
                        preferredMode = session.resolvedMode,
                        message = throwable.message ?: "Speech recognition is unavailable.",
                    )
                }

            if ((availability[STATUS_INDEX_KEY] as Int) == FeatureStatus.AVAILABLE) {
                emitState(session.id, "ready")
            }
            result.success(availability)
        }
    }

    private fun handleDownloadModel(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            result.error(
                "UNSUPPORTED_DEVICE",
                "Microphone recognition requires Android 12 or newer.",
                null,
            )
            return
        }

        val session = getOrCreateSession(call)
        session.downloadJob?.cancel()
        session.downloadJob =
            scope.launch {
                var totalBytes = 0L
                emitState(session.id, "downloading")

                runCatching {
                    session.recognizer.download().collect { downloadStatus ->
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
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            result.error(
                "UNSUPPORTED_DEVICE",
                "Microphone recognition requires Android 12 or newer.",
                null,
            )
            return
        }

        val session = getOrCreateSession(call)
        session.recognitionJob?.cancel()
        session.sequence = 0

        session.recognitionJob =
            scope.launch {
                emitState(session.id, "starting")

                runCatching {
                    val request = speechRecognizerRequest { audioSource = AudioSource.fromMic() }
                    emitState(session.id, "listening")

                    session.recognizer.startRecognition(request).collect { response ->
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
            runCatching {
                session.recognizer.stopRecognition()
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
            recognizer = createSpeechRecognizer(localeTag, resolvedMode),
        ).also { sessions[id] = it }
    }

    private fun createSpeechRecognizer(
        localeTag: String,
        resolvedMode: String,
    ): SpeechRecognizer {
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
        runCatching { session.recognizer.close() }
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
        val recognizer: SpeechRecognizer,
        var recognitionJob: Job? = null,
        var downloadJob: Job? = null,
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
        private const val DEFAULT_LOCALE = "en-US"

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