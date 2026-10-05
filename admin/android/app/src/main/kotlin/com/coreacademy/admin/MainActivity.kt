package com.coreacademy.admin

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The app's version, the phone it runs on, and installing its own updates (Updater.kt).
        val updates = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, Updater.CHANNEL)
        updates.setMethodCallHandler { call, result -> Updater.handle(this, call, result) }
        Updater.channel = updates
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        Updater.channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
