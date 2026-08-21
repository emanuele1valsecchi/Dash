package com.example.dash

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Lets Dart start, update and stop [RunForegroundService].
 *
 * Thin on purpose. Dart decides *when* a run is being recorded and what the
 * notification should say; this only relays that decision, so there is no run
 * state duplicated on the native side to fall out of step.
 */
class RunServicePlugin(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        private const val CHANNEL = "dash/run_service"
    }

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                RunForegroundService.start(context, title(call), body(call))
                result.success(true)
            }
            "update" -> {
                RunForegroundService.update(context, title(call), body(call))
                result.success(true)
            }
            "stop" -> {
                RunForegroundService.stop(context)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun title(call: MethodCall) =
        call.argument<String>("title") ?: "Recording run"

    private fun body(call: MethodCall) = call.argument<String>("body") ?: ""
}
