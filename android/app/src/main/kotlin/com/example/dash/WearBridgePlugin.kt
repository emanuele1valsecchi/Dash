package com.example.dash

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.google.android.gms.wearable.MessageClient
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Thin, symmetric bridge over the Wearable Data Layer.
 *
 * The identical file exists on the watch side (`wear/`), differing only in its
 * package declaration. Deliberately generic — it knows nothing about runs,
 * stats or commands, only "send this string on this path" and "here is a string
 * that arrived on that path". All meaning lives in Dart, in the shared
 * `dash_watch_protocol` package, so the wire format has exactly one definition
 * rather than one per platform.
 *
 * Uses [MessageClient] rather than `DataClient`: live run metrics are a stream
 * of ephemeral values where only the newest matters, and DataItems are designed
 * for persisted state that syncs opportunistically — the wrong shape here, and
 * throttled besides. The cost is that messages sent while disconnected are
 * simply dropped rather than queued; the phone re-sends on the next tick
 * anyway, so a reconnecting watch is at most one tick stale.
 *
 * **Both apps must share an applicationId and a signing key** or the Data Layer
 * silently refuses to route between them, with no error to explain it.
 */
class WearBridgePlugin(private val context: Context) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    MessageClient.OnMessageReceivedListener {

    companion object {
        private const val METHOD_CHANNEL = "dash/wear_bridge"
        private const val EVENT_CHANNEL = "dash/wear_bridge/messages"
    }

    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private val messageClient by lazy { Wearable.getMessageClient(context) }
    private val nodeClient by lazy { Wearable.getNodeClient(context) }

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
    }

    // ── Dart -> native ────────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "send" -> {
                val path = call.argument<String>("path")
                val payload = call.argument<String>("payload") ?: ""
                if (path == null) {
                    result.error("bad_args", "path is required", null)
                    return
                }
                send(path, payload, result)
            }
            // Lets Dart show an honest "not connected" state instead of a
            // frozen display, and avoids sending into the void.
            "nodes" -> {
                nodeClient.connectedNodes
                    .addOnSuccessListener { nodes ->
                        result.success(nodes.map { it.displayName })
                    }
                    .addOnFailureListener { error ->
                        result.error("nodes_failed", error.message, null)
                    }
            }
            else -> result.notImplemented()
        }
    }

    private fun send(path: String, payload: String, result: MethodChannel.Result) {
        val bytes = payload.toByteArray(Charsets.UTF_8)
        nodeClient.connectedNodes
            .addOnSuccessListener { nodes ->
                if (nodes.isEmpty()) {
                    // Not an error: the peer being out of range is an ordinary
                    // state on a wrist device, not a failure worth throwing.
                    result.success(0)
                    return@addOnSuccessListener
                }
                // Broadcast to every connected node. Correct for the 1:1 pairing
                // this app targets, and avoids a CapabilityClient round-trip on
                // every single send.
                for (node in nodes) {
                    messageClient.sendMessage(node.id, path, bytes)
                }
                result.success(nodes.size)
            }
            .addOnFailureListener { error ->
                result.error("send_failed", error.message, null)
            }
    }

    // ── Native -> Dart ────────────────────────────────────────────────────────

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        messageClient.addListener(this)
    }

    override fun onCancel(arguments: Any?) {
        messageClient.removeListener(this)
        eventSink = null
    }

    override fun onMessageReceived(event: MessageEvent) {
        val payload = String(event.data, Charsets.UTF_8)
        // Data Layer callbacks arrive off the main thread; EventSink must be
        // touched on it.
        mainHandler.post {
            eventSink?.success(mapOf("path" to event.path, "payload" to payload))
        }
    }
}
