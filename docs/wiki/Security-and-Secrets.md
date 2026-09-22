# Security and secrets

The server uses provider credentials only for accounts explicitly opted in to monitoring.
Credential uploads are write-only, encrypted at rest with AES-256-GCM, and excluded from
dashboard, history, sync and push payloads. It must decrypt them in memory to contact the
provider. Trust the host, its administrators, installed code and HTTPS termination accordingly.

No implementation can promise that a compromised host or future vulnerability will never
leak a secret. The repository adds explicit disclosure tests and narrow operational defaults
to prevent accidental disclosure through its normal interfaces.

## Know which values are private

| Value | Purpose and handling |
| --- | --- |
| `REGISTRATION_ACCESS_KEY` | Dashboard recovery/admin access and device-link creation; store in a password manager |
| `CREDENTIAL_ENCRYPTION_KEY` | Decrypts stored provider credentials; keep with protected database backups and never enter it in the app |
| Provider tokens, API keys and sessions | Sent only to the selected trusted server and the relevant fixed provider endpoints |
| Device bearer secret and dashboard cookies | Authenticate clients; do not log, screenshot or share |
| APNs device tokens | Permit delivery to a device with the shared signing key; keep private |
| Bundled APNs signing key | Intentionally public and topic-restricted; the only private-key-file scanner exception |

Account names, usage history and APNs device tokens are not all encrypted at the application
layer. Filesystem permissions and encrypted disks/backups protect more than the credential
envelopes alone. Anyone with the database and its encryption key can decrypt the credentials.

## Defaults to retain

- Keep the backend on loopback behind trusted HTTPS. Never publish `/etc/when-reset`,
  `/var/lib/when-reset` or backups through a web-server file root.
- Keep the dedicated service user, environment-file ownership, directory permissions and
  systemd hardening. The service has no root privileges and has core dumps disabled.
- Do not enable shell tracing, Node's debugger/inspector, environment dumps, or request
  header/body logging. The installer disables inherited tracing before reading keys.
- Use the terminal-only dashboard-key helper from the quick start. Do not print the full
  environment file or place keys directly in shell arguments, URLs or command history.
- The supplied proxy examples omit access logs; audit inherited proxy/CDN tracing yourself.
  Custom `X-When-Reset-Server-Key` headers may not be covered by generic secret redaction.
- Worker invocation logs are disabled in the supplied Wrangler configuration. Application
  logs contain fixed events/status codes; external log sinks and live debugging have their
  own settings. Review them before collecting diagnostics.
- Keep hosts, Node.js, the server and TLS certificates updated. Review the installer and use
  a reviewed source commit when reproducibility is required. The installer trusts official
  Node downloads, this repository and its pinned npm dependency tree.

## Keys, passkeys and recovery

The installer preserves both keys during upgrades. Changing the dashboard key invalidates
existing browser sessions and enrolled dashboard passkeys, but **does not** revoke existing
device bearer secrets or rotate provider credentials. Use dashboard/device unlinking and
provider-side revocation when those credentials are compromised.

To rotate the dashboard key, edit the protected environment file on the server using your
secure administrative workflow, put in a new independently generated random value of at least
32 characters, preserve the encryption key exactly, and restart `when-reset`. Do not put
the new key in a shell command argument or an issue. Re-enroll dashboard passkeys afterward.

There is no online credential-key re-encryption command. Do not replace
`CREDENTIAL_ENCRYPTION_KEY` while stored credentials or pending monitoring results still need
it. To move to a new key, set up a fresh server/database and explicitly reauthorize accounts;
securely retire the previous instance after confirming the replacement works.

Passkeys are bound to the exact hostname, and the authenticator retains their private keys.
Keep the dashboard recovery key separately. Changing DNS names requires new enrollment.

## Backups and diagnostics

Follow [operations and backups](Operations-and-Backups.md). A backup that includes both
configuration and data is effectively a credential bundle. Encrypt it before off-host storage,
restrict recovery access and test restoration without exposing it to a public service.

For support, share only version/commit, OS/architecture, fixed event names, HTTP status codes
and a synthetic reproduction. Never upload `.env`, `.dev.vars`, `server.env`, SQLite files,
terminal recordings, request dumps or a backup archive. Screenshots of the locked dashboard
are safer than screenshots containing account details or link QR codes.

## Checks before publication

CI runs Gitleaks on full Git history, verifies private configuration files are untracked and
checks the exact bundled public-key fingerprint. Worker and Linux tests inject fake secret
canaries into provider errors, exception names and APNs errors. Linux installation tests also
check tracing output, journal output, filesystem permissions and key/data preservation on upgrade.

These are regression checks, not an assurance that every secret pattern is detectable. If a
real credential reaches Git or public logs, revoke/rotate it at its issuer promptly; deleting
the visible line or rewriting Git history alone does not make the credential safe again.
See the [security policy](https://github.com/iebb/when-reset/blob/master/SECURITY.md) for reporting.
