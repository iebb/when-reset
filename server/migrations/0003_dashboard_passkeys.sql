CREATE TABLE IF NOT EXISTS dashboard_session_authorizations (
  token_hash TEXT PRIMARY KEY NOT NULL,
  auth_method TEXT NOT NULL CHECK(auth_method IN ('access_key', 'passkey')),
  key_verified_until INTEGER,
  passkey_rp_id TEXT,
  FOREIGN KEY (token_hash) REFERENCES dashboard_sessions(token_hash) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS dashboard_webauthn_identities (
  rp_id TEXT PRIMARY KEY NOT NULL,
  user_handle TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS dashboard_passkeys (
  credential_id TEXT PRIMARY KEY NOT NULL,
  user_handle TEXT NOT NULL,
  rp_id TEXT NOT NULL,
  public_key BLOB NOT NULL,
  counter INTEGER NOT NULL CHECK(counter >= 0),
  transports_json TEXT NOT NULL DEFAULT '[]',
  access_key_generation TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  last_used_at INTEGER,
  FOREIGN KEY (rp_id) REFERENCES dashboard_webauthn_identities(rp_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS dashboard_passkeys_generation
ON dashboard_passkeys(rp_id, access_key_generation);

CREATE TABLE IF NOT EXISTS dashboard_webauthn_challenges (
  transaction_id TEXT PRIMARY KEY NOT NULL,
  purpose TEXT NOT NULL CHECK(purpose IN ('authentication', 'registration')),
  challenge TEXT NOT NULL,
  origin TEXT NOT NULL,
  rp_id TEXT NOT NULL,
  session_token_hash TEXT,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  consumed_at INTEGER,
  FOREIGN KEY (session_token_hash) REFERENCES dashboard_sessions(token_hash) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS dashboard_webauthn_challenges_expires_at
ON dashboard_webauthn_challenges(expires_at);
