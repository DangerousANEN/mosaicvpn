from pathlib import Path
import re

p = Path('flutter/lib/features/servers/servers_screen.dart')
t = p.read_text(encoding='utf-8')

# ---------------------------------------------------------------------------
# servers at 740x360 overflowed 157px on the bottom: a 360px-tall viewport
# cannot hold padding + header + action strip + filters + a list with its own
# minimum, and `Expanded` cannot recover space already consumed above it.
#
# Clean solution (no duplicated widgets, no flex/scroll conflict):
#   1. extract the list expression into a local `listBody`
#   2. on tall screens keep `Expanded(child: listBody)` exactly as before
#   3. on short screens make the whole deck scroll and give the list a bounded
#      height, so there is no Expanded inside a scrollable (which would throw
#      "non-zero flex but incoming height constraints are unbounded")
# ---------------------------------------------------------------------------

# --- 1. replace the Expanded(list) with a reference to a local variable ------
start = t.index("          // ── Expandable Group List ──")
line_start = t.rindex("\n", 0, start) + 1
expanded_start = t.index("Expanded(", line_start)
# find matching close
depth = 0
end = None
for i in range(expanded_start, len(t)):
    if t[i] == '(':
        depth += 1
    elif t[i] == ')':
        depth -= 1
        if depth == 0:
            end = i
            break
assert end is not None, "Expanded close not found"

inner = t[t.index('(', expanded_start) + 1:end]
# de-indent the inner expression by 2 and normalise leading newlines
inner_lines = inner.split('\n')
inner_lines = [l[2:] if l.startswith('  ') else l for l in inner_lines]
while inner_lines and not inner_lines[0].strip():
    inner_lines.pop(0)

t = (t[:line_start]
     + "          // The list fills the remaining height on tall screens; on a short\n"
       "          // viewport the deck scrolls instead (see the layout choice below),\n"
       "          // which is why this is a plain child rather than an Expanded.\n"
       "          if (!isShort)\n"
       "            Expanded(child: listBody)\n"
       "          else\n"
       "            SizedBox(height: listHeight, child: listBody),\n"
     + t[end + 1:])

# --- 2. build listBody + listHeight just before returning -------------------
anchor = """    final screenH = MediaQuery.of(context).size.height;
    final isShort = screenH < 560;
    final pad = isShort ? 10.0 : 24.0;
    // Leave the list at least ~40% of the viewport; the rest is the chrome cap.
    final chromeCap = isShort ? (screenH * 0.55) : null;
    return Padding("""
assert anchor in t, "anchor"

list_body = '\n'.join('      ' + l if l.strip() else l for l in inner_lines)

replacement = f"""    final screenH = MediaQuery.of(context).size.height;
    final isShort = screenH < 560;
    final pad = isShort ? 10.0 : 24.0;
    // On a short viewport the list gets an explicit share of the height because
    // Expanded inside a scrollable is not allowed.
    final listHeight = isShort ? (screenH * 0.45) : 0.0;

    final listBody = {list_body.lstrip()};

    final deck = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: ["""
t = t.replace(anchor, replacement, 1)

p.write_text(t, encoding='utf-8')
print("extracted listBody; list is now Expanded (tall) or fixed-height (short)")
print("NEXT: fix the deck's return + closes")