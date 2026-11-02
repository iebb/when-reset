#!/usr/bin/env bash
# project.yml is the only file a version bump should edit.
# xcodegen copies MARKETING_VERSION and CURRENT_PROJECT_VERSION into
# WhenReset.xcodeproj/project.pbxproj. Config/WhenReset.xcconfig must not
# set either value, or a release can read a stale copy.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
yml="$root/project.yml"
pbx="$root/WhenReset.xcodeproj/project.pbxproj"
xcconfig="$root/Config/WhenReset.xcconfig"

marketing=$(awk -F'"' '/^[[:space:]]*MARKETING_VERSION:/ { print $2; exit }' "$yml")
build=$(awk -F'"' '/^[[:space:]]*CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$yml")

if [[ -z "$marketing" || -z "$build" ]]; then
  echo "project.yml must set MARKETING_VERSION and CURRENT_PROJECT_VERSION." >&2
  exit 1
fi
if [[ ! "$marketing" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "project.yml MARKETING_VERSION is not a numeric version: $marketing" >&2
  exit 1
fi
if [[ ! "$build" =~ ^[0-9]+$ ]]; then
  echo "project.yml CURRENT_PROJECT_VERSION is not an integer: $build" >&2
  exit 1
fi

if grep -E '^[[:space:]]*(MARKETING_VERSION|CURRENT_PROJECT_VERSION)[[:space:]]*=' "$xcconfig" >/dev/null; then
  echo "Config/WhenReset.xcconfig must not set MARKETING_VERSION or CURRENT_PROJECT_VERSION." >&2
  echo "Change them in project.yml, then run: xcodegen generate --spec project.yml" >&2
  exit 1
fi

mapfile -t marketing_values < <(grep -E 'MARKETING_VERSION = ' "$pbx" | sed -E 's/.*MARKETING_VERSION = ([^;]+);/\1/')
mapfile -t build_values < <(grep -E 'CURRENT_PROJECT_VERSION(\[[^]]+\])? = ' "$pbx" | sed -E 's/.*= ([^;]+);/\1/')

if [[ ${#marketing_values[@]} -eq 0 || ${#build_values[@]} -eq 0 ]]; then
  echo "project.pbxproj has no MARKETING_VERSION or CURRENT_PROJECT_VERSION." >&2
  echo "Run: xcodegen generate --spec project.yml" >&2
  exit 1
fi

for value in "${marketing_values[@]}"; do
  if [[ "$value" != "$marketing" ]]; then
    echo "project.pbxproj MARKETING_VERSION is $value; project.yml says $marketing." >&2
    echo "Run: xcodegen generate --spec project.yml" >&2
    exit 1
  fi
done
for value in "${build_values[@]}"; do
  if [[ "$value" != "$build" ]]; then
    echo "project.pbxproj CURRENT_PROJECT_VERSION is $value; project.yml says $build." >&2
    echo "Run: xcodegen generate --spec project.yml" >&2
    exit 1
  fi
done

echo "Version source is project.yml: $marketing ($build). project.pbxproj matches."
