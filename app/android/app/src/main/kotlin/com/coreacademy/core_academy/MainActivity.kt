package com.coreacademy.core_academy

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Push notifications arrive on this channel (the default in AndroidManifest.xml). Creating
        // a channel that exists already does nothing, so this is safe on every start.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel("tests", "Tests", NotificationManager.IMPORTANCE_HIGH)
            channel.description = "New tests, reminders before a test closes, and the teacher's daily summary"
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // While a student is logged in the app sets FLAG_SECURE: Android then blocks screenshots
        // and screen recording, and shows the app blank in the recent-apps list.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "core_academy/screen").setMethodCallHandler { call, result ->
            if (call.method == "setSecure") {
                if (call.arguments == true) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
        // In-app updates: see Updater.kt and lib/core/updater.dart.
        val updates = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, Updater.CHANNEL)
        updates.setMethodCallHandler { call, result -> Updater.handle(this, call, result) }
        Updater.channel = updates
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        Updater.channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
