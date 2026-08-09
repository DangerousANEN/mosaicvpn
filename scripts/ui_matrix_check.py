"""Check the Flutter web build for layout breakage across screen sizes.

The dashboard used a fixed three-column Row, which squeezed panels to ~120px
on a phone and broke words into two characters per line. This walks a matrix
of viewports and fails on either symptom:

  * a Flutter "RenderFlex overflowed" console error
  * horizontal page scroll (scrollWidth > innerWidth)

Run against an already-served build:
    python scripts/ui_matrix_check.py http://127.0.0.1:8085
"""
import json
import os
import subprocess
import sys
import time
from urllib.request import urlopen

import websocket

URL = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8085"
PORT = 9377

VIEWPORTS = [
    ("phone-small", 360, 640, True),
    ("phone", 390, 844, True),
    ("tablet", 768, 1024, False),
    ("desktop", 1440, 900, False),
]


def find_chrome() -> str:
    candidates = [
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    ]
    for c in candidates:
        if os.path.exists(c):
            return c
    raise SystemExit("chrome not found")


class CDP:
    def __init__(self, url: str):
        self.ws = websocket.create_connection(url, timeout=60)
        self.i = 0

    def send(self, method: str, **params):
        self.i += 1
        self.ws.send(json.dumps({"id": self.i, "method": method, "params": params}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == self.i:
                return msg.get("result", {})

    def close(self):
        self.ws.close()


PROBE = """
(() => {
  const de = document.documentElement;
  return JSON.stringify({
    scrollW: de.scrollWidth,
    innerW: window.innerWidth,
    overflow: de.scrollWidth > window.innerWidth + 1,
  });
})()
"""


def main() -> int:
    chrome = find_chrome()
    proc = subprocess.Popen(
        [
            chrome,
            f"--remote-debugging-port={PORT}",
            "--remote-allow-origins=*",
            "--headless=new",
            "--no-first-run",
            "--no-default-browser-check",
            "--user-data-dir=" + os.path.expandvars(r"%TEMP%\cdp_ui_matrix"),
            "about:blank",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    failures = []
    try:
        ws_url = None
        for _ in range(80):
            try:
                data = json.loads(
                    urlopen(f"http://127.0.0.1:{PORT}/json/version", timeout=1).read()
                )
                ws_url = data["webSocketDebuggerUrl"]
                break
            except Exception:
                time.sleep(0.5)
        if not ws_url:
            raise SystemExit("chrome devtools never came up")

        for name, w, h, mobile in VIEWPORTS:
            browser = CDP(ws_url)
            tid = browser.send("Target.createTarget", url="about:blank")["targetId"]
            browser.close()

            page = CDP(f"ws://127.0.0.1:{PORT}/devtools/page/{tid}")
            page.send("Page.enable")
            page.send("Runtime.enable")
            page.send("Log.enable")
            page.send(
                "Emulation.setDeviceMetricsOverride",
                width=w,
                height=h,
                deviceScaleFactor=1,
                mobile=mobile,
            )
            page.send("Page.navigate", url=URL)

            # Flutter web needs time to boot its canvas and lay out.
            time.sleep(9)

            probe = json.loads(
                page.send("Runtime.evaluate", expression=PROBE, returnByValue=True)[
                    "result"
                ]["value"]
            )

            # Drain console for Flutter's overflow complaints.
            overflow_logs = []
            page.ws.settimeout(1.5)
            try:
                while True:
                    msg = json.loads(page.ws.recv())
                    method = msg.get("method", "")
                    if method in ("Runtime.consoleAPICalled", "Log.entryAdded"):
                        text = json.dumps(msg.get("params", {}))
                        if "overflow" in text.lower():
                            overflow_logs.append(text[:160])
            except Exception:
                pass

            status = "OK"
            if probe["overflow"]:
                status = "H-SCROLL"
                failures.append(f"{name}: horizontal scroll {probe['scrollW']}>{probe['innerW']}")
            if overflow_logs:
                status = "OVERFLOW"
                failures.append(f"{name}: {len(overflow_logs)} overflow warning(s)")

            print(
                f"  {name:12} {w}x{h:<5} scrollW={probe['scrollW']:<5} "
                f"innerW={probe['innerW']:<5} {status}"
            )
            for log in overflow_logs[:3]:
                print(f"      {log}")

            page.close()
            b2 = CDP(ws_url)
            b2.send("Target.closeTarget", targetId=tid)
            b2.close()
    finally:
        proc.terminate()

    print()
    if failures:
        print("FAILURES:")
        for f in failures:
            print("  -", f)
        return 1
    print("All viewports clean.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
