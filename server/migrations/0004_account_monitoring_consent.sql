CREATE TABLE IF NOT EXISTS account_monitoring_consent (
  device_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  consent_revision INTEGER NOT NULL CHECK(consent_revision > 0),
  enabled INTEGER NOT NULL CHECK(enabled IN (0, 1)),
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (device_id, account_id),
  FOREIGN KEY (device_id) REFERENCES devices(device_id) ON DELETE CASCADE
);

INSERT OR IGNORE INTO account_monitoring_consent (
  device_id, account_id, consent_revision, enabled, updated_at
)
SELECT device_id, account_id, 1, 1, updated_at
FROM monitored_accounts;
