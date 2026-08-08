"""Measure horizontal overflow of the live landing at three viewport widths.

Uses Chrome via CDP (websocket-client) because puppeteer is not installed.
Emits JSON so failures are unambiguous.
"""
import json
import os
import subprocess
import time
from urllib.request import urlopen

import websocket

URL = "https://sub.zxc1x1.ru/"
PORT = 9333
VIEWPORTS = [("mobile", 390, 844), ("tablet", 768, 1024), ("desktop", 1440, 900)]

MEASURE_JS = """
(() => {
  const over = [];
  document.querySelectorAll('*').forEach(el => {
    const b = el.getBoundingClientRect();
    if (b.width > 0 && b.right > window.innerWidth + 2) {
      const cls = (el.className || '').toString().trim().split(/\\s+/)[0] || '';
      over.push(el.tagName + (cls ? '.' + cls : '') + ' right=' + Math.round(b.right));
    }
  });
  return JSON.stringify({
    scrollW: document.documentElement.scrollWidth,
    innerW: window.innerWidth,
    overflow: document.documentElement.scrollWidth > window.innerWidth + 1,
    offenders: [...new Set(over)].slice(0, 6),
    botLinks: document.querySelectorAll('a[href*="mosaic_tf_bot"]').length,
    dlLinks: document.querySelectorAll('a[href*="releases/download"]').length,
    navVisible: getComputedStyle(document.querySelector('.nav-links')).display,
  });
})()
"""


def find_chrome():
    for p in (
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    ):
        if os.path.exists(p):
            return p
    return None


class CDP:
    def __init__(self, ws_url):
        self.ws = websocket.create_connection(ws_url, timeout=45)
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
    chrome = find_chrome()
    if not chrome:
        print(json.dumps({"error": "chrome not found"}))
        return 1

    proc = subprocess.Popen(
        [
            chrome,
            f"--remote-debugging-port={PORT}",
            "--remote-allow-origins=*",
            "--headless=new",
            "--no-first-run",
            "--no-default-browser-check",
            "--user-data-dir=" + os.path.expandvars(r"%TEMP%\cdp_vp_check"),
            "about:blank",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    try:
        ws_url = None
        for _ in range(60):
            try:
                data = json.loads(urlopen(f"http://127.0.0.1:{PORT}/json/version", timeout=1).read())
                ws_url = data["webSocketDebuggerUrl"]
                break
            except Exception:
                time.sleep(0.5)
        if not ws_url:
            print(json.dumps({"error": "chrome did not expose CDP"}))
            return 1

        results = {}
        for name, w, h in VIEWPORTS:
            browser = CDP(ws_url)
            target = browser.send("Target.createTarget", url="about:blank")
            tid = target["targetId"]
            page_ws = f"ws://127.0.0.1:{PORT}/devtools/page/{tid}"
            browser.close()

            page = CDP(page_ws)
            try:
                page.send("Page.enable")
                page.send(
                    "Emulation.setDeviceMetricsOverride",
                    width=w, height=h, deviceScaleFactor=1, mobile=(name == "mobile"),
                )
                page.send("Page.navigate", url=URL)
                time.sleep(4)
                res = page.send(
                    "Runtime.evaluate", expression=MEASURE_JS, returnByValue=True
                )
                results[name] = json.loads(res["result"]["value"])
            finally:
                page.close()
                b = CDP(ws_url)
                b.send("Target.closeTarget", targetId=tid)
                b.close()

        print(json.dumps(results, indent=1, ensure_ascii=False))
        bad = [k for k, v in results.items() if v.get("overflow")]
        return 1 if bad else 0
    finally:
        proc.terminate()


if __name__ == "__main__":
    raise SystemExit(main())
