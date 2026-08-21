package com.example.dash.dash_wear

import android.content.pm.PackageManager
import android.os.Bundle
import android.util.Log
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
        val permission = HeartRatePlugin.permissionToRequest()
        if (checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) return
        Log.i("DashHeartRate", "requesting $permission")
        requestPermissions(arrayOf(permission), HEART_RATE_REQUEST)
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
    }
}
