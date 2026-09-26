package ru.mosaicvpn.mosaic_vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.IpPrefix
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.service.quicksettings.TileService
import android.util.Log
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.NetworkInterface
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.Notification as LibboxNotification
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.io.File
import java.net.InetAddress
import java.util.Locale

/**
 * Android system VPN integration backed by the GPLv3 sing-box/libbox runtime.
 *
 * Flutter only supplies a validated sing-box JSON configuration. This service
 * owns the privileged Android VpnService permission, TUN file descriptor and
 * foreground lifecycle; no tunnel traffic passes through a mock Flutter layer.
 */
class MosaicVpnService : VpnService(), PlatformInterface, CommandServerHandler {
    companion object {
        const val CHANNEL = "mosaicvpn.tunnel"
        const val NOTIFICATION_ID = 4107
        const val ACTION_START = "ru.mosaicvpn.mosaic_vpn.action.START"
        const val ACTION_STOP = "ru.mosaicvpn.mosaic_vpn.action.STOP"
        const val EXTRA_CONFIG = "singbox_config"
        const val EXTRA_ROUTE_TITLE = "route_title"
        private const val TAG = "MosaicVpnService"

        private val simpleDateFormat =
            java.text.SimpleDateFormat("MM-dd HH:mm:ss.SSS", java.util.Locale.US)

        @Volatile private var runtimeState: String = "disconnected"
        @Volatile var currentRouteTitle: String = ""
            private set

        /// Recent native runtime log lines with monotonic sequence numbers,
        /// newest last. The Flutter logs screen reads this because the libbox
        /// event stream is not wired on Android; without it the screen stayed
        /// empty.
        private const val NATIVE_LOG_LIMIT = 1500
        private val recentLogs = ArrayDeque<Pair<Long, String>>()
        private val logSeqCounter = java.util.concurrent.atomic.AtomicLong(0)

        fun appendNativeLog(line: String) {
            synchronized(recentLogs) {
                recentLogs.addLast(logSeqCounter.incrementAndGet() to line)
                while (recentLogs.size > NATIVE_LOG_LIMIT) recentLogs.removeFirst()
            }
        }

        fun snapshotNativeLogs(afterSeq: Long): List<Map<String, Any?>> =
            synchronized(recentLogs) {
                recentLogs.filter { it.first > afterSeq }
                    .map { mapOf("seq" to it.first, "line" to it.second) }
            }

        /// Blocks until the runtime reports a terminal state or times out.
        private fun stopLatch(context: Context) {
            val deadline = System.currentTimeMillis() + 4_000
            while (System.currentTimeMillis() < deadline) {
                val state = runtimeState
                if (state == "disconnected" || state == "error") return
                Thread.sleep(60)
            }
        }

        @Volatile private var runtimeError: String? = null
        @Volatile private var verifySession: Int = 0
        @Volatile private var libboxReady = false
        private val networkPolicy = UnderlyingNetworkPolicy()
        @Volatile private var activeNetworkFingerprint: String = networkPolicy.currentFingerprint()

        fun status(): Map<String, String?> = mapOf(
            "state" to runtimeState,
            "error" to runtimeError,
            "network_fingerprint" to activeNetworkFingerprint,
        )

        fun start(context: Context, config: String, routeTitle: String = "") {
            runtimeState = "connecting"
            runtimeError = null
            if (routeTitle.isNotBlank()) {
                currentRouteTitle = routeTitle
            }
            val intent = Intent(context, MosaicVpnService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_CONFIG, config)
                .putExtra(EXTRA_ROUTE_TITLE, routeTitle)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            // Mark the state down immediately so Flutter/tray controls cannot
            // remain stuck on Connected while native cleanup finishes.
            if (runtimeState == "disconnected") return
            runtimeState = "disconnected"
            runtimeError = null
            currentRouteTitle = ""
            val intent = Intent(context, MosaicVpnService::class.java)
                .setAction(ACTION_STOP)
            runCatching { context.startService(intent) }
                .onFailure {
                    Log.w(TAG, "Unable to deliver stop intent", it)
                    context.stopService(Intent(context, MosaicVpnService::class.java))
                }
        }

        fun validate(context: Context, config: String) {
            ensureLibbox(context)
            Libbox.checkConfig(config)
        }

        @Synchronized
        private fun ensureLibbox(context: Context) {
            if (libboxReady) return
            val base = File(context.filesDir, "mosaic-libbox").apply { mkdirs() }
            val working = File(base, "working").apply { mkdirs() }
            val temporary = File(context.cacheDir, "mosaic-libbox").apply { mkdirs() }
            Libbox.setLocale(Locale.getDefault().toLanguageTag())
            Libbox.setup(SetupOptions().apply {
                basePath = base.absolutePath
                workingPath = working.absolutePath
                tempPath = temporary.absolutePath
                fixAndroidStack = true
                debug = false
                logMaxLines = 300
            })
            libboxReady = true
        }
    }

    private var commandServer: CommandServer? = null
    private var tunDescriptor: ParcelFileDescriptor? = null
    private var activeConfig: String = ""
    private var shuttingDown = false
    private val runtimeExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> stopRuntime()
            ACTION_START -> {
                val config = intent.getStringExtra(EXTRA_CONFIG).orEmpty()
                if (config.isBlank()) {
                    publishError("VPN configuration is empty")
                    stopRuntime()
                } else {
                        activeConfig = config
                        runtimeState = "connecting"
                        runtimeError = null
                        appendNativeLog("start: accepted config (${config.length} bytes)")
                        // Android VPN relies on VpnService.protect(fd) to keep
                        // outbound sockets off the TUN adapter. libbox calls
                        // PlatformInterface.autoDetectInterfaceControl(fd) which
                        // invokes protect(fd). This ONLY works when the config
                        // sets auto_detect_interface=true.
                        // route.default_interface and route.default_mark are not supported
                        // on Android in sing-box and force bind(SO_BINDTODEVICE) which loops
                        // packets back into tun0. Sanitize unconditionally to keep protect(fd)
                        // active and prevent interface pinning across network handover.
                        runCatching {
                            val cm = getSystemService(Context.CONNECTIVITY_SERVICE)
                                as android.net.ConnectivityManager
                            val active = cm.activeNetwork
                            val iface = active?.let { cm.getLinkProperties(it)?.interfaceName }
                            if (iface != null) {
                                Log.i(TAG, "initial default physical interface = $iface (auto_detect_interface stays enabled)")
                            }
                        }
                        val sanitizedConfig = runCatching {
                            org.json.JSONObject(config).apply {
                                val route = optJSONObject("route") ?: put(
                                    "route", org.json.JSONObject()).let { getJSONObject("route") }
                                route.put("auto_detect_interface", true)
                                route.remove("default_interface")
                                route.remove("default_mark")
                                put("route", route)
                            }.toString()
                        }.getOrDefault(config)
                        activeConfig = sanitizedConfig
                        runCatching {
                            java.io.File(filesDir, "last-config.json").writeText(sanitizedConfig)
                        }
                    // Android 14+ (targetSDK 34+) requires the FGS type to be
                    // declared both in the manifest AND passed explicitly to
                    // startForeground(); the one-arg overload crashes with
                    // MissingForegroundServiceTypeException on API 35/36/37
                    // even when foregroundServiceType="specialUse" is set.
                    // Using literal constant 0x40000000 prevents NoSuchFieldError
                    // on devices with Android < 14.
                    if (Build.VERSION.SDK_INT >= 34) {
                        startForeground(
                            NOTIFICATION_ID,
                            makeNotification("Подключение…"),
                            0x40000000,
                        )
                    } else {
                        startForeground(NOTIFICATION_ID, makeNotification("Подключение…"))
                    }
                    runtimeExecutor.execute { startOrReloadRuntime(sanitizedConfig) }
                }
            }
        }
        return Service.START_NOT_STICKY
    }

    override fun onBind(intent: Intent): IBinder? {
        return super.onBind(intent)
    }

    override fun onDestroy() {
        stopRuntime(releaseService = false)
        super.onDestroy()
    }

    override fun onRevoke() {
        runtimeError = "VPN permission was revoked"
        stopRuntime()
    }

    private fun startOrReloadRuntime(config: String) {
        try {
            ensureLibbox(this)
            Libbox.checkConfig(config)
            val server = commandServer ?: Libbox.newCommandServer(this, this).also {
                it.start()
                commandServer = it
            }
            server.startOrReloadService(config, OverrideOptions().apply {
                // NOTE: autoRedirect must stay disabled on Android. It installs
                // iptables/nftables rules and demands root (`/system/bin/su`),
                // which unprivileged devices report as
                // "root permission is required for auto redirect". The VpnService
                // TUN with auto_route already captures all device traffic.
                autoRedirect = false
            })
            appendNativeLog("runtime: sing-box service started")
        // TUN is up but has not carried a byte yet. Report "verifying" (a
        // non-terminal, busy state) instead of blocking the caller: the UI
        // shows "Проверка связи…" while the async verifier below proves real
        // egress. This is the Exclave/SagerNet model — the tunnel comes up
        // instantly and connectivity is proven in the background — so a slow
        // or dead candidate never stalls the button.
            runtimeState = "verifying"
            runtimeError = null
            updateNotification("Проверка связи…")
            verifyTunnelEgress()
        } catch (error: Exception) {
            Log.e(TAG, "Unable to start sing-box runtime", error)
            appendNativeLog("error: ${error.message ?: "Unable to start VPN runtime"}")
            publishError(error.message ?: "Unable to start VPN runtime")
            stopRuntime(preserveError = true)
        }
    }

    /// Proves the tunnel carries real traffic before declaring "connected".
    /// Retries with settling delays (TUN needs ~600ms before first probe),
    /// then flips runtimeState to "connected" or publishes an honest error.
    private fun verifyTunnelEgress() {
        // A stale verifier from a previous start/reload must never flip the
        // NEW session's state. Token the session so only the current attempt
        // can transition to connected/error.
        val session = ++verifySession
        val verifier = Thread {
            val probeUrl = "http://1.1.1.1/generate_204"
            var attempt = 0
            val delaysMs = longArrayOf(600, 800, 1200, 2000, 3000, 5000)
            while (attempt < delaysMs.size) {
                // Bail out if the user cancelled or a new session started.
                if (session != verifySession || runtimeState == "disconnected") return@Thread
                try {
                    Thread.sleep(delaysMs[attempt])
                } catch (_: InterruptedException) {
                    return@Thread
                }
                if (session != verifySession || runtimeState == "disconnected") return@Thread
                try {
                    val url = java.net.URL(probeUrl)
                    val conn = url.openConnection() as java.net.HttpURLConnection
                    conn.connectTimeout = 4000
                    conn.readTimeout = 4000
                    // Default HttpURLConnection uses the system routing,
                    // which the TUN has already captured (auto_route).
                    val code = conn.responseCode
                    conn.disconnect()
                    if (code in 200..399 || code == 204) {
                        runtimeState = "connected"
                        runtimeError = null
                        appendNativeLog("egress verified: HTTP $code via tunnel")
                        updateNotification("Подключено")
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                            try {
                                TileService.requestListeningState(
                                    this,
                                    ComponentName(this, MosaicVpnTileService::class.java)
                                )
                            } catch (_: Exception) {}
                        }
                        return@Thread
                    }
                    appendNativeLog("egress probe: unexpected HTTP $code, retrying")
                } catch (error: Exception) {
                    appendNativeLog("egress probe failed (${error.javaClass.simpleName}), retrying")
                }
                attempt++
            }
            // All probes failed: the tunnel is up but carries no traffic.
            publishError("Туннель поднят, но трафик не проходит. Попробуйте другой маршрут.")
        }
        verifier.isDaemon = true
        verifier.name = "mosaic-egress-verify"
        verifier.start()
    }

    private fun stopRuntime(releaseService: Boolean = true, preserveError: Boolean = false) {
        if (shuttingDown) return
        shuttingDown = true
        try {
            commandServer?.closeService()
            commandServer?.close()
        } catch (error: Exception) {
            Log.w(TAG, "Unable to close sing-box service cleanly", error)
        } finally {
            commandServer = null
            try {
                tunDescriptor?.close()
            } catch (_: Exception) {
            }
            tunDescriptor = null
            if (!preserveError) {
                runtimeState = "disconnected"
                runtimeError = null
            }
            stopForeground(STOP_FOREGROUND_REMOVE)
            if (releaseService) stopSelf()
            shuttingDown = false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                try {
                    TileService.requestListeningState(
                        this,
                        ComponentName(this, MosaicVpnTileService::class.java)
                    )
                } catch (_: Exception) {}
            }
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL,
                    "MosaicVPN connection",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Shows the active MosaicVPN secure connection"
                    setShowBadge(false)
                },
            )
        }
    }

    private fun makeNotification(detail: String): Notification {
        createNotificationChannel()
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, MosaicVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val title = if (currentRouteTitle.isNotBlank()) "MosaicVPN • $currentRouteTitle" else "MosaicVPN"
        val builder = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setContentTitle(title)
            .setContentText(detail)
            .setContentIntent(openIntent)
            .addAction(Notification.Action.Builder(null, "Отключить", stopIntent).build())
            .setOngoing(true)
        return builder.build()
    }

    private fun updateNotification(detail: String) {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, makeNotification(detail))
    }

    private fun publishError(message: String) {
        runtimeState = "error"
        runtimeError = message
        Log.e(TAG, message)
        // An error state must not keep the VpnService interface up: Android
        // shows the key icon in the status bar the moment Builder.establish()
        // returns, so leaving the TUN alive here keeps "VPN включен" in the
        // system UI while the app reports the route as failed. Tear the
        // runtime down (stopping the core + interface + notification) while
        // preserving the error for the UI to surface.
        stopRuntime(preserveError = true)
    }

    // --- libbox CommandServerHandler -------------------------------------

    override fun serviceStop() {
        appendNativeLog("runtime: stop requested")
        stopRuntime()
    }

    override fun serviceReload() {
        if (activeConfig.isNotBlank()) {
            Thread({ startOrReloadRuntime(activeConfig) }, "MosaicVpnReload").start()
        }
    }

    override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus().apply {
        available = false
        enabled = false
    }

    override fun setSystemProxyEnabled(isEnabled: Boolean) = Unit

    override fun writeDebugMessage(message: String) {
        appendNativeLog(message)
        // Avoid synchronous disk I/O on every routine debug message to prevent battery drain.
        // Only persist error/fatal messages to disk for post-mortem diagnostics.
        val lower = message.lowercase(java.util.Locale.US)
        if (lower.contains("error") || lower.contains("fatal") || lower.contains("panic")) {
            Log.e(TAG, "SINGBOX_ERR: $message")
            try {
                java.io.File(filesDir, "singbox.log")
                    .appendText(simpleDateFormat.format(java.util.Date()) + " " + message + "\n")
            } catch (_: Exception) {}
        }
    }

    // --- libbox PlatformInterface ----------------------------------------

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {
        Log.i(TAG, "protect(fd=$fd) requested by libbox")
        val ok = protect(fd)
        Log.i(TAG, "protect(fd=$fd) -> $ok")
    }

    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) {
            error("Android VPN permission has not been granted")
        }
        val builder = Builder()
            .setSession("MosaicVPN")
            .setMtu(options.mtu.coerceIn(1280, 9000))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)
        // NOTE: allowBypass() intentionally omitted. It lets apps escape the
        // tunnel by binding to a concrete network, which surfaced as "IP did
        // not change" reports while the UI showed a connected state.

        addAddresses(builder, options.inet4Address)
        addAddresses(builder, options.inet6Address)
        if (options.autoRoute) {
            // libbox leaves inet4/6RouteAddress empty when the sing-box config
            // relies on auto_route defaults. Upstream sing-box-for-android falls
            // back to a default route in that case; without it the VPN interface
            // is established with Routes: [] and ALL app traffic bypasses the
            // tunnel while the UI still reports "Connected" (the "IP did not
            // change" bug). Mirror upstream: explicit prefixes first, then the
            // 0.0.0.0/0 + ::/0 fallback, then route ranges, then exclusions.
            var addedInet4 = addRoutes(builder, options.inet4RouteAddress)
            if (!addedInet4) {
                builder.addRoute("0.0.0.0", 0)
            }
            var addedInet6 = addRoutes(builder, options.inet6RouteAddress)
            if (!addedInet6) {
                builder.addRoute("::", 0)
            }
            addRouteRanges(builder, options.inet4RouteRange)
            addRouteRanges(builder, options.inet6RouteRange)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                addExcludedRoutes(builder, options.inet4RouteExcludeAddress)
                addExcludedRoutes(builder, options.inet6RouteExcludeAddress)
            }
            addApplications(builder, options)
        }

        try {
            tunDescriptor?.close()
        } catch (_: Exception) {
        }
        tunDescriptor = null
        val descriptor = builder.establish()
            ?: error("Android failed to establish MosaicVPN TUN interface")
        appendNativeLog(
            "tun: established (mtu=${options.mtu}, " +
                "autoRoute=${options.autoRoute})"
        )
        tunDescriptor = descriptor
        return descriptor.fd
    }

    private fun addAddresses(builder: Builder, routes: io.nekohasekai.libbox.RoutePrefixIterator) {
        while (routes.hasNext()) {
            val route = routes.next()
            builder.addAddress(route.address(), route.prefix())
        }
    }

    private fun addRoutes(builder: Builder, routes: io.nekohasekai.libbox.RoutePrefixIterator): Boolean {
        var added = false
        while (routes.hasNext()) {
            val route = routes.next()
            builder.addRoute(route.address(), route.prefix())
            added = true
        }
        return added
    }

    private fun addRouteRanges(builder: Builder, routes: io.nekohasekai.libbox.RoutePrefixIterator) {
        while (routes.hasNext()) {
            val route = routes.next()
            builder.addRoute(route.address(), route.prefix())
        }
    }

    private fun addExcludedRoutes(builder: Builder, routes: io.nekohasekai.libbox.RoutePrefixIterator) {
        while (routes.hasNext()) {
            val route = routes.next()
            builder.excludeRoute(IpPrefix(InetAddress.getByName(route.address()), route.prefix()))
        }
    }

    private fun addApplications(builder: Builder, options: TunOptions) {
        val include = options.includePackage
        while (include.hasNext()) {
            runCatching { builder.addAllowedApplication(include.next()) }
                .onFailure { Log.w(TAG, "Ignoring missing included package", it) }
        }
        val exclude = options.excludePackage
        while (exclude.hasNext()) {
            runCatching { builder.addDisallowedApplication(exclude.next()) }
                .onFailure { Log.w(TAG, "Ignoring missing excluded package", it) }
        }
    }

    override fun clearDNSCache() = Unit

    // libbox relies on the platform interface to learn the current default
    // network. With a no-op monitor (previous behaviour) sing-box never
    // received UpdateDefaultInterface, considered the default interface
    // unknown and silently dropped every outbound connection: the tunnel came
    // up, ping was answered by the TUN stack itself, but no TCP ever reached
    // the VLESS server ("connected" UI + ERR_CONNECTION_RESET in browsers).
    // Mirror upstream SFA: watch ConnectivityManager and forward each change
    // with the interface name/index of the first non-loopback address.
    private var networkCallback: android.net.ConnectivityManager.NetworkCallback? = null
    private var interfaceListener: InterfaceUpdateListener? = null

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        closeDefaultInterfaceMonitor(listener)
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager
            ?: return
        interfaceListener = listener
        val callback = object : android.net.ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: android.net.Network) = refresh()
            override fun onLinkPropertiesChanged(network: android.net.Network, props: android.net.LinkProperties) = refresh()
            override fun onCapabilitiesChanged(network: android.net.Network, caps: android.net.NetworkCapabilities) = refresh()
            override fun onLost(network: android.net.Network) = refresh(network)
            private fun refresh(lost: android.net.Network? = null) {
                synchronized(this@MosaicVpnService) {
                    if (networkCallback !== this || interfaceListener !== listener) return
                    refreshUnderlyingNetworks(listener, cm, lost)
                }
            }
        }
        networkCallback = callback
        try {
            cm.registerNetworkCallback(
                android.net.NetworkRequest.Builder()
                    .addCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .addCapability(android.net.NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                    .build(), callback)
            synchronized(this) { refreshUnderlyingNetworks(listener, cm, null) }
        } catch (error: Exception) {
            appendNativeLog("network monitor registration failed: ${error.javaClass.simpleName}")
            throw error
        }
    }

    private fun refreshUnderlyingNetworks(
        listener: InterfaceUpdateListener,
        cm: android.net.ConnectivityManager,
        lost: android.net.Network?,
    ) {
        val networks = cm.allNetworks.filter { it != lost }
        val records = networks.mapNotNull { network ->
            runCatching {
                val caps = cm.getNetworkCapabilities(network) ?: return@runCatching null
                val props = cm.getLinkProperties(network) ?: return@runCatching null
                val iface = props.interfaceName ?: return@runCatching null
                val index = java.net.NetworkInterface.getByName(iface)?.index ?: return@runCatching null
                UnderlyingNetworkPolicy.NetworkRecord(
                    networkKey = network.networkHandle, interfaceName = iface, interfaceIndex = index,
                    isWifi = caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI),
                    isCellular = caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR),
                    isEthernet = caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET),
                    isVpn = caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN),
                    hasInternet = caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET),
                    isMetered = !caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
                    isValidated = caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED),
                    isActiveDefault = network == cm.activeNetwork,
                )
            }.getOrNull()
        }
        // Apply one atomic snapshot: callback arrival order cannot cause transient switches.
        when (val action = networkPolicy.updateSnapshot(records)) {
            is UnderlyingNetworkPolicy.PolicyAction.Select -> {
                val network = networks.firstOrNull { it.networkHandle == action.record.networkKey }
                setUnderlyingNetworks(network?.let { arrayOf(it) } ?: emptyArray())
                activeNetworkFingerprint = action.fingerprint
                listener.updateDefaultInterface(action.record.interfaceName, action.record.interfaceIndex,
                    action.record.isMetered, action.record.isConstrained)
                appendNativeLog("underlying network changed; generation=${action.fingerprint.substringAfter(':')}")
            }
            is UnderlyingNetworkPolicy.PolicyAction.Lost -> {
                setUnderlyingNetworks(emptyArray())
                activeNetworkFingerprint = action.fingerprint
                listener.updateDefaultInterface("", -1, false, false)
                appendNativeLog("underlying network unavailable")
            }
            UnderlyingNetworkPolicy.PolicyAction.NoChange -> Unit
        }
    }

    @Synchronized
    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        interfaceListener = null
        val callback = networkCallback
        networkCallback = null
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager
        if (callback != null && cm != null) runCatching { cm.unregisterNetworkCallback(callback) }
        networkPolicy.reset()
        activeNetworkFingerprint = networkPolicy.currentFingerprint()
    }

    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): ConnectionOwner {
        throw UnsupportedOperationException("Connection owner lookup is unavailable")
    }

    // libbox calls this on every reconnect to enumerate usable networks. With
    // the previous EmptyNetworkIterator stub UpdateInterfaces() produced an
    // empty interface table, so InterfaceFinder.ByIndex(wlan0=16) failed and
    // defaultInterface stayed nil — every outbound dial returned ErrNoRoute
    // (instant RST for clients, "connected" UI, zero traffic). Mirror SFA:
    // report each network with INTERNET capability from ConnectivityManager.
    override fun getInterfaces(): NetworkInterfaceIterator {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager
            ?: return EmptyNetworkIterator
        val result = mutableListOf<NetworkInterface>()
        for (network in cm.allNetworks) {
            try {
                val caps = cm.getNetworkCapabilities(network) ?: continue
                if (!caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue
                val props = cm.getLinkProperties(network) ?: continue
                val iface = props.interfaceName ?: continue
                val jni = java.net.NetworkInterface.getByName(iface) ?: continue
                val entry = NetworkInterface().apply {
                    index = jni.index
                    mtu = jni.mtu
                    name = iface
                    val addrList = buildList {
                        // Go side parses every entry with netip.MustParsePrefix,
                        // which panics (SIGABRT inside libbox.so) on a bare IP.
                        // Emit CIDR notation: interface addresses already carry
                        // the prefix length; DNS servers get /32 or /128.
                        for (ua in jni.interfaceAddresses) {
                            // hostAddress of a link-local IPv6 carries an
                            // interface zone suffix ("fe80::1%wlan0"); Go's
                            // netip.ParsePrefix rejects zones and panics.
                            val ip = (ua.address.hostAddress ?: continue)
                                .substringBefore('%')
                            add("$ip/${ua.networkPrefixLength}")
                        }
                        for (dns in props.dnsServers) {
                            val dnsIp = dns.hostAddress ?: continue
                            add(if (dnsIp.contains(':')) "$dnsIp/128" else "$dnsIp/32")
                        }
                    }
                    addresses = SimpleStringIterator(addrList)
                    var rawFlags = 0
                    if (jni.isUp) rawFlags = rawFlags or 1 // IFF_UP
                    if (jni.isLoopback) rawFlags = rawFlags or 8 // IFF_LOOPBACK
                    if (jni.isPointToPoint) rawFlags = rawFlags or 16 // IFF_POINTOPOINT
                    if (jni.supportsMulticast()) rawFlags = rawFlags or 0x1000 // IFF_MULTICAST
                    rawFlags = rawFlags or 0x40 // IFF_RUNNING
                    flags = rawFlags
                    type = when {
                        caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) -> 1
                        caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR) -> 2
                        else -> 0
                    }
                    dnsServer = SimpleStringIterator(props.dnsServers.mapNotNull { it.hostAddress })
                    metered = !caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
                }
                result.add(entry)
            } catch (error: Exception) {
                Log.w(TAG, "getInterfaces: skip $network", error)
            }
        }
        Log.i(TAG, "getInterfaces: ${result.size} networks reported")
        if (result.isEmpty()) return EmptyNetworkIterator
        return object : NetworkInterfaceIterator {
            private val it = result.iterator()
            override fun hasNext(): Boolean = it.hasNext()
            override fun next(): NetworkInterface = it.next()
        }
    }

    override fun includeAllNetworks(): Boolean = false

    override fun localDNSTransport(): LocalDNSTransport? = null

    override fun readWIFIState(): WIFIState? = null

    override fun sendNotification(notification: LibboxNotification) {
        val text = notification.body.ifBlank { notification.title }
        if (text.isNotBlank()) updateNotification(text)
    }

    override fun systemCertificates(): StringIterator = EmptyStringIterator

    override fun underNetworkExtension(): Boolean = false

    override fun useProcFS(): Boolean = false

    private object EmptyStringIterator : StringIterator {
        override fun hasNext(): Boolean = false
        override fun len(): Int = 0
        override fun next(): String = throw NoSuchElementException()
    }

    private class SimpleStringIterator(
        private val items: List<String>,
    ) : StringIterator {
        private val iterator = items.iterator()
        override fun hasNext(): Boolean = iterator.hasNext()
        override fun len(): Int = items.size
        override fun next(): String = iterator.next()
    }

    private object EmptyNetworkIterator : NetworkInterfaceIterator {
        override fun hasNext(): Boolean = false
        override fun next(): NetworkInterface = throw NoSuchElementException()
    }
}
