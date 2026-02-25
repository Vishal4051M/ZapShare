package com.example.zap_share
import android.net.Uri
import android.os.Bundle
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import android.app.Activity
import android.content.Intent
import android.os.Build
import android.provider.DocumentsContract
import org.json.JSONArray
import org.json.JSONObject
import android.database.Cursor
import android.provider.OpenableColumns
import android.net.wifi.WifiManager
import android.content.Context
import android.media.projection.MediaProjectionManager

class MainActivity : FlutterActivity() {
    private val CHANNEL = "zapshare.saf"
    private val WIFI_DIRECT_CHANNEL = "zapshare.wifi_direct"

    private val inputStreams = mutableMapOf<String, InputStream>()
    private var initialSharedUris: List<String>? = null
    private var methodChannel: MethodChannel? = null
    private var wifiDirectChannel: MethodChannel? = null
    private var wifiDirectManager: WiFiDirectManager? = null


    // --- SAF Folder Picker additions ---
    private var folderResult: MethodChannel.Result? = null
    private val FOLDER_PICKER_REQUEST = 9999
    private var pickedFolderUri: Uri? = null
    
    // --- SAF Video Picker additions ---
    private var videoPickerResult: MethodChannel.Result? = null
    private val VIDEO_PICKER_REQUEST = 9998
    
    // --- Multicast Lock for Discovery ---
    private var multicastLock: WifiManager.MulticastLock? = null
    
    // --- Native Video Server ---
    private var videoServer: VideoWebServer? = null

    // --- Screen Mirror ---
    private val MEDIA_PROJECTION_REQUEST = 9997
    private var mediaProjectionManager: MediaProjectionManager? = null
    private var screenCaptureResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        wifiDirectChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WIFI_DIRECT_CHANNEL)

        // Initialize Wi-Fi Direct Manager
        wifiDirectManager = WiFiDirectManager(this, wifiDirectChannel!!)



        // Acquire multicast lock for UDP discovery
        acquireMulticastLock()

        // Set up Wi-Fi Direct channel handler
        wifiDirectChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "initialize" -> {
                    val success = wifiDirectManager?.initialize() ?: false
                    result.success(success)
                }
                "createGroup" -> {
                    val success = wifiDirectManager?.createGroup() ?: false
                    result.success(success)
                }
                "startPeerDiscovery" -> {
                    val success = wifiDirectManager?.startPeerDiscovery() ?: false
                    result.success(success)
                }
                "stopPeerDiscovery" -> {
                    val success = wifiDirectManager?.stopPeerDiscovery() ?: false
                    result.success(success)
                }
                "connectToPeer" -> {
                    val deviceAddress = call.argument<String>("deviceAddress")
                    val isGroupOwner = call.argument<Boolean>("isGroupOwner") ?: false
                    if (deviceAddress != null) {
                        val success = wifiDirectManager?.connectToPeer(deviceAddress, isGroupOwner) ?: false
                        result.success(success)
                    } else {
                        result.error("INVALID_ARGS", "Device address required", null)
                    }
                }
                "removeGroup" -> {
                    val success = wifiDirectManager?.removeGroup() ?: false
                    result.success(success)
                }
                "requestGroupInfo" -> {
                    val groupInfo = wifiDirectManager?.requestGroupInfo()
                    result.success(groupInfo)
                }
                "getDiscoveredPeers" -> {
                    val peers = wifiDirectManager?.getDiscoveredPeers() ?: emptyList()
                    result.success(peers)
                }
                "disconnect" -> {
                    val success = wifiDirectManager?.disconnect() ?: false
                    result.success(success)
                }
                "isWifiP2pEnabled" -> {
                    val enabled = wifiDirectManager?.isWifiP2pEnabled() ?: false
                    result.success(enabled)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }



        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openReadStream" -> {
                    val uriStr = call.argument<String>("uri")
                    try {
                        val uri = Uri.parse(uriStr)
                        val stream = contentResolver.openInputStream(uri)
                        if (stream != null) {
                            val streamId = java.util.UUID.randomUUID().toString()
                            inputStreams[streamId] = stream
                            println("ZapShare: Opened stream $streamId for URI: $uriStr")
                            result.success(streamId)
                        } else {
                            println("ZapShare: Failed to open stream for URI: $uriStr")
                            result.error("STREAM_FAIL", "Could not open input stream", null)
                        }
                    } catch (e: Exception) {
                        println("ZapShare: Exception opening stream: ${e.message}")
                        result.error("EXCEPTION", e.message, null)
                    }
                }

               "getFileSize" -> {
                    val uriStr = call.argument<String>("uri")
                    try {
                        val uri = Uri.parse(uriStr)
                        // Try openAssetFileDescriptor first (reliable for size)
                        var size = -1L
                        try {
                            contentResolver.openAssetFileDescriptor(uri, "r")?.use {
                                size = it.length
                            }
                        } catch (e: Exception) {}
                        
                        // Fallback to query if needed
                        if (size == -1L) {
                            val cursor = contentResolver.query(uri, null, null, null, null)
                            cursor?.use {
                                if (it.moveToFirst()) {
                                    val sizeIndex = it.getColumnIndex(OpenableColumns.SIZE)
                                    if (sizeIndex != -1) {
                                        size = it.getLong(sizeIndex)
                                    }
                                }
                            }
                        }
                        
                        if (size >= 0L) {
                            result.success(size)
                        } else {
                            result.error("SIZE_FAIL", "Unable to determine size", null)
                        }
                    } catch (e: Exception) {
                        result.error("SIZE_EXCEPTION", e.message, null)
                    }
                }

                "readChunk" -> {
                    val streamId = call.argument<String>("streamId")
                    // Fallback to URI for legacy calls (if any)
                    val uriStr = call.argument<String>("uri")
                    val size = call.argument<Int>("size") ?: 4194304
                    
                    val stream = if (streamId != null) inputStreams[streamId] else inputStreams[uriStr]
                    
                    if (stream == null) {
                        result.error("NO_STREAM", "Stream not found", null)
                        return@setMethodCallHandler
                    }

                    try {
                        val buffer = ByteArray(size)
                        val bytesRead = stream.read(buffer)
                        if (bytesRead == -1) {
                            result.success(byteArrayOf()) // End of file
                        } else if (bytesRead == 0) {
                            result.success(byteArrayOf())
                        } else {
                            result.success(buffer.copyOf(bytesRead))
                        }
                    } catch (e: Exception) {
                        println("ZapShare: Read error: ${e.message}")
                        result.error("READ_ERROR", e.message, null)
                    }
                }

                "closeStream" -> {
                    val streamId = call.argument<String>("streamId")
                    val uriStr = call.argument<String>("uri")
                    
                    try {
                        val idToRemove = streamId ?: uriStr
                        val stream = inputStreams.remove(idToRemove)
                        stream?.close()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("CLOSE_ERROR", e.message, null)
                    }
                }
                
                "startForegroundService" -> {
                    val title = call.argument<String>("title") ?: "ZapShare"
                    val content = call.argument<String>("content") ?: "Service Running"
                    startForegroundServiceCompat(title, content)
                    result.success(true)
                }

                "stopForegroundService" -> {
                    stopForegroundServiceCompat()
                    result.success(true)
                }

                "pickFolder" -> {
                    folderResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                    intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                    startActivityForResult(intent, FOLDER_PICKER_REQUEST)
                }

                "listFilesInFolder" -> {
                    val folderUriStr = call.argument<String>("folderUri")
                    if (folderUriStr == null) {
                        result.error("NO_URI", "No folder URI provided", null)
                        return@setMethodCallHandler
                    }
                    val folderUri = Uri.parse(folderUriStr)
                    val files = JSONArray()
                    listFilesRecursively(folderUri, files)
                    result.success(files.toString())
                }

                "readWholeFile" -> {
                    val uriStr = call.argument<String>("uri")
                    if (uriStr == null) {
                        result.error("NO_URI", "No file URI provided", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val uri = Uri.parse(uriStr)
                        val inputStream = contentResolver.openInputStream(uri)
                        if (inputStream != null) {
                            val bytes = inputStream.readBytes()
                            inputStream.close()
                            result.success(bytes)
                        } else {
                            result.error("READ_FAIL", "Could not open input stream", null)
                        }
                    } catch (e: Exception) {
                        result.error("EXCEPTION", e.message, null)
                    }
                }

                "zipFilesToCache" -> {
                    val uris = call.argument<List<String>>("uris")
                    val names = call.argument<List<String>>("names")
                    val zipName = call.argument<String>("zipName") ?: "shared.zip"
                    if (uris == null || names == null || uris.size != names.size) {
                        result.error("INVALID_ARGS", "Invalid file list", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val cacheDir = cacheDir
                        val zipFile = java.io.File(cacheDir, zipName)
                        val zos = java.util.zip.ZipOutputStream(zipFile.outputStream())
                        for (i in uris.indices) {
                            val uri = Uri.parse(uris[i])
                            val entry = java.util.zip.ZipEntry(names[i])
                            zos.putNextEntry(entry)
                            val input = contentResolver.openInputStream(uri)
                            if (input != null) {
                                val buffer = ByteArray(4 * 1024 * 1024)
                                var len: Int
                                while (input.read(buffer).also { len = it } > 0) {
                                    zos.write(buffer, 0, len)
                                }
                                input.close()
                            }
                            zos.closeEntry()
                        }
                        zos.close()
                        result.success(zipFile.absolutePath)
                    } catch (e: Exception) {
                        result.error("ZIP_ERROR", e.message, null)
                    }
                }

                "acquireMulticastLock" -> {
                    try {
                        acquireMulticastLock()
                        result.success(true)
                    } catch (e: Exception) {
                        android.util.Log.e("ZapShare", "Failed to acquire multicast lock: ${e.message}")
                        result.error("MULTICAST_ERROR", e.message, null)
                    }
                }

                "checkMulticastLock" -> {
                    try {
                        val isHeld = multicastLock?.isHeld ?: false
                        android.util.Log.d("ZapShare", "Multicast lock status: ${if (isHeld) "HELD" else "NOT HELD"}")
                        result.success(isHeld)
                    } catch (e: Exception) {
                        android.util.Log.e("ZapShare", "Failed to check multicast lock: ${e.message}")
                        result.error("MULTICAST_ERROR", e.message, null)
                    }
                }

                "getGatewayIp" -> {
                    try {
                        val wifiManager = getSystemService(WIFI_SERVICE) as android.net.wifi.WifiManager
                        val dhcpInfo = wifiManager.dhcpInfo
                        val gateway = dhcpInfo.gateway
                        
                        android.util.Log.d("ZapShare", "Gateway: $gateway")
                        
                        if (gateway == 0) {
                            // If gateway is 0, try to get the device's own IP
                            val connectionInfo = wifiManager.connectionInfo
                            val ipAddress = connectionInfo.ipAddress
                            android.util.Log.d("ZapShare", "IP Address: $ipAddress")
                            val ip = (ipAddress and 0xFF).toString() + "." +
                                    (ipAddress shr 8 and 0xFF) + "." +
                                    (ipAddress shr 16 and 0xFF) + "." +
                                    (ipAddress shr 24 and 0xFF)
                            android.util.Log.d("ZapShare", "Calculated IP: $ip")
                            // Only return if IP is valid (not 0.0.0.0)
                            if (ip != "0.0.0.0") {
                                result.success(ip)
                                return@setMethodCallHandler
                            } else {
                                android.util.Log.d("ZapShare", "WiFi IP is 0.0.0.0, trying network interfaces...")
                            }
                        } else {
                            val ip = (gateway and 0xFF).toString() + "." +
                                    (gateway shr 8 and 0xFF) + "." +
                                    (gateway shr 16 and 0xFF) + "." +
                                    (gateway shr 24 and 0xFF)
                            android.util.Log.d("ZapShare", "Calculated Gateway IP: $ip")
                            // Only return if IP is valid (not 0.0.0.0)
                            if (ip != "0.0.0.0") {
                                result.success(ip)
                                return@setMethodCallHandler
                            } else {
                                android.util.Log.d("ZapShare", "Gateway IP is 0.0.0.0, trying network interfaces...")
                            }
                        }
                    } catch (e: Exception) {
                        android.util.Log.e("ZapShare", "Error getting gateway IP: ${e.message}")
                    }
                    
                    // Always try network interfaces as fallback
                    try {
                        android.util.Log.d("ZapShare", "Trying network interfaces...")
                        val networkInterfaces = java.net.NetworkInterface.getNetworkInterfaces()
                        
                        // Look for hotspot interfaces (wlan, ap, etc.)
                        while (networkInterfaces.hasMoreElements()) {
                            val networkInterface = networkInterfaces.nextElement()
                            android.util.Log.d("ZapShare", "Interface: ${networkInterface.name}, Up: ${networkInterface.isUp}, Loopback: ${networkInterface.isLoopback}")
                            
                            // Look for the interface associated with the hotspot (often named "wlan" or "ap")
                            if (networkInterface.isUp && !networkInterface.isLoopback && 
                                (networkInterface.name.contains("wlan") || networkInterface.name.contains("ap"))) {
                                
                                android.util.Log.d("ZapShare", "Found hotspot interface: ${networkInterface.name}")
                                val inetAddresses = networkInterface.inetAddresses
                                
                                while (inetAddresses.hasMoreElements()) {
                                    val inetAddress = inetAddresses.nextElement()
                                    android.util.Log.d("ZapShare", "Address: ${inetAddress.hostAddress}, Type: ${inetAddress.javaClass.simpleName}, Loopback: ${inetAddress.isLoopbackAddress}, SiteLocal: ${inetAddress.isSiteLocalAddress}")
                                    
                                    // We're interested in the local IP address assigned to the hotspot
                                    if (!inetAddress.isLoopbackAddress && inetAddress.isSiteLocalAddress && inetAddress is java.net.Inet4Address) {
                                        val hotspotIpAddress = inetAddress.hostAddress
                                        android.util.Log.d("ZapShare", "Hotspot IP found: $hotspotIpAddress")
                                        result.success(hotspotIpAddress)
                                        return@setMethodCallHandler
                                    }
                                }
                            }
                        }
                        
                        // If no hotspot interface found, try all interfaces as fallback
                        android.util.Log.d("ZapShare", "No hotspot interface found, trying all interfaces...")
                        val allInterfaces = java.net.NetworkInterface.getNetworkInterfaces()
                        while (allInterfaces.hasMoreElements()) {
                            val networkInterface = allInterfaces.nextElement()
                            
                            if (networkInterface.isUp && !networkInterface.isLoopback) {
                                val inetAddresses = networkInterface.inetAddresses
                                while (inetAddresses.hasMoreElements()) {
                                    val inetAddress = inetAddresses.nextElement()
                                    android.util.Log.d("ZapShare", "Address: ${inetAddress.hostAddress}, Type: ${inetAddress.javaClass.simpleName}")
                                    
                                    if (inetAddress is java.net.Inet4Address && !inetAddress.isLoopbackAddress) {
                                        val ip = inetAddress.hostAddress
                                        android.util.Log.d("ZapShare", "Valid IP found: $ip")
                                        result.success(ip)
                                        return@setMethodCallHandler
                                    }
                                }
                            }
                        }
                        android.util.Log.e("ZapShare", "No valid network interface found")
                        result.error("GATEWAY_ERROR", "No network interface found", null)
                    } catch (e2: Exception) {
                        android.util.Log.e("ZapShare", "Network interface method failed: ${e2.message}")
                        result.error("GATEWAY_ERROR", e2.message, null)
                    }
                }

                "pickMultipleDocuments" -> {
                    videoPickerResult = result
                    val mimeTypes = call.argument<List<String>>("mimeTypes") ?: listOf("video/*")
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toTypedArray())
                        putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    startActivityForResult(intent, VIDEO_PICKER_REQUEST)
                }

                "readFileChunk" -> {
                    // Legacy chunk reader - maintained for backward compatibility primarily
                    val uriStr = call.argument<String>("uri")
                    val offset = call.argument<Int>("offset") ?: 0
                    val length = call.argument<Int>("length") ?: 65536
                    
                    if (uriStr == null) {
                        result.error("NO_URI", "No URI provided", null)
                        return@setMethodCallHandler
                    }
                    
                    try {
                        val uri = Uri.parse(uriStr)
                        val afd = contentResolver.openAssetFileDescriptor(uri, "r")
                        
                        if (afd != null) {
                            val fileInputStream = afd.createInputStream()
                            val fileChannel = fileInputStream.channel
                            fileChannel.position(offset.toLong())
                            
                            val buffer = ByteArray(length)
                            val bytesRead = fileInputStream.read(buffer)
                            
                            fileInputStream.close()
                            afd.close()
                            
                            if (bytesRead > 0) {
                                result.success(buffer.copyOf(bytesRead))
                            } else {
                                result.success(byteArrayOf())
                            }
                        } else {
                            result.error("STREAM_FAIL", "Could not open file descriptor", null)
                        }
                    } catch (e: Exception) {
                        result.error("READ_ERROR", e.message, null)
                    }
                }

                "startVideoServer" -> {
                    try {
                        val filesList = call.argument<List<Map<String, String>>>("files")
                        if (filesList == null) {
                            result.error("ARGS_ERROR", "Files list required", null)
                            return@setMethodCallHandler
                        }
                        
                        // Map index (as string) to Uri string
                        // Map index to Uri and Name
                        val uriMap = filesList.mapIndexed { index, map -> 
                            index.toString() to Uri.parse(map["uri"] as String) 
                        }.toMap()
                        
                        val nameMap = filesList.mapIndexed { index, map ->
                            index.toString() to (map["name"] as String)
                        }.toMap()
                        
                        videoServer?.stopServer()
                        videoServer = VideoWebServer(applicationContext, uriMap, nameMap)
                        videoServer?.start() // Start the thread
                        
                        // Wait briefly for port to be assigned if needed, though init block does it
                        result.success(videoServer?.port)
                    } catch (e: Exception) {
                        result.error("SERVER_ERROR", e.message, null)
                    }
                }
                
                "stopVideoServer" -> {
                    videoServer?.stopServer()
                    videoServer = null
                    result.success(true)
                }

                "requestScreenCapture" -> {
                    screenCaptureResult = result
                    mediaProjectionManager = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                    startActivityForResult(mediaProjectionManager!!.createScreenCaptureIntent(), MEDIA_PROJECTION_REQUEST)
                }

                "getScreenMirrorPort" -> {
                    val port = ScreenMirrorService.instance?.port ?: 0
                    result.success(port)
                }

                "stopScreenMirror" -> {
                    val serviceIntent = Intent(this, ScreenMirrorService::class.java)
                    stopService(serviceIntent)
                    result.success(true)
                }

                "mirrorControl" -> {
                    val action = call.argument<String>("action")
                    val tapX = call.argument<Double>("tapX")
                    val tapY = call.argument<Double>("tapY")
                    val endX = call.argument<Double>("endX")
                    val endY = call.argument<Double>("endY")
                    val text = call.argument<String>("text")
                    val scrollDelta = call.argument<Double>("scrollDelta")
                    val duration = call.argument<Int>("duration") ?: 300
                    try {
                        @Suppress("DEPRECATION")
                        val display = windowManager.defaultDisplay
                        val screenW = display.width
                        val screenH = display.height
                        when (action) {
                            "back" -> {
                                Runtime.getRuntime().exec(arrayOf("sh", "-c", "input keyevent KEYCODE_BACK"))
                            }
                            "home" -> {
                                Runtime.getRuntime().exec(arrayOf("sh", "-c", "input keyevent KEYCODE_HOME"))
                            }
                            "recents" -> {
                                Runtime.getRuntime().exec(arrayOf("sh", "-c", "input keyevent KEYCODE_APP_SWITCH"))
                            }
                            "volume_up" -> {
                                val audioManager = getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
                                audioManager.adjustVolume(android.media.AudioManager.ADJUST_RAISE, android.media.AudioManager.FLAG_SHOW_UI)
                            }
                            "volume_down" -> {
                                val audioManager = getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
                                audioManager.adjustVolume(android.media.AudioManager.ADJUST_LOWER, android.media.AudioManager.FLAG_SHOW_UI)
                            }
                            "power" -> {
                                Runtime.getRuntime().exec(arrayOf("sh", "-c", "input keyevent KEYCODE_POWER"))
                            }
                            "scroll_up" -> {
                                val midX = screenW / 2
                                val startY = screenH * 2 / 3
                                val eY = screenH / 3
                                Runtime.getRuntime().exec(arrayOf("sh", "-c", "input swipe $midX $startY $midX $eY 300"))
                            }
                            "scroll_down" -> {
                                val midX = screenW / 2
                                val startY = screenH / 3
                                val eY = screenH * 2 / 3
                                Runtime.getRuntime().exec(arrayOf("sh", "-c", "input swipe $midX $startY $midX $eY 300"))
                            }
                            // Mouse click / tap at normalized coordinates
                            "tap", "click" -> {
                                if (tapX != null && tapY != null) {
                                    val x = (tapX * screenW).toInt()
                                    val y = (tapY * screenH).toInt()
                                    Runtime.getRuntime().exec(arrayOf("sh", "-c", "input tap $x $y"))
                                }
                            }
                            // Long press
                            "long_press" -> {
                                if (tapX != null && tapY != null) {
                                    val x = (tapX * screenW).toInt()
                                    val y = (tapY * screenH).toInt()
                                    Runtime.getRuntime().exec(arrayOf("sh", "-c", "input swipe $x $y $x $y 800"))
                                }
                            }
                            // Drag / swipe from (tapX,tapY) -> (endX,endY)
                            "swipe", "drag" -> {
                                if (tapX != null && tapY != null && endX != null && endY != null) {
                                    val sx = (tapX * screenW).toInt()
                                    val sy = (tapY * screenH).toInt()
                                    val ex = (endX * screenW).toInt()
                                    val ey = (endY * screenH).toInt()
                                    Runtime.getRuntime().exec(arrayOf("sh", "-c", "input swipe $sx $sy $ex $ey $duration"))
                                }
                            }
                            // Mouse scroll at position with delta
                            "scroll" -> {
                                if (tapX != null && tapY != null && scrollDelta != null) {
                                    val cx = (tapX * screenW).toInt()
                                    val cy = (tapY * screenH).toInt()
                                    val scrollAmount = (scrollDelta * screenH * 0.15).toInt()
                                    val eY = (cy - scrollAmount).coerceIn(0, screenH)
                                    Runtime.getRuntime().exec(arrayOf("sh", "-c", "input swipe $cx $cy $cx $eY 200"))
                                }
                            }
                            // Type text (keyboard input)
                            "type" -> {
                                if (text != null && text.isNotEmpty()) {
                                    // Escape special chars for shell
                                    val escaped = text.replace("\\", "\\\\").replace("'", "'\\''").replace(" ", "%s")
                                    Runtime.getRuntime().exec(arrayOf("sh", "-c", "input text '$escaped'"))
                                }
                            }
                            // Individual key events (enter, backspace, etc)
                            "key" -> {
                                if (text != null) {
                                    val keycode = when (text.lowercase()) {
                                        "enter", "return" -> "KEYCODE_ENTER"
                                        "backspace", "delete" -> "KEYCODE_DEL"
                                        "tab" -> "KEYCODE_TAB"
                                        "escape", "esc" -> "KEYCODE_ESCAPE"
                                        "space" -> "KEYCODE_SPACE"
                                        "up" -> "KEYCODE_DPAD_UP"
                                        "down" -> "KEYCODE_DPAD_DOWN"
                                        "left" -> "KEYCODE_DPAD_LEFT"
                                        "right" -> "KEYCODE_DPAD_RIGHT"
                                        else -> text.uppercase()
                                    }
                                    Runtime.getRuntime().exec(arrayOf("sh", "-c", "input keyevent $keycode"))
                                }
                            }
                            // Brightness
                            "brightness_up" -> {
                                Runtime.getRuntime().exec(arrayOf("sh", "-c", "input keyevent KEYCODE_BRIGHTNESS_UP"))
                            }
                            "brightness_down" -> {
                                Runtime.getRuntime().exec(arrayOf("sh", "-c", "input keyevent KEYCODE_BRIGHTNESS_DOWN"))
                            }
                            // Notification shade
                            "notifications" -> {
                                Runtime.getRuntime().exec(arrayOf("sh", "-c", "cmd statusbar expand-notifications"))
                            }
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        android.util.Log.e("ZapShare", "Mirror control error: ${e.message}")
                        result.success(false)
                    }
                }

                "openUrl" -> {
                    val url = call.argument<String>("url")
                    if (url != null) {
                        val intent = Intent(Intent.ACTION_VIEW)
                        intent.setDataAndType(Uri.parse(url), "video/*")
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        try {
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            // Fallback to generic view if specific video player not found
                            val genericIntent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                            genericIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            try {
                                startActivity(genericIntent)
                                result.success(true)
                            } catch (e2: Exception) {
                                result.error("OPEN_ERROR", e2.message, null)
                            }
                        }
                    } else {
                        result.error("INVALID_ARGS", "URL is null", null)
                    }
                }

                "setScreenOrientation" -> {
                    val mode = call.argument<String>("mode") ?: "auto"
                    val orientation = when (mode) {
                        "landscape" -> android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                        "portrait" -> android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
                        "auto" -> android.content.pm.ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
                        else -> android.content.pm.ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
                    }
                    requestedOrientation = orientation
                    result.success(true)
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
        handleShareIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShareIntent(intent)
    }

    private fun handleShareIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action
        val type = intent.type
        if (Intent.ACTION_SEND == action && type != null) {
            val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            if (uri != null) {
                val name = getFileNameFromUri(uri)
                val files = listOf(mapOf("uri" to uri.toString(), "name" to name))
                methodChannel?.invokeMethod("sharedFiles", files)
            }
        } else if (Intent.ACTION_SEND_MULTIPLE == action && type != null) {
            val uriList = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            if (uriList != null && uriList.isNotEmpty()) {
                val files = uriList.map { uri ->
                    mapOf("uri" to uri.toString(), "name" to getFileNameFromUri(uri))
                }
                methodChannel?.invokeMethod("sharedFiles", files)
            }
        }
    }

    private fun getFileNameFromUri(uri: Uri): String {
        var name = uri.lastPathSegment ?: "file"
        try {
            val cursor: Cursor? = contentResolver.query(uri, null, null, null, null)
            cursor?.use {
                val nameIndex = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (it.moveToFirst() && nameIndex != -1) {
                    name = it.getString(nameIndex)
                }
            }
        } catch (_: Exception) {}
        return name
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        
        if (requestCode == MEDIA_PROJECTION_REQUEST) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                // Store for service to use
                ScreenMirrorService.projectionResultCode = resultCode
                ScreenMirrorService.projectionData = data

                // Start the foreground service (MUST call startForeground before getMediaProjection on Android 10+)
                val metrics = resources.displayMetrics
                val serviceIntent = Intent(this, ScreenMirrorService::class.java)
                serviceIntent.putExtra("width", metrics.widthPixels / 2)
                serviceIntent.putExtra("height", metrics.heightPixels / 2)
                serviceIntent.putExtra("dpi", metrics.densityDpi / 2)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(serviceIntent)
                } else {
                    startService(serviceIntent)
                }
                screenCaptureResult?.success(true)
            } else {
                screenCaptureResult?.success(false)
            }
            screenCaptureResult = null
        } else if (requestCode == FOLDER_PICKER_REQUEST) {
            if (resultCode == Activity.RESULT_OK) {
                val uri = data?.data
                pickedFolderUri = uri
                folderResult?.success(uri?.toString())
            } else {
                folderResult?.success(null)
            }
            folderResult = null
        } else if (requestCode == VIDEO_PICKER_REQUEST) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                val selectedFiles = mutableListOf<Map<String, String>>()
                
                // Handle multiple files
                val clipData = data.clipData
                if (clipData != null) {
                    for (i in 0 until clipData.itemCount) {
                        val uri = clipData.getItemAt(i).uri
                        val name = getFileNameFromUri(uri)
                        selectedFiles.add(mapOf("uri" to uri.toString(), "name" to name))
                    }
                } else {
                    // Handle single file
                    val uri = data.data
                    if (uri != null) {
                        val name = getFileNameFromUri(uri)
                        selectedFiles.add(mapOf("uri" to uri.toString(), "name" to name))
                    }
                }
                
                videoPickerResult?.success(selectedFiles)
            } else {
                videoPickerResult?.success(null)
            }
            videoPickerResult = null
        }
    }



    // Helper function to recursively list files in a folder
    private fun listFilesRecursively(folderUri: Uri, files: JSONArray) {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            folderUri,
            DocumentsContract.getTreeDocumentId(folderUri)
        )
        val cursor = contentResolver.query(childrenUri, arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE
        ), null, null, null)
        cursor?.use {
            while (it.moveToNext()) {
                val docId = it.getString(0)
                val name = it.getString(1)
                val mime = it.getString(2)
                val docUri = DocumentsContract.buildDocumentUriUsingTree(folderUri, docId)
                if (DocumentsContract.Document.MIME_TYPE_DIR == mime) {
                    listFilesRecursively(docUri, files)
                } else {
                    val fileObj = JSONObject()
                    fileObj.put("uri", docUri.toString())
                    fileObj.put("name", name)
                    files.put(fileObj)
                }
            }
        }
    }

    /**
     * Acquire multicast lock to enable UDP multicast/broadcast reception
     * This is CRITICAL for device discovery, especially when device is hotspot
     * 
     * NOTE: In hotspot mode, multicast lock may have limited effect since the device
     * is acting as AP (Access Point) rather than a WiFi client. The socket binding
     * strategy on the Dart side handles hotspot mode by binding to 0.0.0.0 to listen
     * on all interfaces including the hotspot interface.
     */
    private fun acquireMulticastLock() {
        try {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            
            // Release existing lock if any
            multicastLock?.release()
            
            // Create and acquire new multicast lock
            // Set setReferenceCounted(false) to ensure lock is held until explicitly released
            multicastLock = wifiManager.createMulticastLock("ZapShare:MulticastLock")
            multicastLock?.setReferenceCounted(false)
            
            // Acquire with WakeLock mode to ensure it stays active
            multicastLock?.acquire()
            
            val isHeld = multicastLock?.isHeld ?: false
            if (isHeld) {
                android.util.Log.d("ZapShare", "✅ Multicast lock ACQUIRED successfully - UDP discovery enabled")
            } else {
                android.util.Log.w("ZapShare", "⚠️ Multicast lock acquired but not held (may be in hotspot mode)")
            }
            
            // Log WiFi state for debugging
            val wifiInfo = wifiManager.connectionInfo
            val isConnected = wifiInfo != null && wifiInfo.networkId != -1
            android.util.Log.d("ZapShare", "   WiFi connected: $isConnected")
            
            if (!isConnected) {
                android.util.Log.d("ZapShare", "   Device may be in hotspot mode - relying on 0.0.0.0 socket binding")
            }
            
        } catch (e: Exception) {
            android.util.Log.e("ZapShare", "❌ Failed to acquire multicast lock: ${e.message}")
            android.util.Log.d("ZapShare", "   This may be expected in hotspot mode - socket binding should still work")
        }
    }

    /**
     * Release multicast lock to save battery
     */
    private fun releaseMulticastLock() {
        try {
            if (multicastLock?.isHeld == true) {
                multicastLock?.release()
                android.util.Log.d("ZapShare", "✅ Multicast lock RELEASED")
            }
        } catch (e: Exception) {
            android.util.Log.e("ZapShare", "❌ Failed to release multicast lock: ${e.message}")
        }
    }

    override fun onResume() {
        super.onResume()
        // Re-acquire multicast lock when app comes to foreground
        acquireMulticastLock()
    }

    override fun onPause() {
        super.onPause()
        // Release multicast lock when app goes to background to save battery
        // Only release if we're not in background service mode
        // For now, keep it held to maintain discovery
    }

    override fun onDestroy() {
        super.onDestroy()
        // Cleanup Wi-Fi Direct
        wifiDirectManager?.cleanup()
        
        // Stop Screen Mirror Service
        try {
            val serviceIntent = Intent(this, ScreenMirrorService::class.java)
            stopService(serviceIntent)
        } catch (e: Exception) {}

        // Stop Video Server
        videoServer?.stopServer()
        
        // Always release multicast lock when app is destroyed
        releaseMulticastLock()
    }

    // --- Inner Class: Native Video Web Server ---
    private class VideoWebServer(
        private val context: Context, 
        private val fileMap: Map<String, Uri>,
        private val nameMap: Map<String, String>
    ) : Thread() {
        private var serverSocket: java.net.ServerSocket? = null
        var port: Int = 0
        private var isRunning = false
        
        init {
            try {
                serverSocket = java.net.ServerSocket(0)
                port = serverSocket?.localPort ?: 0
            } catch (e: Exception) {
                android.util.Log.e("ZapShareServer", "Failed to bind socket: ${e.message}")
            }
        }
        
        fun stopServer() {
            isRunning = false
            try { serverSocket?.close() } catch (e: Exception) {}
        }
        
        override fun run() {
            isRunning = true
            while (isRunning) {
                try {
                    val client = serverSocket?.accept()
                    if (client != null) {
                       Thread { handleClient(client) }.start()
                    }
                } catch (e: Exception) {
                    // Socket closed or error
                }
            }
        }
        
        private fun handleClient(socket: java.net.Socket) {
            try {
                val inputStream = socket.getInputStream()
                val outputStream = socket.getOutputStream()
                
                // Read headers
                val reader = java.io.BufferedReader(java.io.InputStreamReader(inputStream))
                val firstLine = reader.readLine()
                if (firstLine == null) {
                    socket.close()
                    return
                }
                
                // Parse "GET /video/0 HTTP/1.1"
                val parts = firstLine.split(" ")
                if (parts.size < 2) {
                    socket.close()
                    return
                }
                
                val method = parts[0]
                val path = parts[1] // "/video/0"
                
                // Handle OPTIONS request for CORS Preflight
                if (method == "OPTIONS") {
                    val writer = java.io.PrintWriter(outputStream)
                    writer.print("HTTP/1.1 200 OK\r\n")
                    writer.print("Access-Control-Allow-Origin: *\r\n")
                    writer.print("Access-Control-Allow-Methods: GET, OPTIONS\r\n")
                    writer.print("Access-Control-Allow-Headers: Range\r\n")
                    writer.print("Content-Length: 0\r\n")
                    writer.print("\r\n")
                    writer.flush()
                    socket.close()
                    return
                }
                
                if (!path.startsWith("/video/")) {
                     send404(outputStream)
                     socket.close()
                     return
                }
                
                val idStr = path.substring("/video/".length)
                // Filter out any query params if present
                val idEnd = idStr.indexOf('?')
                val id = if (idEnd != -1) idStr.substring(0, idEnd) else idStr
                
                val uri = fileMap[id]
                
                if (uri == null) {
                    send404(outputStream)
                    socket.close()
                    return
                }
                
                // Parse Headers for Range
                var rangeStart: Long = 0
                var rangeEnd: Long = -1
                var line = reader.readLine()
                while (line != null && line.isNotEmpty()) {
                    if (line.lowercase().startsWith("range: bytes=")) {
                        val rangeVal = line.substring(13).trim()
                        val rangeParts = rangeVal.split("-")
                        try {
                            rangeStart = rangeParts[0].toLong()
                        } catch(e: Exception) {}
                        if (rangeParts.size > 1 && rangeParts[1].isNotEmpty()) {
                            try {
                                rangeEnd = rangeParts[1].toLong()
                            } catch(e: Exception) {}
                        }
                    }
                    line = reader.readLine()
                }
                
                serveFile(outputStream, uri, rangeStart, rangeEnd, method, id)
                
            } catch (e: Exception) {
                e.printStackTrace()
            } finally {
                try { socket.close() } catch(e: Exception) {}
            }
        }
        
        private fun serveFile(output: java.io.OutputStream, uri: Uri, start: Long, end: Long, method: String, id: String) {
            try {
                val afd = context.contentResolver.openAssetFileDescriptor(uri, "r")
                if (afd == null) {
                    return
                }
                
                var fileSize = afd.length
                if (fileSize == -1L) {
                    // Fallback: Try to get size from cursor
                    try {
                        context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                            if (cursor.moveToFirst()) {
                                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                                if (sizeIndex != -1) {
                                    fileSize = cursor.getLong(sizeIndex)
                                }
                            }
                        }
                    } catch (e: Exception) {}
                }
                
                if (fileSize == -1L) {
                     // Unable to determine size, cannot serve properly with ranges
                     afd.close()
                     send404(output) // Or 500
                     return
                }
                val finalEnd = if (end == -1L || end >= fileSize) fileSize - 1 else end
                val contentLength = finalEnd - start + 1
                
                // Determin MimeType Smartly
                val name = nameMap[id] ?: "video.mp4"
                var mimeType = getSmartMimeType(context, uri, name)
                
                val writer = java.io.PrintWriter(output)
                
                // Headers
                if (start > 0 || end != -1L) {
                    writer.print("HTTP/1.1 206 Partial Content\r\n")
                    writer.print("Content-Range: bytes $start-$finalEnd/$fileSize\r\n")
                } else {
                    writer.print("HTTP/1.1 200 OK\r\n")
                }
                
                writer.print("Content-Type: $mimeType\r\n") 
                writer.print("Content-Length: $contentLength\r\n")
                writer.print("Accept-Ranges: bytes\r\n")
                writer.print("Connection: keep-alive\r\n") // Keep-Alive for better streaming
                // CORS Headers (Critical for Web Playback across ports)
                writer.print("Access-Control-Allow-Origin: *\r\n")
                writer.print("Access-Control-Allow-Methods: GET, OPTIONS\r\n")
                writer.print("Access-Control-Allow-Headers: Range\r\n")
                writer.print("\r\n")
                writer.flush()
                
                if (method != "HEAD") {
                   val fileInputStream = afd.createInputStream()
                   val fileChannel = fileInputStream.channel
                   
                   // Transfer logic ...
                   val buffer = ByteArray(64 * 1024)
                   var remaining = contentLength
                   fileChannel.position(start)
                   
                   while (remaining > 0) {
                       val toRead = if (remaining > buffer.size) buffer.size else remaining.toInt()
                       val bytesRead = fileInputStream.read(buffer, 0, toRead)
                       if (bytesRead == -1) break
                       output.write(buffer, 0, bytesRead)
                       remaining -= bytesRead
                   }
                   output.flush()
                   fileInputStream.close()
                }
                afd.close()
            } catch (e: Exception) {
               // Client disconnected
            }
        }
        
        private fun getSmartMimeType(context: Context, uri: Uri, name: String): String {
            val lowerName = name.lowercase()
            return when {
                lowerName.endsWith(".mp4") -> "video/mp4"
                lowerName.endsWith(".mkv") -> "video/webm" // Chrome plays mkv better as webm
                lowerName.endsWith(".webm") -> "video/webm"
                lowerName.endsWith(".mov") -> "video/quicktime"
                lowerName.endsWith(".avi") -> "video/x-msvideo"
                else -> {
                    // Fallback to resolver
                    val resolverType = context.contentResolver.getType(uri)
                    resolverType ?: "video/mp4"
                }
            }
        }
        
        private fun send404(output: java.io.OutputStream) {
             val writer = java.io.PrintWriter(output)
             writer.print("HTTP/1.1 404 Not Found\r\n\r\n")
             writer.flush()
        }
    }
    
    // --- Foreground Service Helper ---
    private fun startForegroundServiceCompat(title: String, content: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channelId = "zapshare_service_channel"
            val channelName = "ZapShare Background Service"
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
            
            if (notificationManager.getNotificationChannel(channelId) == null) {
                val channel = android.app.NotificationChannel(channelId, channelName, android.app.NotificationManager.IMPORTANCE_LOW)
                notificationManager.createNotificationChannel(channel)
            }
            
            // Create pending intent to return to app
            val intent = Intent(this, MainActivity::class.java)
            val pendingIntent = android.app.PendingIntent.getActivity(this, 0, intent, android.app.PendingIntent.FLAG_IMMUTABLE)

            val notification = android.app.Notification.Builder(this, channelId)
                .setContentTitle(title)
                .setContentText(content)
                .setSmallIcon(android.R.drawable.ic_menu_upload) 
                .setContentIntent(pendingIntent)
                .build()
            
            // Note: Since this is an Activity, we can't strictly "startForeground" like a Service.
            // But if the user wants background persistence, we typically rely on a started Service.
            // However, the flutter_foreground_task plugin is managing a service already? 
            // If the user wants *native* persistence without dart:
            // We should start a real Service. For now, rely on Notification to just SHOW status.
            // But to keep alive, we need a Service.
            // Let's rely on flutter_foreground_task running in Dart which keeps the process alive.
            // The "startForegroundService" method channel here is just a convenience to notify system UI if needed,
            // but effectively, logic should drive flutter_foreground_task from Dart.
            
            // RE-EVALUATION: The USER specifically asked for "background support... like show in notification".
            // Since we implemented a Native Video Server, that server runs in this Activity's process.
            // If the Activity dies, the server dies.
            // Android kills background activities. Use a Foreground Service.
            
            // Launch the EmptyService defined below
            val serviceIntent = Intent(this, ZapShareNativeService::class.java)
            serviceIntent.putExtra("title", title)
            serviceIntent.putExtra("content", content)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                // Check permissions (optional safety, as Dart side handles it)
                android.util.Log.d("ZapShareService", "Starting Foreground Service Intent...")
                startForegroundService(serviceIntent)
            } else {
                startService(serviceIntent)
            }
        }
    }
    
    private fun stopForegroundServiceCompat() {
        val serviceIntent = Intent(this, ZapShareNativeService::class.java)
        stopService(serviceIntent)
    }

}

// Minimal Foreground Service to keep Process Alive
class ZapShareNativeService : android.app.Service() {
    override fun onBind(intent: Intent?): android.os.IBinder? = null
    
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        android.util.Log.d("ZapShareService", "onStartCommand called")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val title = intent?.getStringExtra("title") ?: "ZapShare"
            val content = intent?.getStringExtra("content") ?: "Service is running in background"
            val channelId = "zapshare_service_channel"
            val channelName = "ZapShare Background Service"
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
            
             // Use IMPORTANCE_DEFAULT to ensure visibility
             if (notificationManager.getNotificationChannel(channelId) == null) {
                val channel = android.app.NotificationChannel(channelId, channelName, android.app.NotificationManager.IMPORTANCE_DEFAULT)
                notificationManager.createNotificationChannel(channel)
            }
            
            val appIntent = Intent(this, MainActivity::class.java)
            val pendingIntent = android.app.PendingIntent.getActivity(this, 0, appIntent, android.app.PendingIntent.FLAG_IMMUTABLE)

            // Use R.drawable.ic_stat_notify (User provided icon)
            val notification = android.app.Notification.Builder(this, channelId)
                .setContentTitle(title)
                .setContentText(content)
                .setSmallIcon(R.drawable.ic_stat_notify) 
                .setContentIntent(pendingIntent)
                .setOngoing(true)
                .build()
                
            android.util.Log.d("ZapShareService", "Calling startForeground(1, notification)")
            
            // Explicitly specify service type for Android 14 compatibility
            if (Build.VERSION.SDK_INT >= 34) { // Android 14
                 try {
                     startForeground(1, notification, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
                 } catch (e: Exception) {
                     android.util.Log.e("ZapShareService", "Failed to start foreground with type: ${e.message}")
                     // Fallback to standard
                     startForeground(1, notification)
                 }
            } else {
                startForeground(1, notification)
            }
        }
        return START_STICKY
    }
}

// ─── Screen Mirror Service: MediaProjection + MJPEG HTTP Server ──────────────
class ScreenMirrorService : android.app.Service() {
    companion object {
        var projectionResultCode: Int = 0
        var projectionData: Intent? = null
        var instance: ScreenMirrorService? = null
    }

    var port: Int = 0
    private var mediaProjection: android.media.projection.MediaProjection? = null
    private var virtualDisplay: android.hardware.display.VirtualDisplay? = null
    private var imageReader: android.media.ImageReader? = null
    private var mjpegServer: MjpegServer? = null
    private var audioRecord: android.media.AudioRecord? = null

    override fun onBind(intent: Intent?): android.os.IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        instance = this
        android.util.Log.d("ScreenMirror", "onStartCommand called")

        // 1. Start foreground FIRST (required before getMediaProjection on Android 10+)
        val channelId = "zapshare_screen_mirror_channel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
            if (nm.getNotificationChannel(channelId) == null) {
                val channel = android.app.NotificationChannel(
                    channelId, "Screen Mirror", android.app.NotificationManager.IMPORTANCE_LOW
                )
                nm.createNotificationChannel(channel)
            }
        }

        val appIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = android.app.PendingIntent.getActivity(
            this, 0, appIntent, android.app.PendingIntent.FLAG_IMMUTABLE
        )

        val notification = android.app.Notification.Builder(this, channelId)
            .setContentTitle("ZapShare Screen Mirror")
            .setContentText("Casting screen to another device")
            .setSmallIcon(R.drawable.ic_stat_notify)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                2, notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
        } else {
            startForeground(2, notification)
        }

        // 2. Create MediaProjection (AFTER startForeground)
        try {
            val mpManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val projData = projectionData
            if (projData == null) {
                android.util.Log.e("ScreenMirror", "projectionData is null, cannot start capture")
                stopSelf()
                return START_NOT_STICKY
            }
            mediaProjection = mpManager.getMediaProjection(projectionResultCode, projData)

            // 3. Register MediaProjection callback (REQUIRED on Android 14+ / API 34+)
            //    Must be done BEFORE createVirtualDisplay() or it throws IllegalStateException
            if (Build.VERSION.SDK_INT >= 34) {
                android.util.Log.d("ScreenMirror", "Android 14+ (API ${Build.VERSION.SDK_INT}) detected, registering MediaProjection callback")
                mediaProjection!!.registerCallback(object : android.media.projection.MediaProjection.Callback() {
                    override fun onStop() {
                        android.util.Log.d("ScreenMirror", "MediaProjection callback: onStop()")
                        stopSelf()
                    }
                }, android.os.Handler(android.os.Looper.getMainLooper()))
            } else {
                android.util.Log.d("ScreenMirror", "Pre-Android 14 (API ${Build.VERSION.SDK_INT}), skipping MediaProjection callback registration")
            }

            // 4. Set up screen capture (higher resolution for good quality)
            val displayMetrics = resources.displayMetrics
            val screenWidth = displayMetrics.widthPixels
            val screenHeight = displayMetrics.heightPixels
            // Use 75% of actual screen resolution for quality, capped at 1080p
            val captureWidth = intent?.getIntExtra("width", 0)?.takeIf { it > 0 }
                ?: (screenWidth * 3 / 4).coerceAtMost(1080)
            val captureHeight = intent?.getIntExtra("height", 0)?.takeIf { it > 0 }
                ?: (screenHeight * 3 / 4).coerceAtMost(1920)
            val captureDpi = intent?.getIntExtra("dpi", 0)?.takeIf { it > 0 }
                ?: (displayMetrics.densityDpi * 3 / 4).coerceAtLeast(160)

            android.util.Log.d("ScreenMirror", "Creating ImageReader: ${captureWidth}x${captureHeight}")
            imageReader = android.media.ImageReader.newInstance(
                captureWidth, captureHeight, android.graphics.PixelFormat.RGBA_8888, 2
            )

            android.util.Log.d("ScreenMirror", "Creating VirtualDisplay...")
            virtualDisplay = mediaProjection!!.createVirtualDisplay(
                "ZapShareScreen",
                captureWidth, captureHeight, captureDpi,
                android.hardware.display.DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                imageReader!!.surface, null, null
            )
            android.util.Log.d("ScreenMirror", "VirtualDisplay created successfully")

            // 5. Set up AudioPlaybackCapture (Android 10+ / API 29+)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                try {
                    val audioPlaybackConfig = android.media.AudioPlaybackCaptureConfiguration.Builder(mediaProjection!!)
                        .addMatchingUsage(android.media.AudioAttributes.USAGE_MEDIA)
                        .addMatchingUsage(android.media.AudioAttributes.USAGE_GAME)
                        .addMatchingUsage(android.media.AudioAttributes.USAGE_UNKNOWN)
                        .build()

                    val sampleRate = 44100
                    val channelConfig = android.media.AudioFormat.CHANNEL_IN_STEREO
                    val audioFormat = android.media.AudioFormat.ENCODING_PCM_16BIT
                    val minBufSize = android.media.AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
                    val bufferSize = (minBufSize * 4).coerceAtLeast(16384)

                    audioRecord = android.media.AudioRecord.Builder()
                        .setAudioPlaybackCaptureConfig(audioPlaybackConfig)
                        .setAudioFormat(
                            android.media.AudioFormat.Builder()
                                .setSampleRate(sampleRate)
                                .setChannelMask(channelConfig)
                                .setEncoding(audioFormat)
                                .build()
                        )
                        .setBufferSizeInBytes(bufferSize)
                        .build()

                    if (audioRecord?.state == android.media.AudioRecord.STATE_INITIALIZED) {
                        audioRecord?.startRecording()
                        android.util.Log.d("ScreenMirror", "AudioPlaybackCapture started (${sampleRate}Hz stereo 16bit, buf=$bufferSize)")
                    } else {
                        android.util.Log.e("ScreenMirror", "AudioRecord failed to initialize")
                        audioRecord?.release()
                        audioRecord = null
                    }
                } catch (e: Exception) {
                    android.util.Log.e("ScreenMirror", "AudioPlaybackCapture not available: ${e.message}", e)
                    audioRecord = null
                }
            } else {
                android.util.Log.d("ScreenMirror", "AudioPlaybackCapture requires Android 10+ (current: API ${Build.VERSION.SDK_INT})")
            }

            // 6. Start MJPEG server (with optional audio)
            android.util.Log.d("ScreenMirror", "Starting MJPEG server...")
            mjpegServer = MjpegServer(imageReader!!, captureWidth, captureHeight, audioRecord)
            mjpegServer?.start()
            port = mjpegServer?.port ?: 0

            android.util.Log.d("ScreenMirror", "Screen mirror started on port $port (${captureWidth}x${captureHeight})")
        } catch (e: Exception) {
            android.util.Log.e("ScreenMirror", "Failed to start screen capture: ${e.message}", e)
            stopSelf()
        }

        return START_NOT_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        android.util.Log.d("ScreenMirror", "onDestroy - cleaning up")
        mjpegServer?.stopServer()
        mjpegServer = null
        virtualDisplay?.release()
        virtualDisplay = null
        imageReader?.close()
        imageReader = null
        try {
            audioRecord?.stop()
            audioRecord?.release()
        } catch (e: Exception) {
            android.util.Log.w("ScreenMirror", "AudioRecord cleanup error: ${e.message}")
        }
        audioRecord = null
        mediaProjection?.stop()
        mediaProjection = null
        port = 0
        instance = null
        // Clear static projection data to prevent stale reuse
        projectionResultCode = 0
        projectionData = null
    }

    // ─── Inner MJPEG HTTP Server (High Quality, Low Latency) + Audio Stream ────
    private class MjpegServer(
        private val imageReader: android.media.ImageReader,
        private val width: Int,
        private val height: Int,
        private val audioRecord: android.media.AudioRecord? = null
    ) : Thread() {
        private var serverSocket: java.net.ServerSocket? = null
        var port: Int = 0
        @Volatile private var isRunning = false
        private val clients = java.util.Collections.synchronizedList(
            mutableListOf<java.io.OutputStream>()
        )
        private val audioClients = java.util.Collections.synchronizedList(
            mutableListOf<java.io.OutputStream>()
        )
        // Double-buffer: capture writes to one slot, push reads from another
        private val frameSlots = arrayOfNulls<ByteArray>(2)
        private val frameLock = java.util.concurrent.locks.ReentrantLock()
        private val frameCondition = frameLock.newCondition()
        @Volatile private var writeIndex = 0
        @Volatile private var frameSeq: Long = 0
        @Volatile private var jpegQuality = 85 // High quality default

        init {
            serverSocket = java.net.ServerSocket(0)
            serverSocket?.reuseAddress = true
            port = serverSocket?.localPort ?: 0
            isDaemon = true
            android.util.Log.d("MjpegServer", "Server socket created on port $port, capture ${width}x${height}")
        }

        fun stopServer() {
            isRunning = false
            // Wake up any waiting push thread
            try {
                frameLock.lock()
                frameCondition.signalAll()
            } finally {
                frameLock.unlock()
            }
            synchronized(clients) {
                for (client in clients) {
                    try { client.close() } catch (_: Exception) {}
                }
                clients.clear()
            }
            synchronized(audioClients) {
                for (client in audioClients) {
                    try { client.close() } catch (_: Exception) {}
                }
                audioClients.clear()
            }
            try { serverSocket?.close() } catch (_: Exception) {}
        }

        /** Create a WAV header for streaming PCM audio */
        private fun createWavHeader(sampleRate: Int, channels: Int, bitsPerSample: Int): ByteArray {
            val byteRate = sampleRate * channels * bitsPerSample / 8
            val blockAlign = channels * bitsPerSample / 8
            val baos = java.io.ByteArrayOutputStream(44)

            fun writeIntLE(v: Int) {
                baos.write(v and 0xFF)
                baos.write((v shr 8) and 0xFF)
                baos.write((v shr 16) and 0xFF)
                baos.write((v shr 24) and 0xFF)
            }
            fun writeShortLE(v: Int) {
                baos.write(v and 0xFF)
                baos.write((v shr 8) and 0xFF)
            }

            baos.write("RIFF".toByteArray())
            writeIntLE(Int.MAX_VALUE)             // file size (max for streaming)
            baos.write("WAVE".toByteArray())
            baos.write("fmt ".toByteArray())
            writeIntLE(16)                        // PCM chunk size
            writeShortLE(1)                       // PCM format
            writeShortLE(channels)
            writeIntLE(sampleRate)
            writeIntLE(byteRate)
            writeShortLE(blockAlign)
            writeShortLE(bitsPerSample)
            baos.write("data".toByteArray())
            writeIntLE(Int.MAX_VALUE)             // data size (max for streaming)

            return baos.toByteArray()
        }

        override fun run() {
            isRunning = true

            // ── Frame Capture Thread ──────────────────────────────
            // Reads from ImageReader at native speed, encodes JPEG into double-buffer
            Thread {
                var reusableBitmap: android.graphics.Bitmap? = null
                var capturedFrames = 0L
                val startMs = System.currentTimeMillis()

                while (isRunning) {
                    val image = imageReader.acquireLatestImage()
                    if (image != null) {
                        try {
                            val planes = image.planes
                            val buffer = planes[0].buffer
                            val pixelStride = planes[0].pixelStride
                            val rowStride = planes[0].rowStride
                            val rowPadding = rowStride - pixelStride * width
                            val bitmapWidth = width + rowPadding / pixelStride

                            if (reusableBitmap == null || reusableBitmap!!.width != bitmapWidth || reusableBitmap!!.height != height) {
                                reusableBitmap?.recycle()
                                reusableBitmap = android.graphics.Bitmap.createBitmap(
                                    bitmapWidth, height, android.graphics.Bitmap.Config.ARGB_8888
                                )
                            }
                            reusableBitmap!!.copyPixelsFromBuffer(buffer)

                            val cropped = if (bitmapWidth != width) {
                                android.graphics.Bitmap.createBitmap(reusableBitmap!!, 0, 0, width, height)
                            } else {
                                reusableBitmap!!
                            }

                            // Encode to JPEG with high quality
                            val baos = java.io.ByteArrayOutputStream(width * height / 3)
                            cropped.compress(android.graphics.Bitmap.CompressFormat.JPEG, jpegQuality, baos)
                            val frameBytes = baos.toByteArray()

                            // Write to double-buffer slot (lock-free swap)
                            try {
                                frameLock.lock()
                                val slot = writeIndex
                                frameSlots[slot] = frameBytes
                                writeIndex = 1 - slot // flip
                                frameSeq++
                                frameCondition.signalAll() // wake push thread
                            } finally {
                                frameLock.unlock()
                            }

                            capturedFrames++
                            if (cropped !== reusableBitmap) {
                                cropped.recycle()
                            }
                        } catch (e: Exception) {
                            android.util.Log.w("MjpegServer", "Frame capture error: ${e.message}")
                        } finally {
                            image.close()
                        }
                    } else {
                        // No image available yet - short sleep
                        Thread.sleep(2)
                    }
                    // Adaptive rate: ~30fps capture = 16ms, but don't sleep if behind
                    Thread.sleep(16)
                }

                val elapsed = (System.currentTimeMillis() - startMs) / 1000.0
                android.util.Log.d("MjpegServer", "Capture stopped: $capturedFrames frames in ${elapsed}s (${(capturedFrames / elapsed.coerceAtLeast(0.1)).toInt()} fps)")
                reusableBitmap?.recycle()
            }.also { it.isDaemon = true; it.name = "MjpegCapture"; it.priority = Thread.MAX_PRIORITY }.start()

            // ── Frame Push Thread ─────────────────────────────────
            // Waits for new frame signal, then pushes to all clients immediately
            Thread {
                var lastPushedSeq: Long = -1
                var pushedFrames = 0L

                while (isRunning) {
                    var frame: ByteArray? = null
                    try {
                        frameLock.lock()
                        // Wait for a new frame (with timeout to avoid deadlock)
                        while (isRunning && frameSeq == lastPushedSeq) {
                            frameCondition.await(50, java.util.concurrent.TimeUnit.MILLISECONDS)
                        }
                        if (!isRunning) break
                        // Read from the slot the capture thread just wrote to
                        val readSlot = 1 - writeIndex
                        frame = frameSlots[readSlot]
                        lastPushedSeq = frameSeq
                    } finally {
                        frameLock.unlock()
                    }

                    if (frame != null && clients.isNotEmpty()) {
                        val dead = mutableListOf<java.io.OutputStream>()
                        val headerBytes = "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${frame.size}\r\n\r\n".toByteArray()
                        val endBytes = "\r\n".toByteArray()
                        synchronized(clients) {
                            for (client in clients) {
                                try {
                                    client.write(headerBytes)
                                    client.write(frame)
                                    client.write(endBytes)
                                    client.flush()
                                    pushedFrames++
                                } catch (_: Exception) {
                                    dead.add(client)
                                }
                            }
                            clients.removeAll(dead.toSet())
                        }
                    }
                }
                android.util.Log.d("MjpegServer", "Push stopped: $pushedFrames frames pushed")
            }.also { it.isDaemon = true; it.name = "MjpegPush"; it.priority = Thread.MAX_PRIORITY - 1 }.start()

            // ── Audio Capture Thread ──────────────────────────────
            // Reads from AudioRecord and pushes raw PCM to all audio clients
            if (audioRecord != null) {
                Thread {
                    val bufSize = 4096
                    val audioBuffer = ByteArray(bufSize)
                    android.util.Log.d("MjpegServer", "Audio capture thread started")

                    while (isRunning) {
                        try {
                            val bytesRead = audioRecord.read(audioBuffer, 0, bufSize)
                            if (bytesRead > 0 && audioClients.isNotEmpty()) {
                                val data = audioBuffer.copyOf(bytesRead)
                                val dead = mutableListOf<java.io.OutputStream>()
                                synchronized(audioClients) {
                                    for (client in audioClients) {
                                        try {
                                            client.write(data)
                                            client.flush()
                                        } catch (_: Exception) {
                                            dead.add(client)
                                        }
                                    }
                                    audioClients.removeAll(dead.toSet())
                                }
                            }
                        } catch (e: Exception) {
                            android.util.Log.w("MjpegServer", "Audio capture error: ${e.message}")
                            break
                        }
                    }
                    android.util.Log.d("MjpegServer", "Audio capture thread stopped")
                }.also { it.isDaemon = true; it.name = "AudioCapture"; it.priority = Thread.MAX_PRIORITY - 1 }.start()
            }

            // ── Accept Client Connections ─────────────────────────
            while (isRunning) {
                try {
                    val client = serverSocket?.accept() ?: continue
                    client.tcpNoDelay = true
                    client.sendBufferSize = 256 * 1024  // 256KB send buffer
                    client.soTimeout = 15000

                    Thread {
                        try {
                            val reader = java.io.BufferedReader(
                                java.io.InputStreamReader(client.getInputStream())
                            )
                            // Parse request line to determine path
                            val requestLine = reader.readLine() ?: ""
                            val requestPath = requestLine.split(" ").getOrNull(1) ?: "/"
                            // Read remaining headers
                            var line = reader.readLine()
                            while (line != null && line.isNotEmpty()) {
                                line = reader.readLine()
                            }

                            val output = java.io.BufferedOutputStream(client.getOutputStream(), 128 * 1024)
                            val isAudioRequest = requestPath == "/audio" && audioRecord != null

                            if (isAudioRequest) {
                                // ── Serve Audio Stream (WAV) ──
                                val wavHeader = createWavHeader(44100, 2, 16)
                                val headers =
                                    "HTTP/1.1 200 OK\r\n" +
                                    "Content-Type: audio/wav\r\n" +
                                    "Access-Control-Allow-Origin: *\r\n" +
                                    "Cache-Control: no-store, no-cache\r\n" +
                                    "Connection: keep-alive\r\n\r\n"
                                output.write(headers.toByteArray())
                                output.write(wavHeader)
                                output.flush()

                                synchronized(audioClients) {
                                    audioClients.add(output)
                                }
                                android.util.Log.d("MjpegServer", "Audio client connected (total: ${audioClients.size})")
                            } else {
                                // ── Serve MJPEG Stream (video) ──
                                val headers =
                                    "HTTP/1.1 200 OK\r\n" +
                                    "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n" +
                                    "Access-Control-Allow-Origin: *\r\n" +
                                    "Cache-Control: no-store, no-cache\r\n" +
                                    "Pragma: no-cache\r\n" +
                                    "Connection: keep-alive\r\n\r\n"
                                output.write(headers.toByteArray())
                                output.flush()

                                synchronized(clients) {
                                    clients.add(output)
                                }
                                android.util.Log.d("MjpegServer", "Video client connected (total: ${clients.size})")
                            }

                            // Keep connection alive — detect client disconnect
                            while (isRunning) {
                                try {
                                    if (client.getInputStream().read() == -1) break
                                } catch (_: java.net.SocketTimeoutException) {
                                    continue
                                } catch (_: Exception) {
                                    break
                                }
                            }
                        } catch (_: Exception) {
                        } finally {
                            synchronized(clients) {
                                try { client.getOutputStream()?.let { clients.remove(it) } } catch (_: Exception) {}
                            }
                            synchronized(audioClients) {
                                try { client.getOutputStream()?.let { audioClients.remove(it) } } catch (_: Exception) {}
                            }
                            try { client.close() } catch (_: Exception) {}
                            android.util.Log.d("MjpegServer", "Client disconnected (video: ${clients.size}, audio: ${audioClients.size})")
                        }
                    }.also { it.isDaemon = true; it.name = "MjpegClient" }.start()
                } catch (e: Exception) {
                    if (isRunning) {
                        android.util.Log.w("MjpegServer", "Accept error: ${e.message}")
                    }
                }
            }
        }
    }
}
