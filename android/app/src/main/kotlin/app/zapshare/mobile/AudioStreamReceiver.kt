package app.zapshare.mobile

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentSkipListMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

class AudioStreamReceiver {
    companion object {
        var instance: AudioStreamReceiver? = null
            private set

        private var onStopCallback: (() -> Unit)? = null

        fun start(port: Int = AudioStreamSenderService.PORT, cushionMs: Int = 40, maxCushionMs: Int = 160, onStopped: (() -> Unit)? = null) {
            onStopCallback = onStopped
            if (instance == null) {
                instance = AudioStreamReceiver()
            }
            instance?.startReceiver(port, cushionMs, maxCushionMs)
        }

        fun stop() {
            instance?.stopReceiver()
            instance = null
            onStopCallback = null
        }
    }

    @Volatile private var isPlaying = false
    private var socket: DatagramSocket? = null
    private var receiveThread: Thread? = null
    private var renderThread: Thread? = null
    private var playThread: Thread? = null
    private var audioTrack: AudioTrack? = null
    private var decoder: MediaCodec? = null
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    @Volatile private var decoderBroken = false

    // Audio constants
    private val SAMPLE_RATE = 48000
    private val CHANNELS = 2
    private val PCM_FRAME_MS = 20
    private val BYTES_PER_SAMPLE = 2
    private val PCM_FRAME_SIZE = (SAMPLE_RATE * CHANNELS * BYTES_PER_SAMPLE * PCM_FRAME_MS) / 1000 // 3840
    private val silenceFrame = ByteArray(PCM_FRAME_SIZE)

    data class AudioPacket(val seqNum: Int, val timestamp: Long, val payload: ByteArray) : Comparable<AudioPacket> {
        override fun compareTo(other: AudioPacket) = this.seqNum.compareTo(other.seqNum)
    }

    // Sequence-aware jitter buffer keyed by seq number
    private val jitterBuffer = ConcurrentSkipListMap<Int, AudioPacket>()
    private val jitterBufferSignal = ReentrantLock()
    private val jitterBufferCondition = jitterBufferSignal.newCondition()

    // Issue 2 fix: Config packets are queued here by the receive thread and
    // drained by the decode thread, keeping the receive thread lock-free.
    private val pendingCsd = LinkedBlockingQueue<ByteArray>(2)

    private val decodedFrames = ConcurrentSkipListMap<Long, ByteArray>()

    private var initialCushionMs = 40
    // ==================== FIX B: Conservative initial cushion ====================
    private var currentCushionNs = 50 * 1_000_000L   // 50ms — safe startup
    private val MIN_CUSHION = 10 * 1_000_000L         // Floor: 10ms
    private var MAX_CUSHION = 50 * 1_000_000L         // Cap: dynamic based on device type
    private val OFFSET_STABLE_THRESHOLD = 50          // ~500ms of packets before shrinking allowed

    @Volatile private var smoothedOffsetNs = Long.MIN_VALUE
    private var minOffsetInWindow = Long.MAX_VALUE
    private var windowSampleCount = 0
    private var framesSinceStart = 0

    // Congestion detection
    private var jitterHitCount = 0
    private var consecutiveLossCount = 0
    private val JITTER_WARN_THRESHOLD = 100
    private var lastReceivedSeq = -1
    private var totalPacketsReceived = 0L
    private var totalPacketsLost = 0L

    // PLC: fade the last good frame instead of hard silence
    private var lastGoodPcmFrame: ByteArray? = null
    private var plcFadeLevel = 1.0f

    private var lastCsdBytes: ByteArray? = null
    // ==================== FIX E: Separate locks for decoder vs recovery ====================
    // Use one lock for the decoder reference and a separate flag for recovery.
    // handleConfigChange is called from the decode thread (not the receive thread
    // that holds no lock), so there's no deadlock risk anymore.
    private val decoderLock = ReentrantLock()

    private fun startReceiver(port: Int, cushionMs: Int, maxCushionMs: Int) {
        if (isPlaying) return
        isPlaying = true
        
        initialCushionMs = cushionMs.coerceAtLeast(30)
        currentCushionNs = initialCushionMs * 1_000_000L
        MAX_CUSHION = maxCushionMs * 1_000_000L

        try {
            socket = DatagramSocket(null)
            socket?.reuseAddress = true
            socket?.receiveBufferSize = 2 * 1024 * 1024
            socket?.trafficClass = 0xB8
            socket?.bind(java.net.InetSocketAddress(port))
            socket?.soTimeout = 1000
            Log.d("ZapShare", "Receiver bound to port $port, kernel buffer=${socket?.receiveBufferSize}")
        } catch (e: Exception) {
            Log.e("ZapShare", "Socket bind failed: ${e.message}")
            isPlaying = false
            return
        }

        val minBufferSize = AudioTrack.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
        // 2-3 PCM frames (40-60ms) hardware buffer — low latency while still
        // protecting against short decode hiccups.
        val bufferFrames = if (MAX_CUSHION <= 120_000_000L) 4 else 5
        val hwBufferSize = maxOf(minBufferSize, PCM_FRAME_SIZE * bufferFrames)

        audioTrack = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build())
            .setAudioFormat(AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(SAMPLE_RATE)
                .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                .build())
            .setBufferSizeInBytes(hwBufferSize)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .build()
        audioTrack?.play()

        // ==================== Thread 1: Receive ====================
        receiveThread = Thread {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO)
            Log.d("ZapShare", "Receive thread started")
            val buffer = ByteArray(4096)
            var packetCount = 0

            while (isPlaying) {
                try {
                    val packet = DatagramPacket(buffer, buffer.size)
                    socket?.receive(packet)
                    val data = packet.data
                    val length = packet.length
                    if (length < 11) continue

                    packetCount++
                    val packetType = data[0].toInt()
                    val seq = ((data[1].toInt() and 0xFF) shl 8) or (data[2].toInt() and 0xFF)

                    if (packetType == 0x02) {
                        // Issue 2: push CSD into queue — decode thread will handle it.
                        // Never call handleConfigChange here (it acquires decoderLock
                        // and can block while the codec is busy).
                        val csdData = ByteArray(length - 11).also { System.arraycopy(data, 11, it, 0, it.size) }
                        if (!pendingCsd.offer(csdData)) {
                            pendingCsd.poll() // drop oldest if full
                            pendingCsd.offer(csdData)
                        }
                    } else if (packetType == 0x01) {
                        var timestamp = 0L
                        for (i in 0..7) timestamp = (timestamp shl 8) or (data[3 + i].toLong() and 0xFF)
                        val payload = ByteArray(length - 11).also { System.arraycopy(data, 11, it, 0, it.size) }

                        val arrivalNs = System.nanoTime()
                        val observedOffset = arrivalNs - timestamp
                        totalPacketsReceived++
                        framesSinceStart++

                        if (windowSampleCount == 0) {
                            minOffsetInWindow = observedOffset
                        } else if (observedOffset < minOffsetInWindow) {
                            minOffsetInWindow = observedOffset
                        }
                        windowSampleCount++

                        if (windowSampleCount >= 10) {
                            val alpha = if (framesSinceStart < OFFSET_STABLE_THRESHOLD) 0.15 
                                        else if (smoothedOffsetNs != Long.MIN_VALUE && minOffsetInWindow < smoothedOffsetNs) 0.10 // 10% Fast recovery when network improves
                                        else 0.01 // 1% Slow adaptation to jitter spikes
                            
                            smoothedOffsetNs = if (smoothedOffsetNs == Long.MIN_VALUE) minOffsetInWindow
                                else (smoothedOffsetNs * (1.0 - alpha) + minOffsetInWindow * alpha).toLong()
                            windowSampleCount = 0
                            minOffsetInWindow = Long.MAX_VALUE
                        }

                        // Duplicate detection: same seq already in buffer
                        if (jitterBuffer.containsKey(seq)) {
                            continue
                        }

                        // Sequence gap detection
                        if (lastReceivedSeq >= 0) {
                            val expectedSeq = (lastReceivedSeq + 1) % 65536
                            val gap = if (seq >= expectedSeq) seq - expectedSeq
                                      else (seq + 65536) - expectedSeq
                            if (gap > 0 && gap < 1000) {
                                totalPacketsLost += gap
                                consecutiveLossCount += gap
                                val growthNs = minOf(gap * 5_000_000L, 40_000_000L)
                                currentCushionNs = minOf(MAX_CUSHION, currentCushionNs + growthNs)
                                if (gap > 3) {
                                    Log.w("ZapShare", "Packet gap: expected=$expectedSeq got=$seq (lost $gap)")
                                }
                            } else if (gap == 0) {
                                consecutiveLossCount = maxOf(0, consecutiveLossCount - 1) // Decay loss count so cushion can recover
                            }
                        }
                        lastReceivedSeq = seq

                        // Insert into jitter buffer
                        jitterBuffer[seq] = AudioPacket(seq, timestamp, payload)

                        // Signal decode thread
                        jitterBufferSignal.withLock {
                            jitterBufferCondition.signal()
                        }

                        // ====== FIX B: Shrink cushion after offset is stable ======
                        if (framesSinceStart > OFFSET_STABLE_THRESHOLD * 3 && consecutiveLossCount == 0 && jitterBuffer.size > 1) {
                            currentCushionNs = maxOf(30_000_000L, currentCushionNs - 50_000L)
                        }

                        // Bound jitter buffer
                        while (jitterBuffer.size > 30) {
                            val dropped = jitterBuffer.pollFirstEntry()
                            Log.w("ZapShare", "Buffer overflow, dropped seq=${dropped?.key}")
                        }
                    }
                } catch (e: SocketTimeoutException) {
                    if (packetCount == 0) Log.i("ZapShare", "Waiting for first packet...")
                } catch (e: Exception) {
                    if (isPlaying) Log.e("ZapShare", "Receive error: ${e.message}")
                }
            }
        }.apply { start() }

        // ==================== Thread 2: Decode ====================
        // Runs as fast as it can — NO rate limiter. The play thread controls pacing.
        // Rate-limiting here causes the decode thread to slip behind the play thread
        // by even 1ms, starving decodedFrames → silence.
        renderThread = Thread {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO)
            Log.d("ZapShare", "Decode thread started")
            var decodeCount = 0
            val bufferInfo = MediaCodec.BufferInfo()
            var nextExpectedSeq = -1

            while (isPlaying) {
                // Issue 2: drain any pending config packets BEFORE decoding audio.
                // This is the ONLY place handleConfigChange is called, avoiding
                // any lock contention with the receive thread.
                var csd = pendingCsd.poll()
                while (csd != null) {
                    handleConfigChange(csd)
                    csd = pendingCsd.poll()
                }

                // Wait for data
                if (jitterBuffer.isEmpty()) {
                    try {
                        jitterBufferSignal.withLock {
                            jitterBufferCondition.await(80, TimeUnit.MILLISECONDS)
                        }
                    } catch (e: InterruptedException) { break }
                    if (jitterBuffer.isEmpty()) continue
                }

                // Pre-buffering: accumulate at least 1 packet before first decode
                if (framesSinceStart < 5 && jitterBuffer.size < 1) {
                    try { Thread.sleep(2) } catch (e: Exception) {}
                    continue
                }

                val entry = jitterBuffer.pollFirstEntry() ?: continue
                val packet = entry.value

                if (nextExpectedSeq >= 0 && packet.seqNum != nextExpectedSeq) {
                    val gap = if (packet.seqNum > nextExpectedSeq) packet.seqNum - nextExpectedSeq
                             else (packet.seqNum + 65536) - nextExpectedSeq
                    if (gap in 1..10) {
                        Log.d("ZapShare", "Decode gap: $gap frames (seq ${nextExpectedSeq}..${packet.seqNum})")
                    }
                }
                nextExpectedSeq = (packet.seqNum + 1) % 65536

                // Raw PCM packet fallback used by Windows loopback sender.
                if (packet.payload.size == PCM_FRAME_SIZE) {
                    decodedFrames[packet.timestamp] = packet.payload
                    lastGoodPcmFrame = packet.payload
                    nextExpectedSeq = (packet.seqNum + 1) % 65536
                    continue
                }

                // Decoder recovery (decode thread is the only caller)
                if (decoderBroken && lastCsdBytes != null) {
                    Log.i("ZapShare", "Attempting decoder recovery...")
                    handleConfigChange(lastCsdBytes!!)
                    if (decoderBroken) continue
                }

                // Snapshot decoder under lock (very brief)
                val d = decoderLock.withLock { decoder } ?: continue
                if (decoderBroken) continue
                if (packet.payload.size < 4) continue

                try {
                    val inputIndex = d.dequeueInputBuffer(8000)
                    if (inputIndex >= 0) {
                        d.getInputBuffer(inputIndex)?.apply {
                            clear()
                            put(packet.payload)
                        }
                        d.queueInputBuffer(inputIndex, 0, packet.payload.size, packet.timestamp / 1000, 0)
                    } else {
                        Log.w("ZapShare", "Decoder input full, skipping seq=${packet.seqNum}")
                        continue
                    }

                    // Wait up to 5ms for first output, then drain remaining non-blocking
                    var outputIndex = d.dequeueOutputBuffer(bufferInfo, 5000)
                    while (outputIndex >= 0) {
                        val outputBuffer = d.getOutputBuffer(outputIndex)
                        if (outputBuffer != null && bufferInfo.size > 0) {
                            decodeCount++
                            val pcmData = ByteArray(bufferInfo.size).also { outputBuffer.get(it) }
                            val frameTs = bufferInfo.presentationTimeUs * 1000
                            decodedFrames[frameTs] = pcmData
                            if (decodeCount % 300 == 0) {
                                Log.d("ZapShare", "Decoded $decodeCount, queue=${decodedFrames.size}, cushion=${currentCushionNs / 1_000_000}ms, loss=${lossPercent()}%")
                            }
                        }
                        d.releaseOutputBuffer(outputIndex, false)
                        outputIndex = d.dequeueOutputBuffer(bufferInfo, 0)
                    }
                } catch (e: MediaCodec.CodecException) {
                    Log.e("ZapShare", "Codec error: ${e.message}, recoverable=${e.isRecoverable}")
                    if (e.isRecoverable) {
                        try { d.flush() } catch (ex: Exception) {}
                        try { d.start() } catch (ex: Exception) { decoderBroken = true }
                    } else {
                        decoderBroken = true
                    }
                } catch (e: Exception) {
                    Log.e("ZapShare", "Decode failed: ${e.message}")
                    decoderBroken = true
                }
                // No rate limiter — decode as fast as possible.
                // The play thread handles timing.
            }
        }.apply { start() }

        // ==================== Thread 3: Play ====================
        playThread = Thread {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO)
            Log.d("ZapShare", "Play thread started")
            val frameDurationNs = PCM_FRAME_MS * 1_000_000L
            var writeCount = 0
            var silenceCount = 0
            var lastPlayedTs = 0L
            var consecutiveSilence = 0
            var lastUnderrunCount = 0

            while (isPlaying) {
                val loopStartNs = System.nanoTime()

                // ====== FIX F: AudioTrack underrun detection & recovery ======
                // If AudioTrack's internal ring buffer underruns, it silently stops
                // producing audio. Detect via getUnderrunCount() and recover with
                // pause → flush → play cycle.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    val track = audioTrack
                    if (track != null) {
                        val currentUnderruns = track.underrunCount
                        if (currentUnderruns > lastUnderrunCount + 3) {
                            // Multiple underruns since last check — AudioTrack is likely stalled
                            Log.w("ZapShare", "AudioTrack underrun detected ($currentUnderruns), recovering...")
                            try {
                                track.pause()
                                track.flush()
                                track.play()
                            } catch (e: Exception) {
                                Log.e("ZapShare", "AudioTrack recovery failed: ${e.message}")
                            }
                            lastUnderrunCount = currentUnderruns
                            // Reset play state to re-sync
                            lastPlayedTs = 0L
                            consecutiveSilence = 0
                        } else {
                            lastUnderrunCount = currentUnderruns
                        }
                    }
                }

                if (smoothedOffsetNs == Long.MIN_VALUE) {
                    try { Thread.sleep(2) } catch (e: Exception) {}
                    continue
                }

                // Dynamic Backlog Purge: smoothly enforce cushion limit to recover from latency spikes
                val maxFrames = (currentCushionNs / frameDurationNs).toInt() + 4
                if (decodedFrames.size > maxFrames) {
                    // Drop only 1 frame per loop to create a smooth "fast-forward" catchup effect
                    // instead of a massive chunk of dropped audio.
                    val oldestKey = decodedFrames.firstKey()
                    decodedFrames.remove(oldestKey)
                    Log.d("ZapShare", "Backlog purge: dropped 1 frame to smoothly catch up")
                }

                val entry = decodedFrames.firstEntry()
                if (entry != null) {
                    val frameTs = entry.key
                    val pcm = entry.value
                    
                    val targetTime = frameTs + smoothedOffsetNs + currentCushionNs
                    val waitNs = targetTime - System.nanoTime()

                    if (waitNs > 0) {
                        if (waitNs > 1_000_000L) {
                            try { Thread.sleep(waitNs / 1_000_000L, (waitNs % 1_000_000L).toInt()) } catch (e: Exception) {}
                        }
                        while (System.nanoTime() < targetTime) { /* Spin-wait */ }
                    }

                    decodedFrames.remove(frameTs)

                    // ====== FIX H: Don't drop frames based on lastPlayedTs during PLC ======
                    if (consecutiveSilence == 0 && lastPlayedTs > 0 && frameTs < lastPlayedTs) {
                        Log.w("ZapShare", "Dropped out-of-order frame: $frameTs < $lastPlayedTs")
                        continue
                    }

                    audioTrack?.write(pcm, 0, pcm.size)
                    lastPlayedTs = frameTs
                    consecutiveSilence = 0
                    plcFadeLevel = 1.0f
                    lastGoodPcmFrame = pcm
                    writeCount++
                    if (writeCount % 300 == 0) {
                        Log.v("ZapShare", "Cushion=${currentCushionNs / 1_000_000}ms Buf=${decodedFrames.size} Loss=${lossPercent()}%")
                    }
                    
                    // Slowly shrink cushion back to initial if we are playing smoothly
                    val targetCushionNs = maxOf(initialCushionMs * 1_000_000L, 30_000_000L)
                    if (currentCushionNs > targetCushionNs && writeCount % 20 == 0) {
                        currentCushionNs = maxOf(targetCushionNs, currentCushionNs - 100_000L)
                    }
                } else {
                    // ====== PLC: expected frame deadline passed and frame is missing ======
                    consecutiveSilence++

                    if (lastGoodPcmFrame != null && plcFadeLevel > 0.05f && consecutiveSilence <= 8) {
                        val plcFrame = applyFade(lastGoodPcmFrame!!, plcFadeLevel)
                        audioTrack?.write(plcFrame, 0, plcFrame.size)
                        plcFadeLevel *= 0.65f
                    } else {
                        audioTrack?.write(silenceFrame, 0, silenceFrame.size)
                    }

                    silenceCount++

                    // Grow cushion during sustained underflow
                    if (consecutiveSilence > 3 && consecutiveSilence <= 15) {
                        currentCushionNs = minOf(MAX_CUSHION, currentCushionNs + 3_000_000L)
                    }

                    if (silenceCount % 50 == 1) {
                        Log.w("ZapShare", "Underflow: silence x$silenceCount (cushion=${currentCushionNs / 1_000_000}ms)")
                    }
                }

                // Sleep with sub-ms precision
                val wakeTimeNs = loopStartNs + frameDurationNs
                val remainingNs = wakeTimeNs - System.nanoTime()
                if (remainingNs > 1_500_000L) {
                    val sleepMs = (remainingNs - 1_000_000L) / 1_000_000L
                    val sleepNs = ((remainingNs - 1_000_000L) % 1_000_000L).toInt()
                    try { Thread.sleep(sleepMs, sleepNs) } catch (e: Exception) {}
                }
                while (System.nanoTime() < wakeTimeNs) { /* sub-ms spin */ }
            }
        }.apply { start() }
    }

    /**
     * Apply a volume fade to a PCM 16-bit LE stereo frame for PLC.
     */
    private fun applyFade(pcmFrame: ByteArray, fadeLevel: Float): ByteArray {
        val result = ByteArray(pcmFrame.size)
        val sampleCount = pcmFrame.size / 2
        for (i in 0 until sampleCount) {
            val offset = i * 2
            // Read as signed 16-bit little-endian
            val sample = (pcmFrame[offset].toInt() and 0xFF) or (pcmFrame[offset + 1].toInt() shl 8)
            val fadedSample = (sample * fadeLevel).toInt().coerceIn(-32768, 32767)
            result[offset] = (fadedSample and 0xFF).toByte()
            result[offset + 1] = ((fadedSample shr 8) and 0xFF).toByte()
        }
        return result
    }

    private fun lossPercent(): String {
        if (totalPacketsReceived == 0L) return "0.0"
        return String.format("%.1f", totalPacketsLost * 100.0 / (totalPacketsReceived + totalPacketsLost))
    }

    private fun handleConfigChange(csdData: ByteArray) {
        decoderLock.withLock {
            if (decoder != null && !decoderBroken && lastCsdBytes?.contentEquals(csdData) == true) return

            decodedFrames.clear()
            jitterBuffer.clear()

            Log.d("ZapShare", "Initializing Opus decoder (${csdData.size} bytes CSD)")
            try {
                decoder?.let { try { it.stop() } catch (e: Exception) {}; try { it.release() } catch (e: Exception) {} }
                decoder = null

                lastCsdBytes = csdData
                val opusFormat = MediaFormat.createAudioFormat("audio/opus", SAMPLE_RATE, CHANNELS)
                opusFormat.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                opusFormat.setByteBuffer("csd-0", ByteBuffer.wrap(csdData))
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    opusFormat.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                }

                decoder = MediaCodec.createDecoderByType("audio/opus")
                decoder?.configure(opusFormat, null, null, 0)
                decoder?.start()
                decoderBroken = false
                Log.i("ZapShare", "Opus decoder initialized")
            } catch (e: Exception) {
                Log.e("ZapShare", "Decoder init failed: ${e.message}")
                decoderBroken = true
            }
        }
    }

    fun stopReceiver() {
        isPlaying = false

        receiveThread?.interrupt()
        renderThread?.interrupt()
        playThread?.interrupt()

        try { socket?.close() } catch (e: Exception) {}

        // Wait for the decode thread to fully exit before touching the decoder.
        // Without this, decoder?.stop() can race with the decode thread still
        // inside dequeueInputBuffer(), causing a native crash (SIGSEGV) on
        // some devices. 500ms is generous — the thread should exit within
        // 1–2 loop iterations once isPlaying = false.
        try { renderThread?.join(500) } catch (e: Exception) {}

        decoderLock.withLock {
            try { audioTrack?.pause() } catch (e: Exception) {}
            try { audioTrack?.flush() } catch (e: Exception) {}
            try { audioTrack?.stop() } catch (e: Exception) {}
            try { audioTrack?.release() } catch (e: Exception) {}
            audioTrack = null

            try { decoder?.stop() } catch (e: Exception) {}
            try { decoder?.release() } catch (e: Exception) {}
            decoder = null
        }

        jitterBuffer.clear()
        decodedFrames.clear()
        pendingCsd.clear()
        lastCsdBytes = null
        decoderBroken = false
        socket = null
        smoothedOffsetNs = Long.MIN_VALUE
        minOffsetInWindow = Long.MAX_VALUE
        windowSampleCount = 0
        framesSinceStart = 0
        jitterHitCount = 0
        consecutiveLossCount = 0
        lastReceivedSeq = -1
        totalPacketsReceived = 0L
        totalPacketsLost = 0L
        currentCushionNs = initialCushionMs * 1_000_000L
        lastGoodPcmFrame = null
        plcFadeLevel = 1.0f
    }
}
