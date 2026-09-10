import urllib.request
import json
import time
import sys

def consult_opus(prompt, model="opus-5"):
    url = "http://127.0.0.1:20128/v1/chat/completions"
    payload = {
        "model": model,
        "stream": True,
        "messages": [
            {
                "role": "system",
                "content": "Ты — Главный Архитектор MosaicVPN (Brain & Critic). Отвечай четко, емко, структурированно, выделяя критические риски, edge cases и конкретные рекомендации."
            },
            {
                "role": "user",
                "content": prompt
            }
        ]
    }
    
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"}
    )
    
    print(f"Connecting to OmniRoute [{model}]...", flush=True)
    t0 = time.time()
    keepalive_count = 0
    received_tokens = 0
    
    with urllib.request.urlopen(req, timeout=300) as resp:
        for raw_line in resp:
            line = raw_line.decode("utf-8").strip()
            if not line:
                continue
            if line.startswith("data: "):
                data_str = line[6:]
                if data_str == "[DONE]":
                    break
                try:
                    chunk = json.loads(data_str)
                    if chunk.get("id") == "omniroute-keepalive":
                        keepalive_count += 1
                        if keepalive_count % 5 == 0:
                            print(f"[Thinking... {time.time()-t0:.1f}s]", flush=True)
                        continue
                    
                    choices = chunk.get("choices", [])
                    if choices:
                        delta = choices[0].get("delta", {})
                        content = delta.get("content", "")
                        if content:
                            received_tokens += 1
                            print(content, end="", flush=True)
                except Exception:
                    pass
                    
    print(f"\n\n[Finished in {time.time()-t0:.2f}s, tokens received: {received_tokens}]", flush=True)

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1].strip():
        prompt_text = sys.argv[1]
    else:
        prompt_text = """
Проведи архитектурный анализ и код-ревью реализации Android Quick Settings Tile и VpnService lifecycle:

1. MosaicVpnService.kt:
При успешном старте sing-box ('connected') и при остановке stopRuntime ('stopForeground/stopSelf') вызывается:
if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
    try {
        TileService.requestListeningState(this, ComponentName(this, MosaicVpnTileService::class.java))
    } catch (_: Exception) {}
}
Также в Foreground Notification добавлена кнопка ACTION_STOP:
val stopIntent = Intent(this, MosaicVpnService::class.java).apply { action = ACTION_STOP }
val stopPendingIntent = PendingIntent.getService(this, 0, stopIntent, PendingIntent.FLAG_IMMUTABLE)

2. MosaicVpnTileService.kt:
override fun onStartListening() {
    super.onStartListening()
    updateTileState()
}
override fun onClick() {
    super.onClick()
    val isConnected = MosaicVpnService.runtimeState == "connected"
    if (isConnected) {
        val stopIntent = Intent(this, MosaicVpnService::class.java).apply { action = MosaicVpnService.ACTION_STOP }
        startService(stopIntent)
    } else {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        if (launchIntent != null) {
            launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (Build.VERSION.SDK_INT >= 34) {
                val pendingIntent = PendingIntent.getActivity(this, 0, launchIntent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                startActivityAndCollapse(pendingIntent)
            } else {
                @Suppress("DEPRECATION")
                startActivityAndCollapse(launchIntent)
            }
        }
    }
}
private fun updateTileState() {
    val tile = qsTile ?: return
    val isConnected = MosaicVpnService.runtimeState == "connected"
    tile.state = if (isConnected) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
    tile.label = "Mosaic VPN"
    tile.subtitle = if (isConnected) (MosaicVpnService.activeRouteTitle ?: "Подключено") else "Отключено"
    tile.updateTile()
}

Оцени архитектуру:
1. Потенциальные race conditions при одновременном вызове ACTION_STOP из уведомления, TileService и UI Flutter.
2. Корректность API 34+ PendingIntent vs startActivityAndCollapse.
3. Состояние тайла при аварийном завершении процесса (OOM killer, force stop).
4. Рекомендации по усилению надежности.
"""
    consult_opus(prompt_text, model="opus-5")
