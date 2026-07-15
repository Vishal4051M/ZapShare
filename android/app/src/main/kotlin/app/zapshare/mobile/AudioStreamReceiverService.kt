package app.zapshare.mobile

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import android.app.UiModeManager
import android.content.res.Configuration
import androidx.core.app.NotificationCompat
import androidx.localbroadcastmanager.content.LocalBroadcastManager

class AudioStreamReceiverService : Service() {
    companion object {
        const val ACTION_START = "START_AUDIO_RECEIVER"
        const val ACTION_STOP = "STOP_AUDIO_RECEIVER"
        const val EXTRA_PORT = "port"
        const val EXTRA_CUSHION = "cushionMs"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d("ZapShare", "AudioStreamReceiverService: onStartCommand with action: ${intent?.action}")
        if (intent?.action == ACTION_START) {
            val port = intent.getIntExtra(EXTRA_PORT, AudioStreamSenderService.PORT)
            val cushionMs = intent.getIntExtra(EXTRA_CUSHION, 40)
            
            val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
            val isTv = uiModeManager.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
            val maxCushionMs = if (isTv) 120 else 160 // TV: keep lip-sync, Phone: allow stability without big delay
            
            Log.d("ZapShare", "Starting foreground receiver on port $port with cushion ${cushionMs}ms, maxCushion ${maxCushionMs}ms")
            startForeground()
            sendAudioState(true)
            
            AudioStreamReceiver.start(port, cushionMs, maxCushionMs) {
                // Log the jitter but don't stop the foreground service automatically
                Log.w("ZapShare", "Native receiver detected high jitter (auto-recovery in progress)")
                sendAudioState(true, "jitter_warning")
                // stopSelf() // Disabled auto-stop to allow recovery on poor networks
            }
        } else if (intent?.action == ACTION_STOP) {
            Log.d("ZapShare", "Stopping native receiver")
            AudioStreamReceiver.stop()
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startForeground() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel("zapshare_audio_recv", "Audio Receiving", NotificationManager.IMPORTANCE_LOW)
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
        val notification = NotificationCompat.Builder(this, "zapshare_audio_recv")
            .setContentTitle("ZapShare Audio Share")
            .setContentText("Listening for incoming audio...")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
            
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(1002, notification, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(1002, notification)
        }
    }

    private fun sendAudioState(active: Boolean, reason: String? = null) {
        val intent = Intent("app.zapshare.mobile.AUDIO_STATE")
        intent.putExtra("active", active)
        if (reason != null) intent.putExtra("reason", reason)
        LocalBroadcastManager.getInstance(this).sendBroadcast(intent)
    }

    override fun onDestroy() {
        AudioStreamReceiver.stop()
        sendAudioState(false)
        super.onDestroy()
    }
}
