package com.coreacademy.core_academy

import android.app.Activity
import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Saves a file the app has downloaded (the Library's PDFs and photos) straight into the phone's Downloads folder, with no folder of its own,
 * where it shows as the newest item in the file app's Recent list like any other download (lib/core/library.dart downloads it first).
 * Android 10 and later let an app add to Downloads through MediaStore without asking for any permission; a name that is already taken
 * becomes "name (1).pdf". Older Android would need a storage permission, so there the answer is null and the app opens the share sheet instead.
 */
object Files {
    const val CHANNEL = "core_academy/files"
    private val main = Handler(Looper.getMainLooper())

    fun handle(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "saveToDownloads") {
            result.notImplemented()
            return
        }
        val path = call.argument<String>("path")
        val name = call.argument<String>("name")
        val mime = call.argument<String>("mime") ?: "application/octet-stream"
        if (path == null || name == null) {
            result.error("bad_call", "A path and a name are needed.", null)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Copying a big file takes a moment: not on the main thread.
            Thread { save(activity, path, name, mime, result) }.start()
        } else {
            result.success(null)
        }
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun save(activity: Activity, path: String, name: String, mime: String, result: MethodChannel.Result) {
        try {
            val resolver = activity.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("The phone would not make the file.")
            try {
                val out = resolver.openOutputStream(uri) ?: throw IllegalStateException("The phone would not open the file.")
                out.use { o -> File(path).inputStream().use { it.copyTo(o) } }
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (e: Exception) {
                // A half-written file is not left behind.
                resolver.delete(uri, null, null)
                throw e
            }
            main.post { result.success("Downloads") }
        } catch (e: Exception) {
            main.post { result.error("save_failed", e.message, null) }
        }
    }
}
