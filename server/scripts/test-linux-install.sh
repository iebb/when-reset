#!/usr/bin/env bash
# Destructive installation test for disposable CI hosts only. Never run on a real deployment.
set +x +v
set -euo pipefail
umask 077
[[ "${WHEN_RESET_INSTALL_TEST:-}" == 1 ]] || { printf 'Set WHEN_RESET_INSTALL_TEST=1 on a disposable host.\n' >&2; exit 1; }
[[ $EUID -eq 0 ]] || { printf 'Run as root on a disposable host.\n' >&2; exit 1; }
[[ ! -e /etc/when-reset && ! -e /opt/when-reset ]] || { printf 'Refusing to overwrite an existing installation.\n' >&2; exit 1; }
server_source=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_logs=$(mktemp -d)
trap 'systemctl disable --now when-reset.service >/dev/null 2>&1 || true; rm -rf -- "$test_logs"' EXIT
# Deliberately enable tracing. Installer output must still never contain its keys.
# Keep captured output private and do not print it on failure.
bash -xv "$server_source/install.sh" --source "$server_source" --origin https://reset.example > "$test_logs/install.log" 2>&1
systemd-analyze verify /etc/systemd/system/when-reset.service
before=$(sha256sum /etc/when-reset/server.env)
first_release=$(readlink /opt/when-reset/current)

/opt/when-reset/current/node/bin/node --env-file=/etc/when-reset/server.env --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
const response = await fetch('http://127.0.0.1:8787/v1/dashboard/session', {
  method: 'POST',
  headers: { origin: process.env.PUBLIC_ORIGIN, 'x-when-reset-server-key': process.env.REGISTRATION_ACCESS_KEY },
});
assert.equal(response.status, 204);
assert.match(response.headers.get('set-cookie'), /Secure/);
const db = new DatabaseSync('/var/lib/when-reset/when-reset.sqlite');
db.exec("CREATE TABLE installation_test (value TEXT); INSERT INTO installation_test VALUES ('preserved')");
assert.equal(db.prepare('SELECT count(*) AS n FROM dashboard_sessions').get().n, 1);
db.close();
JS

bash -xv "$server_source/install.sh" --source "$server_source" > "$test_logs/upgrade.log" 2>&1
[[ "$before" == "$(sha256sum /etc/when-reset/server.env)" ]]
[[ "$first_release" != "$(readlink /opt/when-reset/current)" ]]
systemctl is-active --quiet when-reset.service
/opt/when-reset/current/node/bin/node --env-file=/etc/when-reset/server.env --input-type=module - "$test_logs" <<'JS'
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/var/lib/when-reset/when-reset.sqlite');
assert.equal(db.prepare('SELECT value FROM installation_test').get().value, 'preserved');
assert.equal(db.prepare('SELECT count(*) AS n FROM dashboard_sessions').get().n, 1);
db.close();
assert.equal(statSync('/etc/when-reset/server.env').mode & 0o777, 0o640);
assert.equal(statSync('/var/lib/when-reset/when-reset.sqlite').mode & 0o777, 0o600);
assert.equal(statSync('/var/lib/when-reset').mode & 0o777, 0o700);
assert.equal(statSync('/var/backups/when-reset').mode & 0o777, 0o700);
assert.equal(readdirSync('/var/backups/when-reset').filter(name => name.endsWith('.tar.gz')).length, 1);
for (const name of readdirSync('/var/backups/when-reset')) {
  assert.equal(statSync(`/var/backups/when-reset/${name}`).mode & 0o077, 0);
}
const logs = readdirSync(process.argv[2]).map(name => readFileSync(`${process.argv[2]}/${name}`, 'utf8')).join('\n')
  + execFileSync('journalctl', ['-u', 'when-reset', '--no-pager'], { encoding: 'utf8' });
for (const value of [process.env.REGISTRATION_ACCESS_KEY, process.env.CREDENTIAL_ENCRYPTION_KEY]) {
  assert.equal(logs.includes(value), false, 'Deployment secrets must not appear in installer or service logs.');
}
assert.equal(execFileSync('systemctl', ['show', 'when-reset', '--property=LimitCORE', '--value'], { encoding: 'utf8' }).trim(), '0');
const accessDisplay = execFileSync('script', ['-qec',
  '/opt/when-reset/current/node/bin/node --env-file=/etc/when-reset/server.env /opt/when-reset/current/app/show-access-key.mjs',
  '/dev/null'], { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] });
assert.equal(accessDisplay.includes(process.env.REGISTRATION_ACCESS_KEY), true, 'Interactive helper must show the recovery key.');
assert.equal(accessDisplay.includes(process.env.CREDENTIAL_ENCRYPTION_KEY), false, 'Interactive helper must never show the encryption key.');
JS
printf 'Linux installation, authenticated API, upgrade persistence and secret isolation passed.\n'
