package ru.mosaicvpn.mosaic_vpn

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log
import androidx.annotation.RequiresApi

@RequiresApi(Build.VERSION_CODES.N)
class MosaicVpnTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        updateTileState()
    }

    override fun onTileAdded() {
        super.onTileAdded()
        updateTileState()
    }

    override fun onClick() {
        super.onClick()
        val currentStatus = MosaicVpnService.status()["state"]
        val isConnected = currentStatus == "connected"
        val isConnecting = currentStatus == "connecting"

        if (isConnected || isConnecting) {
            runCatching {
                MosaicVpnService.stop(this)
            }.onFailure {
                Log.w("MosaicVpnTileService", "Unable to stop MosaicVpnService from tile", it)
            }
            updateTileState()
        } else {
            val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            } ?: Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }

            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    val pendingIntent = PendingIntent.getActivity(
                        this,
                        1001,
                        launchIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    )
                    startActivityAndCollapse(pendingIntent)
                } else {
                    @Suppress("DEPRECATION")
                    startActivityAndCollapse(launchIntent)
                }
            }.onFailure {
                Log.w("MosaicVpnTileService", "Unable to launch activity from tile", it)
                try {
                    startActivity(launchIntent)
                } catch (_: Throwable) {}
            }
            updateTileState()
        }
    }

    private fun updateTileState() {
        val tile = qsTile ?: return
        val currentStatus = MosaicVpnService.status()["state"]
        val isConnected = currentStatus == "connected"
        val isConnecting = currentStatus == "connecting"

        tile.state = when {
            isConnected || isConnecting -> Tile.STATE_ACTIVE
            else -> Tile.STATE_INACTIVE
        }
        tile.label = "MosaicVPN"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                tile.subtitle = when {
                    isConnected -> MosaicVpnService.currentRouteTitle.ifBlank { "Подключено" }
                    isConnecting -> "Подключение…"
                    else -> "Отключено"
                }
            } catch (_: Throwable) {}
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                tile.stateDescription = when {
                    isConnected -> "MosaicVPN подключен"
                    isConnecting -> "MosaicVPN подключается"
                    else -> "MosaicVPN отключен"
                }
            } catch (_: Throwable) {}
        }
        tile.updateTile()
    }
}
