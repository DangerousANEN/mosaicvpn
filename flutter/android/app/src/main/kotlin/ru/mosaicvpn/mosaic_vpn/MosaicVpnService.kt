package ru.mosaicvpn.mosaic_vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.IpPrefix
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
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
        private const val TAG = "MosaicVpnService"

        private val simpleDateFormat =
            java.text.SimpleDateFormat("MM-dd HH:mm:ss.SSS", java.util.Locale.US)

        @Volatile private var runtimeState: String = "disconnected"

        /// Recent native runtime log lines with monotonic sequence numbers,
        /// newest last. The Flutter logs screen reads this because the libbox
        /// event stream is not wired on Android; without it the screen stayed
        /// empty.
        private const val NATIVE_LOG_LIMIT = 400
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
        @Volatile private var libboxReady = false

        fun status(): Map<String, String?> = mapOf(
            "state" to runtimeState,
            "error" to runtimeError,
        )

        fun start(context: Context, config: String) {
            runtimeState = "connecting"
            runtimeError = null
            val intent = Intent(context, MosaicVpnService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_CONFIG, config)
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
                logMaxLines = 500
            })
            libboxReady = true
        }
    }

    private var commandServer: CommandServer? = null
    private var tunDescriptor: ParcelFileDescriptor? = null
    private var activeConfig: String = ""
    private var shuttingDown = false

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
                        // Pin the outbound dialer to the current default network.
                        // route.auto_detect_interface relies on the platform dialer
                        // control path (ProtectFunc), which libbox only wires when
                        // its NetworkManager sees a non-nil platform interface; in
                        // this build the dialers were still looping back into tun0,
                        // so every client TCP got reset. An explicit bind_interface
                        // takes the guaranteed `options.BindInterface` branch in
                        // common/dialer and binds sockets to wlan0/rmnet directly.
                        val pinnedConfig = runCatching {
                            val cm = getSystemService(Context.CONNECTIVITY_SERVICE)
                                as android.net.ConnectivityManager
                            val active = cm.activeNetwork ?: return@runCatching config
                            val iface = cm.getLinkProperties(active)?.interfaceName
                                ?: return@runCatching config
                            Log.i(TAG, "pinning route.default_interface = $iface")
                            org.json.JSONObject(config).apply {
                                val route = optJSONObject("route") ?: put(
                                    "route", org.json.JSONObject()).let { getJSONObject("route") }
                                route.put("default_interface", iface)
                                // bind_interface and auto_detect_interface are
                                // mutually exclusive; explicit bind wins.
                                route.remove("auto_detect_interface")
                                put("route", route)
                            }.toString()
                        }.getOrDefault(config)
                        activeConfig = pinnedConfig
                        runCatching {
                            java.io.File(filesDir, "last-config.json").writeText(pinnedConfig)
                        }
                    // Android 14+ (targetSDK 34+) requires the FGS type to be
                    // declared both in the manifest AND passed explicitly to
                    // startForeground(); the one-arg overload crashes with
                    // MissingForegroundServiceTypeException on API 35/36/37
                    // even when foregroundServiceType="specialUse" is set.
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                        startForeground(
                            NOTIFICATION_ID,
                            makeNotification("Подключение…"),
                            android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                        )
                    } else {
                        startForeground(NOTIFICATION_ID, makeNotification("Подключение…"))
                    }
                    Thread({ startOrReloadRuntime(pinnedConfig) }, "MosaicVpnRuntime").start()
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
            runtimeState = "connected"
            runtimeError = null
            updateNotification("Подключено")
        } catch (error: Exception) {
            Log.e(TAG, "Unable to start sing-box runtime", error)
            appendNativeLog("error: ${error.message ?: "Unable to start VPN runtime"}")
            publishError(error.message ?: "Unable to start VPN runtime")
            stopRuntime(preserveError = true)
        }
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
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setContentTitle("MosaicVPN")
            .setContentText(detail)
            .setContentIntent(openIntent)
            .addAction(Notification.Action.Builder(null, "Отключить", stopIntent).build())
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(detail: String) {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, makeNotification(detail))
    }

    private fun publishError(message: String) {
        runtimeState = "error"
        runtimeError = message
        Log.e(TAG, message)
        updateNotification("Ошибка подключения")
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
        Log.i(TAG, message)
        try {
            java.io.File(filesDir, "singbox.log")
                .appendText(simpleDateFormat.format(java.util.Date()) + " " + message + "\n")
        } catch (_: Exception) {}
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

        val descriptor = builder.establish()
            ?: error("Android failed to establish MosaicVPN TUN interface")
        appendNativeLog(
            "tun: established (mtu=${options.mtu}, " +
                "autoRoute=${options.autoRoute})"
        )
        try {
            tunDescriptor?.close()
        } catch (_: Exception) {
        }
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

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager
            ?: return
        val callback = object : android.net.ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: android.net.Network) {
                notifyDefault(listener, cm, network)
            }

            override fun onLinkPropertiesChanged(
                network: android.net.Network,
                linkProperties: android.net.LinkProperties,
            ) {
                notifyDefault(listener, cm, network)
            }

            override fun onCapabilitiesChanged(
                network: android.net.Network,
                networkCapabilities: android.net.NetworkCapabilities,
            ) {
                notifyDefault(listener, cm, network)
            }
        }
        networkCallback = callback
        try {
            cm.registerNetworkCallback(
                android.net.NetworkRequest.Builder()
                    .addCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .build(),
                callback,
            )
        } catch (error: Exception) {
            Log.w(TAG, "Failed to register default interface monitor", error)
        }
    }

    private fun notifyDefault(
        listener: InterfaceUpdateListener,
        cm: android.net.ConnectivityManager,
        network: android.net.Network,
    ) {
        try {
            val props = cm.getLinkProperties(network) ?: return
            val iface = props.interfaceName ?: return
            val index = java.net.NetworkInterface.getByName(iface)?.index ?: return
            Log.i(TAG, "default interface update: $iface (idx=$index)")
            listener.updateDefaultInterface(iface, index, false, false)
        } catch (error: Exception) {
            Log.w(TAG, "Failed to resolve default interface", error)
        }
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        val callback = networkCallback ?: return
        networkCallback = null
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager
            ?: return
        runCatching { cm.unregisterNetworkCallback(callback) }
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
                    flags = 0
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
