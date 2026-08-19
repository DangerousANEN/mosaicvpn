# RuSender DNS Verification — Pending

Created on 2026-08-19 for the MosaicVPN production password-recovery mailer.

The RuSender account `anen.online@gmail.com` was created with a 100-message transactional trial that expires on 2026-09-18. The sender domain `zxc1x1.ru` was registered in RuSender but remains unverified.

RuSender requires these DNS TXT records before it will issue an SMTP connection:

| Purpose | Type | Host | Value |
|---|---|---|---|
| DKIM | TXT | `mdmdmail._domainkey.zxc1x1.ru` | `v=DKIM1;k=rsa;p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA6E9v97dClcVw8R4Vi0RbOkCKCG4BEKiTNXDnwQA/nIIpjydk4FwAqAnfM6mFjAXSAqZt9E9+tWDxwjMkcwTaMN/r5HE+iOrNSrKArZJCTOZZr/adG0iAOI1Yoe+f6+QOchgfnI4wA4GVsut5iYUm+ZegeAgzEb57V972bQIwWGOGv3l+TkZg5b89cZuEOdLH0LPAx6vGxIOMItEp0rkli5MNpWSkqZLVkQx14K6vWFtsb353TpntE2m/uANM44NjOEGoesGkDyyZ37BMNmbOjxxJqwr/+ILAYeDnwC2mgrH71nML989IJ7JR2pBgP311c4nGzGL+ZArfwwneVZ+bewIDAQAB` |
| DMARC | TXT | `_dmarc.zxc1x1.ru` | `v=DMARC1; p=none; rua=mailto:postmaster@mx1.rusender-mail.ru` |
| SPF | TXT | `zxc1x1.ru` | `v=spf1 include:rsndr.ru ~all` |

## Safety notes

- Before adding SPF, inspect the existing root TXT records. If an SPF record already exists, its mechanisms must be merged into a single SPF record; publishing multiple SPF records is invalid.
- Verify whether an existing DMARC record is already published. If so, add the RuSender `rua` recipient only after retaining the current policy and reports.
- Do not publish duplicate DKIM records at the same selector.
- Once the records are published, wait for DNS propagation and use RuSender's **Проверить** control before creating the SMTP connection.
- The credentials generated later must be stored only in `/etc/mosaic-bot.env` with `chmod 600`, not in this repository.

## Cloudflare inspection on 2026-08-19

The user authorized access to the Cloudflare zone `zxc1x1.ru`. Before the proposed mail-authentication change, the zone had four records only: `host` A to `5.175.188.152`, plus `cdn`, `panel`, and `sub` CNAMEs. No TXT SPF, DKIM, or DMARC record existed, so the RuSender TXT records can be added without merging or replacing existing mail-authentication policies.

The planned change is therefore three **new, DNS-only, unproxied TXT records**:

1. `mdmdmail._domainkey` for RuSender DKIM;
2. `_dmarc` with monitoring-only policy `p=none`;
3. root `@` SPF with `include:rsndr.ru`.

No existing web-routing records will be changed or removed.

## Cloudflare Email Routing requirements discovered on 2026-08-19

RuSender requires e-mail verification of `noreply@zxc1x1.ru`; the domain currently has no mailbox. The user approved Cloudflare Email Routing as a forwarding-only inbox for this address, targeting `anen.online@gmail.com`.

Cloudflare Email Routing requires three MX records for `zxc1x1.ru` (priorities 25, 32, 87, values `route1.mx.cloudflare.net.`, `route2.mx.cloudflare.net.`, and `route3.mx.cloudflare.net.`) plus the DKIM TXT record named `cf2024-1._domainkey` supplied in the Cloudflare panel.

**Critical SPF merge:** Cloudflare’s default "Add missing records" would add a second root SPF TXT (`v=spf1 include:_spf.mx.cloudflare.net ~all`). The domain already has the valid RuSender SPF. Do not use that automatic action. Instead, retain one root SPF record and update it to include both providers, e.g. `v=spf1 include:rsndr.ru include:_spf.mx.cloudflare.net ~all`.

This routing service is required only so the RuSender sender-verification e-mail can be received. It must later contain one explicit route: `noreply@zxc1x1.ru` to `anen.online@gmail.com`; the default catch-all must remain disabled / Drop.

## Cloudflare Email Routing DKIM record (2026-08-19)

Name: `cf2024-1._domainkey.zxc1x1.ru`
Type: TXT
Value: `v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAiweykoi+o48IOGuP7GR3X0MOExCUDY/BCRHoWBnh3rChl7WhdyCxW3jgq1daEjPPqoi7sJvdg5hEQVsgVRQP4DcnQDVjGMbASQtrY4WmB1VebF+RPJB2ECPsEDTpeiI5ZyUAwJaVX7r6bznU67g7LvFq35yIo4sdlmtZGV+i0H4cpYH9+3JJ78km4KXwaf9xUJCWF6nxeD+qG6Fyruw1Qlbds2r85U9dkNDVAS3gioCvELryh1TxKGiVTkg4wqHTyHfWsp7KD3WQHYJn0RyfJJu6YEmL77zonn7p2SRMvTMP3ZEXibnC9gz3nnhR6wcYL8Q7zXypKTMD58bTixDSJwIDAQAB`

Note: The SPF record shown as "Missing" in Cloudflare's panel uses only `include:_spf.mx.cloudflare.net`, but our actual record already has the merged value `v=spf1 include:rsndr.ru include:_spf.mx.cloudflare.net ~all`. Cloudflare's panel does not match partial includes, so it shows "Missing" — this is expected and harmless. Do NOT use "Add missing records" as it would create a duplicate SPF.

## Email Routing provisioning status (2026-08-19)

The approved Cloudflare Email Routing MX records (route1/25, route2/32, route3/87) and DKIM record `cf2024-1._domainkey` are now present in the zone. The merged root SPF remains a single valid record: `v=spf1 include:rsndr.ru include:_spf.mx.cloudflare.net ~all`.

The Cloudflare Email Routing settings screen still marks all service records as `Missing`. This is a normal short propagation/verification delay after record creation. It must be rechecked later. Do not use `Add missing records`: it would create a conflicting second root SPF record.

## Browser reconnection and routing status (2026-08-19)

The user reconnected My Browser and Cloudflare authenticated access is restored. Cloudflare still shows Email Routing as `Disabled` and `Not configured`, even though public DNS-over-HTTPS returns all three required MX records and the published `cf2024-1._domainkey` record. The Cloudflare UI's `Add missing records` action must not be used without a new change review because it proposes its default SPF-only value and may create or overwrite the already-merged SPF record that authorizes RuSender.

## Controlled Cloudflare activation (2026-08-19)

After the user-approved `Add missing records` action, Cloudflare changed Email Routing to an internal `Syncing` state. Its MX and DKIM requirements are now shown as locked/managed, while the SPF row is shown as unlocked. This confirms the service accepted the MX/DKIM configuration; the root SPF still requires a final audit to ensure there remains only one record containing both `include:rsndr.ru` and `include:_spf.mx.cloudflare.net`.

## SPF reconciliation required after Cloudflare activation (2026-08-19)

The controlled Cloudflare activation successfully enabled Email Routing and locked the three MX records plus Cloudflare DKIM. It also replaced the root SPF value with only `v=spf1 include:_spf.mx.cloudflare.net ~all`. Public DNS confirms the same. The required next action is to edit that one root SPF record back to `v=spf1 include:rsndr.ru include:_spf.mx.cloudflare.net ~all`; there is only one SPF record, so no duplicate must be removed.

The Cloudflare managed activation created 11 records total and replaced—not duplicated—the prior SPF. The one root SPF TXT is now being edited back to the required merged value `v=spf1 include:rsndr.ru include:_spf.mx.cloudflare.net ~all`; the MX and Cloudflare DKIM records are Cloudflare-managed and locked.

## RuSender sender verification delivery failure (2026-08-19)

Cloudflare Email Routing is enabled and the explicit `noreply@zxc1x1.ru → anen.online@gmail.com` rule is active. The root SPF was restored to the one correct merged value. RuSender's re-sent verification e-mail nevertheless immediately returned a permanent `address does not exist / mail server permanently rejected delivery` error. No SMTP credentials were created and the VPS SMTP configuration remains unchanged. This requires diagnosis of external sender-domain validation or a different compatible transactional provider; do not resend the same verification message repeatedly.

## Manual routing test pending (2026-08-19)

The user sent a Gmail diagnostic message to `noreply@zxc1x1.ru`. Immediately after sending, Cloudflare Email Routing Activity Log had no entries and stated that logs can take up to two minutes. The service status remains Enabled, its DNS records Locked, and the explicit forwarding rule Active. Await log propagation before drawing conclusions.

## DNS-verified provider replacement assessment (2026-08-19)

Official NotiSend materials identify it as a Russian service with API and secure SMTP. Its documented sender-domain process is DNS based: add provider-issued records, use a `Проверить` action, then wait for domain registration. The service explicitly advises against public Gmail/Yandex/Mail.ru sender domains and supports custom-domain sender addresses. Sources: https://notisend.ru/ and https://blog.notisend.ru/domain/ .

NotiSend is selected as the replacement candidate because the current user-owned domain and working Cloudflare DNS access can support its documented DNS verification flow without requiring receipt of a verification email at the sender address.
