# NotiSend DNS Setup — MosaicVPN

**Date:** 2026-08-19

NotiSend domain created: `zxc1x1.ru` (internal ID 79759), initial status **unverified**.

## Step 1 records issued by NotiSend

| Type | Host | Value | Intended action |
|---|---|---|---|
| A | `service.zxc1x1.ru` | `85.202.84.103` | Add new DNS-only record |
| TXT | `mdmail._domainkey.zxc1x1.ru` | `v=DKIM1;k=rsa;p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDA0HcpolhgrH19XrSNZcJ6/vwl1xR1tAVNQ32IbnHlT8mdQoFLC6uuMXzFunB0U0RL67hnCLhApie4EjMaLuULtpnJIHHFM9T1dV4PrKI/Qeh4ReIOtUSa9HIptRqjqhrHez8jZdVy+Yuq47PVzuLrBo0OteRCwn2WXklP2FDp1QIDAQAB` | Add as a new selector: NotiSend uses `mdmail`, whereas RuSender used the distinct legacy selector `mdmdmail` |
| TXT | `service.zxc1x1.ru` | `v=spf1 include:msndr.net ~all` | Add new subdomain SPF record |
| TXT | `_dmarc.zxc1x1.ru` | `v=DMARC1; p=none; rua=mailto:postmaster@zxc1x1.ru` | No action: compatible monitoring DMARC record already exists and should be preserved |

## Existing records retained

The root SPF record (`v=spf1 include:rsndr.ru include:_spf.mx.cloudflare.net ~all`) is intentionally retained for now because it authorizes Cloudflare Email Routing. NotiSend uses a separate SPF record at `service.zxc1x1.ru`, so no root-SPF merge is required. Cloudflare-managed MX records and `cf2024-1._domainkey` also remain unchanged.

## Verified pre-change DNS state

Cloudflare showed 11 records. The relevant mutable records were:

| Host | Type | Current state | Planned change |
|---|---|---|---|
| `mdmdmail._domainkey.zxc1x1.ru` | TXT | Legacy RuSender DKIM value | Replace with the NotiSend DKIM value above |
| `zxc1x1.ru` | TXT | Single root SPF: `v=spf1 include:rsndr.ru include:_spf.mx.cloudflare.net ~all` | Leave unchanged to preserve Cloudflare Email Routing authorization |
| `_dmarc.zxc1x1.ru` | TXT | `v=DMARC1; p=none; rua=mailto:postmaster@mx1.rusender-mail.ru` | Leave unchanged; monitoring policy is compatible |
| `cf2024-1._domainkey.zxc1x1.ru` | TXT | Cloudflare Email Routing DKIM | Leave unchanged |

## Applied changes

| Change | Applied value | Status |
|---|---|---|
| NotiSend service host | `service.zxc1x1.ru` A → `85.202.84.103`, DNS only, TTL Auto | Published |
| NotiSend envelope SPF | `service.zxc1x1.ru` TXT → `v=spf1 include:msndr.net ~all` | Published |
| NotiSend DKIM | `mdmail._domainkey.zxc1x1.ru` TXT → NotiSend-issued public key | Published successfully |
| Root SPF | `v=spf1 include:rsndr.ru include:_spf.mx.cloudflare.net ~all` | Intentionally unchanged |
| Cloudflare Email Routing MX/DKIM | Cloudflare-managed records | Intentionally unchanged |
| DMARC | Existing monitoring policy and report address | Intentionally unchanged |

Cloudflare displayed success confirmations for the DNS changes. The legacy RuSender selector `mdmdmail._domainkey` and the current NotiSend selector `mdmail._domainkey` are distinct names; both are present, but only `mdmail` is used by NotiSend.

## Independent DNS verification

Immediately after publishing the records, public DNS-over-HTTPS checks confirmed:

| Query | Observed value |
|---|---|
| `A service.zxc1x1.ru` | `85.202.84.103` |
| `TXT service.zxc1x1.ru` | `v=spf1 include:msndr.net ~all` |
| `TXT mdmdmail._domainkey.zxc1x1.ru` | Legacy selector was later determined to be distinct from NotiSend's required `mdmail` selector |

After the mandatory propagation interval, NotiSend's `/verify` action accepted **all four Stage 1 records**: service A, `mdmail` DKIM, service SPF, and the existing monitoring DMARC. The domain verification progressed to Stage 2.

## Stage 2 records issued by NotiSend

| Type | Host | Value | Purpose |
|---|---|---|---|
| TXT | `zxc1x1.ru` | `google-site-verification=RuhCy-W1WXJ79l1VtDSIRL49y6ak8R9DIQ-uHwUTQkM` | Google mail-service integration verification |
| TXT | `zxc1x1.ru` | `mailru-verification: 0cbfe8832eb19d1b` | Mail.ru mail-service integration verification |

Both values must be added as **additional root TXT records**. They must not replace the existing root SPF TXT record.

## Provider verification outcome

NotiSend accepted both DNS stages and now marks `zxc1x1.ru` **confirmed**. The service states that all mandatory technical delivery requirements are fulfilled.

## SMTP connection details (non-secret)

| Setting | Value |
|---|---|
| SMTP host | `smtp.msndr.net` |
| STARTTLS ports | `25` or `587` |
| Implicit TLS port | `465` |
| SMTP username | NotiSend account e-mail |
| SMTP password | Not written to this document or repository; it must be stored only in `/etc/mosaic-bot.env` with mode `0600` |

An activation request for the SMTP/API key was submitted in the NotiSend panel. At the time of request, NotiSend indicated that activation may take some time; no configuration has yet been deployed to the VPS.

## Remaining steps

1. Confirm activation of the NotiSend SMTP/API key.
2. Add the SMTP variables only to `/etc/mosaic-bot.env` on the VPS, restart `mosaic-bot.service`, and confirm the service health.
3. Initiate a controlled password-recovery request and verify actual inbox delivery and provider delivery status.

## Activation and production deployment

NotiSend support confirmed through the in-app chat that the account passed its review and the SMTP/API key is now **active for all user-recipient addresses**. The service was informed that MosaicVPN sends only user-requested password-recovery messages to registered users; no purchased, scraped, or marketing lists are used.

The production VPS configuration was updated only in `/etc/mosaic-bot.env` (mode `0600`) with the five `MOSAIC_SMTP_*` settings. The selected transport is `smtp.msndr.net:587` with STARTTLS, matching the bot implementation. A TLS handshake from the production VPS succeeded, SMTP authentication succeeded, and a direct controlled transport message was accepted by NotiSend.

During validation, the existing VPS `bot.py` was found to be an older build missing `/api/auth/register` and `/api/auth/recovery/start`; it returned HTTP 404 for these routes. The current repository `bot.py`, which had passed syntax validation, was deployed atomically after a timestamped backup. After normal startup time, `mosaic-bot.service` was active, port `12223` was listening, and the recovery endpoint returned its expected HTTP 400 for an empty request.

## Controlled end-to-end recovery test

A technical web account using `noreply@zxc1x1.ru` was created only for delivery validation through the public HTTPS registration endpoint (HTTP 201). A public `POST /api/auth/recovery/start` for that account returned HTTP 202, with no SMTP error in the production service journal. The NotiSend transaction log showed:

| Message | Recipient | Provider status at last check |
|---|---|---|
| `MosaicVPN SMTP transport test` | `noreply@zxc1x1.ru` | Delivered |
| `MosaicVPN — восстановление пароля` | `noreply@zxc1x1.ru` | Delivering (accepted by provider; awaiting final recipient acknowledgement) |

The existing Cloudflare Email Routing rule forwards `noreply@zxc1x1.ru` to the technical inbox. The remaining check is to wait for NotiSend to advance the recovery message from `Delivering` to `Delivered`, then remove the temporary SSH private key from the sandbox.

### Final delivery confirmation

Cloudflare Email Routing Activity Log recorded the controlled recovery message with subject `MosaicVPN — восстановление пароля`, sender `noreply@zxc1x1.ru`, recipient `noreply@zxc1x1.ru`, and result **Forwarded**. This proves the full production path: public recovery endpoint → MosaicVPN bot → authenticated STARTTLS SMTP at NotiSend → Cloudflare Email Routing → verified technical destination.

At the moment of Cloudflare confirmation, NotiSend still displayed the same message as `Delivering`; its later recipient-level acknowledgement is not required for the recovery workflow because Cloudflare has already accepted and forwarded it. The pre-existing direct SMTP transport test was also marked `Delivered` by NotiSend.
