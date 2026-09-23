#!/usr/bin/env bash
# Keep raw distribution logs private: Apple diagnostics can contain account data.
set +x +v
set -euo pipefail
umask 077

[[ $# -eq 3 ]] || { printf 'Usage: export-app-store.sh ARCHIVE EXPORT_DIRECTORY EXPORT_OPTIONS\n' >&2; exit 2; }
: "${ASC_KEY_PATH:?Missing ASC_KEY_PATH}"
: "${ASC_KEY_ID:?Missing ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?Missing ASC_ISSUER_ID}"
log_directory=$(mktemp -d)
trap 'rm -rf -- "$log_directory"' EXIT

for attempt in 1 2 3; do
  log="$log_directory/export-$attempt.log"
  printf 'Exporting signed archive (attempt %s of 3)...\n' "$attempt"
  if xcodebuild -exportArchive \
    -archivePath "$1" \
    -exportPath "$2/attempt-$attempt" \
    -exportOptionsPlist "$3" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" > "$log" 2>&1; then
    printf 'Archive signing and App Store Connect upload succeeded.\n'
    exit 0
  else
    status=$?
  fi

  # Never retry validation failures or an upload that may already have reached
  # Apple. The observed transient failure happens before upload, when Xcode
  # cannot parse the cloud-signing response and then finds no local certificate.
  if grep -Eqi 'Invalid Pre-Release Train|bundle is invalid|Validation failed|already been used' "$log"; then
    printf '::error::Apple rejected the app version or archive validation. This failure is not retried.\n' >&2
    exit "$status"
  fi
  if [[ "$status" -eq 70 ]] \
    && grep -Eq 'error: exportArchive The data couldn.*t be read because it isn.*t in the correct format' "$log" \
    && grep -Eq 'error: exportArchive No signing certificate "(iOS|Apple) Distribution" found' "$log" \
    && ! grep -Eqi 'Uploading|Upload (failed|succeeded)|Uploaded' "$log"; then
    if [[ "$attempt" -lt 3 ]]; then
      printf 'Cloud signing returned an unreadable response; retrying before any upload.\n'
      sleep "$((attempt * 15))"
      continue
    fi
    printf '::error::Cloud signing failed after three attempts. Check Apple service status and cloud-managed signing access.\n' >&2
  else
    printf '::error::Archive export failed (exit %s). No retry was attempted; check signing/provisioning and App Store upload status.\n' "$status" >&2
  fi
  exit "$status"
done
