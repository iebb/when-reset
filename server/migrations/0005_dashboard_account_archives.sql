-- Dashboard-only account removal can retain sanitized quota history for a future
-- re-add without retaining the provider credential.
CREATE TABLE IF NOT EXISTS dashboard_account_archives (
  device_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  provider_id TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  display_name TEXT,
  plan TEXT,
  plan_expires_at INTEGER,
  trial_expires_at INTEGER,
  missing_quotas TEXT NOT NULL DEFAULT '[]',
  latest_snapshot TEXT,
  last_refresh_at INTEGER,
  last_success_at INTEGER,
  refresh_interval_seconds INTEGER NOT NULL,
  history_retention_days INTEGER NOT NULL,
  archived_at INTEGER NOT NULL,
  PRIMARY KEY (device_id, account_id),
  FOREIGN KEY (device_id) REFERENCES devices(device_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS dashboard_account_archive_history (
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
    REFERENCES dashboard_account_archives(device_id, account_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS dashboard_account_archive_history_time
ON dashboard_account_archive_history(device_id, account_id, recorded_at, metric_id);
