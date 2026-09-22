#!/usr/bin/env bash
# Disable inherited tracing before generating or reading deployment secrets.
set +x +v
set -euo pipefail
umask 077

usage() {
  cat <<'HELP'
Usage: sudo bash install.sh --origin https://reset.example.com [--source /path/to/server]

Install or update When Reset on a systemd Linux server (x86_64 or arm64).
Debian/Ubuntu and Fedora/RHEL-family prerequisites are installed automatically.
Node.js 24 is installed privately under /opt/when-reset, leaving system Node alone.
Run the same command to update; existing secrets and database are preserved.
--origin is optional on updates. Configure HTTPS with your reverse proxy separately.
HELP
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
origin=""
source_dir=""
while (($#)); do
  case "$1" in
    --origin) (($# >= 2)) || fail '--origin requires a value'; origin="$2"; shift 2 ;;
    --source) (($# >= 2)) || fail '--source requires a value'; source_dir="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done
[[ $(uname -s) == Linux ]] || fail 'This installer requires Linux.'
[[ $EUID -eq 0 ]] || fail 'Run the installer with sudo.'
if [[ ! -d /run/systemd/system ]] || ! command -v systemctl >/dev/null; then
  fail 'A running systemd installation is required.'
fi
if [[ -n "$origin" ]]; then
  [[ "$origin" =~ ^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?/?$ ]] || fail 'Use an HTTPS hostname origin without a path.'
  origin="${origin%/}"
fi
[[ -f /etc/when-reset/server.env || -n "$origin" ]] || fail '--origin is required on the first installation.'
case $(uname -m) in
  x86_64) arch=x64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) fail 'Supported CPU architectures are x86_64 and arm64.' ;;
esac

missing=0
for dependency in curl tar xz sha256sum openssl flock runuser useradd; do
  command -v "$dependency" >/dev/null || missing=1
done
if ((missing)); then
  if command -v apt-get >/dev/null; then
    apt-get update
    apt-get install -y ca-certificates curl tar xz-utils openssl util-linux passwd
  elif command -v dnf >/dev/null; then
    dnf install -y ca-certificates curl tar xz openssl util-linux shadow-utils
  else
    fail 'Install curl, tar, xz, sha256sum, openssl, util-linux and useradd, then retry.'
  fi
fi
exec 9>/run/lock/when-reset-install.lock
flock -n 9 || fail 'Another When Reset installation is running.'
work_dir=$(mktemp -d)
staged_env=""
trap 'rm -rf -- "$work_dir"; if [[ -n "$staged_env" ]]; then rm -f -- "$staged_env"; fi' EXIT
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -z "$source_dir" && -f "$script_dir/package.json" && -d "$script_dir/src" ]]; then
  source_dir="$script_dir"
fi
if [[ -z "$source_dir" ]]; then
  printf 'Downloading When Reset from master...\n'
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    https://github.com/iebb/when-reset/archive/refs/heads/master.tar.gz -o "$work_dir/source.tar.gz"
  mkdir "$work_dir/source"
  tar -xzf "$work_dir/source.tar.gz" --strip-components=1 -C "$work_dir/source"
  source_dir="$work_dir/source/server"
fi
[[ -f "$source_dir/package-lock.json" && -f "$source_dir/deploy/when-reset.service" ]] || fail 'Invalid server source directory.'

printf 'Preparing a private Node.js 24 runtime...\n'
node_base=https://nodejs.org/dist/latest-v24.x
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  "$node_base/SHASUMS256.txt" -o "$work_dir/SHASUMS256.txt"
node_archive=$(awk -v arch="$arch" '$2 ~ ("^node-v24\\.[0-9]+\\.[0-9]+-linux-" arch "\\.tar\\.xz$") { print $2 }' "$work_dir/SHASUMS256.txt")
[[ "$node_archive" =~ ^node-v24\.[0-9]+\.[0-9]+-linux-(x64|arm64)\.tar\.xz$ ]] || fail 'Could not resolve the Node.js 24 archive.'
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  "$node_base/$node_archive" -o "$work_dir/$node_archive"
(
  cd "$work_dir"
  awk -v archive="$node_archive" '$2 == archive' SHASUMS256.txt | sha256sum --check --status
) || fail 'Node.js checksum verification failed.'
runtime_dir="/opt/when-reset/runtimes/${node_archive%.tar.xz}"
install -d -m 0755 /opt/when-reset /opt/when-reset/runtimes /opt/when-reset/releases
if [[ ! -x "$runtime_dir/bin/node" ]]; then
  mkdir "$work_dir/node"
  tar -xJf "$work_dir/$node_archive" --strip-components=1 -C "$work_dir/node"
  chmod -R a+rX "$work_dir/node"
  mv "$work_dir/node" "$runtime_dir"
fi
export PATH="$runtime_dir/bin:$PATH"

# Build a copy so running this script never rewrites the caller's checkout.
mkdir "$work_dir/build"
for item in package.json package-lock.json src linux scripts apns schema.sql migrations; do
  cp -R "$source_dir/$item" "$work_dir/build/"
done
printf 'Building the Linux server...\n'
(
  cd "$work_dir/build"
  npm ci --no-audit --no-fund
  npm run build:linux
)
id when-reset >/dev/null 2>&1 || useradd --system --user-group --home-dir /var/lib/when-reset --shell /usr/sbin/nologin when-reset
install -d -m 0750 -o root -g when-reset /etc/when-reset
install -d -m 0700 -o when-reset -g when-reset /var/lib/when-reset
stamp=$(date -u +%Y%m%dT%H%M%SZ)
release_dir=$(mktemp -d "/opt/when-reset/releases/$stamp-XXXXXX")
mv "$work_dir/build/dist" "$release_dir/app"
ln -s "$runtime_dir" "$release_dir/node"
chmod -R a+rX "$release_dir"

backup=""
if [[ -f /etc/when-reset/server.env ]]; then
  cp /etc/when-reset/server.env "$work_dir/server.env"
  if [[ -n "$origin" ]]; then
    sed "s|^PUBLIC_ORIGIN=.*|PUBLIC_ORIGIN=$origin|" /etc/when-reset/server.env > "$work_dir/server.env"
  fi
else
  {
    printf 'PUBLIC_ORIGIN=%s\nHOST=127.0.0.1\nPORT=8787\nDATA_DIR=/var/lib/when-reset\n' "$origin"
    printf 'REGISTRATION_ACCESS_KEY=%s\n' "$(openssl rand -hex 32)"
    printf 'CREDENTIAL_ENCRYPTION_KEY=%s\n' "$(openssl rand -hex 32)"
  } > "$work_dir/server.env"
fi
staged_env=$(mktemp /etc/when-reset/server.env.XXXXXX)
install -m 0640 -o root -g when-reset "$work_dir/server.env" "$staged_env"
printf 'Validating configuration before stopping the service...\n'
runuser -u when-reset -- env -i "$runtime_dir/bin/node" --env-file="$staged_env" "$release_dir/app/server.mjs" --check-config
port=$(runuser -u when-reset -- env -i "$runtime_dir/bin/node" --env-file="$staged_env" -e '
  if (require("node:path").resolve(process.env.DATA_DIR || "./data") !== "/var/lib/when-reset") {
    throw new Error("The managed installer requires DATA_DIR=/var/lib/when-reset");
  }
  console.log(process.env.PORT || "8787");
')
if [[ -f /etc/when-reset/server.env ]]; then
  printf 'Stopping the service and backing up configuration and data...\n'
  if [[ -f /etc/systemd/system/when-reset.service ]]; then systemctl stop when-reset.service; fi
  install -d -m 0700 /var/backups/when-reset
  backup="/var/backups/when-reset/${release_dir##*/}.tar.gz"
  tar --exclude="${staged_env#/}" -czf "$backup" -C / etc/when-reset var/lib/when-reset
  printf 'Pre-update backup: %s\n' "$backup"
fi

printf 'Applying database migrations...\n'
runuser -u when-reset -- env -i "$runtime_dir/bin/node" --env-file="$staged_env" "$release_dir/app/server.mjs" --migrate-only
mv -f "$staged_env" /etc/when-reset/server.env
staged_env=""
ln -sfn "$release_dir" /opt/when-reset/current.next
mv -Tf /opt/when-reset/current.next /opt/when-reset/current
install -m 0644 "$source_dir/deploy/when-reset.service" /etc/systemd/system/when-reset.service
systemctl daemon-reload
systemctl enable when-reset.service
systemctl restart when-reset.service
[[ "$port" =~ ^[0-9]+$ ]] || fail 'Invalid PORT in /etc/when-reset/server.env.'
ready=0
for ((attempt=0; attempt<30; attempt++)); do
  if curl --fail --silent --max-time 2 "http://127.0.0.1:$port/healthz" > "$work_dir/health.json"; then
    if node -e 'const fs = require("node:fs"); process.exit(JSON.parse(fs.readFileSync(process.argv[1])).ok === true ? 0 : 1)' "$work_dir/health.json"; then
      ready=1
      break
    fi
  fi
  sleep 1
done
if (( ! ready )); then
  systemctl stop when-reset.service
  [[ -z "$backup" ]] || printf 'Pre-update backup: %s\n' "$backup" >&2
  fail 'Health check failed. Inspect journalctl -u when-reset. Configuration and data have been preserved.'
fi
printf '\nWhen Reset is running on 127.0.0.1:%s.\n' "$port"
printf 'Configure your HTTPS reverse proxy to this address, then open PUBLIC_ORIGIN.\n'
printf 'Configuration and dashboard access key: /etc/when-reset/server.env (not printed).\n'
printf 'Logs: journalctl -u when-reset -f\n'
[[ -z "$backup" ]] || printf 'Pre-update backup: %s\n' "$backup"
