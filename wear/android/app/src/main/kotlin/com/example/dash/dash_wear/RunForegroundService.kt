package com.example.dash.dash_wear

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps a run recording while the phone is in a pocket with the screen off.
 *
 * Deliberately a **keep-alive**, not a tracker: it owns no GPS of its own. The
 * Dart `RunSessionController` keeps its existing Geolocator stream and stays
 * the single source of truth for the run. All this service does is hold an
 * ongoing notification of type `location`, which is what stops Android
 * throttling location updates and killing the process once the app is no
 * longer visible.
 *
 * Doing it this way means backgrounded and foregrounded runs execute the exact
 * same code path — there is no second, subtly-different tracking implementation
 * to keep in step with the first.
 *
 * **This must be started while the app is visible.** Android 12+ forbids
 * launching a foreground service from the background, which is also why a
 * command arriving from the watch while the app is killed cannot start a run
 * on its own.
 */
class RunForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "dash_run_tracking"
        private const val NOTIFICATION_ID = 4301

        const val ACTION_START = "com.example.dash.dash_wear.RUN_START"
        const val ACTION_UPDATE = "com.example.dash.dash_wear.RUN_UPDATE"
        const val ACTION_STOP = "com.example.dash.dash_wear.RUN_STOP"

        const val EXTRA_TITLE = "title"
        const val EXTRA_BODY = "body"

        fun start(context: Context, title: String, body: String) {
            val intent = Intent(context, RunForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_BODY, body)
            }
            context.startForegroundService(intent)
        }

        fun update(context: Context, title: String, body: String) {
            val intent = Intent(context, RunForegroundService::class.java).apply {
                action = ACTION_UPDATE
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_BODY, body)
            }
            context.startService(intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, RunForegroundService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START, ACTION_UPDATE -> {
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "Recording run"
                val body = intent.getStringExtra(EXTRA_BODY) ?: ""
                if (intent.action == ACTION_START) {
                    startAsForeground(title, body)
                } else {
                    notificationManager.notify(NOTIFICATION_ID, buildNotification(title, body))
                }
            }
        }
        // NOT_STICKY rather than STICKY: if the process is killed the Dart side
        // goes with it, and a restarted service would sit there showing a
        // notification for a run that is no longer being recorded. Better to
        // disappear honestly. Crash-recovery persistence is a separate job.
        return START_NOT_STICKY
    }

    private fun startAsForeground(title: String, body: String) {
        createChannel()
        val notification = buildNotification(title, body)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private val notificationManager: NotificationManager
        get() = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun createChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Run tracking",
            // LOW: this notification exists to keep the process alive and to be
            // glanceable, not to interrupt. IMPORTANCE_DEFAULT would make it
            // buzz on every update, which for a run means once a second.
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shown while a run is being recorded"
            setShowBadge(false)
        }
        notificationManager.createNotificationChannel(channel)
    }

    private fun buildNotification(title: String, body: String): Notification {
        // Tapping returns to the running app rather than launching a second
        // copy — MainActivity is singleTop, so this resumes the existing task.
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pending = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentIntent(pending)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_WORKOUT)
            .build()
    }
}
