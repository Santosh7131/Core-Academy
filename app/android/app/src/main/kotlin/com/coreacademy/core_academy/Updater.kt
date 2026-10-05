package com.coreacademy.core_academy

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

/**
 * Installs an update the app has downloaded itself (lib/core/updater.dart does the download).
 *
 * Android 12 and later let an app update itself without the Install prompt, once the user has
 * allowed it to install apps: the session asks for USER_ACTION_NOT_REQUIRED, and the manifest
 * declares UPDATE_PACKAGES_WITHOUT_USER_ACTION. Older Android shows the usual prompt instead.
 * Either way Android closes the app while it replaces it.
 */
object Updater {
    const val CHANNEL = "core_academy/updater"
    private const val MARKER = "update-pending"
    private const val NOTIFICATION_ID = 7

    private val main = Handler(Looper.getMainLooper())
    var channel: MethodChannel? = null

    fun handle(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "info" -> {
                val pm = activity.packageManager
                val info = pm.getPackageInfo(activity.packageName, 0)
                val code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()
                result.success(
                    mapOf(
                        "version" to info.versionName,
                        "build" to code,
                        "canInstall" to canInstall(activity),
                        "silent" to (Build.VERSION.SDK_INT >= 31),
                        "dir" to File(activity.cacheDir, "updates").absolutePath,
                    ),
                )
            }
            "allowInstalls" -> {
                // The per-app "Install unknown apps" switch for Core Academy.
                activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")))
                result.success(null)
            }
            "install" -> {
                val path = call.argument<String>("path")!!
                val sha256 = call.argument<String>("sha256")!!.lowercase()
                val version = call.argument<String>("version") ?: ""
                val context = activity.applicationContext
                Thread {
                    try {
                        val file = File(path)
                        if (digest(file) != sha256) {
                            file.delete()
                            main.post { result.error("digest", "The download was damaged. Try again.", null) }
                            return@Thread
                        }
                        commit(context, file, version)
                        main.post { result.success(null) }
                    } catch (e: Exception) {
                        clearMarker(context)
                        main.post { result.error("install", e.message ?: e.toString(), null) }
                    }
                }.start()
            }
            else -> result.notImplemented()
        }
    }

    private fun canInstall(context: Context) =
        Build.VERSION.SDK_INT < 26 || context.packageManager.canRequestPackageInstalls()

    private fun digest(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(1 shl 16)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    private fun commit(context: Context, file: File, version: String) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(context.packageName)
        params.setSize(file.length())
        if (Build.VERSION.SDK_INT >= 26) params.setInstallReason(PackageManager.INSTALL_REASON_USER)
        if (Build.VERSION.SDK_INT >= 31) params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            file.inputStream().use { input ->
                session.openWrite("core-academy.apk", 0, file.length()).use { out ->
                    input.copyTo(out, 1 shl 16)
                    session.fsync(out)
                }
            }
            // Read back after Android restarts the app, to say the update went in.
            File(context.filesDir, MARKER).writeText(version)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
            val status = PendingIntent.getBroadcast(context, id, Intent(context, UpdateStatusReceiver::class.java), flags)
            session.commit(status.intentSender)
        }
    }

    fun report(status: String, message: String?) {
        main.post { channel?.invokeMethod("status", mapOf("status" to status, "message" to message)) }
    }

    fun clearMarker(context: Context) {
        File(context.filesDir, MARKER).delete()
    }

    /** True once after an update this app installed itself. */
    fun takeMarker(context: Context): Boolean {
        val f = File(context.filesDir, MARKER)
        return f.exists() && f.delete()
    }

    /** Android does not reopen an app it has just updated, so a notification offers the way back in. */
    fun notifyUpdated(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
        val open = PendingIntent.getActivity(context, 0, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val version = context.packageManager.getPackageInfo(context.packageName, 0).versionName
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel("updates", "App updates", NotificationManager.IMPORTANCE_HIGH))
            Notification.Builder(context, "updates")
        } else {
            @Suppress("DEPRECATION") Notification.Builder(context)
        }
        val n = builder
            .setSmallIcon(R.drawable.ic_stat_notify)
            .setContentTitle("Core Academy is updated")
            .setContentText("Version $version is in. Tap to open the app.")
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        nm.notify(NOTIFICATION_ID, n)
    }
}

/** Where Android reports how an install session went. */
class UpdateStatusReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                // Android wants the user to confirm: show its Install prompt.
                val confirm: Intent? = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_INTENT)
                }
                confirm?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (confirm != null) context.startActivity(confirm)
                Updater.report("confirm", null)
            }
            PackageInstaller.STATUS_SUCCESS -> Updater.report("installed", null)
            PackageInstaller.STATUS_FAILURE_ABORTED -> {
                // The user said no at Android's Install prompt.
                Updater.clearMarker(context)
                Updater.report("cancelled", null)
            }
            else -> {
                Updater.clearMarker(context)
                Updater.report("failed", intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE))
            }
        }
    }
}

/** Runs after any update to this app; speaks up only when the app installed the update itself. */
class UpdatedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_MY_PACKAGE_REPLACED && Updater.takeMarker(context)) {
            Updater.notifyUpdated(context)
        }
    }
}
