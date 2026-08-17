# MosaicVPN architecture diagrams

## Render verification

Rendered on 2026-08-17 with `manus-render-diagram` and visually checked.

| Diagram | Purpose | Rendered output | Result |
|---|---|---|---|
| `mosaicvpn_class_architecture.mmd` | UML-like map of shared Flutter, Android runtime, desktop daemon, hosted authority, protected pool, and proposed multi-provider model | `rendered/mosaicvpn_class_architecture.png` | Readable at full resolution; actual and target classes are visually separated. |
| `mosaicvpn_runtime_flow.mmd` | Flowchart for authorization, account sync, subscriptions, Smart Group selection, native tunnel, billing and diagnostics | `rendered/mosaicvpn_runtime_flow.png` | Readable at full resolution; protected private pool is separated from user-visible routes. |

Both Mermaid source files are editable and should be treated as the authoritative diagrams. The PNG files are viewing exports.
