import urllib.request
import json
import sys
import os

tile_service_path = r'C:\Users\ANEN\mosaicvpn\flutter\android\app\src\main\kotlin\ru\mosaicvpn\mosaic_vpn\MosaicVpnTileService.kt'
vpn_service_path = r'C:\Users\ANEN\mosaicvpn\flutter\android\app\src\main\kotlin\ru\mosaicvpn\mosaic_vpn\MosaicVpnService.kt'

with open(tile_service_path, 'r', encoding='utf-8') as f:
    tile_code = f.read()

with open(vpn_service_path, 'r', encoding='utf-8') as f:
    vpn_code = f.read()

# Extract notification and stop parts from vpn_code
prompt = f"""Привет, Claude! Я Gemini (инженер-исполнитель). Мы работаем в тандеме над MosaicVPN Android.
Ты — Главный Архитектор и Рецензент (Brain & Critic).

Пожалуйста, сделай глубокий архитектурный анализ и code review реализации сервиса и плитки быстрых настроек Android (Quick Settings Tile):

=== 1. MosaicVpnTileService.kt ===
```kotlin
{tile_code}
```

=== 2. Фрагмент MosaicVpnService.kt (уведомления, lifecycle, остановка) ===
```kotlin
{vpn_code[:4000]}
```

Проанализируй следующие критические аспекты:
1. Race conditions при одновременном вызове TileService.onClick() и ACTION_STOP из Notification (кнопка 'Отключить').
2. Флаги PendingIntent на Android 12+ (FLAG_IMMUTABLE vs FLAG_MUTABLE).
3. Обновление Tile в реальном времени: вызывается ли TileService.requestListeningState(context, ComponentName(...)) при изменении `runtimeState` внутри MosaicVpnService?
4. Поведение TileService при клике, если VPN отключен: открытие MainActivity (с учетом Android 14+ background activity start restrictions).
5. Необходимые точечные правки в Kotlin коде.

Дай конкретный вердикт и код правок."""

data = {
    'model': 'opus-5',
    'stream': True,
    'messages': [
        {'role': 'user', 'content': prompt}
    ]
}

req = urllib.request.Request(
    'http://127.0.0.1:20128/v1/chat/completions',
    data=json.dumps(data).encode('utf-8'),
    headers={'Content-Type': 'application/json'}
)

print('--- ASKING ARCHITECT (CLAUDE OPUS) VIA OMNIROUTE ---', flush=True)

in_reasoning = False
try:
    with urllib.request.urlopen(req, timeout=300) as resp:
        while True:
            line = resp.readline()
            if not line:
                break
            decoded = line.decode('utf-8', errors='ignore').strip()
            if not decoded.startswith('data: '):
                continue
            chunk_str = decoded[6:]
            if chunk_str == '[DONE]':
                break
            try:
                d = json.loads(chunk_str)
                delta = d.get('choices', [{}])[0].get('delta', {})
                reasoning = delta.get('reasoning_content', '')
                content = delta.get('content', '')
                if reasoning:
                    if not in_reasoning:
                        sys.stdout.write('\n[Opus Reasoning]\n')
                        in_reasoning = True
                    sys.stdout.write(reasoning)
                    sys.stdout.flush()
                if content:
                    if in_reasoning:
                        sys.stdout.write('\n[Opus Verdict & Code]\n')
                        in_reasoning = False
                    sys.stdout.write(content)
                    sys.stdout.flush()
            except:
                pass
except Exception as e:
    print('Failed to consult architect:', e, file=sys.stderr)

print('\n--- ARCHITECT REVIEW COMPLETE ---', flush=True)
