package com.example.dash.dash_wear

import android.content.Context
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Streams the watch's heart rate sensor to Dart.
 *
 * There is no Flutter plugin that does this reliably — `health` reads Health
 * Connect's historical records, which is a different thing from a live
 * on-wrist sensor feed — so it is a small platform channel instead.
 *
 * Heart rate is the one measurement the phone cannot make, which is why it is
 * the only value in this app that travels watch → phone.
 */
class HeartRatePlugin(private val context: Context) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    SensorEventListener {

    companion object {
        private const val METHOD_CHANNEL = "dash/heart_rate"
        private const val EVENT_CHANNEL = "dash/heart_rate/values"

        /**
         * Native logging, not debugPrint: Dart print output is not forwarded
         * to logcat in release builds, so every Dart-side diagnostic here was
         * invisible on a real device — which is exactly when it is needed.
         */
        private const val TAG = "DashHeartRate"

        /** Not in Manifest.permission until a newer compileSdk exposes it. */
        const val READ_HEART_RATE = "android.permission.health.READ_HEART_RATE"

        /**
         * The permission to actually *request*, which is not the same as the
         * set to *accept*.
         *
         * Requesting both at once fails silently: BODY_SENSORS is declared only
         * up to API 34 (see the manifest), and Android rejects an entire
         * request containing a permission the app does not declare — no dialog,
         * no callback, no error. That cost a debugging round trip, so the
         * request is version-matched to what the manifest actually declares
         * while [hasBodySensors] still accepts either once granted.
         */
        fun permissionToRequest(): String =
            if (android.os.Build.VERSION.SDK_INT >= 35) {
                READ_HEART_RATE
            } else {
                android.Manifest.permission.BODY_SENSORS
            }
    }

    private var eventSink: EventChannel.EventSink? = null
    private var wasValid = false

    private val sensorManager by lazy {
        context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    }
    private val heartRateSensor: Sensor? by lazy {
        sensorManager.getDefaultSensor(Sensor.TYPE_HEART_RATE)
    }

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // Not every Wear device has this sensor. Dart asks first so it can
            // show an honest "--" instead of waiting forever for a reading that
            // is never coming.
            "isAvailable" -> {
                val sensor = heartRateSensor
                Log.i(TAG, "isAvailable: ${sensor?.name ?: "NO SENSOR"}")
                result.success(sensor != null)
            }
            "hasPermission" -> result.success(hasBodySensors())
            else -> result.notImplemented()
        }
    }

    /**
     * Either permission is sufficient, because which one actually guards the
     * sensor depends on the OS version.
     *
     * Android 15 deprecated BODY_SENSORS in favour of Health Connect's granular
     * permissions. On Wear OS 6 the heart rate sensor reports
     * `perm: android.permission.health.READ_HEART_RATE` and BODY_SENSORS buys
     * nothing — a request for it is granted and the sensor still returns
     * silence, which is a miserable thing to debug. Older Wear 3/4 devices are
     * the other way round, hence checking both rather than branching on
     * Build.VERSION.
     */
    private fun hasBodySensors(): Boolean =
        context.checkSelfPermission(READ_HEART_RATE) == PackageManager.PERMISSION_GRANTED ||
            context.checkSelfPermission(android.Manifest.permission.BODY_SENSORS) ==
                PackageManager.PERMISSION_GRANTED

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        val sensor = heartRateSensor
        val permitted = hasBodySensors()
        Log.i(TAG, "onListen: sensor=${sensor?.name ?: "null"} permitted=$permitted")
        if (sensor == null || !permitted) {
            // Leave the sink open and simply never emit. Dart already treats
            // "no readings" as "--", so this needs no separate error path.
            return
        }
        // SENSOR_DELAY_NORMAL, not FASTEST: heart rate changes over seconds, and
        // a faster rate would only spend battery on a device that has to last a
        // whole run.
        val registered =
            sensorManager.registerListener(this, sensor, SensorManager.SENSOR_DELAY_NORMAL)
        Log.i(TAG, "registerListener returned $registered")
    }

    override fun onCancel(arguments: Any?) {
        sensorManager.unregisterListener(this)
        eventSink = null
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type != Sensor.TYPE_HEART_RATE) return

        // The sensor reports 0 while it is still acquiring, and garbage if the
        // watch is off the wrist. Anything outside a plausible human range is
        // dropped rather than shown.
        val bpm = event.values.firstOrNull()?.toInt() ?: return
        val valid = bpm > 0 && bpm <= 250
        // Logged only when validity flips, not per sample: readings arrive
        // about once a second for a whole run, and a log line each would drown
        // logcat while telling us nothing new. The transitions are the
        // interesting part — acquiring, then acquired, then lost.
        if (valid != wasValid) {
            wasValid = valid
            Log.i(TAG, if (valid) "acquired: $bpm bpm" else "lost contact (raw=$bpm)")
        }
        if (!valid) return

        // Already on the main thread for sensor callbacks registered without a
        // handler, so the sink can be touched directly.
        eventSink?.success(bpm)
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        // Deliberately ignored. Wear devices report NO_CONTACT/UNRELIABLE
        // routinely mid-run — through sleeves, on a loose strap — and dropping
        // readings on that basis leaves long gaps. The range check in
        // onSensorChanged is the filter that matters.
    }
}
