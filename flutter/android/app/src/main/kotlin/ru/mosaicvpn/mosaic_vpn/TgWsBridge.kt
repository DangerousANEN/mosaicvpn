package ru.mosaicvpn.mosaic_vpn

import android.content.Context
import android.util.Log
import java.io.File

/**
 * Telegram resilience layer: runs the tg-ws-proxy engine (MIT,
 * github.com/d0mhate/-tg-ws-proxy-Manager-go) as a separate native process.
 *
 * The engine is a plain Go binary shipped in jniLibs (executable, like
 * libbox.so). Running it out-of-process avoids the two-gomobile-runtimes
 * clash: the app already embeds libgojni.so from sing-box, so a second
 * gomobile AAR can never coexist in the same classloader. A subprocess also
 * means an engine crash can never take the app down.
 *
 * Lifecycle: start() spawns `libtgws.so -mode socks -port <free> -host
 * 127.0.0.1`; the engine prints `LISTENING 127.0.0.1:<port>` on stdout and
 * we parse it. stop() destroys the process.
 */
object TgWsBridge {
    private const val TAG = "TgWsBridge"
    private const val ENGINE_LIB = "libtgws.so"

    @Volatile var port: Int = 0
        private set
    @Volatile var running: Boolean = false
        private set

    private var process: Process? = null
    private var deathWatch: Thread? = null

    fun engineBinary(context: Context): File {
        return File(context.applicationInfo.nativeLibraryDir, ENGINE_LIB)
    }

    @Synchronized
    fun start(context: Context): Int {
        if (process != null && process!!.isAlive) return port
        val bin = engineBinary(context)
        if (!bin.exists() || !bin.canExecute()) {
            Log.e(TAG, "engine binary missing: ${bin.absolutePath}")
            throw IllegalStateException("tgws engine binary missing")
        }
        val p = ProcessBuilder(bin.absolutePath, "-mode", "socks", "-host", "127.0.0.1", "-port", "0")
            .redirectErrorStream(true)
            .start()
        process = p
        running = true

        // Read stdout for the LISTENING line (engine picks a free port when
        // -port 0). Fall back to a bounded wait if stdout is quiet.
        val stdout = p.inputStream.bufferedReader()
        deathWatch = Thread {
            try {
                while (true) {
                    val line = stdout.readLine() ?: break
                    if (line.startsWith("LISTENING ")) {
                        val addr = line.removePrefix("LISTENING ").trim()
                        port = addr.substringAfterLast(':').toIntOrNull() ?: 0
                        Log.i(TAG, "tg-ws-proxy engine listening on $addr")
                    } else {
                        Log.d(TAG, "engine: ${line.take(300)}")
                    }
                }
            } catch (e: Exception) {
                Log.d(TAG, "engine stdout closed", e)
            } finally {
                running = false
                Log.w(TAG, "tg-ws-proxy engine exited (port=$port)")
            }
        }.apply { isDaemon = true; start() }
        return port
    }

    @Synchronized
    fun stop() {
        val p = process ?: return
        process = null
        running = false
        port = 0
        try {
            p.destroy()
            // SIGTERM grace, then SIGKILL.
            val w = Thread { try { p.waitFor() } catch (_: InterruptedException) {} }
            w.start(); w.join(1500)
            if (p.isAlive) p.destroyForcibly()
        } catch (e: Exception) {
            Log.w(TAG, "engine stop error", e)
        }
    }

    fun status(): Map<String, Any> = mapOf(
        "running" to running,
        "port" to port
    )
}
