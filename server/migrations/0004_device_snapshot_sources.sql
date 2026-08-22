-- Device-assisted monitoring stores only an allowlisted usage projection. It is independent
-- from account_monitoring_consent and monitored_accounts so opting in never uploads or mutates
-- provider credentials.
CREATE TABLE IF NOT EXISTS device_snapshot_consent (
  device_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  consent_revision INTEGER NOT NULL CHECK(consent_revision > 0),
  enabled INTEGER NOT NULL CHECK(enabled IN (0, 1)),
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (device_id, account_id),
  FOREIGN KEY (device_id) REFERENCES devices(device_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS device_snapshot_sources (
  device_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  provider_id TEXT NOT NULL,
  display_name TEXT,
  plan TEXT,
  refresh_interval_seconds INTEGER NOT NULL,
  history_retention_days INTEGER NOT NULL CHECK(history_retention_days BETWEEN 1 AND 3650),
  next_sequence INTEGER NOT NULL DEFAULT 1 CHECK(next_sequence > 0),
  last_payload_hash TEXT,
  latest_snapshot TEXT,
  last_observed_at INTEGER,
  last_upload_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (device_id, account_id),
  FOREIGN KEY (device_id) REFERENCES devices(device_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS device_snapshot_sources_freshness
ON device_snapshot_sources(last_observed_at, device_id, account_id);

CREATE TABLE IF NOT EXISTS device_snapshot_history (
  device_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  row_tag TEXT NOT NULL,
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
  UNIQUE (device_id, account_id, row_tag),
  FOREIGN KEY (device_id, account_id)
    REFERENCES device_snapshot_sources(device_id, account_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS device_snapshot_history_account_time
ON device_snapshot_history(device_id, account_id, recorded_at, metric_id);
