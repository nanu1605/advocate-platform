package `in`.jainavinfotech.advocate_app

import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Answers the notification explainer and preferences (lib/features/onboarding/notifications_screen.dart): the
 * Android 13+ POST_NOTIFICATIONS prompt, whether notifications are on, and the app's notification settings after a
 * denial. flutter_local_notifications shows them but can't open those settings, so this channel stays (ADR 0017).
 */
class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "advocate_app/notifications")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "request" ->
                        if (Build.VERSION.SDK_INT < 33 ||
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                            PackageManager.PERMISSION_GRANTED
                        ) {
                            result.success(true)
                        } else {
                            pending?.success(false)
                            pending = result
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
                        }
                    "enabled" ->
                        result.success(getSystemService(NotificationManager::class.java).areNotificationsEnabled())
                    "openSettings" -> {
                        startActivity(
                            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName),
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_NOTIFICATIONS) return
        pending?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
        pending = null
    }

    private companion object {
        const val REQUEST_NOTIFICATIONS = 7
    }
}
