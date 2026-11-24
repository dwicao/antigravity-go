package io.github.dwicao.antigravity_go.tile

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import io.github.dwicao.antigravity_go.MainActivity
import io.github.dwicao.antigravity_go.R

/**
 * Android Quick Settings tile ("New Chat") adopted from DSH Go:
 * launches directly into a fresh Antigravity Go conversation.
 */
class NewChatTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        val tile = qsTile ?: return
        tile.state = Tile.STATE_INACTIVE
        tile.label = getString(R.string.tile_new_chat_label)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = applicationInfo.loadLabel(packageManager)
        }
        tile.updateTile()
    }

    override fun onClick() {
        super.onClick()
        if (isLocked) unlockAndRun { open() } else open()
    }

    private fun open() {
        val intent = Intent(this, MainActivity::class.java).apply {
            action = MainActivity.ACTION_SHORTCUT
            putExtra(MainActivity.EXTRA_ROUTE_ACTION, "new_chat")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startActivityAndCollapse(
                    PendingIntent.getActivity(
                        this,
                        101,
                        intent,
                        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                    ),
                )
            } else {
                @Suppress("DEPRECATION")
                startActivityAndCollapse(intent)
            }
        }
    }
}
