package com.example.dash.dash_wear

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        WearBridgePlugin(applicationContext)
            .register(flutterEngine.dartExecutor.binaryMessenger)
    }
}
