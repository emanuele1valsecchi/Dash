package com.example.dash.dash_wear

import android.content.pm.PackageManager
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private companion object {
        const val HEART_RATE_REQUEST = 4201
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestHeartRatePermissionIfNeeded()
    }

    /**
     * Asked for here rather than through a Flutter permission plugin, because
     * the permission that actually matters on Wear OS 6
     * (`android.permission.health.READ_HEART_RATE`) is a Health Connect
     * permission that `permission_handler` has no mapping for. Requesting
     * BODY_SENSORS through it succeeds and grants nothing useful.
     *
     * Fire-and-forget: Dart polls [HeartRatePlugin]'s `hasPermission` until it
     * flips, so there is no result callback to thread back through the engine.
     */
    private fun requestHeartRatePermissionIfNeeded() {
        // Location and notifications matter as much as the sensor now: without
        // POST_NOTIFICATIONS the standalone foreground service cannot run at
        // all, and without location there is nothing to record. Requested
        // together so the runner answers one series of prompts, not three
        // spread across the first run.
        val wanted = listOf(
            HeartRatePlugin.permissionToRequest(),
            android.Manifest.permission.ACCESS_FINE_LOCATION,
            android.Manifest.permission.POST_NOTIFICATIONS,
        )
        val missing = wanted.filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) return
        Log.i("DashHeartRate", "requesting $missing")
        requestPermissions(missing.toTypedArray(), HEART_RATE_REQUEST)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != HEART_RATE_REQUEST) return
        // Logged rather than pushed to Dart: HeartRateService polls
        // `hasPermission` and picks the grant up on its own. This is purely so a
        // refusal is visible in logcat instead of looking like a dead sensor.
        Log.i(
            "DashHeartRate",
            "result: ${permissions.toList()} -> ${grantResults.toList()}",
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        WearBridgePlugin(applicationContext).register(messenger)
        HeartRatePlugin(applicationContext).register(messenger)
        RunServicePlugin(applicationContext).register(messenger)

        // Window flags need the Activity, which the application-context plugins
        // above do not have — hence handling this here rather than in one of
        // them. KEEP_SCREEN_ON stops Wear blanking the display mid-run; ambient
        // mode still dims it, which is the behaviour we want.
        MethodChannel(messenger, "dash/screen").setMethodCallHandler { call, result ->
            when (call.method) {
                "keepAwake" -> {
                    val keep = call.argument<Boolean>("keep") ?: false
                    runOnUiThread {
                        if (keep) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
