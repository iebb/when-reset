#!/usr/bin/env bash
# Write the TestFlight update feed. This records a version and build only.
# It does not download, archive, or install an app binary.
#
# The iOS app reads the file from master, because that branch tracks released
# builds after they merge:
#   https://raw.githubusercontent.com/harrisliangsu/blinky-ios/master/update-check.json
#
# The App Store Release workflow runs this after a successful iOS TestFlight
# upload and opens a pull request. It does not push master. Until this script
# is on master, that job copies it out of the release commit first. To refresh
# the feed by hand, commit the file on a branch and open a pull request:
#
#   Scripts/bump-update-check.sh 1.8 31
#   git add update-check.json
#   git commit -m "Update iOS update-check feed to 1.8 (31)"
#
# Usage: Scripts/bump-update-check.sh VERSION BUILD [OUTPUT]

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  printf 'Usage: %s VERSION BUILD [OUTPUT]\n' "$0" >&2
  exit 2
fi

version="$1"
build="$2"
output="${3:-update-check.json}"

if [[ ! "$version" =~ ^[0-9A-Za-z.+-]+$ ]]; then
  printf 'Invalid marketing version: %s\n' "$version" >&2
  exit 2
fi

if [[ ! "$build" =~ ^[0-9]+$ ]]; then
  printf 'Build must be an integer: %s\n' "$build" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf 'python3 is required.\n' >&2
  exit 1
fi

updated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

python3 - "$output" "$version" "$build" "$updated_at" <<'PY'
import json
import sys

path, version, build, updated_at = sys.argv[1:5]
document = {
    "ios": {
        "version": version,
        "build": build,
        "updatedAt": updated_at,
    }
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2)
    handle.write("\n")
PY
