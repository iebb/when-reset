# Operations and backups

## Service and storage

| Path | Contents |
| --- | --- |
| `/etc/when-reset/server.env` | HTTPS origin, listen settings and two private keys; root:when-reset, mode 0640 |
| `/var/lib/when-reset/` | SQLite, its journal files, durable jobs and schedule state; mode 0700 |
| `/opt/when-reset/current` | Symlink to the active app release and its private Node.js runtime |
| `/opt/when-reset/releases/` | Retained application releases |
| `/opt/when-reset/runtimes/` | Retained Node.js runtimes |
| `/var/backups/when-reset/` | Protected pre-upgrade configuration/data backups |

Keep `DATA_DIR=/var/lib/when-reset` for the managed installer. Run one service per database,
on local disk. The unit uses an exclusive lock; SQLite files must not be shared across hosts.
Jobs survive restarts, but missing historical quota samples cannot be reconstructed. The
dashboard leaves gaps longer than 12 hours disconnected and records future plan transitions.

```bash
sudo systemctl status when-reset
curl --fail http://127.0.0.1:8787/healthz
sudo journalctl -u when-reset --since '30 minutes ago' --no-pager
sudo systemctl restart when-reset
```

Logs contain event names, counts and status codes. Do not use commands that dump the process
environment, full service configuration with expanded values, database rows or request headers.

## Upgrade

From a checkout:

```bash
git switch master
git pull --ff-only
sudo bash server/install.sh
```

For a standalone installation, download and review the installer again as in the quick start,
then run it without `--origin` to preserve the hostname. Existing keys and account data are
preserved. Configuration validation and the build run before stopping the old service. The
installer then stops it, creates a private backup, applies migrations and checks the new service.

If an upgrade fails, retain the printed backup path and inspect sanitized service logs. The
installer preserves backups and old releases; it does not automatically roll back database
migrations. Do not restart old code against an incompatible new schema. Record
`readlink /opt/when-reset/current` before upgrading if you want a specific code rollback target.

## Make a consistent backup

Run this on the server. It briefly stops monitoring and creates a root-only archive containing
the database **and its matching encryption key**. The archive is not itself encrypted.

```bash
sudo bash <<'SH'
set +x +v
set -euo pipefail
umask 077
install -d -m 0700 /var/backups/when-reset
systemctl stop when-reset
trap 'systemctl start when-reset' EXIT
archive="/var/backups/when-reset/manual-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
tar -czf "$archive" -C / etc/when-reset var/lib/when-reset
printf 'Backup saved to %s\n' "$archive"
SH
```

Encrypt any off-host copy using your organization's backup system and restrict who can decrypt
it. A disk snapshot containing both keys and data has the same sensitivity. Keep a tested
recovery copy, retain only the history you need, and never attach an archive to an issue.

## Restore or roll back

Use a trusted backup and compatible application release. On a replacement host, first install
the server to provision its dedicated user and runtime, then stop it. If rolling back a schema
migration, select the recorded pre-upgrade release in `/opt/when-reset/current` while the
service is stopped, before running the restore below. Backups do not contain application
releases or the private Node runtime.

Replace the example archive path with your own backup. This moves the stopped current data
and configuration into a private recovery directory before extraction, so old SQLite `-wal`
and `-shm` files cannot mix with the restored database. It then repairs ownership for the
current host's service user and starts the service.

```bash
sudo bash <<'SH'
set +x +v
set -euo pipefail
umask 077
archive=/var/backups/when-reset/CHOSEN-BACKUP.tar.gz
test -f "$archive"
systemctl stop when-reset
install -d -m 0700 /var/backups/when-reset
recovery=$(mktemp -d /var/backups/when-reset/before-restore-XXXXXX)
printf 'Previous state will be preserved in %s\n' "$recovery"
mv /var/lib/when-reset "$recovery/data"
mv /etc/when-reset "$recovery/config"
tar -xzf "$archive" -C / --no-same-owner
chown -R when-reset:when-reset /var/lib/when-reset
chmod 0700 /var/lib/when-reset
find /var/lib/when-reset -type f -exec chmod 0600 {} +
chown root:when-reset /etc/when-reset /etc/when-reset/server.env
chmod 0750 /etc/when-reset
chmod 0640 /etc/when-reset/server.env
systemctl start when-reset
printf 'Previous state preserved in %s\n' "$recovery"
SH
curl --fail http://127.0.0.1:8787/healthz
```

If extraction or validation fails, leave the service stopped, investigate the archive and
recover the previous directories from the printed recovery location before retrying.

Do not regenerate `CREDENTIAL_ENCRYPTION_KEY` during recovery. Restored session state may
include earlier access permissions; after an incident, rotate the dashboard key, re-enroll
passkeys and revoke/relink affected device/provider credentials as appropriate.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Service does not start | Environment file exists, keys differ and are long enough, directory ownership, port conflict, `journalctl` event |
| Local health works but HTTPS fails | Proxy upstream, DNS, firewall and certificate chain |
| Dashboard rejects login or actions | Exact `PUBLIC_ORIGIN`, browser hostname, trusted TLS, current recovery key |
| Passkey works on old hostname only | WebAuthn requires enrollment on the new hostname |
| Health is OK but no provider samples | Account consent, next five-minute boundary, credential validity, outbound provider access, backoff |
| Provider sees the device IP | Account is still refreshing locally; use its server-backed subscription |
| Notifications fail | Outbound Apple HTTP/2 access, valid production device token, push setting and Apple delivery |
| Database was copied from D1 | Direct D1 imports are unsupported; follow the migration guide |

## Stop or uninstall

```bash
sudo systemctl disable --now when-reset
sudo rm /etc/systemd/system/when-reset.service
sudo systemctl daemon-reload
```

This preserves keys, data, code and backups. Deleting those is a separate operator decision;
keep needed recovery material securely. Retire the reverse-proxy site and DNS when appropriate.
