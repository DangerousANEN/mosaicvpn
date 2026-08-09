"""Screenshot the Account cabinet by driving the real UI.

Flutter web paints into a canvas, so there is no DOM text to query and
get_by_text finds nothing. This enables Flutter's semantics tree first (the
hidden "Enable accessibility" placeholder), which mirrors the widget tree
into DOM nodes carrying aria-labels. Clicks then target real widgets by
label instead of guessed pixel coordinates.
"""
import asyncio
import os
import sys

from playwright.async_api import async_playwright

URL = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8099"
OUT = sys.argv[2] if len(sys.argv) > 2 else "artifacts/account"
SCHEME = sys.argv[3] if len(sys.argv) > 3 else "dark"

VIEWPORTS = {
    "phone": {"width": 390, "height": 844},
    "desktop": {"width": 1440, "height": 900},
}

ENABLE_SEMANTICS = """() => {
  const el = document.querySelector('flt-semantics-placeholder');
  if (el) { el.click(); return true; }
  return false;
}"""

# Search the semantics tree for a node whose label matches, and return its
# centre in page coordinates so the click lands on the real widget.
# raw string: Python must not touch the backslash escapes below, otherwise
# a "\n" inside a JS comment becomes a real newline and truncates it.
FIND_LABEL = r"""(wanted) => {
  const nodes = document.querySelectorAll('flt-semantics, [aria-label], [role]');
  for (const n of nodes) {
    const raw = (n.getAttribute('aria-label') || n.textContent || '').trim();
    if (!raw) continue;
    // Flutter appends positional hints to tab semantics, such as a "More"
    // label followed by its index. Compare only the first line so a tab
    // still matches its plain label.
    const label = raw.split('\n')[0].trim();
    if (wanted.some(w => label.toLowerCase() === w.toLowerCase())) {
      const r = n.getBoundingClientRect();
      if (r.width > 0 && r.height > 0) {
        return {x: r.x + r.width / 2, y: r.y + r.height / 2, label: label};
      }
    }
  }
  return null;
}"""

LIST_LABELS = """() => {
  const out = [];
  for (const n of document.querySelectorAll('flt-semantics, [aria-label]')) {
    const l = (n.getAttribute('aria-label') || n.textContent || '').trim();
    const r = n.getBoundingClientRect();
    if (l && r.width > 0 && r.height > 0) out.push(l);
  }
  return Array.from(new Set(out)).slice(0, 60);
}"""


async def tap(page, names, what):
    hit = await page.evaluate(FIND_LABEL, names)
    if not hit:
        print(f"  ! could not find {what} (tried {names})")
        return False
    await page.mouse.click(hit["x"], hit["y"])
    await page.wait_for_timeout(1500)
    print(f"  tapped {what}: '{hit['label']}'")
    return True


async def shoot(page, name, path):
    await page.wait_for_timeout(1000)
    await page.screenshot(path=path)
    print(f"{name}: {path} ({os.path.getsize(path)} bytes)")


async def main():
    os.makedirs(OUT, exist_ok=True)
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        for label, vp in VIEWPORTS.items():
            ctx = await browser.new_context(viewport=vp, color_scheme=SCHEME)
            page = await ctx.new_page()
            errors = []
            page.on("pageerror", lambda e: errors.append(str(e)))
            await page.goto(URL, wait_until="networkidle")
            await page.wait_for_timeout(4500)  # Flutter boots asynchronously

            enabled = await page.evaluate(ENABLE_SEMANTICS)
            await page.wait_for_timeout(2000)
            print(f"[{label}] semantics enabled: {enabled}")

            # A "No Servers Found" modal opens on a fresh profile and swallows
            # every click beneath it; dismiss before navigating.
            await tap(page, ["Later", "Позже"], "modal dismiss")

            await tap(page, ["Account", "Кабинет"], "account nav")

            # On a phone the cabinet sits inside More, so try that path too.
            probe = await page.evaluate(FIND_LABEL, ["Link account", "Привязать аккаунт",
                                                     "Pairing code", "Код привязки"])
            if probe is None:
                await tap(page, ["More", "Ещё"], "more tab")
                await tap(page, ["Account", "Кабинет"], "account row")

            await shoot(page, f"{label}-account",
                        os.path.join(OUT, f"{label}_account_{SCHEME}.png"))

            labels = await page.evaluate(LIST_LABELS)
            print(f"[{label}] visible labels: {labels}")
            if errors:
                print(f"[{label}] JS errors: {errors[:3]}")
            await ctx.close()
        await browser.close()


asyncio.run(main())
