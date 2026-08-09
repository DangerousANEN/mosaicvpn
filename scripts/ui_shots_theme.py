"""Capture Flutter web screenshots in a forced color scheme.

Flutter renders into a canvas, so DOM metrics alone cannot prove the layout
looks right. This grabs real pixels so the result can be inspected.

The app's themeMode defaults to "system", so the scheme is forced via CDP's
prefers-color-scheme emulation rather than trusting whatever the host machine
happens to be set to.

    python scripts/ui_shots_theme.py http://127.0.0.1:8085 out_dir dark
"""
import base64
import json
import os
import subprocess
import sys
import time
from urllib.request import urlopen

import websocket

URL = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8085"
OUT = sys.argv[2] if len(sys.argv) > 2 else "artifacts/ui"
SCHEME = sys.argv[3] if len(sys.argv) > 3 else "dark"
PORT = 9379

VIEWPORTS = [
    ("phone", 390, 844, True),
    ("desktop", 1440, 900, False),
]


def find_chrome() -> str:
    for c in (
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    ):
        if os.path.exists(c):
            return c
    raise SystemExit("chrome not found")


class CDP:
    def __init__(self, url):
        self.ws = websocket.create_connection(url, timeout=90)
        self.i = 0

    def send(self, method, **params):
        self.i += 1
        self.ws.send(json.dumps({"id": self.i, "method": method, "params": params}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == self.i:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg.get("result", {})

    def close(self):
        self.ws.close()


def main():
    os.makedirs(OUT, exist_ok=True)
    chrome = find_chrome()
    proc = subprocess.Popen(
        [
            chrome,
            f"--remote-debugging-port={PORT}",
            "--remote-allow-origins=*",
            "--headless=new",
            "--hide-scrollbars",
            "--no-first-run",
            "--user-data-dir=" + os.path.expandvars(r"%TEMP%\cdp_ui_shots_theme"),
            "about:blank",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        ws_url = None
        for _ in range(80):
            try:
                ws_url = json.loads(
                    urlopen(f"http://127.0.0.1:{PORT}/json/version", timeout=1).read()
                )["webSocketDebuggerUrl"]
                break
            except Exception:
                time.sleep(0.5)
        if not ws_url:
            raise SystemExit("devtools never came up")

        for name, w, h, mobile in VIEWPORTS:
            b = CDP(ws_url)
            tid = b.send("Target.createTarget", url="about:blank")["targetId"]
            b.close()

            p = CDP(f"ws://127.0.0.1:{PORT}/devtools/page/{tid}")
            p.send("Page.enable")
            p.send("Emulation.setEmulatedMedia",
                   features=[{"name": "prefers-color-scheme", "value": SCHEME}])
            p.send(
                "Emulation.setDeviceMetricsOverride",
                width=w,
                height=h,
                deviceScaleFactor=2,
                mobile=mobile,
            )
            p.send("Page.navigate", url=URL)
            time.sleep(12)

            data = p.send("Page.captureScreenshot", format="png")["data"]
            path = os.path.join(OUT, f"{name}_{SCHEME}.png")
            with open(path, "wb") as fh:
                fh.write(base64.b64decode(data))
            print(f"{name} ({SCHEME}): {path} ({os.path.getsize(path)} bytes)")

            p.close()
            b2 = CDP(ws_url)
            b2.send("Target.closeTarget", targetId=tid)
            b2.close()
    finally:
        proc.terminate()
    return 0


if __name__ == "__main__":
    sys.exit(main())
