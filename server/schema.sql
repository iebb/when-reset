CREATE TABLE IF NOT EXISTS devices (
  device_id TEXT PRIMARY KEY NOT NULL,
  secret_hash TEXT NOT NULL,
  apns_token TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL,
  last_push_at INTEGER
);

CREATE INDEX IF NOT EXISTS devices_last_seen_at
ON devices(last_seen_at);

CREATE TABLE IF NOT EXISTS apns_provider_tokens (
  key_id TEXT PRIMARY KEY NOT NULL,
  token TEXT NOT NULL,
  issued_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS device_deletion_tombstones (
  device_id TEXT PRIMARY KEY NOT NULL,
  secret_hash TEXT NOT NULL,
  deleted_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS device_deletion_tombstones_deleted_at
ON device_deletion_tombstones(deleted_at);

CREATE TABLE IF NOT EXISTS link_sessions (
  session_id TEXT PRIMARY KEY NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  server_origin TEXT NOT NULL,
  display_name TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  consumed_at INTEGER,
  claimed_device_id TEXT
);

CREATE INDEX IF NOT EXISTS link_sessions_expires_at
ON link_sessions(expires_at);

CREATE TABLE IF NOT EXISTS account_monitoring_consent (
  device_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  consent_revision INTEGER NOT NULL CHECK(consent_revision > 0),
  enabled INTEGER NOT NULL CHECK(enabled IN (0, 1)),
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (device_id, account_id),
  FOREIGN KEY (device_id) REFERENCES devices(device_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS monitored_accounts (
  device_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  provider_id TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  plan TEXT,
  missing_quotas TEXT NOT NULL DEFAULT '[]',
  encrypted_credentials TEXT NOT NULL,
  credential_fingerprint TEXT,
  scheduled_monitor_at INTEGER,
  refresh_interval_seconds INTEGER NOT NULL,
  next_refresh_at INTEGER NOT NULL,
  last_refresh_at INTEGER,
  last_success_at INTEGER,
  last_error TEXT,
  latest_snapshot TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (device_id, account_id),
  FOREIGN KEY (device_id) REFERENCES devices(device_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS monitored_accounts_due
ON monitored_accounts(next_refresh_at, device_id, account_id);

CREATE INDEX IF NOT EXISTS monitored_accounts_credential_fingerprint
ON monitored_accounts(credential_fingerprint, next_refresh_at);

CREATE TABLE IF NOT EXISTS usage_history (
  device_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  provider_id TEXT NOT NULL,
  metric_id TEXT NOT NULL,
  metric_title TEXT NOT NULL,
  kind TEXT,
  window_minutes INTEGER,
  remaining_percent REAL NOT NULL,
  recorded_at INTEGER NOT NULL,
  resets_at INTEGER NOT NULL,
  seconds_until_reset REAL NOT NULL,
  plan TEXT,
  PRIMARY KEY (device_id, account_id, metric_id, recorded_at),
  FOREIGN KEY (device_id, account_id)
    REFERENCES monitored_accounts(device_id, account_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS usage_history_account_time
ON usage_history(device_id, account_id, recorded_at, metric_id);

CREATE TABLE IF NOT EXISTS monitor_runs (
  run_id TEXT PRIMARY KEY NOT NULL,
  occurrence_at INTEGER NOT NULL,
  credential_fingerprint TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('pending', 'running', 'fetched', 'succeeded', 'failed')),
  encrypted_result_credentials TEXT,
  result_snapshot TEXT,
  result_error TEXT,
  failure_retryable INTEGER CHECK(failure_retryable IN (0, 1)),
  created_at INTEGER NOT NULL,
  started_at INTEGER,
  fetched_at INTEGER,
  completed_at INTEGER,
  UNIQUE (occurrence_at, credential_fingerprint)
);

CREATE INDEX IF NOT EXISTS monitor_runs_created_at
ON monitor_runs(created_at);

CREATE TABLE IF NOT EXISTS monitor_run_targets (
  run_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  consent_revision INTEGER NOT NULL,
  credential_fingerprint TEXT NOT NULL,
  applied_at INTEGER,
  PRIMARY KEY (run_id, device_id, account_id),
  FOREIGN KEY (run_id) REFERENCES monitor_runs(run_id) ON DELETE CASCADE,
  FOREIGN KEY (device_id, account_id)
    REFERENCES monitored_accounts(device_id, account_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS monitor_run_targets_pending
ON monitor_run_targets(run_id, applied_at, device_id, account_id);

CREATE TRIGGER IF NOT EXISTS finalize_orphaned_monitor_run
AFTER DELETE ON monitor_run_targets
WHEN NOT EXISTS (
  SELECT 1 FROM monitor_run_targets WHERE run_id = OLD.run_id
)
BEGIN
  UPDATE monitor_runs SET
    status = 'succeeded',
    encrypted_result_credentials = NULL,
    result_snapshot = NULL,
    result_error = NULL,
    failure_retryable = NULL,
    completed_at = COALESCE(completed_at, occurrence_at)
  WHERE run_id = OLD.run_id;
END;
