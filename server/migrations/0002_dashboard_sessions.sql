CREATE TABLE IF NOT EXISTS dashboard_sessions (
  token_hash TEXT PRIMARY KEY NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS dashboard_sessions_expires_at
ON dashboard_sessions(expires_at);
