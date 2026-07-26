ALTER TABLE monitored_accounts
ADD COLUMN credential_fingerprint TEXT;

ALTER TABLE monitored_accounts
ADD COLUMN scheduled_monitor_at INTEGER;

CREATE INDEX IF NOT EXISTS monitored_accounts_credential_fingerprint
ON monitored_accounts(credential_fingerprint, next_refresh_at);

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
