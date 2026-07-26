CREATE TABLE IF NOT EXISTS device_deletion_tombstones (
  device_id TEXT PRIMARY KEY NOT NULL,
  secret_hash TEXT NOT NULL,
  deleted_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS device_deletion_tombstones_deleted_at
ON device_deletion_tombstones(deleted_at);
