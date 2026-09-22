-- Keep plan transitions independently from quota rows. This lets the dashboard track
-- changes for accounts whose provider currently reports no quota windows.
CREATE TABLE IF NOT EXISTS account_plan_changes (
  change_id INTEGER PRIMARY KEY AUTOINCREMENT,
  source_kind TEXT NOT NULL CHECK(source_kind IN ('worker', 'device')),
  device_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  previous_plan TEXT NOT NULL,
  plan TEXT NOT NULL,
  changed_at INTEGER NOT NULL,
  FOREIGN KEY (device_id) REFERENCES devices(device_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS account_plan_changes_source_time
ON account_plan_changes(source_kind, device_id, account_id, changed_at);

CREATE TRIGGER IF NOT EXISTS monitored_account_plan_changed
AFTER UPDATE OF plan ON monitored_accounts
WHEN OLD.plan IS NOT NEW.plan
  AND OLD.plan IS NOT NULL AND trim(OLD.plan) <> ''
  AND NEW.plan IS NOT NULL AND trim(NEW.plan) <> ''
BEGIN
  INSERT INTO account_plan_changes (
    source_kind, device_id, account_id, previous_plan, plan, changed_at
  ) VALUES (
    'worker', NEW.device_id, NEW.account_id, OLD.plan, NEW.plan, NEW.updated_at
  );
END;

CREATE TRIGGER IF NOT EXISTS device_snapshot_plan_changed
AFTER UPDATE OF plan ON device_snapshot_sources
WHEN OLD.plan IS NOT NEW.plan
  AND OLD.plan IS NOT NULL AND trim(OLD.plan) <> ''
  AND NEW.plan IS NOT NULL AND trim(NEW.plan) <> ''
BEGIN
  INSERT INTO account_plan_changes (
    source_kind, device_id, account_id, previous_plan, plan, changed_at
  ) VALUES (
    'device', NEW.device_id, NEW.account_id, OLD.plan, NEW.plan,
    COALESCE(NEW.last_observed_at, NEW.updated_at)
  );
END;
