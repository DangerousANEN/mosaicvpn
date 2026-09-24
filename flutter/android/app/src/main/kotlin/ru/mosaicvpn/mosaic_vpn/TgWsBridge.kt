package ru.mosaicvpn.mosaic_vpn

import android.util.Log
import tgws.Proxy
import java.util.concurrent.atomic.AtomicReference

/**
 * Telegram resilience layer: runs the embedded tg-ws-proxy engine (MIT,
 * github.com/d0mhate/-tg-ws-proxy-Manager-go) as a local SOCKS5 server that
 * carries Telegram DC traffic over WebSocket+TLS to kws*.web.telegram.org
 * (Telegram domains behind Cloudflare). Works both while the VPN tunnel is
 * up (as a split-tunnel route for Telegram DC ranges) and standalone.
 */
object TgWsBridge {
    private const val TAG = "TgWsBridge"

    private val proxyRef = AtomicReference<Proxy?>(null)

    /** Engine port, or 0 when the engine is not running. */
    @Volatile
    var port: Int = 0
        private set

    fun start() {
        if (proxyRef.get() != null) return
        synchronized(this) {
            if (proxyRef.get() != null) return
            try {
                val proxy = Proxy()
                proxy.start()
                proxyRef.set(proxy)
                port = proxy.port()
                Log.i(TAG, "tg-ws-proxy engine listening on 127.0.0.1:$port")
            } catch (e: Exception) {
                Log.e(TAG, "tg-ws-proxy engine failed to start", e)
                port = 0
            }
        }
    }

    fun stop() {
        val proxy = proxyRef.getAndSet(null) ?: return
        try {
            proxy.stop()
        } catch (e: Exception) {
            Log.w(TAG, "tg-ws-proxy engine stop error", e)
        }
        port = 0
    }

    fun running(): Boolean = proxyRef.get()?.running() ?: false
}
