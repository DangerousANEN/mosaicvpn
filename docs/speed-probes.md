# MosaicVPN HTTPS Speed Probe Contract

The provider may add a `speed_probe` object to a Smart Group's server-defined `client_policy`. The generic client does not infer group names; it only applies the supplied policy when `speed_weight` is greater than zero and `speed_probe.enabled` is true.

| Field | Type | Bounds/default | Meaning |
|---|---:|---:|---|
| `enabled` | boolean | `false` | Enables bounded throughput checks during local candidate selection. |
| `download_urls` | HTTPS URL array | maximum 3; Cloudflare fallback | Candidate download endpoints. The client and daemon reject non-HTTPS URLs. |
| `upload_url` | HTTPS URL | Cloudflare fallback | Endpoint accepting a bounded `application/octet-stream` POST. |
| `sample_bytes` | integer | 256 KiB–8 MiB; default 2 MiB | Maximum payload for each direction. |
| `timeout_seconds` | integer | 3–30; default 12 | Per HTTP client timeout. |
| `max_candidates` | integer | 1–3; default 2 | Maximum top transport-ranked candidates tested for throughput. |
| `target_mbps` | number | 1–1000; default 50 | Normalization target used by client-side scoring. |

The daemon endpoint is `POST /v1/test/speed`. Existing clients may send an empty body. A policy-aware client sends `{ "policy": { ...speed_probe fields... } }`. The probe runs through the active local sing-box SOCKS outbound, so candidate traffic does not pass through the MosaicVPN VPS. The server only provides the manifest and does not rank candidates.

Download uses a bounded GET and reads at most `sample_bytes`; the endpoint may receive a `bytes` query parameter. Upload uses a bounded POST of zero-filled bytes and records the transfer rate only for a successful 2xx response. Results report `download_bps`, `upload_bps`, `download_mbps`, `upload_mbps`, `tested_at`, and an optional `error`.

The client first performs the existing transport probe for the opaque candidate shard. For a speed-enabled policy, it sequentially connects to at most `max_candidates` top candidates, runs the bounded HTTPS probe, caches the measured throughput with the local quality record, and re-sorts locally. Failover remains bounded by `max_failover_tries`. No Ookla SDK or Ookla endpoint is used.

The reserved **Свободный LTE / Free LTE** category remains a disabled manifest placeholder. It has no active source feed or discovery logic and must not be enabled until a separately reviewed, owner-authorized profile source is integrated.
