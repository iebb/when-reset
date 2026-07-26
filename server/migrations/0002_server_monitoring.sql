CREATE TABLE IF NOT EXISTS monitored_accounts (
  device_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  provider_id TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  plan TEXT,
  missing_quotas TEXT NOT NULL DEFAULT '[]',
  encrypted_credentials TEXT NOT NULL,
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
