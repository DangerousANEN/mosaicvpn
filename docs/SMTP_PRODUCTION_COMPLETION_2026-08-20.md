# MosaicVPN — Production SMTP for Password Recovery

**Status:** Completed and validated on 20 August 2026.

## Result

MosaicVPN password-recovery emails are now enabled in production. The bot sends recovery codes through **NotiSend SMTP** from `noreply@zxc1x1.ru`, using STARTTLS on port `587`. NotiSend activated the SMTP/API key after its account review, and the full recovery delivery path has been confirmed by both the provider and Cloudflare Email Routing.

| Component | Production state |
|---|---|
| Transactional provider | NotiSend, activated for recipient addresses of MosaicVPN users |
| Sender domain | `zxc1x1.ru`, verified in NotiSend |
| Envelope/header sender | `noreply@zxc1x1.ru` |
| SMTP transport | `smtp.msndr.net:587` with STARTTLS |
| Bot configuration | Stored only in `/etc/mosaic-bot.env` with mode `0600` |
| Bot service | `mosaic-bot.service` active after restart |
| Inbound forwarding | Cloudflare Email Routing enabled and forwarding `noreply@zxc1x1.ru` to the verified technical inbox |

> SMTP credentials were written only to the protected VPS environment file. They were not written to the repository, website files, logs, or this report.

## Changes completed

The initial provider, RuSender, was abandoned for this purpose because its sender-verification process retained a permanent bounce state for `noreply@zxc1x1.ru` despite independently verified Cloudflare forwarding. NotiSend was selected because it supports domain-level DNS verification and authenticated SMTP for transactional email. Its API/SMTP workflow and configuration model are documented by the provider.[1]

The necessary DNS records were published in Cloudflare and both NotiSend verification stages completed successfully. Existing root SPF, Cloudflare-managed MX records, Cloudflare Email Routing DKIM, and the active forwarding rule were retained. Cloudflare Email Routing remains enabled and locked as expected for a managed routing configuration.[2]

During production validation, the VPS was found to be running an older `bot.py` that did not include the deployed password-account routes. This caused HTTP `404` responses for `/api/auth/register` and `/api/auth/recovery/start`. The current repository version was syntax-validated, installed atomically with a timestamped backup of the old file, and the bot was restarted. The updated process is active and listening on port `12223`.

## End-to-end validation

The following controlled checks were completed using `noreply@zxc1x1.ru`, which forwards to the verified technical destination.

| Check | Evidence | Result |
|---|---|---|
| TLS connectivity from VPS | SMTP TLS handshake with `smtp.msndr.net:465` completed and certificate verification passed | Passed |
| STARTTLS authentication | SMTP authentication to `smtp.msndr.net:587` returned `235 authentication ok` | Passed |
| Direct transport delivery | NotiSend accepted the technical message; provider marked it **Delivered** | Passed |
| Public registration API | `POST /api/auth/register` returned HTTP `201` | Passed |
| Public recovery API | `POST /api/auth/recovery/start` returned HTTP `202` | Passed |
| Bot error monitoring | No password-recovery SMTP error was recorded in the production journal | Passed |
| Provider transaction log | NotiSend recorded `MosaicVPN — восстановление пароля` for the technical recipient | Accepted for delivery |
| Final forwarding verification | Cloudflare Activity Log recorded that recovery message with result **Forwarded** | Passed |

The Cloudflare confirmation proves the actual production flow below, rather than only an SMTP connection test.

```text
Public recovery request
        ↓
MosaicVPN bot on VPS
        ↓
Authenticated STARTTLS SMTP via NotiSend
        ↓
NotiSend accepts the transactional message
        ↓
Cloudflare Email Routing receives it for noreply@zxc1x1.ru
        ↓
Forwarded to the verified technical destination
```

NotiSend may briefly label the recovery message as **Delivering** while recipient-level acknowledgement is pending. This does not block operation: Cloudflare independently recorded that it received and forwarded the message. The separate direct transport test has already advanced to **Delivered** in NotiSend.

## Security and operational notes

A temporary zero-day web account for `noreply@zxc1x1.ru` was created solely to execute the end-to-end recovery test. It has no active paid subscription. The temporary VPS SSH private key used for deployment was securely deleted from the working environment immediately after verification.

For normal operation, users can now open the website recovery form and request a code. The recovery route returns a generic success response regardless of whether an account exists, reducing account-enumeration risk. Codes remain single-use and expire under the existing bot policy.

The detailed implementation audit, exact non-secret DNS record history, and verification chronology remain in [`NOTISEND_DNS_SETUP_2026-08-19.md`](NOTISEND_DNS_SETUP_2026-08-19.md). This report intentionally excludes all SMTP credentials.

## References

[1]: https://notisend.ru/dev/email/api/ "NotiSend API and SMTP documentation"
[2]: https://developers.cloudflare.com/email-routing/ "Cloudflare Email Routing documentation"
