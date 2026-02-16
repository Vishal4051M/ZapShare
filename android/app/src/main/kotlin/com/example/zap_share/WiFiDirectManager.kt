package com.example.zap_share

import android.net.wifi.WpsInfo

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.NetworkInfo
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pDevice
import android.net.wifi.p2p.WifiP2pDeviceList
import android.net.wifi.p2p.WifiP2pGroup
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.lang.reflect.Method

/**
 * Wi-Fi Direct Manager for ZapShare
 */
class WiFiDirectManager(
    private val context: Context,
    private val methodChannel: MethodChannel
) {
    companion object {
        private const val TAG = "WiFiDirectManager"
    }

    private var wifiP2pManager: WifiP2pManager? = null
    private var channel: WifiP2pManager.Channel? = null
    private var receiver: BroadcastReceiver? = null
    private val intentFilter = IntentFilter()

    private var isInitialized = false
    private var isWifiP2pEnabled = false
    private var currentGroup: WifiP2pGroup? = null
    private var thisDeviceAddress: String? = null
    private val discoveredPeers = mutableListOf<WifiP2pDevice>()
    
    // State tracking to prevent duplicate callbacks
    private var lastConnectionState: Boolean = false // Track connected vs disconnected

    init {
        // Set up intent filter for Wi-Fi P2P broadcasts
        intentFilter.apply {
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)
        }
    }

    /**
     * Initialize Wi-Fi Direct manager
     */
    fun initialize(): Boolean {
        try {
            Log.d(TAG, "Initializing Wi-Fi Direct manager...")

            wifiP2pManager = context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
            if (wifiP2pManager == null) {
                Log.e(TAG, "Wi-Fi P2P not supported on this device")
                return false
            }

            channel = wifiP2pManager?.initialize(context, Looper.getMainLooper(), null)
            if (channel == null) {
                Log.e(TAG, "Failed to initialize Wi-Fi P2P channel")
                return false
            }

            // Register broadcast receiver
            receiver = WiFiDirectBroadcastReceiver()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(receiver, intentFilter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                context.registerReceiver(receiver, intentFilter)
            }

            // CRITICAL: Clear any existing persistent groups on startup
            deletePersistentGroups()

            isInitialized = true
            Log.d(TAG, "Wi-Fi Direct manager initialized successfully")
            return true
        } catch (e: Exception) {
            Log.e(TAG, "Error initializing Wi-Fi Direct manager", e)
            return false
        }
    }

    /**
     * Delete all persistent Wi-Fi Direct groups using reflection.
     */
    private fun deletePersistentGroups() {
        if (wifiP2pManager == null || channel == null) return

        try {
            val methods: Array<Method> = WifiP2pManager::class.java.methods
            for (method in methods) {
                if (method.name == "deletePersistentGroup") {
                    Log.d(TAG, "Found deletePersistentGroup method, invoking for netId 0..31")
                    for (netId in 0..31) {
                        method.invoke(wifiP2pManager, channel, netId, object : WifiP2pManager.ActionListener {
                            override fun onSuccess() {}
                            override fun onFailure(reason: Int) {}
                        })
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error deleting persistent groups via reflection", e)
        }
    }

    /**
     * Start discovering Wi-Fi Direct peers
     */
    @SuppressLint("MissingPermission")
    fun startPeerDiscovery(): Boolean {
        if (!isInitialized || wifiP2pManager == null || channel == null) {
            Log.e(TAG, "Wi-Fi Direct not initialized")
            return false
        }

        try {
            Log.d(TAG, "Starting peer discovery...")
            val channelCopy = channel ?: return false
            wifiP2pManager?.discoverPeers(channelCopy, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    Log.d(TAG, "Peer discovery initiated successfully")
                }

                override fun onFailure(reason: Int) {
                    Log.e(TAG, "Failed to start peer discovery. Reason: ${getFailureReason(reason)}")
                }
            })
            return true
        } catch (e: Exception) {
            Log.e(TAG, "Error starting peer discovery", e)
            return false
        }
    }

    /**
     * Stop discovering Wi-Fi Direct peers
     */
    @SuppressLint("MissingPermission")
    fun stopPeerDiscovery(): Boolean {
        if (!isInitialized || wifiP2pManager == null || channel == null) return false

        try {
            Log.d(TAG, "Stopping peer discovery...")
            val channelCopy = channel ?: return false
            wifiP2pManager?.stopPeerDiscovery(channelCopy, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    Log.d(TAG, "Peer discovery stopped successfully")
                }
                override fun onFailure(reason: Int) {
                    Log.e(TAG, "Failed to stop peer discovery. Reason: ${getFailureReason(reason)}")
                }
            })
            return true
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping peer discovery", e)
            return false
        }
    }

    /**
     * Create a Wi-Fi Direct Group (AP/Hotspot mode).
     */
    @SuppressLint("MissingPermission")
    fun createGroup(): Boolean {
        if (!isInitialized || wifiP2pManager == null || channel == null) {
            Log.e(TAG, "Wi-Fi Direct not initialized")
            return false
        }

        try {
            // Clean slate — remove any existing group and persistent groups
            deletePersistentGroups()

            Log.d(TAG, "Creating Wi-Fi Direct group (AP/Hotspot mode)...")

            // Fallback to legacy/auto band selection for better compatibility
            Log.d(TAG, "Creating Wi-Fi Direct group (Legacy/Auto Band)...")
            createGroupLegacy()

            return true
        } catch (e: Exception) {
            Log.e(TAG, "Error creating Wi-Fi Direct group", e)
            return false
        }
    }

    /**
     * Legacy createGroup() — no band preference
     */
    @SuppressLint("MissingPermission")
    private fun createGroupLegacy() {
        val channelCopy = channel ?: return
        wifiP2pManager?.createGroup(channelCopy, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(TAG, "Group created successfully (legacy/auto band)")
            }

            override fun onFailure(reason: Int) {
                Log.e(TAG, "Failed to create group. Reason: ${getFailureReason(reason)}")
                methodChannel.invokeMethod("onGroupCreationFailed", mapOf(
                    "reason" to getFailureReason(reason)
                ))
            }
        })
    }

    /**
     * Connect to a Wi-Fi Direct peer
     */
    @SuppressLint("MissingPermission")
    fun connectToPeer(deviceAddress: String, isGroupOwner: Boolean): Boolean {
        if (!isInitialized || wifiP2pManager == null || channel == null) {
            Log.e(TAG, "Wi-Fi Direct not initialized")
            return false
        }

        if (deviceAddress == thisDeviceAddress) {
            Log.e(TAG, "Cannot connect to self ($deviceAddress)")
            return false
        }

        try {
            // Don't stop peer discovery here - let it continue in the background
            // Don't delete persistent groups here - it can interfere with connection

            Log.d(TAG, "Connecting to peer: $deviceAddress (isGroupOwner: $isGroupOwner)")

            val config = WifiP2pConfig().apply {
                this.deviceAddress = deviceAddress
                this.wps.setup = WpsInfo.PBC
            }
            
            // Set groupOwnerIntent to 0: sender strongly prefers NOT being the Group Owner
            // This makes the receiver the GO at 192.168.49.1, a known predictable IP
            // that the sender can then connect to for HTTP handshake
            config.groupOwnerIntent = 0
            Log.d(TAG, "GroupOwnerIntent set to: ${config.groupOwnerIntent} (prefer client - let receiver be GO)")

            val channelCopy = channel ?: return false
            wifiP2pManager?.connect(channelCopy, config, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    Log.d(TAG, "Connection initiated successfully to $deviceAddress")
                }

                override fun onFailure(reason: Int) {
                    Log.e(TAG, "Failed to connect to peer. Reason: ${getFailureReason(reason)}")
                    methodChannel.invokeMethod("onConnectionFailed", mapOf(
                        "deviceAddress" to deviceAddress,
                        "reason" to getFailureReason(reason)
                    ))
                }
            })

            return true
        } catch (e: Exception) {
            Log.e(TAG, "Error connecting to peer", e)
            return false
        }
    }

    /**
     * Remove the current Wi-Fi Direct group
     */
    @SuppressLint("MissingPermission")
    fun removeGroup(): Boolean {
        if (!isInitialized || wifiP2pManager == null || channel == null) return false

        try {
            Log.d(TAG, "Removing Wi-Fi Direct group...")
            val channelCopy = channel ?: return false
            wifiP2pManager?.removeGroup(channelCopy, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    Log.d(TAG, "Group removed successfully")
                    currentGroup = null
                    methodChannel.invokeMethod("onGroupRemoved", null)
                    deletePersistentGroups()
                }

                override fun onFailure(reason: Int) {
                    Log.e(TAG, "Failed to remove group. Reason: ${getFailureReason(reason)}")
                }
            })
            return true
        } catch (e: Exception) {
            Log.e(TAG, "Error removing Wi-Fi Direct group", e)
            return false
        }
    }

    /**
     * Disconnect from current Wi-Fi Direct connection
     */
    @SuppressLint("MissingPermission")
    fun disconnect(): Boolean {
        if (!isInitialized || wifiP2pManager == null || channel == null) return false

        try {
            Log.d(TAG, "Disconnecting from Wi-Fi Direct...")

            val channelCopy = channel ?: return false
            wifiP2pManager?.cancelConnect(channelCopy, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    Log.d(TAG, "Connect cancelled successfully")
                }
                override fun onFailure(reason: Int) {
                    Log.d(TAG, "Failed to cancel connect: ${getFailureReason(reason)}")
                }
            })
            removeGroup()
            return true
        } catch (e: Exception) {
            Log.e(TAG, "Error disconnecting", e)
            return false
        }
    }

    /**
     * Request group info
     */
    @SuppressLint("MissingPermission")
    fun requestGroupInfo(): Map<String, Any>? {
        if (!isInitialized || wifiP2pManager == null || channel == null) return null

        try {
            Log.d(TAG, "Requesting group info...")
            val channelCopy = channel ?: return null
            wifiP2pManager?.requestGroupInfo(channelCopy) { group ->
                if (group != null) {
                    currentGroup = group
                    val groupInfo = extractGroupInfo(group)
                    methodChannel.invokeMethod("onGroupInfoAvailable", groupInfo)
                } else {
                    Log.w(TAG, "No group info available")
                }
            }
            return null
        } catch (e: Exception) {
            Log.e(TAG, "Error requesting group info", e)
            return null
        }
    }

    /**
     * Get list of discovered peers
     */
    fun getDiscoveredPeers(): List<Map<String, Any>> {
        return discoveredPeers
            .filter { it.deviceAddress != thisDeviceAddress }
            .map { device ->
                mapOf(
                    "deviceName" to (device.deviceName ?: "Unknown Device"),
                    "deviceAddress" to device.deviceAddress,
                    "status" to device.status,
                    "isGroupOwner" to (device.status == WifiP2pDevice.CONNECTED),
                    "primaryDeviceType" to (device.primaryDeviceType ?: ""),
                    "secondaryDeviceType" to (device.secondaryDeviceType ?: "")
                )
            }
    }

    fun isWifiP2pEnabled(): Boolean = isWifiP2pEnabled

    /**
     * Cleanup resources
     */
    fun cleanup() {
        try {
            stopPeerDiscovery()
            disconnect()
            deletePersistentGroups()
            
            receiver?.let {
                context.unregisterReceiver(it)
            }
            receiver = null
            
            channel = null
            wifiP2pManager = null
            isInitialized = false
            discoveredPeers.clear()
            
            Log.d(TAG, "Wi-Fi Direct manager cleaned up")
        } catch (e: Exception) {
            Log.e(TAG, "Error during cleanup", e)
        }
    }

    private fun extractGroupInfo(group: WifiP2pGroup): Map<String, Any> {
        return mapOf(
            "ssid" to (group.networkName ?: ""),
            "password" to (group.passphrase ?: ""),
            "ownerAddress" to (group.owner?.deviceAddress ?: ""),
            "isGroupOwner" to group.isGroupOwner,
            "networkId" to group.networkId,
            "interface" to (group.`interface` ?: "")
        )
    }

    private fun getFailureReason(reason: Int): String {
        return when (reason) {
            WifiP2pManager.ERROR -> "ERROR"
            WifiP2pManager.P2P_UNSUPPORTED -> "P2P_UNSUPPORTED"
            WifiP2pManager.BUSY -> "BUSY"
            else -> "UNKNOWN ($reason)"
        }
    }

    /**
     * Broadcast receiver for Wi-Fi P2P events
     */
    private inner class WiFiDirectBroadcastReceiver : BroadcastReceiver() {
        @SuppressLint("MissingPermission")
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                    val state = intent.getIntExtra(WifiP2pManager.EXTRA_WIFI_STATE, -1)
                    isWifiP2pEnabled = state == WifiP2pManager.WIFI_P2P_STATE_ENABLED
                    methodChannel.invokeMethod("onWifiP2pStateChanged", mapOf(
                        "enabled" to isWifiP2pEnabled
                    ))
                }

                WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> {
                    val channelCopy = channel ?: return
                    wifiP2pManager?.requestPeers(channelCopy) { peerList ->
                        discoveredPeers.clear()
                        discoveredPeers.addAll(peerList.deviceList)
                        methodChannel.invokeMethod("onPeersDiscovered", mapOf(
                            "peers" to getDiscoveredPeers()
                        ))
                    }
                }

                WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                    val networkInfo = intent.getParcelableExtra<NetworkInfo>(WifiP2pManager.EXTRA_NETWORK_INFO)
                    val isConnected = networkInfo?.isConnected == true
                    
                    // Deduplicate: only process if state actually changed
                    if (isConnected == lastConnectionState) {
                        Log.d(TAG, "Wi-Fi P2P connection changed (duplicate, ignoring)")
                        return
                    }
                    lastConnectionState = isConnected
                    
                    if (isConnected) {
                        Log.d(TAG, "Device connected to Wi-Fi P2P group")
                        
                        // Always process connections - the Dart side will ignore
                        // events if no one is actively listening (broadcast stream)
                        val channelCopy = channel ?: return
                        wifiP2pManager?.requestConnectionInfo(channelCopy) { info ->
                            if (info != null) {
                                val connectionInfo = mapOf(
                                    "groupFormed" to info.groupFormed,
                                    "isGroupOwner" to info.isGroupOwner,
                                    "groupOwnerAddress" to (info.groupOwnerAddress?.hostAddress ?: "")
                                )
                                methodChannel.invokeMethod("onConnectionInfoAvailable", connectionInfo)
                            }
                        }
                    } else {
                        Log.d(TAG, "Device disconnected from Wi-Fi P2P group")
                        methodChannel.invokeMethod("onGroupRemoved", null)
                    }
                }

                WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION -> {
                    val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(WifiP2pManager.EXTRA_WIFI_P2P_DEVICE, WifiP2pDevice::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(WifiP2pManager.EXTRA_WIFI_P2P_DEVICE)
                    }
                    
                    device?.let {
                        thisDeviceAddress = it.deviceAddress // Store own address
                        methodChannel.invokeMethod("onThisDeviceChanged", mapOf(
                            "deviceName" to (it.deviceName ?: "Unknown"),
                            "deviceAddress" to it.deviceAddress,
                            "status" to it.status
                        ))
                    }
                }
            }
        }
    }
}
