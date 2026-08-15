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

        @Volatile private var runtimeState: String = "disconnected"
        @Volatile private var runtimeError: String? = null
        @Volatile private var libboxReady = false

        fun status(): Map<String, String?> = mapOf(
            "state" to runtimeState,
            "error" to runtimeError,
        )

        fun start(context: Context, config: String) {
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
            context.startService(
                Intent(context, MosaicVpnService::class.java).setAction(ACTION_STOP),
            )
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
                    startForeground(NOTIFICATION_ID, makeNotification("Подключение…"))
                    Thread({ startOrReloadRuntime(config) }, "MosaicVpnRuntime").start()
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
                autoRedirect = true
            })
            runtimeState = "connected"
            runtimeError = null
            updateNotification("Подключено")
        } catch (error: Exception) {
            Log.e(TAG, "Unable to start sing-box runtime", error)
            publishError(error.message ?: "Unable to start VPN runtime")
            stopRuntime()
        }
    }

    private fun stopRuntime(releaseService: Boolean = true) {
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
            runtimeState = "disconnected"
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
        Log.d(TAG, message)
    }

    // --- libbox PlatformInterface ----------------------------------------

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {
        protect(fd)
    }

    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) {
            error("Android VPN permission has not been granted")
        }
        val builder = Builder()
            .setSession("MosaicVPN")
            .setMtu(options.mtu.coerceIn(1280, 9000))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)
        builder.allowBypass()

        addAddresses(builder, options.inet4Address)
        addAddresses(builder, options.inet6Address)
        if (options.autoRoute) {
            addRoutes(builder, options.inet4RouteAddress)
            addRoutes(builder, options.inet6RouteAddress)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                addExcludedRoutes(builder, options.inet4RouteExcludeAddress)
                addExcludedRoutes(builder, options.inet6RouteExcludeAddress)
            }
            addApplications(builder, options)
        }

        val descriptor = builder.establish()
            ?: error("Android failed to establish MosaicVPN TUN interface")
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

    private fun addRoutes(builder: Builder, routes: io.nekohasekai.libbox.RoutePrefixIterator) {
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

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) = Unit

    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): ConnectionOwner {
        throw UnsupportedOperationException("Connection owner lookup is unavailable")
    }

    override fun getInterfaces(): NetworkInterfaceIterator = EmptyNetworkIterator

    override fun includeAllNetworks(): Boolean = false

    override fun localDNSTransport(): LocalDNSTransport? = null

    override fun readWIFIState(): WIFIState? = null

    override fun sendNotification(notification: LibboxNotification) {
        val text = notification.body.ifBlank { notification.title }
        if (text.isNotBlank()) updateNotification(text)
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) = Unit

    override fun systemCertificates(): StringIterator = EmptyStringIterator

    override fun underNetworkExtension(): Boolean = false

    override fun useProcFS(): Boolean = false

    private object EmptyStringIterator : StringIterator {
        override fun hasNext(): Boolean = false
        override fun len(): Int = 0
        override fun next(): String = throw NoSuchElementException()
    }

    private object EmptyNetworkIterator : NetworkInterfaceIterator {
        override fun hasNext(): Boolean = false
        override fun next(): NetworkInterface = throw NoSuchElementException()
    }
}
