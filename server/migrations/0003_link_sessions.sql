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
