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
