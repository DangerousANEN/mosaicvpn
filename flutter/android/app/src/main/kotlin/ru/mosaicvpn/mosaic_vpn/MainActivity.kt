package ru.mosaicvpn.mosaic_vpn

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "ru.mosaicvpn.mosaic_vpn/android_vpn"
        private const val VPN_PERMISSION_REQUEST = 4108
    }

    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingAuthCallback: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).setMethodCallHandler { call, result -> handleVpnCall(call, result) }
        intent?.dataString?.let { callback ->
            if (callback.startsWith("mosaicvpn://auth/callback")) {
                pendingAuthCallback = callback
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.dataString?.let { callback ->
            if (callback.startsWith("mosaicvpn://auth/callback")) {
                pendingAuthCallback = callback
            }
        }
    }

    private fun handleVpnCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepare" -> prepareVpnPermission(result)
            "start" -> {
                val config = call.argument<String>("config")
                if (config.isNullOrBlank()) {
                    result.error("invalid_config", "A non-empty sing-box configuration is required", null)
                    return
                }
                if (VpnService.prepare(this) != null) {
                    result.error("permission_required", "Android VPN permission has not been granted", null)
                    return
                }
                try {
                    MosaicVpnService.start(this, config)
                    result.success(MosaicVpnService.status())
                } catch (error: Exception) {
                    result.error("start_failed", error.message, null)
                }
            }
            "stop" -> {
                MosaicVpnService.stop(this)
                result.success(MosaicVpnService.status())
            }
            "status" -> result.success(MosaicVpnService.status())
            "consumeAuthCallback" -> {
                val callback = pendingAuthCallback
                pendingAuthCallback = null
                result.success(callback)
            }
            "validateConfig" -> {
                val config = call.argument<String>("config")
                if (config.isNullOrBlank()) {
                    result.error("invalid_config", "A non-empty sing-box configuration is required", null)
                    return
                }
                try {
                    MosaicVpnService.validate(this, config)
                    result.success(true)
                } catch (error: Exception) {
                    result.error("invalid_config", error.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun prepareVpnPermission(result: MethodChannel.Result) {
        if (VpnService.prepare(this) == null) {
            result.success(true)
            return
        }
        if (pendingPermissionResult != null) {
            result.error("permission_in_progress", "VPN permission request is already open", null)
            return
        }
        pendingPermissionResult = result
        @Suppress("DEPRECATION")
        startActivityForResult(VpnService.prepare(this), VPN_PERMISSION_REQUEST)
    }

    @Deprecated("Required for VpnService permission callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != VPN_PERMISSION_REQUEST) return
        val callback = pendingPermissionResult ?: return
        pendingPermissionResult = null
        callback.success(resultCode == Activity.RESULT_OK)
    }
}
