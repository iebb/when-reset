#!/usr/bin/env bash
# Destructive installation test for disposable CI hosts only. Never run on a real deployment.
set -euo pipefail
[[ "${WHEN_RESET_INSTALL_TEST:-}" == 1 ]] || { printf 'Set WHEN_RESET_INSTALL_TEST=1 on a disposable host.\n' >&2; exit 1; }
[[ $EUID -eq 0 ]] || { printf 'Run as root on a disposable host.\n' >&2; exit 1; }
[[ ! -e /etc/when-reset && ! -e /opt/when-reset ]] || { printf 'Refusing to overwrite an existing installation.\n' >&2; exit 1; }
server_source=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
trap 'systemctl disable --now when-reset.service >/dev/null 2>&1 || true' EXIT
bash "$server_source/install.sh" --source "$server_source" --origin https://reset.example
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

bash "$server_source/install.sh" --source "$server_source"
[[ "$before" == "$(sha256sum /etc/when-reset/server.env)" ]]
[[ "$first_release" != "$(readlink /opt/when-reset/current)" ]]
systemctl is-active --quiet when-reset.service
/opt/when-reset/current/node/bin/node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { readdirSync, statSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/var/lib/when-reset/when-reset.sqlite');
assert.equal(db.prepare('SELECT value FROM installation_test').get().value, 'preserved');
assert.equal(db.prepare('SELECT count(*) AS n FROM dashboard_sessions').get().n, 1);
db.close();
assert.equal(statSync('/etc/when-reset/server.env').mode & 0o777, 0o640);
assert.equal(statSync('/var/lib/when-reset/when-reset.sqlite').mode & 0o777, 0o600);
assert.equal(readdirSync('/var/backups/when-reset').filter(name => name.endsWith('.tar.gz')).length, 1);
JS
printf 'Linux installation, service startup, authenticated API and upgrade persistence passed.\n'
