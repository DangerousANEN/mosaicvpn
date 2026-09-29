from pathlib import Path

p = Path('flutter/lib/features/servers/servers_screen.dart')
t = p.read_text(encoding='utf-8')

# ---------------------------------------------------------------------------
# servers at 740x360 still overflowed by 157px on the bottom.
#
# The arithmetic cannot be won by trimming: a 360px-tall viewport must hold
# padding + header + action strip + search/sort row + a list that itself has a
# minimum. My earlier attempt to wrap everything in a scroll failed with
# "non-zero flex but incoming height constraints are unbounded" because the
# Expanded child needs a bounded height.
#
# Correct, contained fix: keep the Column/Expanded structure EXACTLY as it is,
# and on short screens put a max-height, scrollable box around the header +
# filters block only. That block becomes scrollable within a small budget, so it
# can never exceed it, while the list keeps its flex layout on every screen
# size. No new flex/scroll interaction is introduced.
old = """    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: ["""
new = """    // Height budget on a short viewport (landscape phone): padding + header +
    // action strip + filters leave too little for the list, and Expanded cannot
    // recover space that is already consumed -- measured 157px of overflow at
    // 360px tall. The header block is therefore capped and made scrollable on
    // short screens; the list keeps its flex layout everywhere.
    final screenH = MediaQuery.of(context).size.height;
    final isShort = screenH < 560;
    final pad = isShort ? 10.0 : 24.0;
    // Leave the list at least ~40% of the viewport; the rest is the chrome cap.
    final chromeCap = isShort ? (screenH * 0.55) : null;
    return Padding(
      padding: EdgeInsets.all(pad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: ["""
assert old in t, "servers root"
t = t.replace(old, new, 1)

# wrap the chrome (everything up to the list) in a capped scroll view.
# The chrome spans from the SectionHeader to the SizedBox right before the
# "Expandable Group List" marker.
marker = "          // ── Expandable Group List ──"
assert marker in t, "list marker"
head, tail = t.split(marker, 1)

# find the start of the chrome: the SectionHeader comment
chrome_marker = "          // ── Header Section ──"
assert chrome_marker in head, "header marker"
pre, chrome = head.split(chrome_marker, 1)

new_chrome = (
    "          // Chrome cap (short screens only): header + filters scroll inside a\n"
    "          // bounded box so they cannot starve the list below. On tall screens\n"
    "          // this is a transparent wrapper with no height limit.\n"
    "          if (chromeCap != null)\n"
    "            ConstrainedBox(\n"
    "              constraints: BoxConstraints(maxHeight: chromeCap),\n"
    "              child: SingleChildScrollView(\n"
    "                child: Column(\n"
    "                  crossAxisAlignment: CrossAxisAlignment.start,\n"
    "                  children: [\n"
    + '\n'.join('    ' + l if l.strip() else l for l in
                (chrome_marker + chrome).split('\n'))
    + "\n                  ],\n"
    "                ),\n"
    "              ),\n"
    "            )\n"
    "          else ...[\n"
    + '\n'.join('    ' + l if l.strip() else l for l in
                (chrome_marker + chrome).split('\n'))
    + "\n          ],\n"
)

t = pre + new_chrome + marker + tail
p.write_text(t, encoding='utf-8')
print('servers_screen: chrome capped + scrollable on short screens')