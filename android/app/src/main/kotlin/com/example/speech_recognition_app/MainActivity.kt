package com.example.speech_recognition_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
	private var speechBridge: SpeechBridge? = null

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		speechBridge = SpeechBridge(this, flutterEngine.dartExecutor.binaryMessenger)
	}

	override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
		speechBridge?.dispose()
		speechBridge = null
		super.cleanUpFlutterEngine(flutterEngine)
	}
}
