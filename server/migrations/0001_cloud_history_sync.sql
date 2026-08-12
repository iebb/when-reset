ALTER TABLE monitored_accounts
ADD COLUMN history_retention_days INTEGER NOT NULL DEFAULT 35
CHECK(history_retention_days BETWEEN 1 AND 3650);

ALTER TABLE usage_history
ADD COLUMN row_tag TEXT;

ALTER TABLE usage_history
ADD COLUMN history_source TEXT NOT NULL DEFAULT 'worker'
CHECK(history_source IN ('worker', 'device'));

UPDATE usage_history
SET row_tag = 'legacy.' || lower(account_id) || '.' || hex(metric_id) || '.' || recorded_at
WHERE row_tag IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS usage_history_account_row_tag
ON usage_history(device_id, account_id, row_tag);
