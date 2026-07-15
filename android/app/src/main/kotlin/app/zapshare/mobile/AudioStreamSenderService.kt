package app.zapshare.mobile

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.concurrent.ArrayBlockingQueue

class AudioStreamSenderService : Service() {
    companion object {
        const val ACTION_START = "START_AUDIO_STREAM"
        const val ACTION_STOP = "STOP_AUDIO_STREAM"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"
        const val EXTRA_TARGET_IPS = "targetIps"
        const val PORT = 50005

        @Volatile
        var isRunning = false
            private set
    }

    private var audioRecord: AudioRecord? = null
    private var mediaProjection: MediaProjection? = null
    private var captureThread: Thread? = null
    private var encodeThread: Thread? = null
    private var sendThread: Thread? = null
    private var udpSocket: DatagramSocket? = null
    private var encoder: MediaCodec? = null
    @Volatile
    private var usePcm = false

    private val targetAddresses = mutableListOf<InetAddress>()

    // Issue 3: Carry capture-time timestamp through the pipeline so the packet
    // reflects when the PCM was actually captured, not when the encoder finished.
    data class TimestampedPcm(val buffer: ByteArray, val captureTimeNs: Long)

    private val pcmQueue = ArrayBlockingQueue<TimestampedPcm>(8)   // 160ms of PCM buffer
    private val sendQueue = ArrayBlockingQueue<ByteArray>(8)       // 160ms of encoded packets

    // ==================== IMPROVEMENT: Safe PCM pool ====================
    // Use a proper lock-free pool with refcount semantics. Each buffer in the pool
    // is either owned by the capture thread or the encode thread, never both.
    // The pool size must be >= pcmQueue capacity + 2 (one being filled, one being encoded).
    private val PCM_FRAME_SIZE = 3840  // 20ms at 48kHz stereo 16-bit
    private val pcmPool = ArrayBlockingQueue<ByteArray>(16)

    init {
        // Pre-populate the pool
        for (i in 0 until 16) {
            pcmPool.offer(ByteArray(PCM_FRAME_SIZE))
        }
    }

    override fun onCreate() {
        super.onCreate()
        Log.d("ZapShare", "AudioStreamSenderService Created")
    }

    override fun onBind(intent: Intent?): IBinder? = null

    @RequiresApi(Build.VERSION_CODES.Q)
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_START) {
            val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
            val resultData = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(EXTRA_RESULT_DATA) as? Intent
            }
            val ips = intent.getStringArrayExtra(EXTRA_TARGET_IPS)
            usePcm = intent.getBooleanExtra("usePcm", false)

            if (resultData != null && ips != null) {
                targetAddresses.clear()
                ips.forEach { ip ->
                    try {
                        targetAddresses.add(InetAddress.getByName(ip))
                    } catch (e: Exception) {
                        Log.e("ZapShare", "Failed to resolve IP $ip: ${e.message}")
                    }
                }
                startForeground()
                startStreaming(resultCode, resultData)
            }
        } else if (intent?.action == ACTION_STOP) {
            stopStreaming()
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startForeground() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel("zapshare_audio", "Audio Sharing", NotificationManager.IMPORTANCE_LOW)
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
        val notification = NotificationCompat.Builder(this, "zapshare_audio")
            .setContentTitle("ZapShare Audio Sharing")
            .setContentText("Streaming system audio to network...")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(1001, notification, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION or android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(1001, notification)
        }
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun startStreaming(resultCode: Int, resultData: Intent) {
        if (isRunning) return
        isRunning = true

        val mpManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        mediaProjection = mpManager.getMediaProjection(resultCode, resultData)

        val currentMediaProjection = mediaProjection ?: run {
            Log.e("ZapShare", "MediaProjection is null.")
            isRunning = false
            return
        }

        // Register MediaProjection callback (REQUIRED on Android 14+ / API 34+)
        if (Build.VERSION.SDK_INT >= 34) {
            Log.d("ZapShare", "Android 14+ detected, registering MediaProjection callback for Audio")
            currentMediaProjection.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    Log.d("ZapShare", "Audio MediaProjection callback onStop()")
                    stopStreaming()
                    stopSelf()
                }
            }, android.os.Handler(android.os.Looper.getMainLooper()))
        }

        val config = AudioPlaybackCaptureConfiguration.Builder(currentMediaProjection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()

        val sampleRate = 48000
        val channelConfig = AudioFormat.CHANNEL_IN_STEREO
        val audioFormat = AudioFormat.ENCODING_PCM_16BIT

        val minBufferSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
        val bufferSize = if (minBufferSize > 0) minBufferSize else 3840

        audioRecord = AudioRecord.Builder()
            .setAudioFormat(AudioFormat.Builder()
                .setEncoding(audioFormat)
                .setSampleRate(sampleRate)
                .setChannelMask(channelConfig)
                .build())
            .setBufferSizeInBytes(bufferSize)
            .setAudioPlaybackCaptureConfig(config)
            .build()

        udpSocket = DatagramSocket()
        udpSocket?.soTimeout = 200
        udpSocket?.trafficClass = 0xB8                          // DSCP EF
        udpSocket?.sendBufferSize = 512 * 1024                  // 512KB send buffer

        // ==================== IMPROVEMENT: Bitrate negotiation ready ====================
        // Start at 128kbps CBR. If we detect send queue saturation (congestion signal),
        // we can lower this dynamically in a future version.
        if (!usePcm) {
            try {
                val opusFormat = MediaFormat.createAudioFormat("audio/opus", sampleRate, 2)
                opusFormat.setInteger(MediaFormat.KEY_BIT_RATE, 96000)
                opusFormat.setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    opusFormat.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                }

                encoder = MediaCodec.createEncoderByType("audio/opus")
                encoder?.configure(opusFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                encoder?.start()
                Log.d("ZapShare", "Opus Encoder Initialized (CBR 96kbps)")
            } catch (e: Exception) {
                Log.e("ZapShare", "Opus Encoder init failed: ${e.message}")
            }
        } else {
            Log.d("ZapShare", "Raw PCM streaming requested: bypassing Opus encoder initialization.")
        }

        // ==================== Thread 1: Capture ====================
        // Uses the safe pool: takes a buffer from the pool, fills it, puts it in pcmQueue.
        // If the pool is empty (all buffers in use), blocks briefly — this is the
        // backpressure signal that the encode thread is falling behind.
        captureThread = Thread {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO)
            audioRecord?.startRecording()
            if (audioRecord?.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                Log.e("ZapShare", "AudioRecord failed to start! State: ${audioRecord?.state}")
                return@Thread
            }
            Log.d("ZapShare", "Capture thread started")
            var pcmQueueDropCount = 0L

            while (isRunning) {
                // Get a buffer from the pool (blocks if all buffers are in use)
                val buf = try {
                    pcmPool.poll(20, java.util.concurrent.TimeUnit.MILLISECONDS)
                } catch (e: InterruptedException) { break } ?: continue

                // Stamp capture time BEFORE the blocking read loop. audioRecord.read()
                // blocks for ~10ms waiting for hardware to fill the buffer. Stamping
                // after the read systematically biases the timestamp 10ms late, making
                // the receiver's offset EMA underestimate true latency → cushion
                // undershoots → periodic underflows.
                val captureTimeNs = System.nanoTime()
                var offset = 0
                while (offset < PCM_FRAME_SIZE && isRunning) {
                    val read = audioRecord?.read(buf, offset, PCM_FRAME_SIZE - offset) ?: break
                    if (read < 0) {
                        Log.e("ZapShare", "AudioRecord error: $read")
                        pcmPool.offer(buf)
                        break
                    }
                    if (read == 0) {
                        try { Thread.sleep(1) } catch (e: Exception) {}
                        continue
                    }
                    offset += read
                }

                if (offset == PCM_FRAME_SIZE) {
                    val stamped = TimestampedPcm(buf, captureTimeNs)
                    if (!pcmQueue.offer(stamped)) {
                        val dropped = pcmQueue.poll()
                        if (dropped != null) pcmPool.offer(dropped.buffer)
                        pcmQueue.offer(stamped)
                        
                        pcmQueueDropCount++
                        if (pcmQueueDropCount % 50 == 1L) {
                            Log.w("ZapShare", "PCM Queue overflow: dropped $pcmQueueDropCount frames total")
                        }
                    }
                } else {
                    pcmPool.offer(buf)
                }
            }
        }.also { it.start() }

        // ==================== Thread 2: Encode ====================
        // After encoding, returns the PCM buffer to the pool for reuse.
        encodeThread = Thread {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO)
            var sequenceNum = 0
            var frameIndex = 0L
            val startTimeNs = System.nanoTime()
            val bufferInfo = MediaCodec.BufferInfo()
            var lastCodecConfig: ByteArray? = null
            var sendQueueDropCount = 0L
            var encoderInputUnavailableCount = 0L
            Log.d("ZapShare", "Encode thread started")

            while (isRunning) {
                val stampedPcm = try {
                    pcmQueue.poll(50, java.util.concurrent.TimeUnit.MILLISECONDS)
                } catch (e: InterruptedException) { break } ?: continue

                val pcmBuf = stampedPcm.buffer
                val captureTimeNs = stampedPcm.captureTimeNs

                if (usePcm) {
                    try {
                        val packetData = ByteArray(11 + pcmBuf.size)
                        packetData[0] = 0x01
                        packetData[1] = ((sequenceNum shr 8) and 0xFF).toByte()
                        packetData[2] = (sequenceNum and 0xFF).toByte()
                        for (i in 0..7) {
                            packetData[3 + i] = ((captureTimeNs shr ((7 - i) * 8)) and 0xFF).toByte()
                        }
                        System.arraycopy(pcmBuf, 0, packetData, 11, pcmBuf.size)

                        if (!sendQueue.offer(packetData)) {
                            sendQueue.poll()
                            sendQueue.offer(packetData)
                            sendQueueDropCount++
                            if (sendQueueDropCount % 50 == 0L) {
                                Log.w("ZapShare", "Send queue congestion (PCM): dropped $sendQueueDropCount total")
                            }
                        }
                        sequenceNum = (sequenceNum + 1) % 65536
                    } catch (e: Exception) {
                        Log.e("ZapShare", "PCM pack error: ${e.message}")
                    } finally {
                        pcmPool.offer(pcmBuf)
                    }
                    continue
                }

                val enc = encoder
                if (enc == null) {
                    pcmPool.offer(pcmBuf)
                    continue
                }

                try {
                    val inputIndex = enc.dequeueInputBuffer(5000)
                    if (inputIndex >= 0) {
                        val inputBuffer = enc.getInputBuffer(inputIndex)
                        inputBuffer?.clear()
                        inputBuffer?.put(pcmBuf)
                        val frameTimestampUs = captureTimeNs / 1000
                        enc.queueInputBuffer(inputIndex, 0, pcmBuf.size, frameTimestampUs, 0)
                        frameIndex++
                    } else {
                        encoderInputUnavailableCount++
                        if (encoderInputUnavailableCount % 50 == 1L) {
                            Log.w("ZapShare", "Encoder starvation: input buffer unavailable $encoderInputUnavailableCount times")
                        }
                        pcmPool.offer(pcmBuf)
                        continue
                    }

                    // Return PCM buffer to pool immediately after queueing to encoder
                    pcmPool.offer(pcmBuf)

                    var outputIndex = enc.dequeueOutputBuffer(bufferInfo, 2000)
                    while (outputIndex >= 0) {
                        val outputBuffer = enc.getOutputBuffer(outputIndex)
                        val isConfig = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0

                        if (outputBuffer != null && (bufferInfo.size > 0)) {
                            if (isConfig) {
                                lastCodecConfig = ByteArray(bufferInfo.size).also { outputBuffer.get(it) }
                                val configPacket = ByteArray(11 + bufferInfo.size)
                                configPacket[0] = 0x02
                                System.arraycopy(lastCodecConfig!!, 0, configPacket, 11, bufferInfo.size)
                                sendQueue.offer(configPacket)
                                Log.i("ZapShare", "CONFIG packet queued: ${bufferInfo.size} bytes")
                            } else if (bufferInfo.size > 0) {
                                if (frameIndex % 100 == 0L && lastCodecConfig != null) {
                                    val configPacket = ByteArray(11 + lastCodecConfig!!.size)
                                    configPacket[0] = 0x02
                                    System.arraycopy(lastCodecConfig!!, 0, configPacket, 11, lastCodecConfig!!.size)
                                    sendQueue.offer(configPacket)
                                }

                                val opusData = ByteArray(bufferInfo.size).also { outputBuffer.get(it) }
                                // Issue 3: Use the CAPTURE-TIME timestamp, not System.nanoTime().
                                // This removes encoder latency (2-20ms depending on device)
                                // from the receiver's offset EMA, making cross-device
                                // streaming consistent.
                                val packetData = ByteArray(11 + opusData.size)
                                packetData[0] = 0x01
                                packetData[1] = ((sequenceNum shr 8) and 0xFF).toByte()
                                packetData[2] = (sequenceNum and 0xFF).toByte()
                                for (i in 0..7) {
                                    packetData[3 + i] = ((captureTimeNs shr ((7 - i) * 8)) and 0xFF).toByte()
                                }
                                System.arraycopy(opusData, 0, packetData, 11, opusData.size)

                                if (!sendQueue.offer(packetData)) {
                                    sendQueue.poll()
                                    sendQueue.offer(packetData)
                                    sendQueueDropCount++
                                    if (sendQueueDropCount % 50 == 0L) {
                                        Log.w("ZapShare", "Send queue congestion: dropped $sendQueueDropCount total")
                                    }
                                }
                                sequenceNum = (sequenceNum + 1) % 65536
                            }
                        }
                        enc.releaseOutputBuffer(outputIndex, false)
                        outputIndex = enc.dequeueOutputBuffer(bufferInfo, 0)
                    }
                } catch (e: MediaCodec.CodecException) {
                    Log.e("ZapShare", "Encoder codec error: ${e.message}, recoverable=${e.isRecoverable}")
                    pcmPool.offer(pcmBuf)
                    if (!e.isRecoverable) {
                        Log.e("ZapShare", "Unrecoverable encoder error — stopping stream")
                        break
                    }
                } catch (e: Exception) {
                    Log.e("ZapShare", "Encode error: ${e.message}")
                    pcmPool.offer(pcmBuf)
                }
            }
        }.also { it.start() }

        // ==================== Thread 3: Send ====================
        // Blocks on sendQueue.poll() which naturally paces the sends to the hardware capture rate.
        sendThread = Thread {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO)
            Log.d("ZapShare", "Send thread started")
            var sendCount = 0L
            var errorCount = 0

            while (isRunning) {
                val packetData = try {
                    sendQueue.poll(50, java.util.concurrent.TimeUnit.MILLISECONDS)
                } catch (e: InterruptedException) { break } ?: continue

                for (target in targetAddresses) {
                    try {
                        udpSocket?.send(DatagramPacket(packetData, packetData.size, target, PORT))
                        errorCount = 0  // Reset on success
                    } catch (e: Exception) {
                        errorCount++
                        if (errorCount <= 5 || errorCount % 100 == 0) {
                            Log.w("ZapShare", "Send error to $target: ${e.message} (count=$errorCount)")
                        }
                        // If we're getting persistent send errors, briefly back off
                        // to avoid flooding a congested network
                        if (errorCount >= 10) {
                            try { Thread.sleep(5) } catch (ex: Exception) {}
                        }
                    }
                }
                sendCount++

                if (sendCount % 500 == 0L) {
                    Log.d("ZapShare", "Sent $sendCount packets, queue=${sendQueue.size}")
                }
            }
        }.also { it.start() }
    }

    private fun stopStreaming() {
        isRunning = false

        captureThread?.interrupt()
        encodeThread?.interrupt()
        sendThread?.interrupt()

        pcmQueue.clear()
        sendQueue.clear()

        try { audioRecord?.stop() } catch (e: Exception) {}
        try { audioRecord?.release() } catch (e: Exception) {}
        audioRecord = null

        try { encoder?.stop() } catch (e: Exception) {}
        try { encoder?.release() } catch (e: Exception) {}
        encoder = null

        try { mediaProjection?.stop() } catch (e: Exception) {}
        mediaProjection = null

        try { udpSocket?.close() } catch (e: Exception) {}
        udpSocket = null

        // Return any remaining PCM buffers to pool
        val remaining = mutableListOf<TimestampedPcm>()
        pcmQueue.drainTo(remaining)
        remaining.forEach { pcmPool.offer(it.buffer) }
    }
}
