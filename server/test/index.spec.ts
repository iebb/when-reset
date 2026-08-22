import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { testing } from "../src/index";
import { ProviderFetchError } from "../src/providers";

const deviceID = "019f724a-3414-4d52-ae37-0c7024a1ab97";
const deviceSecret = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
const apnsToken = "a".repeat(64);
const FIVE_MINUTES_SECONDS = 5 * 60;
const FIVE_MINUTES_MILLISECONDS = FIVE_MINUTES_SECONDS * 1_000;

beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare("DROP TABLE IF EXISTS device_snapshot_history"),
    env.DB.prepare("DROP TABLE IF EXISTS device_snapshot_sources"),
    env.DB.prepare("DROP TABLE IF EXISTS device_snapshot_consent"),
    env.DB.prepare("DROP TABLE IF EXISTS dashboard_account_archive_history"),
    env.DB.prepare("DROP TABLE IF EXISTS dashboard_account_archives"),
    env.DB.prepare("DROP TABLE IF EXISTS usage_history"),
    env.DB.prepare("DROP TABLE IF EXISTS monitor_run_targets"),
    env.DB.prepare("DROP TABLE IF EXISTS monitor_runs"),
    env.DB.prepare("DROP TABLE IF EXISTS remote_account_subscriptions"),
    env.DB.prepare("DROP TABLE IF EXISTS monitored_accounts"),
    env.DB.prepare("DROP TABLE IF EXISTS account_monitoring_consent"),
    env.DB.prepare("DROP TABLE IF EXISTS dashboard_webauthn_challenges"),
    env.DB.prepare("DROP TABLE IF EXISTS dashboard_passkeys"),
    env.DB.prepare("DROP TABLE IF EXISTS dashboard_webauthn_identities"),
    env.DB.prepare("DROP TABLE IF EXISTS dashboard_session_authorizations"),
    env.DB.prepare("DROP TABLE IF EXISTS dashboard_sessions"),
    env.DB.prepare("DROP TABLE IF EXISTS link_sessions"),
    env.DB.prepare("DROP TABLE IF EXISTS device_deletion_tombstones"),
    env.DB.prepare("DROP TABLE IF EXISTS devices"),
    env.DB.prepare(`CREATE TABLE devices (
      device_id TEXT PRIMARY KEY NOT NULL,
      secret_hash TEXT NOT NULL,
      apns_token TEXT NOT NULL UNIQUE,
      apns_environment TEXT NOT NULL DEFAULT 'production',
      created_at INTEGER NOT NULL,
      last_seen_at INTEGER NOT NULL,
      last_push_at INTEGER,
      push_disabled_at INTEGER
    )`),
    env.DB.prepare(`CREATE TABLE device_deletion_tombstones (
      device_id TEXT PRIMARY KEY NOT NULL,
      secret_hash TEXT NOT NULL,
      deleted_at INTEGER NOT NULL
    )`),
    env.DB.prepare(`CREATE TABLE link_sessions (
      session_id TEXT PRIMARY KEY NOT NULL,
      token_hash TEXT NOT NULL UNIQUE,
      server_origin TEXT NOT NULL,
      display_name TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL,
      consumed_at INTEGER,
      claimed_device_id TEXT
    )`),
    env.DB.prepare(`CREATE TABLE dashboard_sessions (
      token_hash TEXT PRIMARY KEY NOT NULL,
      created_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL
    )`),
    env.DB.prepare(`CREATE TABLE dashboard_session_authorizations (
      token_hash TEXT PRIMARY KEY NOT NULL,
      auth_method TEXT NOT NULL CHECK(auth_method IN ('access_key', 'passkey')),
      key_verified_until INTEGER,
      passkey_rp_id TEXT,
      FOREIGN KEY (token_hash) REFERENCES dashboard_sessions(token_hash) ON DELETE CASCADE
    )`),
    env.DB.prepare(`CREATE TABLE dashboard_webauthn_identities (
      rp_id TEXT PRIMARY KEY NOT NULL,
      user_handle TEXT NOT NULL UNIQUE,
      created_at INTEGER NOT NULL
    )`),
    env.DB.prepare(`CREATE TABLE dashboard_passkeys (
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
    )`),
    env.DB.prepare(`CREATE TABLE dashboard_webauthn_challenges (
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
    )`),
    env.DB.prepare(`CREATE TABLE account_monitoring_consent (
      device_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
      consent_revision INTEGER NOT NULL CHECK(consent_revision > 0),
      enabled INTEGER NOT NULL CHECK(enabled IN (0, 1)),
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (device_id, account_id),
      FOREIGN KEY (device_id) REFERENCES devices(device_id) ON DELETE CASCADE
    )`),
    env.DB.prepare(`CREATE TABLE device_snapshot_consent (
      device_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
      consent_revision INTEGER NOT NULL CHECK(consent_revision > 0),
      enabled INTEGER NOT NULL CHECK(enabled IN (0, 1)),
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (device_id, account_id),
      FOREIGN KEY (device_id) REFERENCES devices(device_id) ON DELETE CASCADE
    )`),
    env.DB.prepare(`CREATE TABLE device_snapshot_sources (
      device_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
      provider_id TEXT NOT NULL,
      display_name TEXT,
      plan TEXT,
      refresh_interval_seconds INTEGER NOT NULL,
      history_retention_days INTEGER NOT NULL,
      next_sequence INTEGER NOT NULL DEFAULT 1 CHECK(next_sequence > 0),
      last_payload_hash TEXT,
      latest_snapshot TEXT,
      last_observed_at INTEGER,
      last_upload_at INTEGER,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (device_id, account_id),
      FOREIGN KEY (device_id) REFERENCES devices(device_id) ON DELETE CASCADE
    )`),
    env.DB.prepare(`CREATE TABLE monitored_accounts (
      device_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
      provider_id TEXT NOT NULL,
      workspace_id TEXT NOT NULL,
      display_name TEXT,
      profile_name TEXT,
      email TEXT,
      plan TEXT,
      plan_expires_at INTEGER,
      trial_expires_at INTEGER,
      missing_quotas TEXT NOT NULL DEFAULT '[]',
      encrypted_credentials TEXT NOT NULL,
      credential_fingerprint TEXT,
      credential_revision INTEGER NOT NULL CHECK(credential_revision > 0),
      scheduled_monitor_at INTEGER,
      refresh_interval_seconds INTEGER NOT NULL,
      history_retention_days INTEGER NOT NULL DEFAULT 35,
      next_refresh_at INTEGER NOT NULL,
      last_refresh_at INTEGER,
      last_success_at INTEGER,
      last_error TEXT,
      consecutive_failures INTEGER NOT NULL DEFAULT 0 CHECK(consecutive_failures >= 0),
      latest_snapshot TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (device_id, account_id),
      FOREIGN KEY (device_id) REFERENCES devices(device_id) ON DELETE CASCADE
    )`),
    env.DB.prepare(`CREATE TABLE remote_account_subscriptions (
      subscriber_device_id TEXT NOT NULL,
      local_account_id TEXT NOT NULL,
      source_device_id TEXT NOT NULL,
      source_account_id TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      PRIMARY KEY (subscriber_device_id, local_account_id),
      UNIQUE (subscriber_device_id, source_device_id, source_account_id),
      FOREIGN KEY (subscriber_device_id) REFERENCES devices(device_id) ON DELETE CASCADE,
      FOREIGN KEY (source_device_id, source_account_id)
        REFERENCES monitored_accounts(device_id, account_id) ON DELETE CASCADE
    )`),
    env.DB.prepare(`CREATE TABLE dashboard_account_archives (
      device_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
      provider_id TEXT NOT NULL,
      workspace_id TEXT NOT NULL,
      display_name TEXT,
      plan TEXT,
      plan_expires_at INTEGER,
      trial_expires_at INTEGER,
      missing_quotas TEXT NOT NULL DEFAULT '[]',
      latest_snapshot TEXT,
      last_refresh_at INTEGER,
      last_success_at INTEGER,
      refresh_interval_seconds INTEGER NOT NULL,
      history_retention_days INTEGER NOT NULL,
      archived_at INTEGER NOT NULL,
      PRIMARY KEY (device_id, account_id),
      FOREIGN KEY (device_id) REFERENCES devices(device_id) ON DELETE CASCADE
    )`),
    env.DB.prepare(`CREATE TABLE dashboard_account_archive_history (
      device_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
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
      FOREIGN KEY (device_id, account_id)
        REFERENCES dashboard_account_archives(device_id, account_id) ON DELETE CASCADE
    )`),
    env.DB.prepare(`CREATE TABLE monitor_runs (
      run_id TEXT PRIMARY KEY NOT NULL,
      occurrence_at INTEGER NOT NULL,
      credential_fingerprint TEXT NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('pending', 'running', 'fetched', 'succeeded', 'failed')),
      encrypted_result_credentials TEXT,
      result_snapshot TEXT,
      result_error TEXT,
      failure_retryable INTEGER CHECK(failure_retryable IN (0, 1)),
      failure_retry_after_seconds INTEGER CHECK(failure_retry_after_seconds >= 0),
      created_at INTEGER NOT NULL,
      started_at INTEGER,
      fetched_at INTEGER,
      completed_at INTEGER,
      UNIQUE (occurrence_at, credential_fingerprint)
    )`),
    env.DB.prepare(`CREATE TABLE monitor_run_targets (
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
    )`),
    env.DB.prepare(`CREATE TRIGGER finalize_orphaned_monitor_run
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
          failure_retry_after_seconds = NULL,
          completed_at = COALESCE(completed_at, occurrence_at)
        WHERE run_id = OLD.run_id;
      END`),
    env.DB.prepare(`CREATE TABLE usage_history (
      device_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
      row_tag TEXT,
      history_source TEXT NOT NULL DEFAULT 'worker',
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
      FOREIGN KEY (device_id, account_id)
        REFERENCES monitored_accounts(device_id, account_id) ON DELETE CASCADE
    )`),
    env.DB.prepare(`CREATE UNIQUE INDEX usage_history_account_row_tag
      ON usage_history(device_id, account_id, row_tag)`),
    env.DB.prepare(`CREATE TABLE device_snapshot_history (
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
    )`),
  ]);
});

type LinkSessionResponse = {
  version: number;
  session_id: string;
  server_origin: string;
  display_name: string;
  expires_at: number;
  link_uri: string;
  qr_svg: string;
};

async function createLinkSession(): Promise<LinkSessionResponse> {
  const response = await SELF.fetch("https://push.example/v1/link-sessions", {
    method: "POST",
    headers: { "x-when-reset-server-key": env.REGISTRATION_ACCESS_KEY },
  });
  expect(response.status).toBe(201);
  return response.json<LinkSessionResponse>();
}

async function registerDevice(
  id = deviceID,
  secret = deviceSecret,
  token = apnsToken,
): Promise<void> {
  const response = await SELF.fetch("https://push.example/v1/devices", {
    method: "POST",
    headers: { "x-when-reset-server-key": env.REGISTRATION_ACCESS_KEY },
    body: JSON.stringify({ device_id: id, device_secret: secret, apns_token: token }),
  });
  expect(response.ok).toBe(true);
}

function accountRequestBody(providerID = "chatgpt", consentRevision?: number) {
  return {
    provider_id: providerID,
    workspace_id: "workspace-123",
    display_name: "Worker account",
    plan: "Plus",
    metadata: {
      name: "Provider Person",
      email: "person@example.com",
      plan_expires_at: 2_000_000_000,
      trial_expires_at: 1_999_000_000,
    },
    refresh_interval_seconds: FIVE_MINUTES_SECONDS,
    history_retention_days: 35,
    ...(consentRevision === undefined ? {} : { consent_revision: consentRevision }),
    missing_quotas: [{
      metric_id: "weekly",
      title: "Weekly limit",
      kind: "weekly",
      window_minutes: 10_080,
      resets_at: 2_000_086_400,
    }],
    credentials: {
      access_token: "access-secret",
      refresh_token: "refresh-secret",
      id_token: "id-secret",
      expires_at: 2_000_000_000,
    },
  };
}

function linkToken(session: LinkSessionResponse): string {
  return new URL(session.link_uri).searchParams.get("token")!;
}

function claimURL(session: LinkSessionResponse): string {
  return `https://push.example/v1/link-sessions/${session.session_id}/claim`;
}

async function createDashboardSessionCookie(): Promise<string> {
  const response = await SELF.fetch("https://push.example/v1/dashboard/session", {
    method: "POST",
    headers: {
      origin: "https://push.example",
      "x-when-reset-server-key": env.REGISTRATION_ACCESS_KEY,
    },
  });
  expect(response.status).toBe(204);
  const setCookie = response.headers.get("set-cookie");
  expect(setCookie).toContain("__Host-when_reset_dashboard=");
  expect(setCookie).toContain("Path=/");
  expect(setCookie).toContain("Max-Age=43200");
  expect(setCookie).toContain("HttpOnly");
  expect(setCookie).toContain("Secure");
  expect(setCookie).toContain("SameSite=Strict");
  return setCookie!.split(";", 1)[0];
}

function testBase64URL(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function testBase64URLBytes(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/")
    + "=".repeat((4 - value.length % 4) % 4);
  return Uint8Array.from(atob(padded), (character) => character.charCodeAt(0));
}

function concatTestBytes(...values: Uint8Array[]): Uint8Array {
  const result = new Uint8Array(values.reduce((sum, value) => sum + value.length, 0));
  let offset = 0;
  for (const value of values) {
    result.set(value, offset);
    offset += value.length;
  }
  return result;
}

function coseES256PublicKey(x: Uint8Array, y: Uint8Array): Uint8Array {
  return Uint8Array.from([
    0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01,
    0x21, 0x58, 0x20, ...x,
    0x22, 0x58, 0x20, ...y,
  ]);
}

function cborText(value: string): Uint8Array {
  const bytes = new TextEncoder().encode(value);
  if (bytes.length >= 24) throw new Error("Test CBOR text is too long");
  return Uint8Array.from([0x60 + bytes.length, ...bytes]);
}

function cborBytes(value: Uint8Array): Uint8Array {
  if (value.length < 24) return Uint8Array.from([0x40 + value.length, ...value]);
  if (value.length <= 0xff) return Uint8Array.from([0x58, value.length, ...value]);
  if (value.length <= 0xffff) {
    return Uint8Array.from([0x59, value.length >> 8, value.length & 0xff, ...value]);
  }
  throw new Error("Test CBOR bytes are too long");
}

function cborMap(entries: Array<[Uint8Array, Uint8Array]>): Uint8Array {
  if (entries.length >= 24) throw new Error("Test CBOR map is too large");
  return concatTestBytes(Uint8Array.from([0xa0 + entries.length]),
    ...entries.flatMap(([key, value]) => [key, value]));
}

function uint32Bytes(value: number): Uint8Array {
  return Uint8Array.from([
    value >>> 24,
    value >>> 16,
    value >>> 8,
    value,
  ]);
}

function rawES256SignatureToDER(raw: Uint8Array): Uint8Array {
  if (raw.length !== 64) throw new Error("Unexpected test ES256 signature length");
  const integer = (component: Uint8Array): Uint8Array => {
    let first = 0;
    while (first < component.length - 1 && component[first] === 0) first += 1;
    const trimmed = component.slice(first);
    const positive = (trimmed[0] & 0x80) === 0 ? trimmed : Uint8Array.from([0, ...trimmed]);
    return Uint8Array.from([0x02, positive.length, ...positive]);
  };
  const r = integer(raw.slice(0, 32));
  const s = integer(raw.slice(32));
  return Uint8Array.from([0x30, r.length + s.length, ...r, ...s]);
}

describe("one-use Worker linking", () => {
  it("serves a same-origin monitoring dashboard with no-store security headers", async () => {
    for (const path of ["/", "/link"]) {
      const response = await SELF.fetch(`https://push.example${path}`);
      const body = await response.text();
      expect(response.status).toBe(200);
      expect(response.headers.get("cache-control")).toBe("no-store");
      expect(response.headers.get("content-security-policy")).toContain("default-src 'none'");
      expect(response.headers.get("referrer-policy")).toBe("no-referrer");
      expect(response.headers.get("x-frame-options")).toBe("DENY");
      expect(body).toContain("When Reset");
      expect(body).toContain("Open private dashboard");
      expect(body).toContain("push.example");
      expect(body).toContain("method=\"post\" action=\"/v1/dashboard/session\"");
      expect(body).toContain("X-When-Reset-Server-Key");
      expect(body).toContain("Your private session is still active");
      expect(body).not.toContain("#logout-button { display: none; }");
      expect(body).not.toContain(env.REGISTRATION_ACCESS_KEY);
    }
  });

  it("requires the admin key and creates a five-minute QR without exposing long-lived keys", async () => {
    expect((await SELF.fetch("https://push.example/v1/link-sessions", {
      method: "POST",
    })).status).toBe(401);
    expect((await SELF.fetch("https://push.example/v1/link-sessions", {
      method: "POST",
      headers: {
        origin: "https://malicious.example",
        "x-when-reset-server-key": env.REGISTRATION_ACCESS_KEY,
      },
    })).status).toBe(403);

    const before = Math.floor(Date.now() / 1_000);
    const session = await createLinkSession();
    const token = linkToken(session);
    const link = new URL(session.link_uri);
    expect(session).toMatchObject({
      version: 1,
      server_origin: "https://push.example",
      display_name: "push.example",
    });
    expect(session.session_id).toMatch(/^[0-9a-f-]{36}$/);
    expect(session.expires_at).toBeGreaterThanOrEqual(before + 299);
    expect(session.expires_at).toBeLessThanOrEqual(before + 301);
    expect(session.qr_svg).toMatch(/^<svg[\s>]/);
    expect(token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(link.protocol).toBe("whenreset:");
    expect(link.host).toBe("link-worker");
    expect(link.searchParams.get("v")).toBe("1");
    expect(link.searchParams.get("server")).toBe("https://push.example");
    expect(link.searchParams.get("session")).toBe(session.session_id);
    expect(link.searchParams.get("expires")).toBe(String(session.expires_at));
    const serialized = JSON.stringify(session);
    expect(serialized).not.toContain(env.REGISTRATION_ACCESS_KEY);
    expect(serialized).not.toContain(env.CREDENTIAL_ENCRYPTION_KEY);
    expect(serialized).not.toContain(deviceSecret);
    expect(serialized).not.toContain("access-secret");
    expect(serialized).not.toContain("refresh-secret");
    expect(serialized).not.toContain("id-secret");
    expect(session.link_uri).not.toContain("access_key");

    const row = await env.DB.prepare(
      "SELECT token_hash FROM link_sessions WHERE session_id = ?"
    ).bind(session.session_id).first<{ token_hash: string }>();
    expect(row?.token_hash).toBe(await testing.hashSecret(token));
    expect(row?.token_hash).not.toBe(token);
  });

  it("returns authenticated metadata without consuming the session", async () => {
    const session = await createLinkSession();
    const metadataURL = `https://push.example/v1/link-sessions/${session.session_id}`;
    expect((await SELF.fetch(metadataURL)).status).toBe(401);
    expect((await SELF.fetch(metadataURL, {
      headers: { authorization: `Bearer ${"z".repeat(43)}` },
    })).status).toBe(401);

    const response = await SELF.fetch(metadataURL, {
      headers: { authorization: `Bearer ${linkToken(session)}` },
    });
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({
      version: 1,
      mode: "self_hosted",
      topic: "ad.neko.when",
      server_origin: "https://push.example",
      display_name: "push.example",
      expires_at: session.expires_at,
    });
    expect(await env.DB.prepare(
      "SELECT consumed_at FROM link_sessions WHERE session_id = ?"
    ).bind(session.session_id).first<{ consumed_at: number | null }>()).toEqual({ consumed_at: null });
  });

  it("binds a link session to the Worker origin that created it", async () => {
    const session = await createLinkSession();
    const response = await SELF.fetch(
      `https://other.example/v1/link-sessions/${session.session_id}`,
      { headers: { authorization: `Bearer ${linkToken(session)}` } },
    );

    expect(response.status).toBe(403);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.has("access-control-allow-origin")).toBe(false);
    expect(await env.DB.prepare(
      "SELECT consumed_at FROM link_sessions WHERE session_id = ?"
    ).bind(session.session_id).first<{ consumed_at: number | null }>()).toEqual({ consumed_at: null });
  });

  it("rejects malformed and oversized claims without consuming the session", async () => {
    const session = await createLinkSession();
    const authorization = { authorization: `Bearer ${linkToken(session)}` };

    const malformed = await SELF.fetch(claimURL(session), {
      method: "POST",
      headers: authorization,
      body: "{}",
    });
    expect(malformed.status).toBe(400);

    const oversized = await SELF.fetch(claimURL(session), {
      method: "POST",
      headers: { ...authorization, "content-length": "3000" },
      body: "{}",
    });
    expect(oversized.status).toBe(400);
    expect(await env.DB.prepare(
      "SELECT consumed_at FROM link_sessions WHERE session_id = ?"
    ).bind(session.session_id).first<{ consumed_at: number | null }>()).toEqual({ consumed_at: null });
  });

  it("atomically registers one device, hashes its secret, and rejects replay", async () => {
    const session = await createLinkSession();
    const token = linkToken(session);
    const response = await SELF.fetch(claimURL(session), {
      method: "POST",
      headers: { authorization: `Bearer ${token}` },
      body: JSON.stringify({ device_id: deviceID, device_secret: deviceSecret, apns_token: apnsToken }),
    });
    expect(response.status).toBe(201);
    expect(await response.json()).toEqual({ ok: true });

    const device = await env.DB.prepare(
      "SELECT secret_hash, apns_token FROM devices WHERE device_id = ?"
    ).bind(deviceID).first<{ secret_hash: string; apns_token: string }>();
    expect(device).toEqual({ secret_hash: await testing.hashSecret(deviceSecret), apns_token: apnsToken });
    const storedSession = await env.DB.prepare(
      "SELECT consumed_at, claimed_device_id FROM link_sessions WHERE session_id = ?"
    ).bind(session.session_id).first<{ consumed_at: number; claimed_device_id: string }>();
    expect(storedSession?.consumed_at).toBeTypeOf("number");
    expect(storedSession?.claimed_device_id).toBe(deviceID);

    const replay = await SELF.fetch(claimURL(session), {
      method: "POST",
      headers: { authorization: `Bearer ${token}` },
      body: JSON.stringify({
        device_id: "019f724a-3414-4d52-ae37-0c7024a1ab99",
        device_secret: "C".repeat(43),
        apns_token: "c".repeat(64),
      }),
    });
    expect(replay.status).toBe(409);
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM devices")
      .first<{ count: number }>()).toEqual({ count: 1 });
  });

  it("allows only one of two concurrent claims", async () => {
    const session = await createLinkSession();
    const token = linkToken(session);
    const registrations = [
      { device_id: deviceID, device_secret: deviceSecret, apns_token: apnsToken },
      {
        device_id: "019f724a-3414-4d52-ae37-0c7024a1ab99",
        device_secret: "C".repeat(43),
        apns_token: "c".repeat(64),
      },
    ];
    const responses = await Promise.all(registrations.map((registration) => SELF.fetch(
      claimURL(session),
      {
        method: "POST",
        headers: { authorization: `Bearer ${token}` },
        body: JSON.stringify(registration),
      },
    )));
    expect(responses.map((response) => response.status).sort()).toEqual([201, 409]);
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM devices")
      .first<{ count: number }>()).toEqual({ count: 1 });
  });

  it("consumes a new link when the same authenticated device already exists", async () => {
    await registerDevice();
    const session = await createLinkSession();
    const response = await SELF.fetch(claimURL(session), {
      method: "POST",
      headers: { authorization: `Bearer ${linkToken(session)}` },
      body: JSON.stringify({
        device_id: deviceID,
        device_secret: deviceSecret,
        apns_token: "b".repeat(64),
      }),
    });
    expect(response.status).toBe(201);
    expect(await env.DB.prepare("SELECT apns_token FROM devices WHERE device_id = ?")
      .bind(deviceID).first<{ apns_token: string }>()).toEqual({ apns_token: "b".repeat(64) });
    expect(await env.DB.prepare(
      "SELECT claimed_device_id FROM link_sessions WHERE session_id = ? AND consumed_at IS NOT NULL"
    ).bind(session.session_id).first<{ claimed_device_id: string }>())
      .toEqual({ claimed_device_id: deviceID });
  });

  it("reassigns an APNs token during linking without deleting the previous device", async () => {
    await registerDevice();
    const session = await createLinkSession();
    const otherDeviceID = "019f724a-3414-4d52-ae37-0c7024a1ab99";
    const response = await SELF.fetch(claimURL(session), {
      method: "POST",
      headers: { authorization: `Bearer ${linkToken(session)}` },
      body: JSON.stringify({
        device_id: otherDeviceID,
        device_secret: "C".repeat(43),
        apns_token: apnsToken,
      }),
    });

    expect(response.status).toBe(201);
    expect(await response.json()).toEqual({ ok: true });
    expect(await env.DB.prepare("SELECT device_id FROM devices WHERE apns_token = ?")
      .bind(apnsToken).first<{ device_id: string }>()).toEqual({ device_id: otherDeviceID });
    expect(await env.DB.prepare(
      "SELECT apns_token, push_disabled_at FROM devices WHERE device_id = ?"
    ).bind(deviceID).first<{ apns_token: string; push_disabled_at: number | null }>())
      .toEqual({ apns_token: `retired:${deviceID}`, push_disabled_at: expect.any(Number) });
    expect(await env.DB.prepare(
      "SELECT claimed_device_id FROM link_sessions WHERE session_id = ? AND consumed_at IS NOT NULL"
    ).bind(session.session_id).first<{ claimed_device_id: string }>())
      .toEqual({ claimed_device_id: otherDeviceID });
  });

  it("rejects expired sessions and prunes them", async () => {
    const session = await createLinkSession();
    const expiredAt = Math.floor(Date.now() / 1_000) - 1;
    await env.DB.prepare("UPDATE link_sessions SET expires_at = ? WHERE session_id = ?")
      .bind(expiredAt, session.session_id).run();
    const metadata = await SELF.fetch(
      `https://push.example/v1/link-sessions/${session.session_id}`,
      { headers: { authorization: `Bearer ${linkToken(session)}` } },
    );
    expect(metadata.status).toBe(410);
    await testing.pruneLinkSessions(env, expiredAt + 1);
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM link_sessions")
      .first<{ count: number }>()).toEqual({ count: 0 });
  });
});

describe("credential-safe monitoring dashboard", () => {
  it("rejects any response field outside the dashboard endpoint allowlists", () => {
    expect(() => testing.assertDashboardResponseSafe({ email: "private@example.com" }, "overview"))
      .toThrow("Unsafe dashboard response field");
    expect(() => testing.assertDashboardResponseSafe({
      version: 1,
      generated_at: 0,
      summary: {
        accounts: 0,
        shown_accounts: 0,
        healthy: 0,
        attention: 0,
        unchecked: 0,
        last_success_at: null,
        nearest_reset_at: null,
        truncated: false,
      },
      devices: { total: 0, active: 0, push_disabled: 0, production: 0, development: 0 },
      runs: { pending: 0, running: 0, failed_24h: 0, succeeded_24h: 0, last_completed_at: null },
      accounts: [{
        id: "opaque",
        provider_id: "chatgpt",
        provider_name: "ChatGPT",
        display_name: "Account",
        plan: null,
        plan_expires_at: null,
        trial_expires_at: null,
        status: "unchecked",
        last_checked_at: null,
        last_success_at: null,
        next_refresh_at: null,
        refresh_interval_seconds: 300,
        history_retention_days: 35,
        source_count: 1,
        snapshot: { windows: [], reset_credits: [], credentials: "never" },
      }],
    }, "overview")).toThrow("Unsafe dashboard response field");
  });

  it("serves a locked dashboard shell and exchanges the server key for an HttpOnly session", async () => {
    const page = await SELF.fetch("https://push.example/");
    const html = await page.text();
    expect(page.status).toBe(200);
    expect(page.headers.get("cache-control")).toBe("no-store");
    expect(page.headers.get("content-security-policy")).toContain("default-src 'none'");
    expect(page.headers.get("x-robots-tag")).toBe("noindex, nofollow, noarchive");
    expect(html).toContain("When Reset");
    expect(html).toContain("dashboard");
    expect(html).toContain("Device upload");
    expect(html).toContain("Worker polling");
    expect(html).not.toContain(env.REGISTRATION_ACCESS_KEY);
    expect(html).not.toContain(env.CREDENTIAL_ENCRYPTION_KEY);

    expect((await SELF.fetch("https://push.example/v1/dashboard/session", {
      method: "POST",
      headers: { "x-when-reset-server-key": env.REGISTRATION_ACCESS_KEY },
    })).status).toBe(403);
    const wrongKey = await SELF.fetch("https://push.example/v1/dashboard/session", {
      method: "POST",
      headers: {
        origin: "https://push.example",
        "x-when-reset-server-key": "Z".repeat(43),
      },
    });
    expect(wrongKey.status).toBe(401);
    expect(wrongKey.headers.has("set-cookie")).toBe(false);
    expect((await SELF.fetch("https://push.example/v1/dashboard")).status).toBe(401);

    const cookie = await createDashboardSessionCookie();
    const token = cookie.slice(cookie.indexOf("=") + 1);
    expect(token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const stored = await env.DB.prepare("SELECT token_hash FROM dashboard_sessions")
      .first<{ token_hash: string }>();
    expect(stored?.token_hash).toBe(await testing.dashboardSessionHash(env, token));
    expect(stored?.token_hash).not.toBe(token);
    expect(await testing.dashboardSessionHash({
      REGISTRATION_ACCESS_KEY: "rotated-registration-access-key-value-1234567890",
    }, token)).not.toBe(stored?.token_hash);

    const dashboard = await SELF.fetch("https://push.example/v1/dashboard", {
      headers: { cookie },
    });
    expect(dashboard.status).toBe(200);
    expect(dashboard.headers.get("cache-control")).toBe("no-store");
    expect(dashboard.headers.has("access-control-allow-origin")).toBe(false);
    expect(await dashboard.json()).toMatchObject({
      version: 1,
      summary: { accounts: 0, shown_accounts: 0, healthy: 0, attention: 0, unchecked: 0 },
      devices: { total: 0 },
      accounts: [],
    });

    const link = await SELF.fetch("https://push.example/v1/link-sessions", {
      method: "POST",
      headers: { origin: "https://push.example", cookie },
    });
    expect(link.status).toBe(201);
    expect(JSON.stringify(await link.json())).not.toContain(env.REGISTRATION_ACCESS_KEY);

    const logout = await SELF.fetch("https://push.example/v1/dashboard/session", {
      method: "DELETE",
      headers: { origin: "https://push.example", cookie },
    });
    expect(logout.status).toBe(204);
    expect(logout.headers.get("set-cookie")).toContain("Max-Age=0");
    expect((await SELF.fetch("https://push.example/v1/dashboard", {
      headers: { cookie },
    })).status).toBe(401);
  });

  it("keeps passkey discovery public and lets an authenticated session manage passkeys safely", async () => {
    const publicMethods = await SELF.fetch("https://push.example/v1/dashboard/auth-methods");
    expect(publicMethods.status).toBe(200);
    expect(await publicMethods.json()).toEqual({ passkey_enabled: false });

    expect((await SELF.fetch("https://push.example/v1/dashboard/passkeys")).status).toBe(401);
    const cookie = await createDashboardSessionCookie();
    const summary = await SELF.fetch("https://push.example/v1/dashboard/passkeys", {
      headers: { cookie },
    });
    expect(await summary.json()).toEqual({ count: 0, can_manage: true });

    const options = await SELF.fetch(
      "https://push.example/v1/dashboard/passkeys/registration/options",
      { method: "POST", headers: { origin: "https://push.example", cookie } },
    );
    expect(options.status).toBe(200);
    const payload = await options.json<{
      transaction_id: string;
      options: Record<string, unknown> & {
        rp: { id: string };
        authenticatorSelection: Record<string, unknown>;
        user: { id: string };
        excludeCredentials?: unknown[];
      };
    }>();
    expect(payload.transaction_id).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(payload.options).toMatchObject({
      rp: { id: "push.example" },
      attestation: "none",
      timeout: 300_000,
      authenticatorSelection: {
        residentKey: "required",
        requireResidentKey: true,
        userVerification: "required",
      },
      pubKeyCredParams: [{ alg: -7, type: "public-key" }],
    });
    expect(payload.options.excludeCredentials ?? []).toEqual([]);
    const serialized = JSON.stringify(payload);
    expect(serialized).not.toContain(env.REGISTRATION_ACCESS_KEY);
    expect(serialized).not.toContain(env.CREDENTIAL_ENCRYPTION_KEY);

    const transaction = await env.DB.prepare(
      `SELECT origin, rp_id, session_token_hash FROM dashboard_webauthn_challenges
       WHERE transaction_id = ?`
    ).bind(payload.transaction_id).first<{
      origin: string;
      rp_id: string;
      session_token_hash: string | null;
    }>();
    expect(transaction).toEqual({
      origin: "https://push.example",
      rp_id: "push.example",
      session_token_hash: expect.stringMatching(/^[A-Za-z0-9_-]{43}$/),
    });

    await env.DB.prepare(
      "UPDATE dashboard_session_authorizations SET key_verified_until = 0"
    ).run();
    expect((await SELF.fetch(
      "https://push.example/v1/dashboard/passkeys/registration/options",
      { method: "POST", headers: {
        origin: "https://push.example", cookie, "content-length": "0",
      } },
    )).status).toBe(200);
    const wrongReverify = await SELF.fetch(
      "https://push.example/v1/dashboard/passkeys/reverify",
      {
        method: "POST",
        headers: {
          origin: "https://push.example",
          cookie,
          "x-when-reset-server-key": "Z".repeat(43),
        },
      },
    );
    expect(wrongReverify.status).toBe(401);
    expect((await SELF.fetch("https://push.example/v1/dashboard/passkeys/reverify", {
      method: "POST",
      headers: {
        origin: "https://push.example",
        cookie,
        "x-when-reset-server-key": env.REGISTRATION_ACCESS_KEY,
      },
    })).status).toBe(204);
  });

  it("advertises only current-generation RP passkeys and deletes only the current RP", async () => {
    const now = Math.floor(Date.now() / 1_000);
    const generation = await testing.dashboardAccessKeyGeneration(env);
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO dashboard_webauthn_identities (rp_id, user_handle, created_at)
         VALUES ('push.example', ?, ?), ('other.example', ?, ?)`
      ).bind("u".repeat(43), now, "v".repeat(43), now),
      env.DB.prepare(
        `INSERT INTO dashboard_passkeys (
           credential_id, user_handle, rp_id, public_key, counter, transports_json,
           access_key_generation, created_at
         ) VALUES (?, ?, 'push.example', ?, 0, '[]', ?, ?),
                  (?, ?, 'other.example', ?, 0, '[]', ?, ?)`
      ).bind(
        "c".repeat(43), "u".repeat(43), new Uint8Array([1]).buffer, generation, now,
        "d".repeat(43), "v".repeat(43), new Uint8Array([2]).buffer, generation, now,
      ),
    ]);
    expect(await (await SELF.fetch("https://push.example/v1/dashboard/auth-methods")).json())
      .toEqual({ passkey_enabled: true });
    expect(await (await SELF.fetch("https://new.example/v1/dashboard/auth-methods")).json())
      .toEqual({ passkey_enabled: false });

    const authOptions = await SELF.fetch(
      "https://push.example/v1/dashboard/passkeys/authentication/options",
      { method: "POST", headers: { origin: "https://push.example" } },
    );
    expect(authOptions.status).toBe(200);
    const authPayload = await authOptions.json<{
      transaction_id: string;
      options: Record<string, unknown>;
    }>();
    expect(authPayload.options).toMatchObject({
      rpId: "push.example",
      userVerification: "required",
      timeout: 300_000,
    });
    expect(authPayload.options).not.toHaveProperty("allowCredentials");

    const cookie = await createDashboardSessionCookie();
    expect((await SELF.fetch("https://push.example/v1/dashboard/passkeys", {
      method: "DELETE",
      headers: { origin: "https://push.example", cookie },
    })).status).toBe(204);
    expect(await env.DB.prepare(
      "SELECT rp_id FROM dashboard_passkeys ORDER BY rp_id"
    ).all<{ rp_id: string }>()).toMatchObject({ results: [{ rp_id: "other.example" }] });
  });

  it("atomically burns malformed passkey assertions so a transaction cannot be replayed", async () => {
    const now = Math.floor(Date.now() / 1_000);
    const generation = await testing.dashboardAccessKeyGeneration(env);
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO dashboard_webauthn_identities (rp_id, user_handle, created_at)
         VALUES ('push.example', ?, ?)`
      ).bind("u".repeat(43), now),
      env.DB.prepare(
        `INSERT INTO dashboard_passkeys (
           credential_id, user_handle, rp_id, public_key, counter, transports_json,
           access_key_generation, created_at
         ) VALUES (?, ?, 'push.example', ?, 0, '[]', ?, ?)`
      ).bind(
        "c".repeat(43), "u".repeat(43), new Uint8Array([1]).buffer, generation, now,
      ),
    ]);
    const options = await SELF.fetch(
      "https://push.example/v1/dashboard/passkeys/authentication/options",
      { method: "POST", headers: { origin: "https://push.example" } },
    );
    const payload = await options.json<{ transaction_id: string }>();
    const credential = {
      id: "c".repeat(43),
      rawId: "c".repeat(43),
      type: "public-key" as const,
      authenticatorAttachment: null,
      clientExtensionResults: {},
      response: {
        clientDataJSON: testBase64URL(new TextEncoder().encode(JSON.stringify({
          type: "webauthn.get",
          challenge: "wrong",
          origin: "https://push.example",
          crossOrigin: false,
        }))),
        authenticatorData: testBase64URL(new Uint8Array(37)),
        signature: testBase64URL(new Uint8Array([1])),
        userHandle: "u".repeat(43),
      },
    };
    const verify = () => SELF.fetch(
      "https://push.example/v1/dashboard/passkeys/authentication/verify",
      {
        method: "POST",
        headers: { origin: "https://push.example" },
        body: JSON.stringify({ transaction_id: payload.transaction_id, credential }),
      },
    );
    expect((await verify()).status).toBe(401);
    expect((await verify()).status).toBe(401);
    expect(await env.DB.prepare(
      "SELECT consumed_at FROM dashboard_webauthn_challenges WHERE transaction_id = ?"
    ).bind(payload.transaction_id).first<{ consumed_at: number | null }>())
      .toEqual({ consumed_at: expect.any(Number) });
  });

  it("verifies genuine ES256 registration and authentication ceremonies end to end", async () => {
    const keyPair = await crypto.subtle.generateKey(
      { name: "ECDSA", namedCurve: "P-256" },
      true,
      ["sign", "verify"],
    ) as CryptoKeyPair;
    const publicJWK = await crypto.subtle.exportKey("jwk", keyPair.publicKey);
    if (!publicJWK.x || !publicJWK.y) throw new Error("Test key is missing coordinates");
    expect(testBase64URLBytes(publicJWK.x)).toHaveLength(32);
    expect(testBase64URLBytes(publicJWK.y)).toHaveLength(32);
    const credentialIDBytes = Uint8Array.from(
      Array.from({ length: 32 }, (_, index) => index + 1),
    );
    expect(credentialIDBytes).toHaveLength(32);
    const credentialID = testBase64URL(credentialIDBytes);
    const rpIDHash = new Uint8Array(await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode("push.example"),
    ));

    const keyCookie = await createDashboardSessionCookie();
    const registrationOptionsResponse = await SELF.fetch(
      "https://push.example/v1/dashboard/passkeys/registration/options",
      { method: "POST", headers: { origin: "https://push.example", cookie: keyCookie } },
    );
    expect(registrationOptionsResponse.status).toBe(200);
    const registrationEnvelope = await registrationOptionsResponse.json<{
      transaction_id: string;
      options: { challenge: string; user: { id: string } };
    }>();
    const registrationClientData = new TextEncoder().encode(JSON.stringify({
      type: "webauthn.create",
      challenge: registrationEnvelope.options.challenge,
      origin: "https://push.example",
      crossOrigin: false,
    }));
    const cosePublicKey = coseES256PublicKey(
      testBase64URLBytes(publicJWK.x),
      testBase64URLBytes(publicJWK.y),
    );
    expect(cosePublicKey).toHaveLength(77);
    const registrationAuthenticatorData = concatTestBytes(
      rpIDHash,
      Uint8Array.from([0x45]),
      uint32Bytes(0),
      new Uint8Array(16),
      Uint8Array.from([0, credentialIDBytes.length]),
      credentialIDBytes,
      cosePublicKey,
    );
    expect(registrationAuthenticatorData).toHaveLength(164);
    expect(registrationAuthenticatorData[87]).toBe(0xa5);
    const attestationObject = cborMap([
      [cborText("fmt"), cborText("none")],
      [cborText("attStmt"), cborMap([])],
      [cborText("authData"), cborBytes(registrationAuthenticatorData)],
    ]);
    const registrationCredential = {
      id: credentialID,
      rawId: credentialID,
      type: "public-key" as const,
      clientExtensionResults: {},
      response: {
        clientDataJSON: testBase64URL(registrationClientData),
        attestationObject: testBase64URL(attestationObject),
      },
    };
    const registrationVerify = await SELF.fetch(
      "https://push.example/v1/dashboard/passkeys/registration/verify",
      {
        method: "POST",
        headers: {
          origin: "https://push.example",
          cookie: keyCookie,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          transaction_id: registrationEnvelope.transaction_id,
          credential: registrationCredential,
        }),
      },
    );
    const registrationChallengeState = await env.DB.prepare(
      "SELECT consumed_at FROM dashboard_webauthn_challenges WHERE transaction_id = ?"
    ).bind(registrationEnvelope.transaction_id).first<{ consumed_at: number | null }>();
    const registrationPasskeyCount = await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM dashboard_passkeys"
    ).first<{ count: number }>();
    expect({
      status: registrationVerify.status,
      challenge_consumed: registrationChallengeState?.consumed_at !== null,
      passkey_count: registrationPasskeyCount?.count,
    }).toEqual({ status: 204, challenge_consumed: true, passkey_count: 1 });
    const storedPasskey = await env.DB.prepare(
      `SELECT credential_id, user_handle, length(public_key) AS public_key_bytes, counter
       FROM dashboard_passkeys WHERE rp_id = 'push.example'`
    ).first<{
      credential_id: string;
      user_handle: string;
      public_key_bytes: number;
      counter: number;
    }>();
    expect(storedPasskey).toEqual({
      credential_id: credentialID,
      user_handle: registrationEnvelope.options.user.id,
      public_key_bytes: expect.any(Number),
      counter: 0,
    });
    expect(storedPasskey!.public_key_bytes).toBeGreaterThan(64);

    const authenticationOptions = async () => {
      const response = await SELF.fetch(
        "https://push.example/v1/dashboard/passkeys/authentication/options",
        { method: "POST", headers: { origin: "https://push.example" } },
      );
      expect(response.status).toBe(200);
      return response.json<{
        transaction_id: string;
        options: { challenge: string; rpId: string; userVerification: string };
      }>();
    };
    const signedAuthenticationCredential = async (
      challenge: string,
      counter: number,
    ) => {
      const clientData = new TextEncoder().encode(JSON.stringify({
        type: "webauthn.get",
        challenge,
        origin: "https://push.example",
        crossOrigin: false,
      }));
      const authenticatorData = concatTestBytes(
        rpIDHash,
        Uint8Array.from([0x05]),
        uint32Bytes(counter),
      );
      const clientDataHash = new Uint8Array(await crypto.subtle.digest("SHA-256", clientData));
      const rawSignature = new Uint8Array(await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" },
        keyPair.privateKey,
        new Uint8Array(concatTestBytes(authenticatorData, clientDataHash)),
      ));
      return {
        id: credentialID,
        rawId: credentialID,
        type: "public-key",
        clientExtensionResults: {},
        response: {
          clientDataJSON: testBase64URL(clientData),
          authenticatorData: testBase64URL(authenticatorData),
          signature: testBase64URL(rawES256SignatureToDER(rawSignature)),
          userHandle: registrationEnvelope.options.user.id,
        },
      };
    };
    const firstAuthentication = await authenticationOptions();
    expect(firstAuthentication.options).toEqual(expect.objectContaining({
      rpId: "push.example",
      userVerification: "required",
    }));
    const firstAssertion = await signedAuthenticationCredential(
      firstAuthentication.options.challenge,
      1,
    );
    const verifyAssertion = (transactionID: string, credential: unknown) => SELF.fetch(
      "https://push.example/v1/dashboard/passkeys/authentication/verify",
      {
        method: "POST",
        headers: { origin: "https://push.example", "content-type": "application/json" },
        body: JSON.stringify({ transaction_id: transactionID, credential }),
      },
    );
    const authenticationVerify = await verifyAssertion(
      firstAuthentication.transaction_id,
      firstAssertion,
    );
    expect(authenticationVerify.status).toBe(204);
    const sessionCookie = authenticationVerify.headers.get("set-cookie");
    expect(sessionCookie).toContain("__Host-when_reset_dashboard=");
    expect(sessionCookie).toContain("HttpOnly");
    expect(sessionCookie).toContain("Secure");
    expect(sessionCookie).toContain("SameSite=Strict");
    const passkeyCookie = sessionCookie!.split(";", 1)[0];
    expect((await SELF.fetch("https://push.example/v1/dashboard", {
      headers: { cookie: passkeyCookie },
    })).status).toBe(200);
    expect(await (await SELF.fetch("https://push.example/v1/dashboard/passkeys", {
      headers: { cookie: passkeyCookie },
    })).json()).toEqual({ count: 1, can_manage: true });
    expect(await env.DB.prepare(
      "SELECT counter FROM dashboard_passkeys WHERE credential_id = ?"
    ).bind(credentialID).first<{ counter: number }>()).toEqual({ counter: 1 });

    expect((await verifyAssertion(
      firstAuthentication.transaction_id,
      firstAssertion,
    )).status).toBe(401);

    const rollbackAuthentication = await authenticationOptions();
    const rollbackAssertion = await signedAuthenticationCredential(
      rollbackAuthentication.options.challenge,
      1,
    );
    expect((await verifyAssertion(
      rollbackAuthentication.transaction_id,
      rollbackAssertion,
    )).status).toBe(401);
    expect(await env.DB.prepare(
      "SELECT counter FROM dashboard_passkeys WHERE credential_id = ?"
    ).bind(credentialID).first<{ counter: number }>()).toEqual({ counter: 1 });
  });

  it("returns only allowlisted account, quota, balance, and history fields", async () => {
    await registerDevice();
    const accountID = "019f724a-3414-4d52-ae37-0c7024a1ab98";
    const accountURL = `https://push.example/v1/devices/${deviceID}/accounts/${accountID}`;
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody()),
    })).status).toBe(201);

    const now = Math.floor(Date.now() / 1_000);
    const rawAccountReference = "R".repeat(43);
    const snapshot = {
      provider_id: "chatgpt",
      plan: "Plus",
      fetched_at: now - 30,
      windows: [{
        position: 0,
        metric_id: "raw-weekly-metric",
        title: "Weekly limit",
        kind: "weekly",
        window_minutes: 10_080,
        remaining_percent: 62.5,
        resets_at: now + 3_600,
        credential: "snapshot-credential-canary",
      }],
      available_reset_count: 1,
      reset_credits: [{
        id: "raw-reset-credit-id",
        status: "available",
        granted_at: now - 60,
        expires_at: now + 7_200,
      }],
      api_balance: {
        title: "Monthly API budget",
        currency_code: "usd",
        spent: 12.5,
        limit: 50,
        remaining: 37.5,
        period_start: now - 86_400,
        period_end: now + 86_400,
        access_expires_at: null,
        is_unlimited: false,
        kind: "budget",
        unit_label: null,
        token: "balance-token-canary",
      },
      account_reference: rawAccountReference,
      credentials: { access_token: "snapshot-access-canary" },
    };
    await env.DB.prepare(
      `UPDATE monitored_accounts SET latest_snapshot = ?, last_refresh_at = ?,
         last_success_at = ?, next_refresh_at = ?, last_error = ?
       WHERE device_id = ? AND account_id = ?`
    ).bind(
      JSON.stringify(snapshot), now - 30, now - 30, now + 270,
      "provider failure credential-error-canary", deviceID, accountID,
    ).run();
    await env.DB.batch([now - 600, now - 300].map((recordedAt, index) => env.DB.prepare(
      `INSERT INTO usage_history (
         device_id, account_id, row_tag, history_source, provider_id,
         metric_id, metric_title, kind, window_minutes, remaining_percent,
         recorded_at, resets_at, seconds_until_reset, plan
       ) VALUES (?, ?, ?, 'worker', 'chatgpt', ?, ?, 'weekly', 10080, ?, ?, ?, ?, 'Plus')`
    ).bind(
      deviceID, accountID, `dashboard-${index}`, "raw-weekly-metric", "Weekly limit",
      70 - index * 5, recordedAt, now + 3_600, now + 3_600 - recordedAt,
    )));

    const storedPrivate = await env.DB.prepare(
      `SELECT encrypted_credentials, credential_fingerprint FROM monitored_accounts
       WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first<{
      encrypted_credentials: string;
      credential_fingerprint: string;
    }>();
    const cookie = await createDashboardSessionCookie();
    const response = await SELF.fetch("https://push.example/v1/dashboard", {
      headers: { cookie },
    });
    expect(response.status).toBe(200);
    const payload = await response.json<{
      accounts: Array<Record<string, unknown> & { id: string }>;
      summary: Record<string, unknown>;
    }>();
    expect(payload.accounts).toHaveLength(1);
    expect(payload.accounts[0]).toMatchObject({
      provider_id: "chatgpt",
      provider_name: "ChatGPT",
      display_name: "Worker account",
      plan: "Plus",
      status: "error",
      source_count: 1,
      snapshot: {
        windows: [expect.objectContaining({
          title: "Weekly limit",
          remaining_percent: 62.5,
        })],
        available_reset_count: 1,
        api_balance: expect.objectContaining({
          title: "Monthly API budget",
          currency_code: "USD",
          remaining: 37.5,
        }),
      },
    });
    expect(payload.accounts[0].id).toMatch(/^[A-Za-z0-9_-]{43}$/);

    const serialized = JSON.stringify(payload);
    for (const privateValue of [
      deviceID, accountID, "workspace-123", "person@example.com", "Provider Person",
      "access-secret", "refresh-secret", "id-secret", rawAccountReference,
      "raw-weekly-metric", "raw-reset-credit-id", "snapshot-credential-canary",
      "snapshot-access-canary", "balance-token-canary", "credential-error-canary",
      storedPrivate!.encrypted_credentials, storedPrivate!.credential_fingerprint,
      env.REGISTRATION_ACCESS_KEY, env.CREDENTIAL_ENCRYPTION_KEY,
    ]) {
      expect(serialized).not.toContain(privateValue);
    }
    for (const forbiddenField of [
      "credentials", "encrypted_credentials", "credential_fingerprint", "workspace_id",
      "device_id", "account_id", "email", "profile_name", "last_error",
    ]) {
      expect(payload.accounts[0]).not.toHaveProperty(forbiddenField);
    }

    const history = await SELF.fetch(
      `https://push.example/v1/dashboard/accounts/${payload.accounts[0].id}/history?range=24h`,
      { headers: { cookie } },
    );
    expect(history.status).toBe(200);
    const historyPayload = await history.json<{
      series: Array<{ id: string; title: string; points: unknown[] }>;
    }>();
    expect(historyPayload.series).toHaveLength(1);
    expect(historyPayload.series[0]).toMatchObject({
      title: "Weekly limit",
      points: expect.arrayContaining([
        expect.objectContaining({ remaining_percent: 70 }),
        expect.objectContaining({ remaining_percent: 65 }),
      ]),
    });
    expect(historyPayload.series[0].id).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const serializedHistory = JSON.stringify(historyPayload);
    expect(serializedHistory).not.toContain("raw-weekly-metric");
    expect(serializedHistory).not.toContain(deviceID);
    expect(serializedHistory).not.toContain(accountID);
    expect(serializedHistory).not.toContain("workspace-123");
  });

  it("groups duplicate account sources and deduplicates history before applying its limit", async () => {
    const accountID = "019f724a-3414-4d52-ae37-0c7024a1ab98";
    const secondDeviceID = "019f724a-3414-4d52-ae37-0c7024a1ab99";
    const secondSecret = "B".repeat(43);
    await registerDevice();
    await registerDevice(secondDeviceID, secondSecret, "b".repeat(64));
    for (const [id, secret] of [[deviceID, deviceSecret], [secondDeviceID, secondSecret]] as const) {
      expect((await SELF.fetch(`https://push.example/v1/devices/${id}/accounts/${accountID}`, {
        method: "PUT",
        headers: { authorization: `Bearer ${secret}` },
        body: JSON.stringify(accountRequestBody()),
      })).status).toBe(201);
    }

    const now = Math.floor(Date.now() / 1_000);
    const recordedAt = now - 300;
    const snapshot = JSON.stringify({
      provider_id: "chatgpt",
      fetched_at: now - 30,
      windows: [],
      available_reset_count: 0,
      reset_credits: [],
      account_reference: "R".repeat(43),
      account_reference_verified: true,
      account_reference_scope: "provider_account_v2",
    });
    await env.DB.prepare(
      `UPDATE monitored_accounts SET latest_snapshot = ?, last_refresh_at = ?, last_success_at = ?
       WHERE account_id = ?`
    ).bind(snapshot, now - 30, now - 30, accountID).run();
    await env.DB.batch([deviceID, secondDeviceID].map((sourceDeviceID, index) => env.DB.prepare(
      `INSERT INTO usage_history (
         device_id, account_id, row_tag, history_source, provider_id,
         metric_id, metric_title, kind, window_minutes, remaining_percent,
         recorded_at, resets_at, seconds_until_reset, plan
       ) VALUES (?, ?, ?, 'worker', 'chatgpt', 'same-raw-metric', 'Weekly limit',
         'weekly', 10080, 72, ?, ?, 3600, 'Plus')`
    ).bind(sourceDeviceID, accountID, `duplicate-source-${index}`, recordedAt, recordedAt + 3_600)));

    const cookie = await createDashboardSessionCookie();
    const overview = await SELF.fetch("https://push.example/v1/dashboard", { headers: { cookie } });
    const overviewPayload = await overview.json<{
      summary: { accounts: number; shown_accounts: number };
      accounts: Array<{ id: string; source_count: number }>;
    }>();
    expect(overviewPayload.summary).toMatchObject({ accounts: 1, shown_accounts: 1 });
    expect(overviewPayload.accounts).toHaveLength(1);
    expect(overviewPayload.accounts[0].source_count).toBe(2);

    const history = await SELF.fetch(
      `https://push.example/v1/dashboard/accounts/${overviewPayload.accounts[0].id}/history?range=24h`,
      { headers: { cookie } },
    );
    expect(history.status).toBe(200);
    expect(await history.json()).toMatchObject({
      series: [{ title: "Weekly limit", points: [{ recorded_at: recordedAt, remaining_percent: 72 }] }],
      truncated: false,
    });
  });

  it("lets the dashboard remove an account while retaining sanitized data for re-add", async () => {
    await registerDevice();
    const accountID = "019f724a-3414-4d52-ae37-0c7024a1ab98";
    const accountURL = `https://push.example/v1/devices/${deviceID}/accounts/${accountID}`;
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody("chatgpt", 1)),
    })).status).toBe(201);
    const now = Math.floor(Date.now() / 1_000);
    await env.DB.prepare(
      `INSERT INTO usage_history (
         device_id, account_id, provider_id, metric_id, metric_title, kind,
         window_minutes, remaining_percent, recorded_at, resets_at,
         seconds_until_reset, plan
       ) VALUES (?, ?, 'chatgpt', 'weekly', 'Weekly limit', 'weekly',
         10080, 80, ?, ?, 3600, 'Plus')`
    ).bind(deviceID, accountID, now - 60, now + 3_600).run();

    const cookie = await createDashboardSessionCookie();
    const overview = await SELF.fetch("https://push.example/v1/dashboard", { headers: { cookie } });
    const overviewPayload = await overview.json<{ accounts: Array<{ id: string }> }>();
    const dashboardID = overviewPayload.accounts[0].id;
    const detach = await SELF.fetch(
      `https://push.example/v1/dashboard/accounts/${dashboardID}?mode=preserve`,
      { method: "DELETE", headers: { origin: "https://push.example", cookie } },
    );
    expect(detach.status).toBe(200);
    expect(await detach.json()).toEqual({ ok: true, mode: "preserve", retained_data: true });
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM monitored_accounts")
      .first<{ count: number }>()).toEqual({ count: 0 });
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM dashboard_account_archives")
      .first<{ count: number }>()).toEqual({ count: 1 });
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM dashboard_account_archive_history")
      .first<{ count: number }>()).toEqual({ count: 1 });

    const hidden = await SELF.fetch("https://push.example/v1/dashboard", { headers: { cookie } });
    expect((await hidden.json<{ accounts: unknown[] }>()).accounts).toEqual([]);

    const readd = await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody("chatgpt", 1)),
    });
    expect(readd.status).toBe(201);
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM dashboard_account_archives")
      .first<{ count: number }>()).toEqual({ count: 0 });
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM usage_history WHERE device_id = ? AND account_id = ?"
    ).bind(deviceID, accountID).first<{ count: number }>()).toEqual({ count: 1 });
  });

  it("lets the dashboard purge an account and its stored history", async () => {
    await registerDevice();
    const accountID = "019f724a-3414-4d52-ae37-0c7024a1ab98";
    expect((await SELF.fetch(`https://push.example/v1/devices/${deviceID}/accounts/${accountID}`, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody("chatgpt", 1)),
    })).status).toBe(201);
    const cookie = await createDashboardSessionCookie();
    const overview = await SELF.fetch("https://push.example/v1/dashboard", { headers: { cookie } });
    const dashboardID = (await overview.json<{ accounts: Array<{ id: string }> }>()).accounts[0].id;
    const purge = await SELF.fetch(
      `https://push.example/v1/dashboard/accounts/${dashboardID}?mode=purge`,
      { method: "DELETE", headers: { origin: "https://push.example", cookie } },
    );
    expect(purge.status).toBe(200);
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM monitored_accounts")
      .first<{ count: number }>()).toEqual({ count: 0 });
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM account_monitoring_consent")
      .first<{ count: number }>()).toEqual({ count: 0 });
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM dashboard_account_archives")
      .first<{ count: number }>()).toEqual({ count: 0 });
  });

  it("lists linked devices behind opaque handles and never leaks device identifiers", async () => {
    await registerDevice();
    const accountID = "019f724a-3414-4d52-ae37-0c7024a1ab98";
    expect((await SELF.fetch(`https://push.example/v1/devices/${deviceID}/accounts/${accountID}`, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody("chatgpt", 1)),
    })).status).toBe(201);

    const cookie = await createDashboardSessionCookie();
    const response = await SELF.fetch("https://push.example/v1/dashboard/devices", {
      headers: { cookie },
    });
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const payload = await response.json<{
      version: number;
      can_manage: boolean;
      truncated: boolean;
      devices: Array<Record<string, unknown>>;
    }>();
    expect(payload.version).toBe(1);
    expect(payload.truncated).toBe(false);
    expect(payload.devices).toHaveLength(1);
    const device = payload.devices[0];
    expect(device).toMatchObject({
      environment: "production",
      push_enabled: true,
      active: true,
      retired: false,
      monitored_accounts: 1,
      published_accounts: 0,
      subscriptions: 0,
    });
    expect(device.id).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(device.label).toMatch(/^[23456789ABCDEFGHJKMNPQRSTVWXYZ]{4}$/);
    const serialized = JSON.stringify(payload);
    expect(serialized).not.toContain(deviceID);
    expect(serialized).not.toContain(apnsToken);
    expect(serialized).not.toContain(deviceSecret);
    expect((await SELF.fetch("https://push.example/v1/dashboard/devices")).status).toBe(401);
  });

  it("requires recovery access verification before changing a linked device", async () => {
    await registerDevice();
    const cookie = await createDashboardSessionCookie();
    const listed = await SELF.fetch("https://push.example/v1/dashboard/devices", {
      headers: { cookie },
    });
    const payload = await listed.json<{
      can_manage: boolean;
      devices: Array<{ id: string }>;
    }>();
    expect(payload.can_manage).toBe(true);
    const handle = payload.devices[0].id;

    await env.DB.prepare(
      "UPDATE dashboard_session_authorizations SET key_verified_until = 0"
    ).run();
    const denied = await SELF.fetch(`https://push.example/v1/dashboard/devices/${handle}`, {
      method: "DELETE",
      headers: { origin: "https://push.example", cookie },
    });
    expect(denied.status).toBe(403);
    expect(await denied.json()).toEqual({ error: "access_key_verification_required" });
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM devices")
      .first<{ count: number }>()).toEqual({ count: 1 });

    const stale = await SELF.fetch("https://push.example/v1/dashboard/devices", {
      headers: { cookie },
    });
    expect((await stale.json<{ can_manage: boolean }>()).can_manage).toBe(false);

    expect((await SELF.fetch(`https://push.example/v1/dashboard/devices/${handle}`, {
      method: "DELETE",
      headers: { origin: "https://evil.example", cookie },
    })).status).toBe(403);
    expect((await SELF.fetch(`https://push.example/v1/dashboard/devices/${handle}`, {
      method: "GET",
      headers: { cookie },
    })).status).toBe(405);
  });

  it("toggles push delivery for a linked device from the dashboard", async () => {
    await registerDevice();
    const cookie = await createDashboardSessionCookie();
    const listed = await SELF.fetch("https://push.example/v1/dashboard/devices", {
      headers: { cookie },
    });
    const handle = (await listed.json<{ devices: Array<{ id: string }> }>()).devices[0].id;

    const disabled = await SELF.fetch(`https://push.example/v1/dashboard/devices/${handle}`, {
      method: "PATCH",
      headers: { origin: "https://push.example", cookie, "content-type": "application/json" },
      body: JSON.stringify({ push_enabled: false }),
    });
    expect(disabled.status).toBe(200);
    expect(await disabled.json()).toEqual({ ok: true, push_enabled: false });
    expect(await env.DB.prepare(
      "SELECT push_disabled_at IS NOT NULL AS off FROM devices WHERE device_id = ?"
    ).bind(deviceID).first<{ off: number }>()).toEqual({ off: 1 });

    const enabled = await SELF.fetch(`https://push.example/v1/dashboard/devices/${handle}`, {
      method: "PATCH",
      headers: { origin: "https://push.example", cookie, "content-type": "application/json" },
      body: JSON.stringify({ push_enabled: true }),
    });
    expect(enabled.status).toBe(200);
    expect(await env.DB.prepare(
      "SELECT push_disabled_at IS NULL AS on_ FROM devices WHERE device_id = ?"
    ).bind(deviceID).first<{ on_: number }>()).toEqual({ on_: 1 });

    const invalid = await SELF.fetch(`https://push.example/v1/dashboard/devices/${handle}`, {
      method: "PATCH",
      headers: { origin: "https://push.example", cookie, "content-type": "application/json" },
      body: JSON.stringify({ push_enabled: true, apns_token: "a".repeat(64) }),
    });
    expect(invalid.status).toBe(400);
    expect(await invalid.json()).toEqual({ error: "invalid_device_update" });

    const unknown = await SELF.fetch(
      `https://push.example/v1/dashboard/devices/${"z".repeat(43)}`,
      {
        method: "PATCH",
        headers: { origin: "https://push.example", cookie, "content-type": "application/json" },
        body: JSON.stringify({ push_enabled: false }),
      },
    );
    expect(unknown.status).toBe(404);
    expect(await unknown.json()).toEqual({ error: "device_not_found" });
  });

  it("unlinks a device, cascades its Worker data, and tombstones the registration", async () => {
    await registerDevice();
    const accountID = "019f724a-3414-4d52-ae37-0c7024a1ab98";
    expect((await SELF.fetch(`https://push.example/v1/devices/${deviceID}/accounts/${accountID}`, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody("chatgpt", 1)),
    })).status).toBe(201);

    const cookie = await createDashboardSessionCookie();
    const listed = await SELF.fetch("https://push.example/v1/dashboard/devices", {
      headers: { cookie },
    });
    const handle = (await listed.json<{ devices: Array<{ id: string }> }>()).devices[0].id;

    const unlink = await SELF.fetch(`https://push.example/v1/dashboard/devices/${handle}`, {
      method: "DELETE",
      headers: { origin: "https://push.example", cookie },
    });
    expect(unlink.status).toBe(200);
    expect(await unlink.json()).toEqual({ ok: true });
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM devices")
      .first<{ count: number }>()).toEqual({ count: 0 });
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM monitored_accounts")
      .first<{ count: number }>()).toEqual({ count: 0 });
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM account_monitoring_consent")
      .first<{ count: number }>()).toEqual({ count: 0 });
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM device_deletion_tombstones")
      .first<{ count: number }>()).toEqual({ count: 1 });

    const empty = await SELF.fetch("https://push.example/v1/dashboard/devices", {
      headers: { cookie },
    });
    expect((await empty.json<{ devices: unknown[] }>()).devices).toEqual([]);

    const repeat = await SELF.fetch(`https://push.example/v1/dashboard/devices/${handle}`, {
      method: "DELETE",
      headers: { origin: "https://push.example", cookie },
    });
    expect(repeat.status).toBe(404);
  });

  it("expires dashboard sessions without disclosing why authentication failed", async () => {
    const cookie = await createDashboardSessionCookie();
    await env.DB.prepare("UPDATE dashboard_sessions SET expires_at = 0").run();
    const response = await SELF.fetch("https://push.example/v1/dashboard", {
      headers: { cookie },
    });
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized" });
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM dashboard_sessions")
      .first<{ count: number }>()).toEqual({ count: 0 });
  });

  it("keeps unverified same-workspace sources separate in discovery and the dashboard", async () => {
    const firstAccountID = "019f724a-3414-4d52-ae37-0c7024a1ab98";
    const secondDeviceID = "019f724a-3414-4d52-ae37-0c7024a1ab99";
    const secondDeviceSecret = "B".repeat(43);
    const secondAccountID = "019f724a-3414-4d52-ae37-0c7024a1aba0";
    await registerDevice();
    await registerDevice(secondDeviceID, secondDeviceSecret, "b".repeat(64));
    for (const [ownerDeviceID, ownerSecret, id] of [
      [deviceID, deviceSecret, firstAccountID],
      [secondDeviceID, secondDeviceSecret, secondAccountID],
    ] as const) {
      const body = accountRequestBody("openrouter", 1);
      body.workspace_id = "same-client-supplied-creator";
      expect((await SELF.fetch(
        `https://push.example/v1/devices/${ownerDeviceID}/accounts/${id}`,
        {
          method: "PUT",
          headers: { authorization: `Bearer ${ownerSecret}` },
          body: JSON.stringify(body),
        },
      )).status).toBe(201);
    }

    const subscriberDeviceID = "019f724a-3414-4d52-ae37-0c7024a1aba1";
    const subscriberSecret = "C".repeat(43);
    await registerDevice(subscriberDeviceID, subscriberSecret, "c".repeat(64));
    const available = await SELF.fetch(
      `https://push.example/v1/devices/${subscriberDeviceID}/remote-accounts`,
      { headers: { authorization: `Bearer ${subscriberSecret}` } },
    );
    const availableBody = await available.json<{
      accounts: Array<{ account_reference: string }>;
    }>();
    expect(availableBody.accounts).toHaveLength(2);
    expect(new Set(availableBody.accounts.map((account) => account.account_reference)).size)
      .toBe(2);

    const overview = await SELF.fetch("https://push.example/v1/dashboard", {
      headers: { cookie: await createDashboardSessionCookie() },
    });
    const overviewBody = await overview.json<{
      summary: { accounts: number };
      accounts: Array<{ id: string; source_count: number }>;
    }>();
    expect(overviewBody.summary.accounts).toBe(2);
    expect(overviewBody.accounts).toHaveLength(2);
    expect(overviewBody.accounts.every((account) => account.source_count === 1)).toBe(true);
    expect(new Set(overviewBody.accounts.map((account) => account.id)).size).toBe(2);
  });
});

describe("push registration API", () => {
  it("signs an APNs provider token with the bundled topic-specific key", async () => {
    const token = await testing.createAPNSAuthorization();
    const [encodedHeader, encodedClaims, signature] = token.split(".");
    const decodePart = (part: string) => JSON.parse(
      new TextDecoder().decode(Uint8Array.from(
        atob(part.replace(/-/g, "+").replace(/_/g, "/")),
        (character) => character.charCodeAt(0)
      ))
    ) as Record<string, unknown>;

    expect(decodePart(encodedHeader)).toEqual({ alg: "ES256", kid: "Y35ZLFTW8W" });
    expect(decodePart(encodedClaims).iss).toBe("7P8CLHDH5G");
    expect(signature).toMatch(/^[A-Za-z0-9_-]+$/);
  });

  it("reports the configured deployment mode without exposing credentials", async () => {
    const response = await SELF.fetch("https://push.example/healthz");

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      mode: "self_hosted",
      topic: "ad.neko.when",
    });
  });

  it("registers a device and stores only the secret hash", async () => {
    const response = await SELF.fetch("https://push.example/v1/devices", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-when-reset-server-key": env.REGISTRATION_ACCESS_KEY,
      },
      body: JSON.stringify({
        device_id: deviceID,
        device_secret: deviceSecret,
        apns_token: apnsToken,
        apns_environment: "development",
      }),
    });

    expect(response.status).toBe(201);
    const row = await env.DB.prepare(
      "SELECT secret_hash, apns_token, apns_environment FROM devices WHERE device_id = ?"
    ).bind(deviceID).first<{
      secret_hash: string;
      apns_token: string;
      apns_environment: string;
    }>();
    expect(row?.secret_hash).toBe(await testing.hashSecret(deviceSecret));
    expect(row?.secret_hash).not.toBe(deviceSecret);
    expect(row?.apns_token).toBe(apnsToken);
    expect(row?.apns_environment).toBe("development");
  });

  it("rotates an existing APNs token using only the device secret", async () => {
    await registerDevice();
    const url = `https://push.example/v1/devices/${deviceID}`;
    await env.DB.prepare("UPDATE devices SET push_disabled_at = 123 WHERE device_id = ?")
      .bind(deviceID).run();
    expect((await SELF.fetch(url, {
      method: "PUT",
      headers: { authorization: `Bearer ${"B".repeat(43)}` },
      body: JSON.stringify({ apns_token: "b".repeat(64) }),
    })).status).toBe(401);

    const response = await SELF.fetch(url, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify({
        apns_token: "b".repeat(64),
        apns_environment: "development",
      }),
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
    expect(await env.DB.prepare(
      `SELECT apns_token, apns_environment, push_disabled_at
       FROM devices WHERE device_id = ?`
    ).bind(deviceID).first<{
      apns_token: string;
      apns_environment: string;
      push_disabled_at: number | null;
    }>()).toEqual({
      apns_token: "b".repeat(64),
      apns_environment: "development",
      push_disabled_at: null,
    });
  });

  it("reassigns an APNs token during access-key registration", async () => {
    await registerDevice();
    const otherDeviceID = "019f724a-3414-4d52-ae37-0c7024a1ab99";
    const response = await SELF.fetch("https://push.example/v1/devices", {
      method: "POST",
      headers: { "x-when-reset-server-key": env.REGISTRATION_ACCESS_KEY },
      body: JSON.stringify({
        device_id: otherDeviceID,
        device_secret: "C".repeat(43),
        apns_token: apnsToken,
      }),
    });

    expect(response.status).toBe(201);
    expect(await response.json()).toEqual({ ok: true });
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM devices")
      .first<{ count: number }>()).toEqual({ count: 2 });
    expect(await env.DB.prepare(
      "SELECT apns_token, push_disabled_at FROM devices WHERE device_id = ?"
    ).bind(deviceID).first<{ apns_token: string; push_disabled_at: number | null }>())
      .toEqual({ apns_token: `retired:${deviceID}`, push_disabled_at: expect.any(Number) });
    expect(await env.DB.prepare("SELECT device_id FROM devices WHERE apns_token = ?")
      .bind(apnsToken).first<{ device_id: string }>()).toEqual({ device_id: otherDeviceID });
  });

  it("reassigns an APNs token during authenticated token rotation", async () => {
    await registerDevice();
    const otherDeviceID = "019f724a-3414-4d52-ae37-0c7024a1ab99";
    const otherAPNSToken = "b".repeat(64);
    const registered = await SELF.fetch("https://push.example/v1/devices", {
      method: "POST",
      headers: { "x-when-reset-server-key": env.REGISTRATION_ACCESS_KEY },
      body: JSON.stringify({
        device_id: otherDeviceID,
        device_secret: "C".repeat(43),
        apns_token: otherAPNSToken,
      }),
    });
    expect(registered.status).toBe(201);

    const response = await SELF.fetch(`https://push.example/v1/devices/${deviceID}`, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify({ apns_token: otherAPNSToken }),
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
    expect(await env.DB.prepare("SELECT apns_token FROM devices WHERE device_id = ?")
      .bind(deviceID).first<{ apns_token: string }>()).toEqual({ apns_token: otherAPNSToken });
    expect(await env.DB.prepare(
      "SELECT apns_token, push_disabled_at FROM devices WHERE device_id = ?"
    ).bind(otherDeviceID).first<{ apns_token: string; push_disabled_at: number | null }>())
      .toEqual({ apns_token: `retired:${otherDeviceID}`, push_disabled_at: expect.any(Number) });
  });

  it("requires the original secret to update or delete a registration", async () => {
    await SELF.fetch("https://push.example/v1/devices", {
      method: "POST",
      headers: { "x-when-reset-server-key": env.REGISTRATION_ACCESS_KEY },
      body: JSON.stringify({
        device_id: deviceID,
        device_secret: deviceSecret,
        apns_token: apnsToken,
      }),
    });

    const conflicting = await SELF.fetch("https://push.example/v1/devices", {
      method: "POST",
      headers: { "x-when-reset-server-key": env.REGISTRATION_ACCESS_KEY },
      body: JSON.stringify({
        device_id: deviceID,
        device_secret: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
        apns_token: "b".repeat(64),
      }),
    });
    expect(conflicting.status).toBe(401);

    const unauthorizedDelete = await SELF.fetch(`https://push.example/v1/devices/${deviceID}`, {
      method: "DELETE",
      headers: { authorization: "Bearer BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" },
    });
    expect(unauthorizedDelete.status).toBe(401);

    const authorizedDelete = await SELF.fetch(`https://push.example/v1/devices/${deviceID}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${deviceSecret}` },
    });
    expect(authorizedDelete.status).toBe(204);
  });

  it("authenticates a lost-response DELETE retry and cascades all account data", async () => {
    await registerDevice();
    const accountID = "019f724a-3414-4d52-ae37-0c7024a1ab98";
    const accountURL = `https://push.example/v1/devices/${deviceID}/accounts/${accountID}`;
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody("chatgpt", 1)),
    })).status).toBe(201);
    await env.DB.prepare(
      `INSERT INTO usage_history (
         device_id, account_id, provider_id, metric_id, metric_title, kind, window_minutes,
         remaining_percent, recorded_at, resets_at, seconds_until_reset, plan
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    ).bind(
      deviceID, accountID, "chatgpt", "weekly", "Weekly limit", "weekly", 10_080,
      60, 2_000_000_000, 2_000_086_400, 86_400, "Plus"
    ).run();

    const url = `https://push.example/v1/devices/${deviceID}`;
    const first = await SELF.fetch(url, {
      method: "DELETE",
      headers: { authorization: `Bearer ${deviceSecret}` },
    });
    expect(first.status).toBe(204);
    expect(first.headers.get("cache-control")).toBe("no-store");
    const retry = await SELF.fetch(url, {
      method: "DELETE",
      headers: { authorization: `Bearer ${deviceSecret}` },
    });
    expect(retry.status).toBe(204);
    expect((await SELF.fetch(url, {
      method: "DELETE",
      headers: { authorization: `Bearer ${"B".repeat(43)}` },
    })).status).toBe(401);

    for (const table of ["devices", "monitored_accounts", "usage_history", "account_monitoring_consent"]) {
      expect(await env.DB.prepare(`SELECT COUNT(*) AS count FROM ${table}`)
        .first<{ count: number }>()).toEqual({ count: 0 });
    }
    const tombstone = await env.DB.prepare(
      "SELECT device_id, secret_hash, deleted_at FROM device_deletion_tombstones WHERE device_id = ?"
    ).bind(deviceID).first<{ device_id: string; secret_hash: string; deleted_at: number }>();
    expect(tombstone).toMatchObject({
      device_id: deviceID,
      secret_hash: await testing.hashSecret(deviceSecret),
    });
    expect(tombstone?.secret_hash).not.toBe(deviceSecret);
    expect(tombstone?.deleted_at).toBeTypeOf("number");
    const columns = await env.DB.prepare("PRAGMA table_info(device_deletion_tombstones)")
      .all<{ name: string }>();
    expect(columns.results.map((column) => column.name))
      .toEqual(["device_id", "secret_hash", "deleted_at"]);
  });

  it("disables pushes after permanent APNs rejection without deleting server monitoring", async () => {
    await registerDevice();
    const accountID = "019f724a-3414-4d52-ae37-0c7024a1ab98";
    const accountURL = `https://push.example/v1/devices/${deviceID}/accounts/${accountID}`;
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody("chatgpt", 1)),
    })).status).toBe(201);
    await env.DB.prepare(
      `INSERT INTO usage_history (
         device_id, account_id, provider_id, metric_id, metric_title, kind, window_minutes,
         remaining_percent, recorded_at, resets_at, seconds_until_reset, plan
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    ).bind(
      deviceID, accountID, "chatgpt", "weekly", "Weekly limit", "weekly", 10_080,
      60, 2_000_000_000, 2_000_086_400, 86_400, "Plus"
    ).run();

    await testing.handleAPNSResult(
      env,
      { device_id: deviceID, apns_token: apnsToken },
      { ok: false, status: 410, reason: "Unregistered" },
    );

    for (const table of ["devices", "monitored_accounts", "usage_history", "account_monitoring_consent"]) {
      expect(await env.DB.prepare(`SELECT COUNT(*) AS count FROM ${table}`)
        .first<{ count: number }>()).toEqual({ count: 1 });
    }
    expect(await env.DB.prepare(
      "SELECT push_disabled_at FROM devices WHERE device_id = ?"
    ).bind(deviceID).first<{ push_disabled_at: number | null }>()
    ).toEqual({ push_disabled_at: expect.any(Number) });
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM device_deletion_tombstones WHERE device_id = ?"
    ).bind(deviceID).first<{ count: number }>()).toEqual({ count: 0 });
    expect((await SELF.fetch(`https://push.example/v1/devices/${deviceID}/refresh`, {
      method: "POST",
      headers: { authorization: `Bearer ${deviceSecret}` },
    })).status).toBe(409);
  });

  it("does not tombstone or delete a live device whose APNs token rotated", async () => {
    await registerDevice();
    const rotatedToken = "b".repeat(64);
    expect((await SELF.fetch(`https://push.example/v1/devices/${deviceID}`, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify({ apns_token: rotatedToken }),
    })).status).toBe(200);

    await testing.handleAPNSResult(
      env,
      { device_id: deviceID, apns_token: apnsToken },
      { ok: false, status: 410, reason: "Unregistered" },
    );

    expect(await env.DB.prepare(
      "SELECT apns_token FROM devices WHERE device_id = ?"
    ).bind(deviceID).first<{ apns_token: string }>()).toEqual({ apns_token: rotatedToken });
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM device_deletion_tombstones WHERE device_id = ?"
    ).bind(deviceID).first<{ count: number }>()).toEqual({ count: 0 });
  });

  it("does not enqueue hourly pushes for a device with a rejected APNs token", async () => {
    await registerDevice();
    await env.DB.prepare("UPDATE devices SET push_disabled_at = 123 WHERE device_id = ?")
      .bind(deviceID).run();
    const queued: unknown[] = [];
    const testEnv = {
      DB: env.DB,
      PUSH_QUEUE: {
        sendBatch: async (messages: { body: unknown }[]) => {
          queued.push(...messages.map((message) => message.body));
        },
      },
    } as unknown as Env;

    await testing.runScheduledRefresh(testEnv, Date.UTC(2033, 4, 18, 4, 0));

    expect(queued).toEqual([]);
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM devices")
      .first<{ count: number }>()).toEqual({ count: 1 });
  });

  it("disables an unsupported APNs environment without deleting the registration", async () => {
    await registerDevice();

    await testing.handleAPNSResult(
      env,
      { device_id: deviceID, apns_token: apnsToken },
      { ok: false, status: 403, reason: "BadEnvironmentKeyInToken" },
    );

    expect(await env.DB.prepare(
      "SELECT push_disabled_at FROM devices WHERE device_id = ?"
    ).bind(deviceID).first<{ push_disabled_at: number | null }>()).toEqual({
      push_disabled_at: expect.any(Number),
    });
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM device_deletion_tombstones")
      .first<{ count: number }>()).toEqual({ count: 0 });
  });

  it("does not disable a token whose APNs environment rotated after enqueue", async () => {
    await registerDevice();
    expect((await SELF.fetch(`https://push.example/v1/devices/${deviceID}`, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify({
        apns_token: apnsToken,
        apns_environment: "development",
      }),
    })).status).toBe(200);

    await testing.handleAPNSResult(
      env,
      {
        device_id: deviceID,
        apns_token: apnsToken,
        apns_environment: "production",
      },
      { ok: false, status: 403, reason: "BadEnvironmentKeyInToken" },
    );

    expect(await env.DB.prepare(
      "SELECT apns_environment, push_disabled_at FROM devices WHERE device_id = ?"
    ).bind(deviceID).first()).toEqual({
      apns_environment: "development",
      push_disabled_at: null,
    });
  });

  it("does not let an old deletion secret remove a newly registered device", async () => {
    await registerDevice();
    const url = `https://push.example/v1/devices/${deviceID}`;
    expect((await SELF.fetch(url, {
      method: "DELETE",
      headers: { authorization: `Bearer ${deviceSecret}` },
    })).status).toBe(204);

    const newSecret = "C".repeat(43);
    const newAPNSToken = "c".repeat(64);
    const registration = await SELF.fetch("https://push.example/v1/devices", {
      method: "POST",
      headers: { "x-when-reset-server-key": env.REGISTRATION_ACCESS_KEY },
      body: JSON.stringify({
        device_id: deviceID,
        device_secret: newSecret,
        apns_token: newAPNSToken,
      }),
    });
    expect(registration.status).toBe(201);
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM device_deletion_tombstones WHERE device_id = ?"
    ).bind(deviceID).first<{ count: number }>()).toEqual({ count: 0 });

    expect((await SELF.fetch(url, {
      method: "DELETE",
      headers: { authorization: `Bearer ${deviceSecret}` },
    })).status).toBe(401);
    expect(await env.DB.prepare(
      "SELECT secret_hash, apns_token FROM devices WHERE device_id = ?"
    ).bind(deviceID).first<{ secret_hash: string; apns_token: string }>()).toEqual({
      secret_hash: await testing.hashSecret(newSecret),
      apns_token: newAPNSToken,
    });
  });

  it("clears an old deletion tombstone when QR relinking succeeds", async () => {
    await registerDevice();
    const url = `https://push.example/v1/devices/${deviceID}`;
    expect((await SELF.fetch(url, {
      method: "DELETE",
      headers: { authorization: `Bearer ${deviceSecret}` },
    })).status).toBe(204);

    const newSecret = "C".repeat(43);
    const session = await createLinkSession();
    const claim = await SELF.fetch(claimURL(session), {
      method: "POST",
      headers: { authorization: `Bearer ${linkToken(session)}` },
      body: JSON.stringify({
        device_id: deviceID,
        device_secret: newSecret,
        apns_token: "c".repeat(64),
      }),
    });
    expect(claim.status).toBe(201);
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM device_deletion_tombstones WHERE device_id = ?"
    ).bind(deviceID).first<{ count: number }>()).toEqual({ count: 0 });
    expect((await SELF.fetch(url, {
      method: "DELETE",
      headers: { authorization: `Bearer ${deviceSecret}` },
    })).status).toBe(401);
  });

  it("prunes only expired device deletion tombstones", async () => {
    const now = 2_000_000_000;
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO device_deletion_tombstones (device_id, secret_hash, deleted_at) VALUES (?, ?, ?)"
      ).bind(deviceID, "old-hash", now - 91 * 86_400),
      env.DB.prepare(
        "INSERT INTO device_deletion_tombstones (device_id, secret_hash, deleted_at) VALUES (?, ?, ?)"
      ).bind("019f724a-3414-4d52-ae37-0c7024a1ab99", "new-hash", now - 89 * 86_400),
    ]);

    await testing.pruneDeviceDeletionTombstones(env, now);
    expect(await env.DB.prepare(
      "SELECT device_id FROM device_deletion_tombstones ORDER BY device_id"
    ).all<{ device_id: string }>()).toMatchObject({
      results: [{ device_id: "019f724a-3414-4d52-ae37-0c7024a1ab99" }],
    });
  });

  it("rejects malformed and oversized registrations", async () => {
    const unauthorized = await SELF.fetch("https://push.example/v1/devices", {
      method: "POST",
      body: "{}",
    });
    expect(unauthorized.status).toBe(401);

    const malformed = await SELF.fetch("https://push.example/v1/devices", {
      method: "POST",
      headers: { "x-when-reset-server-key": env.REGISTRATION_ACCESS_KEY },
      body: "{}",
    });
    expect(malformed.status).toBe(400);

    const oversized = await SELF.fetch("https://push.example/v1/devices", {
      method: "POST",
      headers: {
        "content-length": "3000",
        "x-when-reset-server-key": env.REGISTRATION_ACCESS_KEY,
      },
      body: "{}",
    });
    expect(oversized.status).toBe(400);
  });
});

describe("credential-free device snapshot publishing", () => {
  const accountID = "019f724a-3414-4d52-ae37-0c7024a1ab98";
  const url = `https://push.example/v1/devices/${deviceID}/accounts/${accountID}/snapshots`;
  const headers = { authorization: `Bearer ${deviceSecret}` };

  function sourceBody(consentRevision = 1) {
    return {
      provider_id: "chatgpt",
      display_name: "Personal",
      refresh_interval_seconds: 900,
      history_retention_days: 35,
      consent_revision: consentRevision,
    };
  }

  function snapshotBody(sequence = 1, consentRevision = 1, observedAt?: number) {
    const observed = observedAt ?? Math.floor(Date.now() / 1_000);
    return {
      consent_revision: consentRevision,
      sequence,
      observed_at: observed,
      snapshot: {
        provider_id: "chatgpt",
        plan: "Plus",
        windows: [{
          position: 0,
          metric_id: "weekly",
          title: "Weekly limit",
          kind: "weekly",
          window_minutes: 10_080,
          remaining_percent: 73,
          resets_at: observed + 86_400,
        }],
        available_reset_count: 1,
        reset_credits: [{
          expires_at: observed + 21_600,
          status: "available",
          granted_at: null,
        }],
        reset_credits_authoritative: true,
      },
    };
  }

  it("requires device authentication and rejects secret-bearing or unknown fields", async () => {
    await registerDevice();
    expect((await SELF.fetch(url, {
      method: "PUT",
      body: JSON.stringify(sourceBody()),
    })).status).toBe(401);
    for (const forbidden of ["credentials", "workspace_id", "email", "account_reference"]) {
      const response = await SELF.fetch(url, {
        method: "PUT",
        headers,
        body: JSON.stringify({ ...sourceBody(), [forbidden]: "secret-canary" }),
      });
      expect(response.status).toBe(400);
      expect(await response.json()).toEqual({ error: "invalid_snapshot_source" });
    }
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM device_snapshot_sources")
      .first<{ count: number }>()).toEqual({ count: 0 });
  });

  it("publishes a sanitized snapshot without credentials and safely deduplicates retries", async () => {
    await registerDevice();
    const enabled = await SELF.fetch(url, {
      method: "PUT",
      headers,
      body: JSON.stringify(sourceBody()),
    });
    expect(enabled.status).toBe(201);
    expect(await enabled.json()).toEqual({ ok: true, consent_revision: 1, next_sequence: 1 });

    const body = snapshotBody();
    for (const field of ["credentials", "workspace_id", "email", "account_reference", "accountID"]) {
      const rejected = await SELF.fetch(url, {
        method: "POST",
        headers,
        body: JSON.stringify({ ...body, snapshot: { ...body.snapshot, [field]: "token-canary" } }),
      });
      expect(rejected.status).toBe(400);
      expect(await rejected.json()).toEqual({ error: "invalid_device_snapshot" });
    }

    const upload = () => SELF.fetch(url, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
    });
    expect(await (await upload()).json()).toEqual({ accepted: true, sequence: 1 });
    expect(await (await upload()).json()).toEqual({ accepted: true, sequence: 1 });
    const conflictingReplay = await SELF.fetch(url, {
      method: "POST",
      headers,
      body: JSON.stringify({
        ...body,
        snapshot: { ...body.snapshot, available_reset_count: 0 },
      }),
    });
    expect(conflictingReplay.status).toBe(409);
    expect(await conflictingReplay.json()).toEqual({ error: "snapshot_replay" });
    const row = await env.DB.prepare(
      `SELECT next_sequence, latest_snapshot, last_payload_hash
       FROM device_snapshot_sources WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first<{
      next_sequence: number;
      latest_snapshot: string;
      last_payload_hash: string;
    }>();
    expect(row?.next_sequence).toBe(2);
    expect(row?.last_payload_hash).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const serialized = row?.latest_snapshot ?? "";
    for (const canary of ["token-canary", "credentials", "workspace_id", "email"]) {
      expect(serialized).not.toContain(canary);
    }
    expect(JSON.parse(serialized)).toMatchObject({
      provider_id: "chatgpt",
      fetched_at: body.observed_at,
      windows: [{ metric_id: "weekly", remaining_percent: 73 }],
    });
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM device_snapshot_history WHERE device_id = ? AND account_id = ?"
    ).bind(deviceID, accountID).first<{ count: number }>()).toEqual({ count: 1 });
  });

  it("accepts omitted optional snapshot fields and rejects impractical future reset data", async () => {
    await registerDevice();
    expect((await SELF.fetch(url, {
      method: "PUT",
      headers,
      body: JSON.stringify({ ...sourceBody(), refresh_interval_seconds: 0 }),
    })).status).toBe(201);
    const now = Math.floor(Date.now() / 1_000);
    const compact = snapshotBody(1, 1, now);
    delete (compact.snapshot.windows[0] as Record<string, unknown>).kind;
    delete (compact.snapshot.windows[0] as Record<string, unknown>).window_minutes;
    compact.snapshot.reset_credits = [{} as never];
    expect((await SELF.fetch(url, {
      method: "POST",
      headers,
      body: JSON.stringify(compact),
    })).status).toBe(200);

    const future = snapshotBody(2, 1, now + 1);
    future.snapshot.windows[0].resets_at = now + 11 * 365 * 86_400;
    const rejected = await SELF.fetch(url, {
      method: "POST",
      headers,
      body: JSON.stringify(future),
    });
    expect(rejected.status).toBe(400);
    expect(await rejected.json()).toEqual({ error: "invalid_device_snapshot" });
  });

  it("surfaces device-published usage in the dashboard without duplicating an exact-PK Worker source", async () => {
    await registerDevice();
    const monitoredURL = `https://push.example/v1/devices/${deviceID}/accounts/${accountID}`;
    expect((await SELF.fetch(monitoredURL, {
      method: "PUT",
      headers,
      body: JSON.stringify(accountRequestBody("chatgpt")),
    })).status).toBe(201);
    expect((await SELF.fetch(url, {
      method: "PUT",
      headers,
      body: JSON.stringify(sourceBody()),
    })).status).toBe(201);
    expect((await SELF.fetch(url, {
      method: "POST",
      headers,
      body: JSON.stringify(snapshotBody()),
    })).status).toBe(200);

    const cookie = await createDashboardSessionCookie();
    const response = await SELF.fetch("https://push.example/v1/dashboard", {
      headers: { cookie },
    });
    expect(response.status).toBe(200);
    const payload = await response.json<{
      accounts: Array<{
        id: string;
        source: string;
        source_count: number;
        refresh_interval_seconds: number;
        snapshot: { windows: Array<{ remaining_percent: number }> };
      }>;
    }>();
    expect(payload.accounts).toHaveLength(1);
    expect(payload.accounts[0]).toMatchObject({
      source: "device",
      source_count: 1,
      snapshot: { windows: [{ remaining_percent: 73 }] },
    });
    const history = await SELF.fetch(
      `https://push.example/v1/dashboard/accounts/${payload.accounts[0].id}/history?range=24h`,
      { headers: { cookie } },
    );
    expect(history.status).toBe(200);
    expect(await history.json()).toMatchObject({
      series: [expect.objectContaining({
        points: [expect.objectContaining({ remaining_percent: 73 })],
      })],
    });

    const later = Math.floor(Date.now() / 1_000) + 60;
    await env.DB.prepare(
      `UPDATE monitored_accounts SET latest_snapshot = ?, last_refresh_at = ?, last_success_at = ?
       WHERE device_id = ? AND account_id = ?`
    ).bind("{invalid", later, later, deviceID, accountID).run();
    const fallback = await SELF.fetch("https://push.example/v1/dashboard", {
      headers: { cookie },
    });
    expect(fallback.status).toBe(200);
    const fallbackPayload = await fallback.json<{
      accounts: Array<{
        source: string;
        snapshot: { windows: Array<{ remaining_percent: number }> };
      }>;
    }>();
    expect(fallbackPayload.accounts).toHaveLength(1);
    expect(fallbackPayload.accounts[0].source).toBe("device");
    expect(fallbackPayload.accounts[0].snapshot.windows[0].remaining_percent).toBe(73);
  });

  it("keeps snapshot consent independent and permits exact-PK credential coexistence", async () => {
    await registerDevice();
    const monitoredURL = `https://push.example/v1/devices/${deviceID}/accounts/${accountID}`;
    expect((await SELF.fetch(monitoredURL, {
      method: "PUT",
      headers,
      body: JSON.stringify(accountRequestBody("chatgpt")),
    })).status).toBe(201);
    expect((await SELF.fetch(url, {
      method: "PUT",
      headers,
      body: JSON.stringify(sourceBody()),
    })).status).toBe(201);
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM monitored_accounts WHERE device_id = ? AND account_id = ?"
    ).bind(deviceID, accountID).first<{ count: number }>()).toEqual({ count: 1 });
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM device_snapshot_sources WHERE device_id = ? AND account_id = ?"
    ).bind(deviceID, accountID).first<{ count: number }>()).toEqual({ count: 1 });

    const equalRevisionDelete = await SELF.fetch(`${url}?consent_revision=1`, {
      method: "DELETE",
      headers,
    });
    expect(equalRevisionDelete.status).toBe(409);
    expect(await equalRevisionDelete.json()).toEqual({ error: "consent_revision_conflict" });
    expect((await env.DB.prepare(
      "SELECT enabled FROM device_snapshot_consent WHERE device_id = ? AND account_id = ?"
    ).bind(deviceID, accountID).first<{ enabled: number }>())?.enabled).toBe(1);

    expect((await SELF.fetch(`${url}?consent_revision=2`, {
      method: "DELETE",
      headers,
    })).status).toBe(204);
    expect((await SELF.fetch(`${url}?consent_revision=2`, {
      method: "DELETE",
      headers,
    })).status).toBe(204);
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM device_snapshot_sources WHERE device_id = ? AND account_id = ?"
    ).bind(deviceID, accountID).first<{ count: number }>()).toEqual({ count: 0 });
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM monitored_accounts WHERE device_id = ? AND account_id = ?"
    ).bind(deviceID, accountID).first<{ count: number }>()).toEqual({ count: 1 });
  });
});

describe("self-hosted account monitoring API", () => {
  const accountID = "019f724a-3414-4d52-ae37-0c7024a1ab98";
  const accountURL = `https://push.example/v1/devices/${deviceID}/accounts/${accountID}`;

  it("encrypts provider credentials before storing them in D1", async () => {
    await registerDevice();
    const response = await SELF.fetch(accountURL, {
      method: "PUT",
      headers: {
        authorization: `Bearer ${deviceSecret}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(accountRequestBody()),
    });

    expect(response.status).toBe(201);
    const responseBody = await response.json<Record<string, unknown>>();
    expect(responseBody).toMatchObject({
      history: [],
      next_cursor: null,
      metadata: {
        name: "Provider Person",
        email: "person@example.com",
        plan: "Plus",
        plan_expires_at: 2_000_000_000,
        trial_expires_at: 1_999_000_000,
      },
    });
    expect(responseBody).not.toHaveProperty("credentials");
    expect(JSON.stringify(responseBody)).not.toContain("access-secret");
    expect(JSON.stringify(responseBody)).not.toContain("refresh-secret");
    expect(JSON.stringify(responseBody)).not.toContain("id-secret");
    const row = await env.DB.prepare(
      `SELECT encrypted_credentials, profile_name, email, plan,
              plan_expires_at, trial_expires_at
       FROM monitored_accounts WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first<{
      encrypted_credentials: string;
      profile_name: string;
      email: string;
      plan: string;
      plan_expires_at: number;
      trial_expires_at: number;
    }>();
    expect(row).toMatchObject({
      profile_name: "Provider Person",
      email: "person@example.com",
      plan: "Plus",
      plan_expires_at: 2_000_000_000,
      trial_expires_at: 1_999_000_000,
    });
    expect(row?.encrypted_credentials).not.toContain("access-secret");
    expect(row?.encrypted_credentials).not.toContain("refresh-secret");
    expect(JSON.parse(row!.encrypted_credentials)).toMatchObject({ v: 1 });
  });

  it("classifies replacement verification failures without committing new credentials", async () => {
    await registerDevice();
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody("chatgpt", 1)),
    })).status).toBe(201);
    const storedState = () => env.DB.prepare(
      `SELECT encrypted_credentials, credential_fingerprint, credential_revision,
              latest_snapshot, last_error
       FROM monitored_accounts WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first();
    const before = await storedState();

    for (const failure of [
      { providerStatus: 401, responseStatus: 401, code: "provider_session_expired" },
      { providerStatus: 403, responseStatus: 403, code: "provider_request_forbidden" },
    ]) {
      const replacementBody = accountRequestBody("chatgpt", 1);
      replacementBody.credentials.access_token =
        `replacement-canary-${failure.providerStatus}`;
      const replacement = await testing.parseAccountUpload(new Request(
        "https://push.example/credential-replacement-test",
        { method: "PUT", body: JSON.stringify(replacementBody) },
      ));
      const response = await testing.upsertMonitoredAccount(
        env,
        deviceID,
        accountID,
        replacement!,
        true,
        async () => {
          throw new ProviderFetchError(
            `provider-body-canary-${failure.providerStatus}`,
            failure.providerStatus,
            false,
          );
        },
      );
      expect(response.status).toBe(failure.responseStatus);
      expect(response.headers.get("cache-control")).toBe("no-store");
      const responseBody = await response.json<Record<string, unknown>>();
      expect(responseBody).toEqual({ error: failure.code });
      expect(JSON.stringify(responseBody)).not.toContain("canary");
      expect(await storedState()).toEqual(before);
    }
  });

  it("updates cloud policy without requiring provider credentials", async () => {
    await registerDevice();
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody()),
    })).status).toBe(201);

    const response = await SELF.fetch(`${accountURL}/settings`, {
      method: "PATCH",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify({
        refresh_interval_seconds: 1_800,
        history_retention_days: 365,
      }),
    });

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ history_retention_days: 365 });
    expect(await env.DB.prepare(
      `SELECT refresh_interval_seconds, history_retention_days
       FROM monitored_accounts WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first()).toEqual({
      refresh_interval_seconds: 1_800,
      history_retention_days: 365,
    });
  });

  it("tags and deduplicates local history uploaded to the cloud", async () => {
    await registerDevice();
    const body = accountRequestBody();
    body.history_retention_days = 90;
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(body),
    })).status).toBe(201);

    const recordedAt = Math.floor(Date.now() / 1_000) - 600;
    const point = {
      row_tag: `h1.${accountID}.d2Vla2x5.${recordedAt}`,
      provider_id: "chatgpt",
      metric_id: "weekly",
      metric_title: "Weekly limit",
      kind: "weekly",
      window_minutes: 10_080,
      remaining_percent: 64,
      recorded_at: recordedAt,
      resets_at: recordedAt + 86_400,
      seconds_until_reset: 86_400,
      plan: "Plus",
    };
    const upload = () => SELF.fetch(`${accountURL}/history`, {
      method: "POST",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify({ history: [point] }),
    });

    const first = await upload();
    expect(first.status).toBe(200);
    expect(await first.json()).toEqual({ accepted: 1, deduplicated: 0 });
    const repeated = await upload();
    expect(repeated.status).toBe(200);
    expect(await repeated.json()).toEqual({ accepted: 0, deduplicated: 1 });
    expect(await env.DB.prepare(
      `SELECT row_tag, history_source, COUNT(*) AS count
       FROM usage_history WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first()).toEqual({
      row_tag: point.row_tag,
      history_source: "device",
      count: 1,
    });

    const sync = await SELF.fetch(`${accountURL}/sync?since=0`, {
      headers: { authorization: `Bearer ${deviceSecret}` },
    });
    expect(await sync.json()).toMatchObject({
      history_retention_days: 90,
      history: [{ row_tag: point.row_tag, history_source: "device" }],
    });
  });

  it("clears another verified direct device's expired state after reauthentication", async () => {
    const secondDeviceID = "019f724a-3414-4d52-ae37-0c7024a1ab99";
    const secondDeviceSecret = "B".repeat(43);
    await registerDevice();
    await registerDevice(secondDeviceID, secondDeviceSecret, "b".repeat(64));
    for (const [id, secret] of [
      [deviceID, deviceSecret],
      [secondDeviceID, secondDeviceSecret],
    ] as const) {
      expect((await SELF.fetch(
        `https://push.example/v1/devices/${id}/accounts/${accountID}`,
        {
          method: "PUT",
          headers: { authorization: `Bearer ${secret}` },
          body: JSON.stringify(accountRequestBody("claude", 1)),
        },
      )).status).toBe(201);
    }
    const firstVerificationBody = accountRequestBody("claude", 1);
    firstVerificationBody.credentials.access_token = "first-verified-claude-access";
    firstVerificationBody.credentials.refresh_token = "first-verified-claude-refresh";
    const firstVerificationUpload = await testing.parseAccountUpload(new Request(
      "https://push.example/credential-replacement-test",
      { method: "PUT", body: JSON.stringify(firstVerificationBody) },
    ));
    expect((await testing.upsertMonitoredAccount(
      env,
      deviceID,
      accountID,
      firstVerificationUpload!,
      true,
      async (providerAccount, credentials, checkedAt) => ({
        credentials,
        account_identity: "claude-user:shared",
        snapshot: {
          provider_id: providerAccount.provider_id,
          plan: "Max",
          fetched_at: checkedAt ?? Math.floor(Date.now() / 1_000),
          windows: [],
          available_reset_count: 0,
          reset_credits: [],
        },
      }),
    )).status).toBe(200);
    await env.DB.prepare(
      `UPDATE monitored_accounts SET last_error = 'Provider returned HTTP 401.'
       WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).run();

    const replacementBody = accountRequestBody("claude", 1);
    replacementBody.credentials.access_token = "fresh-claude-access";
    replacementBody.credentials.refresh_token = "fresh-claude-refresh";
    const parsed = await testing.parseAccountUpload(new Request(
      "https://push.example/credential-replacement-test",
      { method: "PUT", body: JSON.stringify(replacementBody) },
    ));
    const replacement = await testing.upsertMonitoredAccount(
      env,
      secondDeviceID,
      accountID,
      parsed!,
      true,
      async (providerAccount, credentials, checkedAt) => ({
        credentials,
        account_identity: "claude-user:shared",
        snapshot: {
          provider_id: providerAccount.provider_id,
          plan: "Max",
          fetched_at: checkedAt ?? Math.floor(Date.now() / 1_000),
          windows: [],
          available_reset_count: 0,
          reset_credits: [],
        },
      }),
    );
    expect(replacement.status).toBe(200);

    const rows = await env.DB.prepare(
      `SELECT device_id, credential_fingerprint, last_error, latest_snapshot
       FROM monitored_accounts WHERE account_id = ? ORDER BY device_id`
    ).bind(accountID).all<{
      device_id: string;
      credential_fingerprint: string;
      last_error: string | null;
      latest_snapshot: string;
    }>();
    expect(rows.results).toHaveLength(2);
    expect(new Set(rows.results.map((row) => row.credential_fingerprint)).size).toBe(1);
    expect(rows.results.every((row) => row.last_error === null)).toBe(true);
    expect(rows.results.every((row) =>
      /^[A-Za-z0-9_-]{43}$/.test(JSON.parse(row.latest_snapshot).account_reference)
    )).toBe(true);
  });

  it("rotates a key-scoped provider credential without changing its Worker account scope", async () => {
    await registerDevice();
    const original = accountRequestBody("deepseek", 1);
    original.workspace_id = "deepseek-key-existing-scope";
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(original),
    })).status).toBe(201);

    const replacementBody = accountRequestBody("deepseek", 1);
    replacementBody.workspace_id = original.workspace_id;
    replacementBody.credentials.access_token = "rotated-deepseek-access-secret";
    const replacementUpload = await testing.parseAccountUpload(new Request(
      "https://push.example/credential-replacement-test",
      { method: "PUT", body: JSON.stringify(replacementBody) },
    ));
    const replacement = await testing.upsertMonitoredAccount(
      env,
      deviceID,
      accountID,
      replacementUpload!,
      true,
      async (providerAccount, credentials, checkedAt) => ({
        credentials,
        snapshot: {
          provider_id: providerAccount.provider_id,
          plan: providerAccount.plan,
          fetched_at: checkedAt ?? Math.floor(Date.now() / 1_000),
          windows: [],
          available_reset_count: 0,
          reset_credits: [],
        },
      }),
    );
    expect(replacement.status).toBe(200);
    const replacementJSON = await replacement.json<Record<string, unknown>>();
    expect(replacementJSON).not.toHaveProperty("credentials");
    expect(JSON.stringify(replacementJSON)).not.toContain("rotated-deepseek-access-secret");

    const row = await env.DB.prepare(
      "SELECT * FROM monitored_accounts WHERE device_id = ? AND account_id = ?"
    ).bind(deviceID, accountID).first();
    expect(row).not.toBeNull();
    expect(row!.workspace_id).toBe(original.workspace_id);
    expect((await testing.decryptCredentials(env, row as never)).access_token)
      .toBe("rotated-deepseek-access-secret");

    const wrongScope = accountRequestBody("deepseek", 1);
    wrongScope.workspace_id = "deepseek-key-different-scope";
    wrongScope.credentials.access_token = "other-deepseek-access-secret";
    const wrongScopeUpload = await testing.parseAccountUpload(new Request(
      "https://push.example/credential-replacement-test",
      { method: "PUT", body: JSON.stringify(wrongScope) },
    ));
    let providerCalled = false;
    const rejected = await testing.upsertMonitoredAccount(
      env,
      deviceID,
      accountID,
      wrongScopeUpload!,
      true,
      async () => {
        providerCalled = true;
        throw new Error("A mismatched scope must be rejected before provider access.");
      },
    );
    expect(rejected.status).toBe(409);
    expect(providerCalled).toBe(false);
  });

  it("migrates a legacy workspace reference to a provider-verified identity", async () => {
    await registerDevice();
    const original = accountRequestBody("chatgpt", 1);
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(original),
    })).status).toBe(201);
    const legacyReference = "l".repeat(43);
    await env.DB.prepare(
      `UPDATE monitored_accounts SET latest_snapshot = ?
       WHERE device_id = ? AND account_id = ?`
    ).bind(JSON.stringify({
      provider_id: "chatgpt",
      plan: "Plus",
      fetched_at: 2_000_000_000,
      windows: [],
      available_reset_count: 0,
      reset_credits: [],
      account_reference: legacyReference,
      account_reference_verified: true,
    }), deviceID, accountID).run();

    const replacementBody = accountRequestBody("chatgpt", 1);
    replacementBody.credentials.access_token = "verified-migration-access-secret";
    const replacementUpload = await testing.parseAccountUpload(new Request(
      "https://push.example/credential-replacement-test",
      { method: "PUT", body: JSON.stringify(replacementBody) },
    ));
    const response = await testing.upsertMonitoredAccount(
      env,
      deviceID,
      accountID,
      replacementUpload!,
      true,
      async (providerAccount, credentials, checkedAt) => ({
        credentials,
        account_identity: "provider-user:migrated-stable-identity",
        snapshot: {
          provider_id: providerAccount.provider_id,
          plan: providerAccount.plan,
          fetched_at: checkedAt ?? Math.floor(Date.now() / 1_000),
          windows: [],
          available_reset_count: 0,
          reset_credits: [],
        },
      }),
    );
    expect(response.status).toBe(200);
    const responseBody = await response.json<Record<string, unknown>>();
    expect(JSON.stringify(responseBody)).not.toContain("verified-migration-access-secret");
    expect(JSON.stringify(responseBody)).not.toContain("account_reference_verified");
    expect(JSON.stringify(responseBody)).not.toContain("account_reference_scope");
    const row = await env.DB.prepare(
      `SELECT * FROM monitored_accounts WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first();
    expect(row).not.toBeNull();
    expect((await testing.decryptCredentials(env, row as never)).access_token)
      .toBe("verified-migration-access-secret");
    const snapshot = JSON.parse((row as { latest_snapshot: string }).latest_snapshot);
    expect(snapshot.account_reference_verified).toBe(true);
    expect(snapshot.account_reference_scope).toBe("provider_account_v2");
    expect(snapshot.account_reference).not.toBe(legacyReference);
  });

  it("allows only one suspended legacy relink to win its credential and identity CAS", async () => {
    await registerDevice();
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody("chatgpt", 1)),
    })).status).toBe(201);
    await env.DB.prepare(
      `UPDATE monitored_accounts SET latest_snapshot = ?
       WHERE device_id = ? AND account_id = ?`
    ).bind(JSON.stringify({
      provider_id: "chatgpt",
      plan: "Plus",
      fetched_at: 2_000_000_000,
      windows: [],
      available_reset_count: 0,
      reset_credits: [],
      account_reference: "l".repeat(43),
      account_reference_verified: true,
    }), deviceID, accountID).run();

    const replacement = async (label: "a" | "b") => {
      const body = accountRequestBody("chatgpt", 1);
      body.credentials.access_token = `concurrent-${label}-access-secret`;
      const upload = await testing.parseAccountUpload(new Request(
        `https://push.example/concurrent-${label}`,
        { method: "PUT", body: JSON.stringify(body) },
      ));
      return upload!;
    };
    const uploadA = await replacement("a");
    const uploadB = await replacement("b");
    let started = 0;
    let markBothStarted: (() => void) | undefined;
    const bothStarted = new Promise<void>((resolve) => { markBothStarted = resolve; });
    let releaseA: (() => void) | undefined;
    let releaseB: (() => void) | undefined;
    const mayFinishA = new Promise<void>((resolve) => { releaseA = resolve; });
    const mayFinishB = new Promise<void>((resolve) => { releaseB = resolve; });
    const fetchFor = (label: "a" | "b", mayFinish: Promise<void>):
      Parameters<typeof testing.upsertMonitoredAccount>[5] =>
      async (providerAccount, credentials, checkedAt) => {
        started += 1;
        if (started === 2) markBothStarted?.();
        await mayFinish;
        return {
          credentials,
          account_identity: `provider-user:concurrent-${label}`,
          snapshot: {
            provider_id: providerAccount.provider_id,
            plan: providerAccount.plan,
            fetched_at: checkedAt ?? Math.floor(Date.now() / 1_000),
            windows: [],
            available_reset_count: 0,
            reset_credits: [],
          },
        };
      };

    const inFlightA = testing.upsertMonitoredAccount(
      env, deviceID, accountID, uploadA, true, fetchFor("a", mayFinishA),
    );
    const inFlightB = testing.upsertMonitoredAccount(
      env, deviceID, accountID, uploadB, true, fetchFor("b", mayFinishB),
    );
    await bothStarted;
    releaseA?.();
    const responseA = await inFlightA;
    expect(responseA.status).toBe(200);
    const responseABody = await responseA.json<Record<string, unknown>>();
    releaseB?.();
    const responseB = await inFlightB;
    expect(responseB.status).toBe(409);
    expect(await responseB.json()).toEqual({ error: "consent_revision_conflict" });

    const winner = await env.DB.prepare(
      `SELECT * FROM monitored_accounts WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first();
    expect(winner).not.toBeNull();
    expect((await testing.decryptCredentials(env, winner as never)).access_token)
      .toBe("concurrent-a-access-secret");
    expect(JSON.parse((winner as { latest_snapshot: string }).latest_snapshot))
      .toMatchObject({
        account_reference: responseABody.account_reference,
        account_reference_verified: true,
        account_reference_scope: "provider_account_v2",
      });
    expect(JSON.stringify(responseABody)).not.toContain("concurrent-a-access-secret");
    expect(JSON.stringify(responseABody)).not.toContain("concurrent-b-access-secret");
  });

  it("rejects a replacement when a previously verified provider identity differs", async () => {
    await registerDevice();
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody("chatgpt", 1)),
    })).status).toBe(201);
    const verify = async (accessToken: string, accountIdentity: string) => {
      const body = accountRequestBody("chatgpt", 1);
      body.credentials.access_token = accessToken;
      const upload = await testing.parseAccountUpload(new Request(
        "https://push.example/credential-replacement-test",
        { method: "PUT", body: JSON.stringify(body) },
      ));
      return testing.upsertMonitoredAccount(
        env,
        deviceID,
        accountID,
        upload!,
        true,
        async (providerAccount, credentials, checkedAt) => ({
          credentials,
          account_identity: accountIdentity,
          snapshot: {
            provider_id: providerAccount.provider_id,
            plan: providerAccount.plan,
            fetched_at: checkedAt ?? Math.floor(Date.now() / 1_000),
            windows: [],
            available_reset_count: 0,
            reset_credits: [],
          },
        }),
      );
    };
    expect((await verify(
      "first-verified-account-access-secret",
      "provider-user:first-verified-account",
    )).status).toBe(200);
    const before = await env.DB.prepare(
      `SELECT encrypted_credentials, latest_snapshot FROM monitored_accounts
       WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first<{
      encrypted_credentials: string;
      latest_snapshot: string;
    }>();

    const rejected = await verify(
      "different-verified-account-access-secret",
      "provider-user:different-verified-account",
    );
    expect(rejected.status).toBe(409);
    const rejectedBody = await rejected.json<Record<string, unknown>>();
    expect(rejectedBody).toEqual({ error: "provider_account_mismatch" });
    expect(JSON.stringify(rejectedBody)).not.toContain("different-verified-account-access-secret");
    const after = await env.DB.prepare(
      `SELECT encrypted_credentials, latest_snapshot FROM monitored_accounts
       WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first<{
      encrypted_credentials: string;
      latest_snapshot: string;
    }>();
    expect(after).toEqual(before);
    const stored = await env.DB.prepare(
      `SELECT * FROM monitored_accounts WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first();
    expect((await testing.decryptCredentials(env, stored as never)).access_token)
      .toBe("first-verified-account-access-secret");
  });

  it("rejects a stale identity-A propagation after its target moves to verified identity B", async () => {
    await registerDevice();
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody("chatgpt", 1)),
    })).status).toBe(201);
    const body = accountRequestBody("chatgpt", 1);
    body.credentials.access_token = "verified-a-access-secret";
    const upload = await testing.parseAccountUpload(new Request(
      "https://push.example/verify-a",
      { method: "PUT", body: JSON.stringify(body) },
    ));
    expect((await testing.upsertMonitoredAccount(
      env,
      deviceID,
      accountID,
      upload!,
      true,
      async (providerAccount, credentials, checkedAt) => ({
        credentials,
        account_identity: "provider-user:identity-a",
        snapshot: {
          provider_id: providerAccount.provider_id,
          plan: providerAccount.plan,
          fetched_at: checkedAt ?? Math.floor(Date.now() / 1_000),
          windows: [],
          available_reset_count: 0,
          reset_credits: [],
        },
      }),
    )).status).toBe(200);

    const capturedA = await testing.loadCredentialTarget(env, deviceID, accountID);
    expect(capturedA).not.toBeNull();
    const staleSnapshot = JSON.parse(capturedA!.latest_snapshot!);
    const identityBReference = "B".repeat(43);
    await env.DB.prepare(
      `UPDATE monitored_accounts SET latest_snapshot = ?
       WHERE device_id = ? AND account_id = ?`
    ).bind(JSON.stringify({
      ...staleSnapshot,
      account_reference: identityBReference,
      account_reference_verified: true,
      account_reference_scope: "provider_account_v2",
    }), deviceID, accountID).run();

    const staleApplied = await testing.applyVerifiedCredentialResult(
      env,
      capturedA!,
      {
        credentials: {
          access_token: "stale-propagated-a-access-secret",
          refresh_token: "stale-propagated-a-refresh-secret",
          id_token: "",
          expires_at: 2_000_000_000,
        },
        account_identity: "provider-user:identity-a",
        snapshot: {
          ...staleSnapshot,
          fetched_at: staleSnapshot.fetched_at + 60,
        },
      } as never,
    );
    expect(staleApplied).toBe(false);
    const retainedB = await env.DB.prepare(
      `SELECT * FROM monitored_accounts WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first();
    expect(JSON.parse((retainedB as { latest_snapshot: string }).latest_snapshot))
      .toMatchObject({ account_reference: identityBReference });
    expect((await testing.decryptCredentials(env, retainedB as never)).access_token)
      .toBe("verified-a-access-secret");
    expect(JSON.stringify(retainedB)).not.toContain("stale-propagated-a-access-secret");
  });

  it("rotates an imported remote credential without exposing its source workspace", async () => {
    const subscriberDeviceID = "019f724a-3414-4d52-ae37-0c7024a1ab99";
    const subscriberSecret = "B".repeat(43);
    const localAccountID = "019f724a-3414-4d52-ae37-0c7024a1aba0";
    await registerDevice();
    await registerDevice(subscriberDeviceID, subscriberSecret, "b".repeat(64));

    const sourceBody = accountRequestBody("deepseek", 1);
    sourceBody.workspace_id = "deepseek-key-source-scope";
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(sourceBody),
    })).status).toBe(201);
    await env.DB.prepare(
      `INSERT INTO remote_account_subscriptions (
         subscriber_device_id, local_account_id, source_device_id, source_account_id, created_at
       ) VALUES (?, ?, ?, ?, ?)`
    ).bind(subscriberDeviceID, localAccountID, deviceID, accountID, 2_000_000_000).run();

    const replacementBody = accountRequestBody("deepseek", 1);
    replacementBody.workspace_id = `when-reset.remote.${"r".repeat(43)}`;
    replacementBody.credentials.access_token = "rotated-remote-deepseek-secret";
    const replacementUpload = await testing.parseAccountUpload(new Request(
      "https://push.example/credential-replacement-test",
      { method: "PUT", body: JSON.stringify(replacementBody) },
    ));
    let verifiedScope: string | null = null;
    const replacement = await testing.upsertMonitoredAccount(
      env,
      subscriberDeviceID,
      localAccountID,
      replacementUpload!,
      true,
      async (providerAccount, credentials, checkedAt) => {
        verifiedScope = providerAccount.workspace_id;
        return {
          credentials,
          snapshot: {
            provider_id: providerAccount.provider_id,
            plan: providerAccount.plan,
            fetched_at: checkedAt ?? Math.floor(Date.now() / 1_000),
            windows: [],
            available_reset_count: 0,
            reset_credits: [],
          },
        };
      },
    );
    expect(replacement.status).toBe(200);
    expect(verifiedScope).toBe(sourceBody.workspace_id);
    const responseJSON = await replacement.json<Record<string, unknown>>();
    expect(responseJSON).not.toHaveProperty("workspace_id");
    expect(responseJSON).not.toHaveProperty("credentials");
    expect(JSON.stringify(responseJSON)).not.toContain("rotated-remote-deepseek-secret");

    const sourceRow = await env.DB.prepare(
      "SELECT * FROM monitored_accounts WHERE device_id = ? AND account_id = ?"
    ).bind(deviceID, accountID).first();
    expect(sourceRow!.workspace_id).toBe(sourceBody.workspace_id);
    expect((await testing.decryptCredentials(env, sourceRow as never)).access_token)
      .toBe("rotated-remote-deepseek-secret");
  });

  it("notifies the owner and every enabled subscriber after a remote credential relink", async () => {
    const callerDeviceID = "019f724a-3414-4d52-ae37-0c7024a1ab99";
    const secondSubscriberDeviceID = "019f724a-3414-4d52-ae37-0c7024a1aba0";
    const disabledSubscriberDeviceID = "019f724a-3414-4d52-ae37-0c7024a1aba1";
    const callerLocalAccountID = "019f724a-3414-4d52-ae37-0c7024a1aba2";
    const secondLocalAccountID = "019f724a-3414-4d52-ae37-0c7024a1aba3";
    const disabledLocalAccountID = "019f724a-3414-4d52-ae37-0c7024a1aba4";
    const callerToken = "b".repeat(64);
    const secondToken = "c".repeat(64);
    const disabledToken = "d".repeat(64);
    await registerDevice();
    await registerDevice(callerDeviceID, "B".repeat(43), callerToken);
    await registerDevice(secondSubscriberDeviceID, "C".repeat(43), secondToken);
    await registerDevice(disabledSubscriberDeviceID, "D".repeat(43), disabledToken);
    const sourceBody = accountRequestBody("deepseek", 1);
    sourceBody.workspace_id = "remote-push-source-scope";
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(sourceBody),
    })).status).toBe(201);
    await env.DB.batch([
      ...[
        [callerDeviceID, callerLocalAccountID],
        [secondSubscriberDeviceID, secondLocalAccountID],
        [disabledSubscriberDeviceID, disabledLocalAccountID],
      ].map(([subscriberDeviceID, localAccountID]) => env.DB.prepare(
        `INSERT INTO remote_account_subscriptions (
           subscriber_device_id, local_account_id, source_device_id, source_account_id, created_at
         ) VALUES (?, ?, ?, ?, ?)`
      ).bind(subscriberDeviceID, localAccountID, deviceID, accountID, 2_000_000_000)),
      env.DB.prepare(
        "UPDATE devices SET push_disabled_at = ? WHERE device_id = ?"
      ).bind(2_000_000_000, disabledSubscriberDeviceID),
    ]);

    const queued: Array<Record<string, unknown>> = [];
    const testEnv = {
      DB: env.DB,
      REGISTRATION_ACCESS_KEY: env.REGISTRATION_ACCESS_KEY,
      CREDENTIAL_ENCRYPTION_KEY: env.CREDENTIAL_ENCRYPTION_KEY,
      PUSH_QUEUE: {
        sendBatch: async (messages: { body: Record<string, unknown> }[]) => {
          queued.push(...messages.map((message) => message.body));
        },
      },
    } as unknown as Env;
    const replacementBody = accountRequestBody("deepseek", 1);
    replacementBody.workspace_id = `when-reset.remote.${"r".repeat(43)}`;
    replacementBody.credentials.access_token = "remote-relink-push-access-secret";
    const upload = await testing.parseAccountUpload(new Request(
      "https://push.example/remote-relink-push",
      { method: "PUT", body: JSON.stringify(replacementBody) },
    ));
    const response = await testing.upsertMonitoredAccount(
      testEnv,
      callerDeviceID,
      callerLocalAccountID,
      upload!,
      true,
      async (providerAccount, credentials, checkedAt) => ({
        credentials,
        snapshot: {
          provider_id: providerAccount.provider_id,
          plan: providerAccount.plan,
          fetched_at: checkedAt ?? Math.floor(Date.now() / 1_000),
          windows: [],
          available_reset_count: 0,
          reset_credits: [],
        },
      }),
    );
    expect(response.status).toBe(200);
    const pushes = queued.filter((message) => message.kind === "push");
    const pushedDeviceIDs = pushes.map((message) => message.device_id as string);
    expect(pushedDeviceIDs.sort()).toEqual([
      deviceID, callerDeviceID, secondSubscriberDeviceID,
    ].sort());
    expect(new Set(pushedDeviceIDs).size).toBe(3);
    expect(pushes).toEqual(expect.arrayContaining([
      expect.objectContaining({ device_id: deviceID, apns_token: apnsToken }),
      expect.objectContaining({ device_id: callerDeviceID, apns_token: callerToken }),
      expect.objectContaining({
        device_id: secondSubscriberDeviceID,
        apns_token: secondToken,
      }),
    ]));
    expect(pushes).not.toContainEqual(expect.objectContaining({
      device_id: disabledSubscriberDeviceID,
    }));
    expect(JSON.stringify(pushes)).not.toContain("remote-relink-push-access-secret");
    expect(JSON.stringify(pushes)).not.toContain("refresh-secret");
    expect(JSON.stringify(pushes)).not.toContain("id-secret");
  });

  it("rejects stale direct and replayed remote consent revisions before provider verification", async () => {
    const subscriberDeviceID = "019f724a-3414-4d52-ae37-0c7024a1ab99";
    const subscriberSecret = "B".repeat(43);
    const localAccountID = "019f724a-3414-4d52-ae37-0c7024a1aba0";
    await registerDevice();
    await registerDevice(subscriberDeviceID, subscriberSecret, "b".repeat(64));
    const sourceBody = accountRequestBody("deepseek", 2);
    sourceBody.workspace_id = "revision-guarded-source";
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(sourceBody),
    })).status).toBe(201);
    await env.DB.prepare(
      `INSERT INTO remote_account_subscriptions (
         subscriber_device_id, local_account_id, source_device_id, source_account_id, created_at
       ) VALUES (?, ?, ?, ?, ?)`
    ).bind(subscriberDeviceID, localAccountID, deviceID, accountID, 2_000_000_000).run();
    const before = await env.DB.prepare(
      `SELECT encrypted_credentials FROM monitored_accounts
       WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first<{ encrypted_credentials: string }>();
    let providerChecks = 0;
    const mustNotVerify: Parameters<typeof testing.upsertMonitoredAccount>[5] = async () => {
      providerChecks += 1;
      throw new Error("A rejected revision must not reach the provider.");
    };

    const staleDirectBody = accountRequestBody("deepseek", 1);
    staleDirectBody.workspace_id = sourceBody.workspace_id;
    staleDirectBody.credentials.access_token = "stale-direct-replacement-secret";
    const staleDirectUpload = await testing.parseAccountUpload(new Request(
      "https://push.example/credential-replacement-test",
      { method: "PUT", body: JSON.stringify(staleDirectBody) },
    ));
    const staleDirect = await testing.upsertMonitoredAccount(
      env, deviceID, accountID, staleDirectUpload!, true, mustNotVerify,
    );
    expect(staleDirect.status).toBe(409);
    const staleDirectResponse = await staleDirect.json<Record<string, unknown>>();
    expect(staleDirectResponse).toEqual({ error: "consent_revision_conflict" });
    expect(JSON.stringify(staleDirectResponse)).not.toContain("stale-direct-replacement-secret");

    const replayedRemoteBody = accountRequestBody("deepseek", 2);
    replayedRemoteBody.workspace_id = `when-reset.remote.${"r".repeat(43)}`;
    replayedRemoteBody.credentials.access_token = "replayed-remote-replacement-secret";
    const replayedRemoteUpload = await testing.parseAccountUpload(new Request(
      "https://push.example/credential-replacement-test",
      { method: "PUT", body: JSON.stringify(replayedRemoteBody) },
    ));
    const replayedRemote = await testing.upsertMonitoredAccount(
      env, subscriberDeviceID, localAccountID, replayedRemoteUpload!, true, mustNotVerify,
    );
    expect(replayedRemote.status).toBe(409);
    const replayedRemoteResponse = await replayedRemote.json<Record<string, unknown>>();
    expect(replayedRemoteResponse).toEqual({ error: "consent_revision_conflict" });
    expect(JSON.stringify(replayedRemoteResponse))
      .not.toContain("replayed-remote-replacement-secret");
    expect(providerChecks).toBe(0);
    expect(await env.DB.prepare(
      `SELECT encrypted_credentials FROM monitored_accounts
       WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first()).toEqual(before);
  });

  it("does not apply a remote credential verified across source disable and re-enable", async () => {
    const subscriberDeviceID = "019f724a-3414-4d52-ae37-0c7024a1ab99";
    const subscriberSecret = "B".repeat(43);
    const localAccountID = "019f724a-3414-4d52-ae37-0c7024a1aba0";
    await registerDevice();
    await registerDevice(subscriberDeviceID, subscriberSecret, "b".repeat(64));
    const sourceBody = accountRequestBody("deepseek", 1);
    sourceBody.workspace_id = "raced-source-scope";
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(sourceBody),
    })).status).toBe(201);
    await env.DB.prepare(
      `INSERT INTO remote_account_subscriptions (
         subscriber_device_id, local_account_id, source_device_id, source_account_id, created_at
       ) VALUES (?, ?, ?, ?, ?)`
    ).bind(subscriberDeviceID, localAccountID, deviceID, accountID, 2_000_000_000).run();

    const replacementBody = accountRequestBody("deepseek", 1);
    replacementBody.workspace_id = `when-reset.remote.${"r".repeat(43)}`;
    replacementBody.credentials.access_token = "verified-before-disable-secret";
    const replacementUpload = await testing.parseAccountUpload(new Request(
      "https://push.example/credential-replacement-test",
      { method: "PUT", body: JSON.stringify(replacementBody) },
    ));
    let markVerificationStarted: (() => void) | undefined;
    let releaseVerification: (() => void) | undefined;
    const verificationStarted = new Promise<void>((resolve) => {
      markVerificationStarted = resolve;
    });
    const verificationMayFinish = new Promise<void>((resolve) => {
      releaseVerification = resolve;
    });
    const replacement = testing.upsertMonitoredAccount(
      env,
      subscriberDeviceID,
      localAccountID,
      replacementUpload!,
      true,
      async (providerAccount, credentials, checkedAt) => {
        markVerificationStarted?.();
        await verificationMayFinish;
        return {
          credentials,
          snapshot: {
            provider_id: providerAccount.provider_id,
            plan: providerAccount.plan,
            fetched_at: checkedAt ?? Math.floor(Date.now() / 1_000),
            windows: [],
            available_reset_count: 0,
            reset_credits: [],
          },
        };
      },
    );
    await verificationStarted;

    expect((await SELF.fetch(`${accountURL}?consent_revision=2`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${deviceSecret}` },
    })).status).toBe(204);
    const reenabledBody = accountRequestBody("deepseek", 3);
    reenabledBody.workspace_id = sourceBody.workspace_id;
    reenabledBody.credentials.access_token = "newly-relinked-source-secret";
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(reenabledBody),
    })).status).toBe(201);
    releaseVerification?.();

    const response = await replacement;
    expect(response.status).toBe(409);
    const responseBody = await response.json<Record<string, unknown>>();
    expect(responseBody).toEqual({ error: "consent_revision_conflict" });
    const serialized = JSON.stringify(responseBody);
    expect(serialized).not.toContain("verified-before-disable-secret");
    expect(serialized).not.toContain("newly-relinked-source-secret");
    const sourceRow = await env.DB.prepare(
      `SELECT * FROM monitored_accounts WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first();
    expect(sourceRow).not.toBeNull();
    expect((await testing.decryptCredentials(env, sourceRow as never)).access_token)
      .toBe("newly-relinked-source-secret");
    expect(await env.DB.prepare(
      `SELECT consent_revision, enabled FROM account_monitoring_consent
       WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first()).toEqual({ consent_revision: 3, enabled: 1 });
  });

  it("merges retained history for one provider-verified identity without duplicating it logically", async () => {
    const duplicateDeviceID = "019f724a-3414-4d52-ae37-0c7024a1ab99";
    const duplicateDeviceSecret = "B".repeat(43);
    const duplicateAccountID = "019f724a-3414-4d52-ae37-0c7024a1aba0";
    const duplicateURL =
      `https://push.example/v1/devices/${duplicateDeviceID}/accounts/${duplicateAccountID}`;
    await registerDevice();
    await registerDevice(duplicateDeviceID, duplicateDeviceSecret, "b".repeat(64));
    const firstBody = accountRequestBody("deepseek", 1);
    firstBody.workspace_id = "first-uploaded-scope";
    const duplicateBody = accountRequestBody("deepseek", 1);
    duplicateBody.workspace_id = "replacement-uploaded-scope";
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(firstBody),
    })).status).toBe(201);
    expect((await SELF.fetch(duplicateURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${duplicateDeviceSecret}` },
      body: JSON.stringify(duplicateBody),
    })).status).toBe(201);

    const verify = async (
      ownerDeviceID: string,
      id: string,
      body: ReturnType<typeof accountRequestBody>,
      accessToken: string,
    ) => {
      body.credentials.access_token = accessToken;
      const upload = await testing.parseAccountUpload(new Request(
        "https://push.example/credential-replacement-test",
        { method: "PUT", body: JSON.stringify(body) },
      ));
      return testing.upsertMonitoredAccount(
        env,
        ownerDeviceID,
        id,
        upload!,
        true,
        async (providerAccount, credentials, checkedAt) => ({
          credentials,
          account_identity: "provider-user:stable-123",
          snapshot: {
            provider_id: providerAccount.provider_id,
            plan: providerAccount.plan,
            fetched_at: checkedAt ?? Math.floor(Date.now() / 1_000),
            windows: [],
            available_reset_count: 0,
            reset_credits: [],
          },
        }),
      );
    };
    const firstVerification = await verify(
      deviceID, accountID,
      { ...firstBody, credentials: { ...firstBody.credentials } },
      "first-verified-identity-secret",
    );
    expect(firstVerification.status).toBe(200);
    const firstResponse = await firstVerification.json<Record<string, unknown>>();
    expect(JSON.stringify(firstResponse)).not.toContain("first-verified-identity-secret");
    expect(JSON.stringify(firstResponse)).not.toContain("account_reference_verified");
    expect(JSON.stringify(firstResponse)).not.toContain("account_reference_scope");

    const firstRecordedAt = Math.floor(Date.now() / 1_000) - 600;
    const duplicateRecordedAt = firstRecordedAt + 300;
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO usage_history (
           device_id, account_id, row_tag, history_source, provider_id,
           metric_id, metric_title, kind, window_minutes, remaining_percent,
           recorded_at, resets_at, seconds_until_reset, plan
         ) VALUES (?, ?, ?, 'worker', 'deepseek', 'legacy', 'Legacy quota',
                   'weekly', 10080, 68, ?, ?, 3600, 'Plus')`
      ).bind(
        deviceID, accountID, `h1.${accountID}.bGVnYWN5.${firstRecordedAt}`,
        firstRecordedAt, firstRecordedAt + 3_600,
      ),
      env.DB.prepare(
        `INSERT INTO usage_history (
           device_id, account_id, row_tag, history_source, provider_id,
           metric_id, metric_title, kind, window_minutes, remaining_percent,
           recorded_at, resets_at, seconds_until_reset, plan
         ) VALUES (?, ?, ?, 'device', 'deepseek', 'current', 'Current quota',
                   'weekly', 10080, 54, ?, ?, 3600, 'Plus')`
      ).bind(
        duplicateDeviceID, duplicateAccountID,
        `h1.${duplicateAccountID}.Y3VycmVudA.${duplicateRecordedAt}`,
        duplicateRecordedAt, duplicateRecordedAt + 3_600,
      ),
    ]);

    const duplicateVerification = await verify(
      duplicateDeviceID, duplicateAccountID,
      { ...duplicateBody, credentials: { ...duplicateBody.credentials } },
      "replacement-verified-identity-secret",
    );
    expect(duplicateVerification.status).toBe(200);
    const duplicateResponse = await duplicateVerification.json<Record<string, unknown>>();
    const serialized = JSON.stringify(duplicateResponse);
    expect(serialized).not.toContain("replacement-verified-identity-secret");
    expect(serialized).not.toContain("account_reference_verified");
    expect(serialized).not.toContain("account_reference_scope");

    for (const [ownerDeviceID, ownerSecret, id, peerAccountID] of [
      [deviceID, deviceSecret, accountID, duplicateAccountID],
      [duplicateDeviceID, duplicateDeviceSecret, duplicateAccountID, accountID],
    ] as const) {
      const response = await SELF.fetch(
        `https://push.example/v1/devices/${ownerDeviceID}/accounts/${id}/sync?since=0`,
        { headers: { authorization: `Bearer ${ownerSecret}` } },
      );
      expect(response.status).toBe(200);
      const serialized = await response.text();
      expect(serialized).not.toContain(peerAccountID);
      const body = JSON.parse(serialized) as { history: Array<{
        metric_id: string;
        row_tag: string;
      }> };
      expect(body.history.map((point) => point.metric_id).sort())
        .toEqual(["current", "legacy"]);
      expect(body.history.every((point) => point.row_tag.includes(id))).toBe(true);
    }
    const repeatedVerification = await verify(
      duplicateDeviceID, duplicateAccountID,
      { ...duplicateBody, credentials: { ...duplicateBody.credentials } },
      "second-refresh-same-verified-identity-secret",
    );
    expect(repeatedVerification.status).toBe(200);
    expect(JSON.stringify(await repeatedVerification.json()))
      .not.toContain("second-refresh-same-verified-identity-secret");
    // Logical union keeps refresh work bounded: verification does not copy retained rows.
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM usage_history")
      .first<{ count: number }>()).toEqual({ count: 2 });
    const candidates = await SELF.fetch(
      `https://push.example/v1/devices/${deviceID}/remote-accounts`,
      { headers: { authorization: `Bearer ${deviceSecret}` } },
    );
    expect(candidates.status).toBe(200);
    expect((await candidates.json<{ accounts: unknown[] }>()).accounts).toHaveLength(1);
  });

  it("does not merge matching metadata or workspace when verified provider identities differ", async () => {
    const otherAccountID = "019f724a-3414-4d52-ae37-0c7024a1aba0";
    const otherURL = `https://push.example/v1/devices/${deviceID}/accounts/${otherAccountID}`;
    await registerDevice();
    for (const [id, url] of [[accountID, accountURL], [otherAccountID, otherURL]] as const) {
      const body = accountRequestBody("deepseek", 1);
      body.workspace_id = "same-unverified-workspace";
      expect((await SELF.fetch(url, {
        method: "PUT",
        headers: { authorization: `Bearer ${deviceSecret}` },
        body: JSON.stringify(body),
      })).status).toBe(201);
      const replacement = accountRequestBody("deepseek", 1);
      replacement.workspace_id = body.workspace_id;
      replacement.credentials.access_token = `private-${id}`;
      const upload = await testing.parseAccountUpload(new Request(
        "https://push.example/credential-replacement-test",
        { method: "PUT", body: JSON.stringify(replacement) },
      ));
      const response = await testing.upsertMonitoredAccount(
        env,
        deviceID,
        id,
        upload!,
        true,
        async (providerAccount, credentials, checkedAt) => ({
          credentials,
          account_identity: id === accountID ? "provider-user:first" : "provider-user:second",
          snapshot: {
            provider_id: providerAccount.provider_id,
            plan: providerAccount.plan,
            fetched_at: checkedAt ?? Math.floor(Date.now() / 1_000),
            windows: [],
            available_reset_count: 0,
            reset_credits: [],
          },
        }),
      );
      expect(response.status).toBe(200);
      expect(JSON.stringify(await response.json())).not.toContain(`private-${id}`);
    }
    const recordedAt = Math.floor(Date.now() / 1_000) - 600;
    await env.DB.prepare(
      `INSERT INTO usage_history (
         device_id, account_id, row_tag, history_source, provider_id,
         metric_id, metric_title, kind, window_minutes, remaining_percent,
         recorded_at, resets_at, seconds_until_reset, plan
       ) VALUES (?, ?, ?, 'worker', 'deepseek', 'only-first', 'Only first',
                 'weekly', 10080, 80, ?, ?, 3600, 'Plus')`
    ).bind(
      deviceID, accountID, `h1.${accountID}.b25seS1maXJzdA.${recordedAt}`,
      recordedAt, recordedAt + 3_600,
    ).run();

    const secondSync = await SELF.fetch(
      `${otherURL}/sync?since=0`,
      { headers: { authorization: `Bearer ${deviceSecret}` } },
    );
    expect(secondSync.status).toBe(200);
    expect(await secondSync.json()).toMatchObject({ history: [] });
    const firstRow = await env.DB.prepare(
      `SELECT * FROM monitored_accounts WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first();
    const secondRow = await env.DB.prepare(
      `SELECT * FROM monitored_accounts WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, otherAccountID).first();
    expect((await testing.decryptCredentials(env, firstRow as never)).access_token)
      .toBe(`private-${accountID}`);
    expect((await testing.decryptCredentials(env, secondRow as never)).access_token)
      .toBe(`private-${otherAccountID}`);
    const candidates = await SELF.fetch(
      `https://push.example/v1/devices/${deviceID}/remote-accounts`,
      { headers: { authorization: `Bearer ${deviceSecret}` } },
    );
    expect((await candidates.json<{ accounts: unknown[] }>()).accounts).toHaveLength(2);
  });

  it("accepts legacy uploads without identity metadata and rejects malformed metadata", async () => {
    await registerDevice();
    const { metadata: _metadata, ...legacyBody } = accountRequestBody();
    const legacy = await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(legacyBody),
    });
    expect(legacy.status).toBe(201);
    expect(await legacy.json()).toMatchObject({
      metadata: {
        name: null,
        email: null,
        plan: "Plus",
        plan_expires_at: null,
        trial_expires_at: null,
      },
    });

    const malformed = accountRequestBody("chatgpt", 2);
    malformed.metadata.email = "x".repeat(321);
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(malformed),
    })).status).toBe(400);
  });

  it("lists and idempotently attaches an eligible account owned by the device", async () => {
    await registerDevice();
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody("chatgpt", 2)),
    })).status).toBe(201);

    const response = await SELF.fetch(
      `https://push.example/v1/devices/${deviceID}/remote-accounts`,
      { headers: { authorization: `Bearer ${deviceSecret}` } },
    );
    expect(response.status).toBe(200);
    const body = await response.json<{
      accounts: Array<Record<string, unknown> & { remote_account_id: string }>;
    }>();
    expect(body.accounts).toEqual([
      expect.objectContaining({
        provider_id: "chatgpt",
        display_name: "Worker account",
        session_status: "unchecked",
        session_checked_at: null,
      }),
    ]);
    expect(body.accounts[0].remote_account_id).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const serialized = JSON.stringify(body);
    for (const privateValue of [
      deviceID, accountID, "workspace-123", "access-secret", "refresh-secret", "id-secret",
    ]) {
      expect(serialized).not.toContain(privateValue);
    }
    expect(body.accounts[0]).not.toHaveProperty("credentials");
    expect(body.accounts[0]).not.toHaveProperty("encrypted_credentials");
    expect(body.accounts[0]).not.toHaveProperty("credential_fingerprint");
    expect(body.accounts[0]).not.toHaveProperty("workspace_id");
    expect(body.accounts[0]).not.toHaveProperty("device_id");
    expect(body.accounts[0]).not.toHaveProperty("account_id");
    expect(body.accounts[0]).not.toHaveProperty("consent_revision");

    const attachment = await SELF.fetch(
      `https://push.example/v1/devices/${deviceID}/remote-accounts`,
      {
        method: "POST",
        headers: { authorization: `Bearer ${deviceSecret}` },
        body: JSON.stringify({
          remote_account_id: body.accounts[0].remote_account_id,
          local_account_id: accountID,
        }),
      },
    );
    expect(attachment.status).toBe(200);
    const attachmentBody = await attachment.json<{
      account: Record<string, unknown> & { local_account_id: string };
    }>();
    expect(attachmentBody.account).toMatchObject({
      remote_account_id: body.accounts[0].remote_account_id,
      local_account_id: accountID,
      provider_id: "chatgpt",
      consent_revision: 2,
      session_status: "unchecked",
    });
    expect(attachmentBody.account).not.toHaveProperty("credentials");
    expect(attachmentBody.account).not.toHaveProperty("encrypted_credentials");
    expect(attachmentBody.account).not.toHaveProperty("credential_fingerprint");
    expect(attachmentBody.account).not.toHaveProperty("workspace_id");
    expect(attachmentBody.account).not.toHaveProperty("source_device_id");
    expect(attachmentBody.account).not.toHaveProperty("source_account_id");
    expect(attachmentBody.account).not.toHaveProperty("device_id");
    expect(attachmentBody.account).not.toHaveProperty("account_id");
    expect(JSON.stringify(attachmentBody)).not.toContain("workspace-123");
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM remote_account_subscriptions"
    ).first()).toEqual({ count: 0 });
    const directSync = await SELF.fetch(`${accountURL}/sync`, {
      headers: { authorization: `Bearer ${deviceSecret}` },
    });
    expect(directSync.status).toBe(200);
    expect(await directSync.json()).toMatchObject({ consent_revision: 2 });
  });

  it("lists an expired credential-backed account even before it has a snapshot", async () => {
    await registerDevice();
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody()),
    })).status).toBe(201);
    const checkedAt = Math.floor(Date.now() / 1_000) - 120;
    await env.DB.prepare(
      `UPDATE monitored_accounts SET latest_snapshot = NULL, last_refresh_at = ?,
         last_success_at = NULL, last_error = 'Provider returned HTTP 401.'
       WHERE device_id = ? AND account_id = ?`
    ).bind(checkedAt, deviceID, accountID).run();

    const subscriberDeviceID = "019f724a-3414-4d52-ae37-0c7024a1ab99";
    const subscriberSecret = "B".repeat(43);
    await registerDevice(subscriberDeviceID, subscriberSecret, "b".repeat(64));
    const response = await SELF.fetch(
      `https://push.example/v1/devices/${subscriberDeviceID}/remote-accounts`,
      { headers: { authorization: `Bearer ${subscriberSecret}` } },
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      accounts: [{
        provider_id: "chatgpt",
        display_name: "Worker account",
        last_success_at: null,
        session_status: "expired",
        session_checked_at: checkedAt,
      }],
    });
  });

  it("rediscovers and safely rebinds a stale remote subscription", async () => {
    await registerDevice();
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody()),
    })).status).toBe(201);

    const subscriberDeviceID = "019f724a-3414-4d52-ae37-0c7024a1ab99";
    const subscriberSecret = "B".repeat(43);
    await registerDevice(subscriberDeviceID, subscriberSecret, "b".repeat(64));
    const remoteAccountsURL =
      `https://push.example/v1/devices/${subscriberDeviceID}/remote-accounts`;
    const available = await SELF.fetch(remoteAccountsURL, {
      headers: { authorization: `Bearer ${subscriberSecret}` },
    });
    const availableBody = await available.json<{
      accounts: Array<{ remote_account_id: string }>;
    }>();
    expect(availableBody.accounts).toHaveLength(1);
    const remoteAccountID = availableBody.accounts[0].remote_account_id;
    const staleLocalAccountID = "019f724a-3414-4d52-ae37-0c7024a1aba0";
    const recoveredLocalAccountID = "019f724a-3414-4d52-ae37-0c7024a1aba1";
    const importAccount = (localAccountID: string) => SELF.fetch(remoteAccountsURL, {
      method: "POST",
      headers: { authorization: `Bearer ${subscriberSecret}` },
      body: JSON.stringify({
        remote_account_id: remoteAccountID,
        local_account_id: localAccountID,
      }),
    });

    expect((await importAccount(staleLocalAccountID)).status).toBe(201);
    const rediscovered = await SELF.fetch(remoteAccountsURL, {
      headers: { authorization: `Bearer ${subscriberSecret}` },
    });
    expect(await rediscovered.json()).toMatchObject({
      accounts: [{ remote_account_id: remoteAccountID }],
    });

    const rebound = await importAccount(recoveredLocalAccountID);
    expect(rebound.status).toBe(200);
    expect(await rebound.json()).toMatchObject({
      account: {
        remote_account_id: remoteAccountID,
        local_account_id: recoveredLocalAccountID,
      },
    });
    expect(await env.DB.prepare(
      `SELECT local_account_id FROM remote_account_subscriptions
       WHERE subscriber_device_id = ?`
    ).bind(subscriberDeviceID).all<{ local_account_id: string }>()).toMatchObject({
      results: [{ local_account_id: recoveredLocalAccountID }],
    });
    expect((await SELF.fetch(
      `https://push.example/v1/devices/${subscriberDeviceID}/accounts/${staleLocalAccountID}/sync`,
      { headers: { authorization: `Bearer ${subscriberSecret}` } },
    )).status).toBe(404);
    expect((await SELF.fetch(
      `https://push.example/v1/devices/${subscriberDeviceID}/accounts/${recoveredLocalAccountID}/sync`,
      { headers: { authorization: `Bearer ${subscriberSecret}` } },
    )).status).toBe(200);

    const directAccountID = "019f724a-3414-4d52-ae37-0c7024a1aba2";
    const directBody = accountRequestBody("claude", 1);
    directBody.workspace_id = "direct-claude-account";
    expect((await SELF.fetch(
      `https://push.example/v1/devices/${subscriberDeviceID}/accounts/${directAccountID}`,
      {
        method: "PUT",
        headers: { authorization: `Bearer ${subscriberSecret}` },
        body: JSON.stringify(directBody),
      },
    )).status).toBe(201);
    const conflict = await importAccount(directAccountID);
    expect(conflict.status).toBe(409);
    expect(await conflict.json()).toEqual({ error: "local_account_conflict" });
    expect(await env.DB.prepare(
      `SELECT local_account_id FROM remote_account_subscriptions
       WHERE subscriber_device_id = ?`
    ).bind(subscriberDeviceID).first()).toEqual({
      local_account_id: recoveredLocalAccountID,
    });
  });

  it("atomically chooses either a direct account or remote subscription under race", async () => {
    await registerDevice();
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody()),
    })).status).toBe(201);

    const subscriberDeviceID = "019f724a-3414-4d52-ae37-0c7024a1ab99";
    const subscriberSecret = "B".repeat(43);
    const localAccountID = "019f724a-3414-4d52-ae37-0c7024a1aba0";
    await registerDevice(subscriberDeviceID, subscriberSecret, "b".repeat(64));
    const remoteAccountsURL =
      `https://push.example/v1/devices/${subscriberDeviceID}/remote-accounts`;
    const candidatesResponse = await SELF.fetch(remoteAccountsURL, {
      headers: { authorization: `Bearer ${subscriberSecret}` },
    });
    const candidates = await candidatesResponse.json<{
      accounts: Array<{ remote_account_id: string }>;
    }>();
    expect(candidates.accounts).toHaveLength(1);

    const directBody = accountRequestBody("claude", 1);
    directBody.workspace_id = "race-direct-claude";
    directBody.credentials.access_token = "race-direct-access-secret";
    const directURL =
      `https://push.example/v1/devices/${subscriberDeviceID}/accounts/${localAccountID}`;
    const [directResponse, importResponse] = await Promise.all([
      SELF.fetch(directURL, {
        method: "PUT",
        headers: { authorization: `Bearer ${subscriberSecret}` },
        body: JSON.stringify(directBody),
      }),
      SELF.fetch(remoteAccountsURL, {
        method: "POST",
        headers: { authorization: `Bearer ${subscriberSecret}` },
        body: JSON.stringify({
          remote_account_id: candidates.accounts[0].remote_account_id,
          local_account_id: localAccountID,
        }),
      }),
    ]);
    expect([directResponse.status, importResponse.status].sort()).toEqual([201, 409]);
    const directResponseBody = await directResponse.json<Record<string, unknown>>();
    const importResponseBody = await importResponse.json<Record<string, unknown>>();
    expect(JSON.stringify([directResponseBody, importResponseBody]))
      .not.toContain("race-direct-access-secret");
    if (directResponse.status === 409) {
      expect(directResponseBody).toEqual({ error: "remote_account_is_read_only" });
    }
    if (importResponse.status === 409) {
      expect(importResponseBody).toEqual({ error: "local_account_conflict" });
    }

    const invariant = await env.DB.prepare(
      `SELECT
         (SELECT COUNT(*) FROM monitored_accounts
          WHERE device_id = ? AND account_id = ?) AS direct_count,
         (SELECT COUNT(*) FROM remote_account_subscriptions
          WHERE subscriber_device_id = ? AND local_account_id = ?) AS subscription_count`
    ).bind(
      subscriberDeviceID, localAccountID, subscriberDeviceID, localAccountID,
    ).first<{ direct_count: number; subscription_count: number }>();
    expect(invariant).not.toBeNull();
    expect(invariant!.direct_count + invariant!.subscription_count).toBe(1);
    expect((await SELF.fetch(`${directURL}/sync`, {
      headers: { authorization: `Bearer ${subscriberSecret}` },
    })).status).toBe(200);
  });

  it("imports a read-only remote account without returning or duplicating credentials", async () => {
    await registerDevice();
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody()),
    })).status).toBe(201);
    const fetchedAt = Math.floor(Date.now() / 1_000) - 60;
    const snapshot = {
      provider_id: "chatgpt",
      plan: "Plus",
      fetched_at: fetchedAt,
      windows: [{
        position: 0,
        metric_id: "weekly",
        title: "Weekly limit",
        kind: "weekly",
        window_minutes: 10_080,
        remaining_percent: 72,
        resets_at: fetchedAt + 86_400,
      }],
      available_reset_count: 1,
      reset_credits: [],
    };
    const storedSnapshot = {
      ...snapshot,
      credentials: { access_token: "sync-snapshot-access-canary" },
      encrypted_credentials: "sync-encrypted-envelope-canary",
      account_reference_verified: true,
      account_reference_scope: "provider_account_v2",
      windows: snapshot.windows.map((window) => ({
        ...window,
        credential: "sync-window-credential-canary",
      })),
      api_balance: {
        title: "Monthly API budget",
        currency_code: "USD",
        spent: 1,
        limit: 10,
        remaining: 9,
        period_start: fetchedAt - 86_400,
        period_end: fetchedAt + 86_400,
        access_expires_at: null,
        is_unlimited: false,
        token: "sync-balance-token-canary",
      },
    };
    await env.DB.batch([
      env.DB.prepare(
        `UPDATE monitored_accounts SET latest_snapshot = ?, last_success_at = ?
         WHERE device_id = ? AND account_id = ?`
      ).bind(JSON.stringify(storedSnapshot), fetchedAt, deviceID, accountID),
      env.DB.prepare(
        `INSERT INTO usage_history (
           device_id, account_id, provider_id, metric_id, metric_title, kind,
           window_minutes, remaining_percent, recorded_at, resets_at,
           seconds_until_reset, plan
         ) VALUES (?, ?, 'chatgpt', 'weekly', 'Weekly limit', 'weekly',
                   10080, 72, ?, ?, 86400, 'Plus')`
      ).bind(deviceID, accountID, fetchedAt, fetchedAt + 86_400),
    ]);

    const subscriberDeviceID = "019f724a-3414-4d52-ae37-0c7024a1ab99";
    const subscriberSecret = "B".repeat(43);
    const subscriberToken = "b".repeat(64);
    const localAccountID = "019f724a-3414-4d52-ae37-0c7024a1aba0";
    await registerDevice(subscriberDeviceID, subscriberSecret, subscriberToken);
    const remoteAccountsURL = `https://push.example/v1/devices/${subscriberDeviceID}/remote-accounts`;
    expect((await SELF.fetch(remoteAccountsURL)).status).toBe(401);
    const candidatesResponse = await SELF.fetch(remoteAccountsURL, {
      headers: { authorization: `Bearer ${subscriberSecret}` },
    });
    expect(candidatesResponse.status).toBe(200);
    expect(candidatesResponse.headers.get("cache-control")).toBe("no-store");
    const candidates = await candidatesResponse.json<{
      accounts: Array<Record<string, unknown> & { remote_account_id: string }>;
    }>();
    expect(candidates.accounts).toHaveLength(1);
    expect(candidates.accounts[0]).toMatchObject({
      provider_id: "chatgpt",
      synced_account_reference: expect.stringMatching(/^[A-Za-z0-9_-]{43}$/),
      account_reference: expect.stringMatching(/^[A-Za-z0-9_-]{43}$/),
      display_name: "Worker account",
      plan: "Plus",
      metadata: {
        name: "Provider Person",
        email: "person@example.com",
        plan: "Plus",
        plan_expires_at: 2_000_000_000,
        trial_expires_at: 1_999_000_000,
      },
      last_success_at: fetchedAt,
      session_status: "active",
      session_checked_at: fetchedAt,
    });
    expect(candidates.accounts[0]).not.toHaveProperty("credentials");
    expect(candidates.accounts[0]).not.toHaveProperty("encrypted_credentials");
    expect(candidates.accounts[0]).not.toHaveProperty("credential_fingerprint");
    expect(candidates.accounts[0]).not.toHaveProperty("consent_revision");
    const serializedCandidates = JSON.stringify(candidates);
    expect(serializedCandidates).not.toContain(deviceID);
    expect(serializedCandidates).not.toContain(accountID);
    expect(serializedCandidates).not.toContain("workspace-123");
    expect(serializedCandidates).not.toContain("access-secret");
    expect(serializedCandidates).not.toContain("refresh-secret");
    expect(serializedCandidates).not.toContain("id-secret");

    const imported = await SELF.fetch(remoteAccountsURL, {
      method: "POST",
      headers: { authorization: `Bearer ${subscriberSecret}` },
      body: JSON.stringify({
        remote_account_id: candidates.accounts[0].remote_account_id,
        local_account_id: localAccountID.toUpperCase(),
      }),
    });
    expect(imported.status).toBe(201);
    const importedBody = await imported.json<Record<string, unknown>>();
    expect(importedBody).toMatchObject({
      account: {
        synced_account_reference: candidates.accounts[0].synced_account_reference,
        account_reference: candidates.accounts[0].account_reference,
        consent_revision: 1,
        session_status: "active",
        session_checked_at: fetchedAt,
        metadata: {
          name: "Provider Person",
          email: "person@example.com",
          plan: "Plus",
          plan_expires_at: 2_000_000_000,
          trial_expires_at: 1_999_000_000,
        },
      },
    });
    expect(JSON.stringify(importedBody)).not.toContain("access-secret");
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM monitored_accounts"
    ).first()).toEqual({ count: 1 });
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM remote_account_subscriptions"
    ).first()).toEqual({ count: 1 });
    const repeatedImport = await SELF.fetch(remoteAccountsURL, {
      method: "POST",
      headers: { authorization: `Bearer ${subscriberSecret}` },
      body: JSON.stringify({
        remote_account_id: candidates.accounts[0].remote_account_id,
        local_account_id: localAccountID,
      }),
    });
    expect(repeatedImport.status).toBe(200);
    const repeatedImportBody = await repeatedImport.json<Record<string, unknown>>();
    expect(repeatedImportBody).toMatchObject({ account: { consent_revision: 1 } });
    expect(JSON.stringify(repeatedImportBody)).not.toContain("access-secret");

    const sync = await SELF.fetch(
      `https://push.example/v1/devices/${subscriberDeviceID}/accounts/${localAccountID}/sync?since=0`,
      { headers: { authorization: `Bearer ${subscriberSecret}` } },
    );
    expect(sync.status).toBe(200);
    const serializedSync = await sync.text();
    expect(serializedSync).not.toContain(deviceID);
    expect(serializedSync).not.toContain(accountID);
    for (const canary of [
      "sync-snapshot-access-canary", "sync-encrypted-envelope-canary",
      "sync-window-credential-canary", "sync-balance-token-canary",
      "account_reference_verified", "account_reference_scope",
    ]) expect(serializedSync).not.toContain(canary);
    const syncBody = JSON.parse(serializedSync);
    expect(syncBody).toMatchObject({
      snapshot,
      account_reference: candidates.accounts[0].account_reference,
      session_status: "active",
      session_checked_at: fetchedAt,
      metadata: {
        name: "Provider Person",
        email: "person@example.com",
        plan: "Plus",
        plan_expires_at: 2_000_000_000,
        trial_expires_at: 1_999_000_000,
      },
      history: [{ metric_id: "weekly", remaining_percent: 72 }],
      consent_revision: 1,
    });
    expect(syncBody.history[0].row_tag).toContain(localAccountID);

    await testing.handleAPNSResult(
      env,
      { device_id: subscriberDeviceID, apns_token: subscriberToken },
      { ok: false, status: 410, reason: "Unregistered" },
    );
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM remote_account_subscriptions"
    ).first()).toEqual({ count: 1 });
    expect((await SELF.fetch(
      `https://push.example/v1/devices/${subscriberDeviceID}/accounts/${localAccountID}/sync?since=0`,
      { headers: { authorization: `Bearer ${subscriberSecret}` } },
    )).status).toBe(200);

    expect((await SELF.fetch(
      `https://push.example/v1/devices/${subscriberDeviceID}/accounts/${localAccountID}`,
      {
        method: "PUT",
        headers: { authorization: `Bearer ${subscriberSecret}` },
        body: JSON.stringify(accountRequestBody()),
      },
    )).status).toBe(409);

    const beforeReplacement = await env.DB.prepare(
      `SELECT encrypted_credentials, credential_fingerprint
       FROM monitored_accounts WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first<{
      encrypted_credentials: string;
      credential_fingerprint: string;
    }>();
    await env.DB.prepare(
      `UPDATE monitored_accounts SET last_refresh_at = ?, last_error = 'Provider returned HTTP 401.'
       WHERE device_id = ? AND account_id = ?`
    ).bind(fetchedAt + 1, deviceID, accountID).run();
    const replacementUpload = accountRequestBody("chatgpt", 1);
    replacementUpload.credentials.access_token = "fresh-write-only-access";
    replacementUpload.credentials.refresh_token = "fresh-write-only-refresh";
    replacementUpload.credentials.id_token = "fresh-write-only-id";
    const parsedReplacement = await testing.parseAccountUpload(new Request(
      "https://push.example/credential-replacement-test",
      { method: "PUT", body: JSON.stringify(replacementUpload) },
    ));
    expect(parsedReplacement).not.toBeNull();
    let providerCheckCount = 0;
    let checkedWorkspace: string | null = null;
    let checkedAccessToken: string | null = null;
    const replacement = await testing.upsertMonitoredAccount(
      env,
      subscriberDeviceID,
      localAccountID,
      parsedReplacement!,
      true,
      async (providerAccount, credentials, checkedAt) => {
        providerCheckCount += 1;
        checkedWorkspace = providerAccount.workspace_id;
        checkedAccessToken = credentials.access_token;
        const effectiveCheckedAt = checkedAt ?? Math.floor(Date.now() / 1_000);
        return {
          credentials,
          account_identity: "user:same-chatgpt-user",
          snapshot: {
            provider_id: "chatgpt",
            plan: "Plus",
            fetched_at: effectiveCheckedAt,
            windows: [{
              position: 0,
              metric_id: "weekly",
              title: "Weekly limit",
              kind: "weekly",
              window_minutes: 10_080,
              remaining_percent: 80,
              resets_at: effectiveCheckedAt + 604_800,
            }],
            available_reset_count: 0,
            reset_credits: [],
          },
        };
      },
    );
    expect(replacement.status).toBe(200);
    expect(replacement.headers.get("cache-control")).toBe("no-store");
    const replacementBody = await replacement.json<Record<string, unknown>>();
    expect(replacementBody).toMatchObject({
      account_reference: expect.stringMatching(/^[A-Za-z0-9_-]{43}$/),
      session_status: "active",
      last_error: null,
    });
    const serializedReplacement = JSON.stringify(replacementBody);
    expect(serializedReplacement).not.toContain("fresh-write-only-access");
    expect(serializedReplacement).not.toContain("fresh-write-only-refresh");
    expect(serializedReplacement).not.toContain("fresh-write-only-id");
    expect(replacementBody).not.toHaveProperty("credentials");
    expect(replacementBody).not.toHaveProperty("encrypted_credentials");
    expect(replacementBody).not.toHaveProperty("credential_fingerprint");
    expect(providerCheckCount).toBe(1);
    expect(checkedWorkspace).toBe("workspace-123");
    expect(checkedAccessToken).toBe("fresh-write-only-access");
    const afterReplacement = await env.DB.prepare(
      `SELECT encrypted_credentials, credential_fingerprint, last_error, latest_snapshot
       FROM monitored_accounts WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first<{
      encrypted_credentials: string;
      credential_fingerprint: string;
      last_error: string | null;
      latest_snapshot: string;
    }>();
    expect(afterReplacement?.encrypted_credentials).not.toBe(
      beforeReplacement?.encrypted_credentials
    );
    expect(afterReplacement?.credential_fingerprint).not.toBe(
      beforeReplacement?.credential_fingerprint
    );
    expect(afterReplacement?.encrypted_credentials).not.toContain("fresh-write-only-access");
    expect(afterReplacement?.last_error).toBeNull();
    expect(JSON.parse(afterReplacement!.latest_snapshot)).toMatchObject({
      account_reference: replacementBody.account_reference,
    });

    expect((await SELF.fetch(
      `https://push.example/v1/devices/${subscriberDeviceID}/accounts/${localAccountID}?consent_revision=2`,
      {
        method: "DELETE",
        headers: { authorization: `Bearer ${subscriberSecret}` },
      },
    )).status).toBe(204);
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM monitored_accounts"
    ).first()).toEqual({ count: 1 });
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM remote_account_subscriptions"
    ).first()).toEqual({ count: 0 });
  });

  it("offers one logical account and keeps its subscribed source recoverable", async () => {
    await registerDevice();
    const firstUpload = accountRequestBody("chatgpt", 1);
    firstUpload.display_name = "ieb";
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(firstUpload),
    })).status).toBe(201);

    const secondDeviceID = "019f724a-3414-4d52-ae37-0c7024a1ab98";
    const secondDeviceSecret = "C".repeat(43);
    const secondAPNSToken = "c".repeat(64);
    const secondAccountID = "019f724a-3414-4d52-ae37-0c7024a1ab96";
    await registerDevice(secondDeviceID, secondDeviceSecret, secondAPNSToken);
    const secondUpload = accountRequestBody("chatgpt", 1);
    secondUpload.display_name = "Natu Leppanen";
    expect((await SELF.fetch(
      `https://push.example/v1/devices/${secondDeviceID}/accounts/${secondAccountID}`,
      {
        method: "PUT",
        headers: { authorization: `Bearer ${secondDeviceSecret}` },
        body: JSON.stringify(secondUpload),
      },
    )).status).toBe(201);

    const fetchedAt = Math.floor(Date.now() / 1_000) - 30;
    const accountReference = "D".repeat(43);
    const snapshot = JSON.stringify({
      provider_id: "chatgpt",
      plan: "Plus",
      fetched_at: fetchedAt,
      windows: [],
      available_reset_count: 0,
      reset_credits: [],
      account_reference: accountReference,
      account_reference_verified: true,
      account_reference_scope: "provider_account_v2",
    });
    await env.DB.batch([
      env.DB.prepare(
        `UPDATE monitored_accounts SET latest_snapshot = ?, last_refresh_at = ?,
           last_success_at = ?, last_error = NULL
         WHERE device_id = ? AND account_id = ?`
      ).bind(snapshot, fetchedAt, fetchedAt, deviceID, accountID),
      env.DB.prepare(
        `UPDATE monitored_accounts SET latest_snapshot = ?, last_refresh_at = ?,
           last_success_at = ?, last_error = 'Provider returned HTTP 401.'
         WHERE device_id = ? AND account_id = ?`
      ).bind(snapshot, fetchedAt - 60, fetchedAt - 60, secondDeviceID, secondAccountID),
    ]);

    const subscriberDeviceID = "019f724a-3414-4d52-ae37-0c7024a1ab99";
    const subscriberSecret = "E".repeat(43);
    const subscriberToken = "e".repeat(64);
    const localAccountID = "019f724a-3414-4d52-ae37-0c7024a1aba0";
    await registerDevice(subscriberDeviceID, subscriberSecret, subscriberToken);
    const remoteAccountsURL = `https://push.example/v1/devices/${subscriberDeviceID}/remote-accounts`;
    const available = await SELF.fetch(remoteAccountsURL, {
      headers: { authorization: `Bearer ${subscriberSecret}` },
    });
    const availableBody = await available.json<{
      accounts: Array<{
        remote_account_id: string;
        account_reference: string;
        display_name: string;
        session_status: string;
      }>;
    }>();
    expect(availableBody.accounts).toEqual([
      expect.objectContaining({
        account_reference: accountReference,
        display_name: "ieb",
        session_status: "active",
      }),
    ]);
    expect(JSON.stringify(availableBody)).not.toContain("account_reference_verified");
    expect(JSON.stringify(availableBody)).not.toContain("account_reference_scope");

    expect((await SELF.fetch(remoteAccountsURL, {
      method: "POST",
      headers: { authorization: `Bearer ${subscriberSecret}` },
      body: JSON.stringify({
        remote_account_id: availableBody.accounts[0].remote_account_id,
        local_account_id: localAccountID,
      }),
    })).status).toBe(201);
    const afterImport = await SELF.fetch(remoteAccountsURL, {
      headers: { authorization: `Bearer ${subscriberSecret}` },
    });
    expect(await afterImport.json()).toMatchObject({
      accounts: [{
        remote_account_id: availableBody.accounts[0].remote_account_id,
        account_reference: accountReference,
      }],
    });
  });

  it("does not overwrite refreshed Worker credentials or backoff on an idempotent upload", async () => {
    await registerDevice();
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody("chatgpt", 1)),
    })).status).toBe(201);
    const delayedUntil = Math.floor(Date.now() / 1_000) + 7_200;
    await env.DB.prepare(
      `UPDATE monitored_accounts
       SET next_refresh_at = ?, last_error = 'Provider rate limit reached; retrying later.'
       WHERE device_id = ? AND account_id = ?`
    ).bind(delayedUntil, deviceID, accountID).run();
    const original = await env.DB.prepare(
      `SELECT encrypted_credentials, credential_fingerprint, credential_revision, next_refresh_at
       FROM monitored_accounts WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first<{
      encrypted_credentials: string;
      credential_fingerprint: string;
      credential_revision: number;
      next_refresh_at: number;
    }>();

    const staleUpload = accountRequestBody("chatgpt", 1);
    staleUpload.credentials.access_token = "stale-device-access-token";
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(staleUpload),
    })).status).toBe(200);
    expect(await env.DB.prepare(
      `SELECT encrypted_credentials, credential_fingerprint, credential_revision, next_refresh_at
       FROM monitored_accounts WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first()).toEqual(original);

    const relinkedUpload = accountRequestBody("chatgpt", 2);
    relinkedUpload.credentials.access_token = "explicitly-relinked-access-token";
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(relinkedUpload),
    })).status).toBe(200);
    const relinked = await env.DB.prepare(
      `SELECT credential_fingerprint, credential_revision, next_refresh_at
       FROM monitored_accounts WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first<{
      credential_fingerprint: string;
      credential_revision: number;
      next_refresh_at: number;
    }>();
    expect(relinked?.credential_revision).toBe(2);
    expect(relinked?.credential_fingerprint).not.toBe(original?.credential_fingerprint);
    expect(relinked!.next_refresh_at).toBeLessThan(delayedUntil);
  });

  it("keeps a delete tombstone so stale and same-revision uploads cannot recreate credentials", async () => {
    await registerDevice();
    const enabled = await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody("chatgpt", 1)),
    });
    expect(enabled.status).toBe(201);
    await env.DB.prepare(
      `INSERT INTO usage_history (
         device_id, account_id, provider_id, metric_id, metric_title, kind, window_minutes,
         remaining_percent, recorded_at, resets_at, seconds_until_reset, plan
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    ).bind(
      deviceID, accountID, "chatgpt", "weekly", "Weekly limit", "weekly", 10_080,
      75, 2_000_000_000, 2_000_086_400, 86_400, "Plus"
    ).run();

    const removed = await SELF.fetch(`${accountURL}?consent_revision=2`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${deviceSecret}` },
    });
    expect(removed.status).toBe(204);

    for (const revision of [1, 2]) {
      const staleBody = accountRequestBody("chatgpt", revision);
      staleBody.credentials.access_token = `stale-access-${revision}`;
      const stale = await SELF.fetch(accountURL, {
        method: "PUT",
        headers: { authorization: `Bearer ${deviceSecret}` },
        body: JSON.stringify(staleBody),
      });
      expect(stale.status).toBe(409);
      expect(await stale.json()).toEqual({ error: "consent_revision_conflict" });
    }

    expect(await env.DB.prepare(
      "SELECT consent_revision, enabled FROM account_monitoring_consent WHERE device_id = ? AND account_id = ?"
    ).bind(deviceID, accountID).first<{ consent_revision: number; enabled: number }>())
      .toEqual({ consent_revision: 2, enabled: 0 });
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM monitored_accounts WHERE device_id = ? AND account_id = ?"
    ).bind(deviceID, accountID).first<{ count: number }>()).toEqual({ count: 0 });
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM usage_history WHERE device_id = ? AND account_id = ?"
    ).bind(deviceID, accountID).first<{ count: number }>()).toEqual({ count: 0 });

    const retry = await SELF.fetch(`${accountURL}?consent_revision=2`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${deviceSecret}` },
    });
    expect(retry.status).toBe(204);
    const olderDelete = await SELF.fetch(`${accountURL}?consent_revision=1`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${deviceSecret}` },
    });
    expect(olderDelete.status).toBe(409);
    expect(await olderDelete.json()).toEqual({ error: "consent_revision_conflict" });
  });

  it("erases an orphaned result but retains its idempotency tombstone", async () => {
    await registerDevice();
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody("chatgpt", 1)),
    })).status).toBe(201);
    const account = await env.DB.prepare(
      `SELECT credential_fingerprint FROM monitored_accounts
       WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first<{ credential_fingerprint: string }>();
    const runID = "opaque-test-run";
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO monitor_runs (
           run_id, occurrence_at, credential_fingerprint, status,
           encrypted_result_credentials, result_snapshot, created_at
         ) VALUES (?, ?, ?, 'fetched', 'encrypted-secret-result', '{}', ?)`
      ).bind(runID, 2_000_000_000, account!.credential_fingerprint, 2_000_000_000),
      env.DB.prepare(
        `INSERT INTO monitor_run_targets (
           run_id, device_id, account_id, consent_revision, credential_fingerprint
         ) VALUES (?, ?, ?, 1, ?)`
      ).bind(runID, deviceID, accountID, account!.credential_fingerprint),
    ]);

    expect((await SELF.fetch(`${accountURL}?consent_revision=2`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${deviceSecret}` },
    })).status).toBe(204);
    expect(await env.DB.prepare(
      `SELECT status, encrypted_result_credentials, result_snapshot
       FROM monitor_runs WHERE run_id = ?`
    ).bind(runID).first()).toEqual({
      status: "succeeded",
      encrypted_result_credentials: null,
      result_snapshot: null,
    });
  });

  it("prunes completed monitor runs and their targets without trigger recursion", async () => {
    await registerDevice();
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody("chatgpt", 1)),
    })).status).toBe(201);
    const account = await env.DB.prepare(
      `SELECT credential_fingerprint FROM monitored_accounts
       WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first<{ credential_fingerprint: string }>();
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO monitor_runs (
           run_id, occurrence_at, credential_fingerprint, status, created_at
         ) VALUES ('old-run', 1, ?, 'succeeded', 1)`
      ).bind(account!.credential_fingerprint),
      env.DB.prepare(
        `INSERT INTO monitor_run_targets (
           run_id, device_id, account_id, consent_revision, credential_fingerprint, applied_at
         ) VALUES ('old-run', ?, ?, 1, ?, 1)`
      ).bind(deviceID, accountID, account!.credential_fingerprint),
    ]);

    await testing.pruneMonitorRuns(env, 8 * 86_400);
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM monitor_runs"
    ).first<{ count: number }>()).toEqual({ count: 0 });
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM monitor_run_targets"
    ).first<{ count: number }>()).toEqual({ count: 0 });
  });

  it("allows a newer PUT, then lets a higher DELETE win and a still-newer PUT re-enable", async () => {
    await registerDevice();
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody("chatgpt", 1)),
    })).status).toBe(201);
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody("chatgpt", 2)),
    })).status).toBe(200);
    expect((await SELF.fetch(`${accountURL}?consent_revision=3`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${deviceSecret}` },
    })).status).toBe(204);

    const reenabledBody = accountRequestBody("chatgpt", 4);
    reenabledBody.credentials.access_token = "new-access-secret";
    const reenabled = await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(reenabledBody),
    });
    expect(reenabled.status).toBe(201);
    const reenabledBodyJSON = await reenabled.json<Record<string, unknown>>();
    expect(reenabledBodyJSON).toMatchObject({ consent_revision: 4 });
    expect(reenabledBodyJSON).not.toHaveProperty("credentials");
    expect(JSON.stringify(reenabledBodyJSON)).not.toContain("new-access-secret");
    expect(await env.DB.prepare(
      "SELECT consent_revision, enabled FROM account_monitoring_consent WHERE device_id = ? AND account_id = ?"
    ).bind(deviceID, accountID).first<{ consent_revision: number; enabled: number }>())
      .toEqual({ consent_revision: 4, enabled: 1 });
  });

  it("serializes a concurrent PUT and higher DELETE so the higher tombstone always wins", async () => {
    await registerDevice();
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody("chatgpt", 1)),
    })).status).toBe(201);

    const [put, deletion] = await Promise.all([
      SELF.fetch(accountURL, {
        method: "PUT",
        headers: { authorization: `Bearer ${deviceSecret}` },
        body: JSON.stringify(accountRequestBody("chatgpt", 2)),
      }),
      SELF.fetch(`${accountURL}?consent_revision=3`, {
        method: "DELETE",
        headers: { authorization: `Bearer ${deviceSecret}` },
      }),
    ]);
    expect([200, 409]).toContain(put.status);
    expect(deletion.status).toBe(204);
    expect(await env.DB.prepare(
      "SELECT consent_revision, enabled FROM account_monitoring_consent WHERE device_id = ? AND account_id = ?"
    ).bind(deviceID, accountID).first<{ consent_revision: number; enabled: number }>())
      .toEqual({ consent_revision: 3, enabled: 0 });
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM monitored_accounts WHERE device_id = ? AND account_id = ?"
    ).bind(deviceID, accountID).first<{ count: number }>()).toEqual({ count: 0 });
  });

  it("maps missing legacy revisions to one without crossing a disable tombstone", async () => {
    await registerDevice();
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody()),
    })).status).toBe(201);
    expect((await SELF.fetch(accountURL, {
      method: "DELETE",
      headers: { authorization: `Bearer ${deviceSecret}` },
    })).status).toBe(204);
    const staleLegacyUpload = await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody()),
    });
    expect(staleLegacyUpload.status).toBe(409);
    expect(await env.DB.prepare(
      "SELECT consent_revision, enabled FROM account_monitoring_consent WHERE device_id = ? AND account_id = ?"
    ).bind(deviceID, accountID).first<{ consent_revision: number; enabled: number }>())
      .toEqual({ consent_revision: 1, enabled: 0 });
  });

  it("requires explicit revisions to be positive safe integers", async () => {
    await registerDevice();
    for (const revision of [0, -1, 9_007_199_254_740_992]) {
      expect((await SELF.fetch(accountURL, {
        method: "PUT",
        headers: { authorization: `Bearer ${deviceSecret}` },
        body: JSON.stringify(accountRequestBody("chatgpt", revision)),
      })).status).toBe(400);
    }
    for (const query of ["0", "-1", "9007199254740992", "1&consent_revision=2"]) {
      expect((await SELF.fetch(`${accountURL}?consent_revision=${query}`, {
        method: "DELETE",
        headers: { authorization: `Bearer ${deviceSecret}` },
      })).status).toBe(400);
    }
  });

  it("returns five-minute D1 history and deletes it with the account", async () => {
    await registerDevice();
    await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody("claude")),
    });
    const insertHistory = env.DB.prepare(
      `INSERT INTO usage_history (
         device_id, account_id, provider_id, metric_id, metric_title, kind, window_minutes,
         remaining_percent, recorded_at, resets_at, seconds_until_reset, plan
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    );
    await env.DB.batch([
      insertHistory.bind(
        deviceID, accountID, "claude", "weekly", "Weekly limit", "weekly", 10_080,
        72.5, 2_000_000_000, 2_000_086_400, 86_400, "Max",
      ),
      insertHistory.bind(
        deviceID, accountID, "claude", "weekly", "Weekly limit", "weekly", 10_080,
        70, 2_000_000_300, 2_000_086_400, 86_100, "Max",
      ),
    ]);
    await env.DB.prepare(
      `UPDATE monitored_accounts SET encrypted_credentials = 'unreadable-by-design'
       WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).run();

    const response = await SELF.fetch(`${accountURL}/sync?since=1999999999`, {
      headers: { authorization: `Bearer ${deviceSecret}` },
    });
    expect(response.status).toBe(200);
    const responseBody = await response.json<Record<string, unknown>>();
    expect(responseBody).toMatchObject({
      history: [
        {
          provider_id: "claude",
          metric_id: "weekly",
          remaining_percent: 72.5,
          recorded_at: 2_000_000_000,
          plan: "Max",
        },
        {
          provider_id: "claude",
          metric_id: "weekly",
          remaining_percent: 70,
          recorded_at: 2_000_000_300,
          plan: "Max",
        },
      ],
    });
    expect(responseBody).not.toHaveProperty("credentials");
    expect(JSON.stringify(responseBody)).not.toContain("access-secret");
    expect(JSON.stringify(responseBody)).not.toContain("refresh-secret");

    const removed = await SELF.fetch(accountURL, {
      method: "DELETE",
      headers: { authorization: `Bearer ${deviceSecret}` },
    });
    expect(removed.status).toBe(204);
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM usage_history WHERE device_id = ? AND account_id = ?"
    ).bind(deviceID, accountID).first<{ count: number }>()).toMatchObject({ count: 0 });
  });

  it("accepts five-minute monitoring and rejects intervals below cron resolution", async () => {
    await registerDevice();
    const unknown = await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody("unknown")),
    });
    expect(unknown.status).toBe(400);

    const tooFrequent = accountRequestBody();
    tooFrequent.refresh_interval_seconds = FIVE_MINUTES_SECONDS - 1;
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(tooFrequent),
    })).status).toBe(400);

    const minimumInterval = accountRequestBody();
    minimumInterval.refresh_interval_seconds = FIVE_MINUTES_SECONDS;
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(minimumInterval),
    })).status).toBe(201);

    expect((await SELF.fetch(`${accountURL}/sync`)).status).toBe(401);
  });

  it("advances an opted-in synthetic quota reset window when the provider omits it", () => {
    expect(testing.syntheticResetAt({
      metric_id: "weekly",
      title: "Weekly limit",
      kind: "weekly",
      window_minutes: 10_080,
      resets_at: 2_000_000_000,
    }, 2_000_000_001)).toBe(2_000_604_800);
  });

  it("enqueues due account monitors from the five-minute cron", async () => {
    await registerDevice();
    await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody()),
    });
    const queued: unknown[] = [];
    const testEnv = {
      DB: env.DB,
      REGISTRATION_ACCESS_KEY: env.REGISTRATION_ACCESS_KEY,
      CREDENTIAL_ENCRYPTION_KEY: env.CREDENTIAL_ENCRYPTION_KEY,
      PUSH_QUEUE: {
        sendBatch: async (messages: { body: unknown }[]) => {
          queued.push(...messages.map((message) => message.body));
        },
      },
    } as unknown as Env;

    const occurrence = Date.UTC(2033, 4, 18, 3, 5);
    await testing.runScheduledRefresh(testEnv, occurrence);

    expect(queued).toHaveLength(1);
    expect(queued[0]).toEqual({
      kind: "monitor_run",
      run_id: expect.stringMatching(/^[A-Za-z0-9_-]{43}$/),
    });
    expect(JSON.stringify(queued[0])).not.toContain(deviceID);
    expect(JSON.stringify(queued[0])).not.toContain("access-secret");
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM monitor_run_targets"
    ).first<{ count: number }>()).toEqual({ count: 1 });
    expect(await env.DB.prepare(
      `SELECT scheduled_monitor_at, next_refresh_at FROM monitored_accounts
       WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first()).toEqual({
      scheduled_monitor_at: occurrence / 1_000,
      next_refresh_at: occurrence / 1_000 + FIVE_MINUTES_SECONDS,
    });
    expect(queued).not.toContainEqual(expect.objectContaining({ kind: "push" }));
  });

  it("notifies each enabled owner and subscriber once after a successful refresh", async () => {
    const subscriberDeviceID = "019f724a-3414-4d52-ae37-0c7024a1ab99";
    const disabledDeviceID = "019f724a-3414-4d52-ae37-0c7024a1aba0";
    const subscriberToken = "b".repeat(64);
    const disabledToken = "c".repeat(64);
    await registerDevice();
    await registerDevice(subscriberDeviceID, "B".repeat(43), subscriberToken);
    await registerDevice(disabledDeviceID, "C".repeat(43), disabledToken);
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody()),
    })).status).toBe(201);
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO remote_account_subscriptions (
           subscriber_device_id, local_account_id, source_device_id, source_account_id, created_at
         ) VALUES (?, ?, ?, ?, ?)`
      ).bind(
        deviceID, "019f724a-3414-4d52-ae37-0c7024a1aba1",
        deviceID, accountID, 2_000_000_000,
      ),
      env.DB.prepare(
        `INSERT INTO remote_account_subscriptions (
           subscriber_device_id, local_account_id, source_device_id, source_account_id, created_at
         ) VALUES (?, ?, ?, ?, ?)`
      ).bind(
        subscriberDeviceID, "019f724a-3414-4d52-ae37-0c7024a1aba2",
        deviceID, accountID, 2_000_000_000,
      ),
      env.DB.prepare(
        `INSERT INTO remote_account_subscriptions (
           subscriber_device_id, local_account_id, source_device_id, source_account_id, created_at
         ) VALUES (?, ?, ?, ?, ?)`
      ).bind(
        disabledDeviceID, "019f724a-3414-4d52-ae37-0c7024a1aba3",
        deviceID, accountID, 2_000_000_000,
      ),
      env.DB.prepare(
        "UPDATE devices SET push_disabled_at = ? WHERE device_id = ?"
      ).bind(2_000_000_000, disabledDeviceID),
    ]);

    const queued: Array<Record<string, unknown>> = [];
    const testEnv = {
      DB: env.DB,
      REGISTRATION_ACCESS_KEY: env.REGISTRATION_ACCESS_KEY,
      CREDENTIAL_ENCRYPTION_KEY: env.CREDENTIAL_ENCRYPTION_KEY,
      PUSH_QUEUE: {
        sendBatch: async (messages: { body: Record<string, unknown> }[]) => {
          queued.push(...messages.map((message) => message.body));
        },
      },
    } as unknown as Env;
    const occurrence = Math.ceil(Date.now() / FIVE_MINUTES_MILLISECONDS)
      * FIVE_MINUTES_MILLISECONDS;
    await testing.runScheduledRefresh(testEnv, occurrence);
    const monitorMessage = queued.find((body) => body.kind === "monitor_run");
    expect(monitorMessage).toMatchObject({ kind: "monitor_run" });
    queued.length = 0;
    const fetchUsage: Parameters<typeof testing.refreshMonitorRun>[2] = async (
      account, credentials, now,
    ) => {
      const fetchedAt = now ?? Math.floor(Date.now() / 1_000);
      return {
        credentials,
        snapshot: {
          provider_id: account.provider_id,
          plan: account.plan,
          fetched_at: fetchedAt,
          windows: [{
            position: 0,
            metric_id: "weekly",
            title: "Weekly limit",
            kind: "weekly",
            window_minutes: 10_080,
            remaining_percent: 72,
            resets_at: fetchedAt + 86_400,
          }],
          available_reset_count: 0,
          reset_credits: [],
        },
      };
    };
    const acknowledgements = { ack: 0, retry: 0 };
    await testing.refreshMonitorRun({
      body: monitorMessage,
      ack: () => { acknowledgements.ack += 1; },
      retry: () => { acknowledgements.retry += 1; },
    } as never, testEnv, fetchUsage);

    const pushes = queued.filter((body) => body.kind === "push");
    const pushedDeviceIDs = pushes.map((body) => body.device_id as string);
    expect(acknowledgements).toEqual({ ack: 1, retry: 0 });
    expect(pushedDeviceIDs.sort()).toEqual([deviceID, subscriberDeviceID].sort());
    expect(new Set(pushedDeviceIDs).size).toBe(2);
    expect(pushes).toEqual(expect.arrayContaining([
      expect.objectContaining({ device_id: deviceID, apns_token: apnsToken }),
      expect.objectContaining({ device_id: subscriberDeviceID, apns_token: subscriberToken }),
    ]));
    expect(pushes).not.toContainEqual(expect.objectContaining({
      device_id: disabledDeviceID,
    }));
    expect(JSON.stringify(pushes)).not.toContain("access-secret");
  });

  it("notifies the enabled owner and subscribers when refresh reports an expired session", async () => {
    const subscriberDeviceID = "019f724a-3414-4d52-ae37-0c7024a1ab99";
    const disabledDeviceID = "019f724a-3414-4d52-ae37-0c7024a1aba0";
    await registerDevice();
    await registerDevice(subscriberDeviceID, "B".repeat(43), "b".repeat(64));
    await registerDevice(disabledDeviceID, "C".repeat(43), "c".repeat(64));
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody()),
    })).status).toBe(201);
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO remote_account_subscriptions (
           subscriber_device_id, local_account_id, source_device_id, source_account_id, created_at
         ) VALUES (?, ?, ?, ?, ?)`
      ).bind(
        subscriberDeviceID, "019f724a-3414-4d52-ae37-0c7024a1aba1",
        deviceID, accountID, 2_000_000_000,
      ),
      env.DB.prepare(
        `INSERT INTO remote_account_subscriptions (
           subscriber_device_id, local_account_id, source_device_id, source_account_id, created_at
         ) VALUES (?, ?, ?, ?, ?)`
      ).bind(
        disabledDeviceID, "019f724a-3414-4d52-ae37-0c7024a1aba2",
        deviceID, accountID, 2_000_000_000,
      ),
      env.DB.prepare(
        "UPDATE devices SET push_disabled_at = ? WHERE device_id = ?"
      ).bind(2_000_000_000, disabledDeviceID),
    ]);

    const queued: Array<Record<string, unknown>> = [];
    const testEnv = {
      DB: env.DB,
      REGISTRATION_ACCESS_KEY: env.REGISTRATION_ACCESS_KEY,
      CREDENTIAL_ENCRYPTION_KEY: env.CREDENTIAL_ENCRYPTION_KEY,
      PUSH_QUEUE: {
        sendBatch: async (messages: { body: Record<string, unknown> }[]) => {
          queued.push(...messages.map((message) => message.body));
        },
      },
    } as unknown as Env;
    const occurrence = Math.ceil(Date.now() / FIVE_MINUTES_MILLISECONDS)
      * FIVE_MINUTES_MILLISECONDS;
    await testing.runScheduledRefresh(testEnv, occurrence);
    const monitorMessage = queued.find((body) => body.kind === "monitor_run");
    expect(monitorMessage).toMatchObject({ kind: "monitor_run" });
    queued.length = 0;
    const expired: Parameters<typeof testing.refreshMonitorRun>[2] = async () => {
      throw new ProviderFetchError("Provider session expired; reconnect this account.", 401, false);
    };
    const acknowledgements = { ack: 0, retry: 0 };
    await testing.refreshMonitorRun({
      body: monitorMessage,
      ack: () => { acknowledgements.ack += 1; },
      retry: () => { acknowledgements.retry += 1; },
    } as never, testEnv, expired);

    const pushes = queued.filter((body) => body.kind === "push");
    const pushedDeviceIDs = pushes.map((body) => body.device_id as string);
    expect(acknowledgements).toEqual({ ack: 1, retry: 0 });
    expect(pushedDeviceIDs.sort()).toEqual([deviceID, subscriberDeviceID].sort());
    expect(new Set(pushedDeviceIDs).size).toBe(2);
    expect(pushes).not.toContainEqual(expect.objectContaining({
      device_id: disabledDeviceID,
    }));
    expect(await env.DB.prepare(
      `SELECT last_error FROM monitored_accounts
       WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first()).toEqual({
      last_error: "provider_session_expired",
    });
    expect(JSON.stringify(pushes)).not.toContain("access-secret");
  });

  it("marks a scheduled ChatGPT 403 as forbidden without leaking provider details", async () => {
    await registerDevice();
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody()),
    })).status).toBe(201);

    const queued: Array<Record<string, unknown>> = [];
    const testEnv = {
      DB: env.DB,
      REGISTRATION_ACCESS_KEY: env.REGISTRATION_ACCESS_KEY,
      CREDENTIAL_ENCRYPTION_KEY: env.CREDENTIAL_ENCRYPTION_KEY,
      PUSH_QUEUE: {
        sendBatch: async (messages: { body: Record<string, unknown> }[]) => {
          queued.push(...messages.map((message) => message.body));
        },
      },
    } as unknown as Env;
    const occurrence = Math.ceil(Date.now() / FIVE_MINUTES_MILLISECONDS)
      * FIVE_MINUTES_MILLISECONDS;
    await testing.runScheduledRefresh(testEnv, occurrence);
    const monitorMessage = queued.find((body) => body.kind === "monitor_run");
    expect(monitorMessage).toMatchObject({ kind: "monitor_run" });
    queued.length = 0;

    const forbidden: Parameters<typeof testing.refreshMonitorRun>[2] = async () => {
      throw new ProviderFetchError(
        "provider-body-canary-that-must-not-be-stored",
        403,
        false,
      );
    };
    await testing.refreshMonitorRun({
      body: monitorMessage,
      ack: () => {},
      retry: () => {},
    } as never, testEnv, forbidden);

    expect(await env.DB.prepare(
      `SELECT last_error FROM monitored_accounts
       WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first()).toEqual({
      last_error: "provider_request_forbidden",
    });
    const sync = await SELF.fetch(`${accountURL}/sync?since=0`, {
      headers: { authorization: `Bearer ${deviceSecret}` },
    });
    expect(sync.status).toBe(200);
    const syncBody = await sync.json<Record<string, unknown>>();
    expect(syncBody).toMatchObject({ session_status: "error" });
    expect(JSON.stringify(syncBody)).not.toContain("provider-body-canary");
    expect(JSON.stringify(queued)).not.toContain("provider-body-canary");
    expect(JSON.stringify(queued)).not.toContain("access-secret");
  });

  it("serializes monitor messages so provider requests cannot burst concurrently", async () => {
    let active = 0;
    let maximumActive = 0;
    const completed: string[] = [];
    const messages = ["first", "second", "third"].map((runID) => ({
      body: { kind: "monitor_run" as const, run_id: runID },
      ack: () => {},
      retry: () => {},
    }));
    const refreshMonitor: Parameters<typeof testing.processQueue>[2] = async (message) => {
      if (message.body.kind !== "monitor_run") return;
      active += 1;
      maximumActive = Math.max(maximumActive, active);
      await new Promise((resolve) => setTimeout(resolve, 5));
      completed.push(message.body.run_id);
      active -= 1;
    };

    await testing.processQueue(
      { messages } as never,
      {} as Env,
      refreshMonitor,
    );

    expect(maximumActive).toBe(1);
    expect(completed).toEqual(["first", "second", "third"]);
  });

  it("backs off a rate-limited provider without repeating the failed run", async () => {
    await registerDevice();
    await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody()),
    });
    const queued: Array<{ kind?: string; run_id?: string }> = [];
    const testEnv = {
      DB: env.DB,
      REGISTRATION_ACCESS_KEY: env.REGISTRATION_ACCESS_KEY,
      CREDENTIAL_ENCRYPTION_KEY: env.CREDENTIAL_ENCRYPTION_KEY,
      PUSH_QUEUE: {
        sendBatch: async (messages: { body: { kind?: string; run_id?: string } }[]) => {
          queued.push(...messages.map((message) => message.body));
        },
      },
    } as unknown as Env;
    const occurrence = Math.ceil(Date.now() / FIVE_MINUTES_MILLISECONDS)
      * FIVE_MINUTES_MILLISECONDS;
    await testing.runScheduledRefresh(testEnv, occurrence);
    const runID = queued.find((body) => body.kind === "monitor_run")!.run_id!;
    let fetchCount = 0;
    let acknowledgements = 0;
    const queueMessage = {
      body: { kind: "monitor_run", run_id: runID },
      ack: () => { acknowledgements += 1; },
      retry: () => {},
    };
    const rateLimited: Parameters<typeof testing.refreshMonitorRun>[2] = async () => {
      fetchCount += 1;
      throw new ProviderFetchError("Provider rate limit reached; retrying later.", 429, true, 120);
    };

    await testing.refreshMonitorRun(queueMessage as never, testEnv, rateLimited);
    const account = await env.DB.prepare(
      `SELECT last_refresh_at, next_refresh_at, last_error FROM monitored_accounts
       WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first<{
      last_refresh_at: number;
      next_refresh_at: number;
      last_error: string;
    }>();
    expect(account).not.toBeNull();
    expect(account!.next_refresh_at - account!.last_refresh_at).toBe(30 * 60);
    expect(account!.last_error).toBe("Provider rate limit reached; retrying later.");
    expect(await env.DB.prepare(
      `SELECT status, failure_retryable, failure_retry_after_seconds
       FROM monitor_runs WHERE run_id = ?`
    ).bind(runID).first()).toEqual({
      status: "failed",
      failure_retryable: 1,
      failure_retry_after_seconds: 30 * 60,
    });

    const mustNotFetch: Parameters<typeof testing.refreshMonitorRun>[2] = async () => {
      fetchCount += 1;
      throw new Error("terminal rate-limited run must not fetch again");
    };
    await testing.refreshMonitorRun(queueMessage as never, testEnv, mustNotFetch);
    expect(fetchCount).toBe(1);
    expect(acknowledgements).toBe(2);
  });

  it("increases repeated provider backoff without exceeding eight hours", () => {
    expect(testing.monitorRetryDelaySeconds(true, 30 * 60, FIVE_MINUTES_SECONDS, 0))
      .toBe(30 * 60);
    expect(testing.monitorRetryDelaySeconds(true, 30 * 60, FIVE_MINUTES_SECONDS, 1))
      .toBe(60 * 60);
    expect(testing.monitorRetryDelaySeconds(true, 30 * 60, FIVE_MINUTES_SECONDS, 3))
      .toBe(4 * 60 * 60);
    expect(testing.monitorRetryDelaySeconds(true, 30 * 60, FIVE_MINUTES_SECONDS, 8))
      .toBe(8 * 60 * 60);
    expect(testing.monitorRetryDelaySeconds(false, 6 * 60 * 60, FIVE_MINUTES_SECONDS, 1))
      .toBe(8 * 60 * 60);
  });

  it("recovers a pending queue gap without scheduling a second provider run", async () => {
    await registerDevice();
    await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody()),
    });
    const queued: Array<{ kind?: string; run_id?: string }> = [];
    const testEnv = {
      DB: env.DB,
      REGISTRATION_ACCESS_KEY: env.REGISTRATION_ACCESS_KEY,
      CREDENTIAL_ENCRYPTION_KEY: env.CREDENTIAL_ENCRYPTION_KEY,
      PUSH_QUEUE: {
        sendBatch: async (messages: { body: { kind?: string; run_id?: string } }[]) => {
          queued.push(...messages.map((message) => message.body));
        },
      },
    } as unknown as Env;
    const firstOccurrence = Math.ceil(Date.now() / FIVE_MINUTES_MILLISECONDS)
      * FIVE_MINUTES_MILLISECONDS;
    await testing.runScheduledRefresh(testEnv, firstOccurrence);
    const firstRun = queued.find((body) => body.kind === "monitor_run")?.run_id;
    expect(firstRun).toBeTruthy();

    queued.length = 0;
    await testing.runScheduledRefresh(testEnv, firstOccurrence + FIVE_MINUTES_MILLISECONDS);
    const recoveredRuns = queued.filter((body) => body.kind === "monitor_run");
    expect(recoveredRuns).toEqual([{ kind: "monitor_run", run_id: firstRun }]);
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM monitor_runs"
    ).first<{ count: number }>()).toEqual({ count: 1 });
  });

  it("does not attach a newly linked client after an occurrence has been claimed", async () => {
    await registerDevice();
    await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody()),
    });
    const queued: Array<{ kind?: string; run_id?: string }> = [];
    const testEnv = {
      DB: env.DB,
      REGISTRATION_ACCESS_KEY: env.REGISTRATION_ACCESS_KEY,
      CREDENTIAL_ENCRYPTION_KEY: env.CREDENTIAL_ENCRYPTION_KEY,
      PUSH_QUEUE: {
        sendBatch: async (messages: { body: { kind?: string; run_id?: string } }[]) => {
          queued.push(...messages.map((message) => message.body));
        },
      },
    } as unknown as Env;
    const occurrence = Math.ceil(Date.now() / FIVE_MINUTES_MILLISECONDS)
      * FIVE_MINUTES_MILLISECONDS;
    await testing.runScheduledRefresh(testEnv, occurrence);
    const runID = queued.find((body) => body.kind === "monitor_run")!.run_id!;
    await env.DB.prepare(
      "UPDATE monitor_runs SET status = 'running', started_at = ? WHERE run_id = ?"
    ).bind(occurrence / 1_000, runID).run();

    const secondDeviceID = "019f724a-3414-4d52-ae37-0c7024a1ab99";
    const secondDeviceSecret = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC";
    await registerDevice(secondDeviceID, secondDeviceSecret, "b".repeat(64));
    const secondAccountURL = `https://push.example/v1/devices/${secondDeviceID}/accounts/${accountID}`;
    expect((await SELF.fetch(secondAccountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${secondDeviceSecret}` },
      body: JSON.stringify(accountRequestBody()),
    })).status).toBe(201);

    await testing.runScheduledRefresh(testEnv, occurrence);

    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM monitor_run_targets WHERE run_id = ?"
    ).bind(runID).first<{ count: number }>()).toEqual({ count: 1 });
    expect(await env.DB.prepare(
      `SELECT scheduled_monitor_at FROM monitored_accounts
       WHERE device_id = ? AND account_id = ?`
    ).bind(secondDeviceID, accountID).first()).toEqual({ scheduled_monitor_at: null });
  });

  it("does not reserve a due account through an already applied terminal target", async () => {
    await registerDevice();
    await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody()),
    });
    const queued: Array<{ kind?: string; run_id?: string }> = [];
    const testEnv = {
      DB: env.DB,
      REGISTRATION_ACCESS_KEY: env.REGISTRATION_ACCESS_KEY,
      CREDENTIAL_ENCRYPTION_KEY: env.CREDENTIAL_ENCRYPTION_KEY,
      PUSH_QUEUE: {
        sendBatch: async (messages: { body: { kind?: string; run_id?: string } }[]) => {
          queued.push(...messages.map((message) => message.body));
        },
      },
    } as unknown as Env;
    const occurrence = Math.ceil(Date.now() / FIVE_MINUTES_MILLISECONDS)
      * FIVE_MINUTES_MILLISECONDS;
    await testing.runScheduledRefresh(testEnv, occurrence);
    const runID = queued.find((body) => body.kind === "monitor_run")!.run_id!;
    await env.DB.batch([
      env.DB.prepare(
        "UPDATE monitor_run_targets SET applied_at = ? WHERE run_id = ?"
      ).bind(occurrence / 1_000, runID),
      env.DB.prepare(
        "UPDATE monitor_runs SET status = 'succeeded', completed_at = ? WHERE run_id = ?"
      ).bind(occurrence / 1_000, runID),
      env.DB.prepare(
        `UPDATE monitored_accounts
         SET scheduled_monitor_at = NULL, next_refresh_at = ?
         WHERE device_id = ? AND account_id = ?`
      ).bind(occurrence / 1_000, deviceID, accountID),
    ]);

    await testing.runScheduledRefresh(testEnv, occurrence);

    expect(await env.DB.prepare(
      `SELECT scheduled_monitor_at, next_refresh_at FROM monitored_accounts
       WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first()).toEqual({
      scheduled_monitor_at: null,
      next_refresh_at: occurrence / 1_000,
    });
  });

  it("finalizes a stale claimed run without repeating its provider request", async () => {
    await registerDevice();
    await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody()),
    });
    const queued: Array<{ kind?: string; run_id?: string }> = [];
    const testEnv = {
      DB: env.DB,
      REGISTRATION_ACCESS_KEY: env.REGISTRATION_ACCESS_KEY,
      CREDENTIAL_ENCRYPTION_KEY: env.CREDENTIAL_ENCRYPTION_KEY,
      PUSH_QUEUE: {
        sendBatch: async (messages: { body: { kind?: string; run_id?: string } }[]) => {
          queued.push(...messages.map((message) => message.body));
        },
      },
    } as unknown as Env;
    const firstOccurrence = Math.ceil(Date.now() / FIVE_MINUTES_MILLISECONDS)
      * FIVE_MINUTES_MILLISECONDS;
    await testing.runScheduledRefresh(testEnv, firstOccurrence);
    const runID = queued.find((body) => body.kind === "monitor_run")!.run_id!;
    await env.DB.prepare(
      "UPDATE monitor_runs SET status = 'running', started_at = ? WHERE run_id = ?"
    ).bind(firstOccurrence / 1_000 - 1_000, runID).run();

    queued.length = 0;
    await testing.runScheduledRefresh(testEnv, firstOccurrence + 3 * FIVE_MINUTES_MILLISECONDS);
    expect(queued.filter((body) => body.kind === "monitor_run"))
      .toContainEqual({ kind: "monitor_run", run_id: runID });
    let fetchCount = 0;
    let ackCount = 0;
    const mustNotFetch: Parameters<typeof testing.refreshMonitorRun>[2] = async () => {
      fetchCount += 1;
      throw new Error("provider must not be called");
    };
    await testing.refreshMonitorRun({
      body: { kind: "monitor_run", run_id: runID },
      ack: () => { ackCount += 1; },
      retry: () => {},
    } as never, testEnv, mustNotFetch);

    expect(fetchCount).toBe(0);
    expect(ackCount).toBe(1);
    expect(await env.DB.prepare(
      `SELECT status, encrypted_result_credentials, failure_retryable
       FROM monitor_runs WHERE run_id = ?`
    ).bind(runID).first()).toEqual({
      status: "failed",
      encrypted_result_credentials: null,
      failure_retryable: 0,
    });
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM monitor_run_targets WHERE run_id = ? AND applied_at IS NOT NULL"
    ).bind(runID).first<{ count: number }>()).toEqual({ count: 1 });
  });

  it("keeps the occurrence tombstone when the last target is deleted during its fetch", async () => {
    await registerDevice();
    await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody("chatgpt", 1)),
    });
    const queued: Array<{ kind?: string; run_id?: string }> = [];
    const testEnv = {
      DB: env.DB,
      REGISTRATION_ACCESS_KEY: env.REGISTRATION_ACCESS_KEY,
      CREDENTIAL_ENCRYPTION_KEY: env.CREDENTIAL_ENCRYPTION_KEY,
      PUSH_QUEUE: {
        sendBatch: async (messages: { body: { kind?: string; run_id?: string } }[]) => {
          queued.push(...messages.map((message) => message.body));
        },
      },
    } as unknown as Env;
    const occurrence = Math.ceil(Date.now() / FIVE_MINUTES_MILLISECONDS)
      * FIVE_MINUTES_MILLISECONDS;
    await testing.runScheduledRefresh(testEnv, occurrence);
    const runID = queued.find((body) => body.kind === "monitor_run")!.run_id!;

    let fetchCount = 0;
    let releaseFetch: (() => void) | undefined;
    let markFetchStarted: (() => void) | undefined;
    const fetchMayFinish = new Promise<void>((resolve) => { releaseFetch = resolve; });
    const fetchStarted = new Promise<void>((resolve) => { markFetchStarted = resolve; });
    const fetchUsage: Parameters<typeof testing.refreshMonitorRun>[2] = async (
      account, credentials, now,
    ) => {
      fetchCount += 1;
      markFetchStarted?.();
      await fetchMayFinish;
      const fetchedAt = now ?? Math.floor(Date.now() / 1_000);
      return {
        credentials,
        snapshot: {
          provider_id: account.provider_id,
          plan: account.plan,
          fetched_at: fetchedAt,
          windows: [{
            position: 0,
            metric_id: "weekly",
            title: "Weekly limit",
            kind: "weekly",
            window_minutes: 10_080,
            remaining_percent: 80,
            resets_at: fetchedAt + 86_400,
          }],
          available_reset_count: 0,
          reset_credits: [],
        },
      };
    };
    let acknowledgements = 0;
    const queueMessage = {
      body: { kind: "monitor_run", run_id: runID },
      ack: () => { acknowledgements += 1; },
      retry: () => {},
    };
    const inFlight = testing.refreshMonitorRun(queueMessage as never, testEnv, fetchUsage);
    await fetchStarted;

    expect((await SELF.fetch(`${accountURL}?consent_revision=2`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${deviceSecret}` },
    })).status).toBe(204);
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody("chatgpt", 3)),
    })).status).toBe(201);
    queued.length = 0;
    await testing.runScheduledRefresh(testEnv, occurrence);
    expect(queued.filter((body) => body.kind === "monitor_run"))
      .toContainEqual({ kind: "monitor_run", run_id: runID });

    releaseFetch?.();
    await inFlight;
    await testing.refreshMonitorRun(queueMessage as never, testEnv, fetchUsage);
    expect(fetchCount).toBe(1);
    expect(acknowledgements).toBe(2);
    expect(await env.DB.prepare(
      `SELECT status, encrypted_result_credentials, result_snapshot
       FROM monitor_runs WHERE run_id = ?`
    ).bind(runID).first()).toEqual({
      status: "succeeded",
      encrypted_result_credentials: null,
      result_snapshot: null,
    });
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM monitor_runs WHERE occurrence_at = ?"
    ).bind(occurrence / 1_000).first<{ count: number }>()).toEqual({ count: 1 });
  });

  it("fetches one overlapping credential scope once per cron and fans it out to both clients", async () => {
    const secondDeviceID = "019f724a-3414-4d52-ae37-0c7024a1ab99";
    const secondDeviceSecret = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC";
    await registerDevice();
    await registerDevice(secondDeviceID, secondDeviceSecret, "b".repeat(64));
    expect((await SELF.fetch(accountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify(accountRequestBody()),
    })).status).toBe(201);
    const secondAccountURL = `https://push.example/v1/devices/${secondDeviceID}/accounts/${accountID}`;
    expect((await SELF.fetch(secondAccountURL, {
      method: "PUT",
      headers: { authorization: `Bearer ${secondDeviceSecret}` },
      body: JSON.stringify(accountRequestBody()),
    })).status).toBe(201);

    const queued: unknown[] = [];
    const testEnv = {
      DB: env.DB,
      REGISTRATION_ACCESS_KEY: env.REGISTRATION_ACCESS_KEY,
      CREDENTIAL_ENCRYPTION_KEY: env.CREDENTIAL_ENCRYPTION_KEY,
      PUSH_QUEUE: {
        sendBatch: async (messages: { body: unknown }[]) => {
          queued.push(...messages.map((message) => message.body));
        },
      },
    } as unknown as Env;
    const occurrence = Math.ceil(Date.now() / FIVE_MINUTES_MILLISECONDS)
      * FIVE_MINUTES_MILLISECONDS;
    await testing.runScheduledRefresh(testEnv, occurrence);
    const monitorMessages = queued.filter(
      (body): body is { kind: "monitor_run"; run_id: string } =>
        typeof body === "object" && body !== null
          && (body as { kind?: string }).kind === "monitor_run"
    );
    expect(monitorMessages).toHaveLength(1);
    expect(JSON.stringify(monitorMessages[0])).not.toContain(deviceID);
    expect(JSON.stringify(monitorMessages[0])).not.toContain(secondDeviceID);
    expect(JSON.stringify(monitorMessages[0])).not.toContain("access-secret");
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM monitor_run_targets WHERE run_id = ?"
    ).bind(monitorMessages[0].run_id).first<{ count: number }>()).toEqual({ count: 2 });

    let fetchCount = 0;
    let releaseFetch: (() => void) | undefined;
    let markFetchStarted: (() => void) | undefined;
    const fetchMayFinish = new Promise<void>((resolve) => { releaseFetch = resolve; });
    const fetchStarted = new Promise<void>((resolve) => { markFetchStarted = resolve; });
    const acknowledgements = { ack: 0, retry: 0 };
    const queueMessage = {
      body: monitorMessages[0],
      ack: () => { acknowledgements.ack += 1; },
      retry: () => { acknowledgements.retry += 1; },
    };
    const fetchUsage: Parameters<typeof testing.refreshMonitorRun>[2] = async (
      account, credentials, now,
    ) => {
      const fetchedAt = now ?? Math.floor(Date.now() / 1_000);
      fetchCount += 1;
      markFetchStarted?.();
      await fetchMayFinish;
      expect(account.workspace_id).toBe("workspace-123");
      expect(credentials.access_token).toBe("access-secret");
      return {
        credentials: {
          access_token: "rotated-access-secret",
          refresh_token: "rotated-refresh-secret",
          id_token: "rotated-id-secret",
          expires_at: fetchedAt + 3_600,
        },
        snapshot: {
          provider_id: account.provider_id,
          plan: "Plus",
          fetched_at: fetchedAt,
          windows: [{
            position: 0,
            metric_id: "weekly",
            title: "Weekly limit",
            kind: "weekly",
            window_minutes: 10_080,
            remaining_percent: 73,
            resets_at: fetchedAt + 86_400,
          }],
          available_reset_count: 0,
          reset_credits: [],
        },
      };
    };

    const firstDelivery = testing.refreshMonitorRun(queueMessage as never, testEnv, fetchUsage);
    await fetchStarted;
    await testing.refreshMonitorRun(queueMessage as never, testEnv, fetchUsage);
    releaseFetch?.();
    await firstDelivery;
    await testing.refreshMonitorRun(queueMessage as never, testEnv, fetchUsage);

    expect(fetchCount).toBe(1);
    expect(acknowledgements).toEqual({ ack: 3, retry: 0 });
    expect(await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM usage_history WHERE metric_id = 'weekly'"
    ).first<{ count: number }>()).toEqual({ count: 2 });
    const run = await env.DB.prepare(
      `SELECT status, encrypted_result_credentials, result_snapshot
       FROM monitor_runs WHERE run_id = ?`
    ).bind(monitorMessages[0].run_id).first<{
      status: string;
      encrypted_result_credentials: string | null;
      result_snapshot: string | null;
    }>();
    expect(run).toEqual({
      status: "succeeded",
      encrypted_result_credentials: null,
      result_snapshot: null,
    });
    for (const [id, secret] of [
      [deviceID, deviceSecret],
      [secondDeviceID, secondDeviceSecret],
    ] as const) {
      const response = await SELF.fetch(
        `https://push.example/v1/devices/${id}/accounts/${accountID}/sync`,
        { headers: { authorization: `Bearer ${secret}` } },
      );
      const body = await response.json<Record<string, unknown>>();
      expect(body).not.toHaveProperty("credentials");
      expect(JSON.stringify(body)).not.toContain("rotated-access-secret");
      expect(body).toMatchObject({
        history: [expect.objectContaining({ metric_id: "weekly", remaining_percent: 73 })],
      });
    }
  });

  it("deduplicates API credentials across display budgets and reapplies each budget", async () => {
    const account = {
      provider_id: "openai_api" as const,
      workspace_id: "organization-123",
      plan: null,
    };
    const credentials = {
      access_token: "admin-api-key",
      refresh_token: "",
      id_token: "",
      expires_at: null,
      currency_code: "USD",
    };
    const firstFingerprint = await testing.credentialFingerprint(
      env,
      account,
      { ...credentials, monthly_budget: 10 },
    );
    const secondFingerprint = await testing.credentialFingerprint(
      env,
      account,
      { ...credentials, monthly_budget: 25 },
    );
    expect(firstFingerprint).toBe(secondFingerprint);

    const snapshot = testing.snapshotForCredentials({
      provider_id: "openai_api",
      plan: null,
      fetched_at: 2_000_000_000,
      windows: [],
      available_reset_count: 0,
      reset_credits: [],
      api_balance: {
        title: "Monthly API budget",
        currency_code: "USD",
        spent: 2,
        limit: 10,
        remaining: 8,
        period_start: 1_999_000_000,
        period_end: 2_001_000_000,
        access_expires_at: null,
        is_unlimited: false,
      },
    }, { ...credentials, monthly_budget: 25 });
    expect(snapshot.api_balance).toMatchObject({
      title: "Monthly API budget",
      spent: 2,
      limit: 25,
      remaining: 23,
    });
  });

  it("accepts write-only monitoring uploads for the four new API providers", async () => {
    for (const providerID of ["openrouter", "fireworks", "deepseek", "poe"] as const) {
      const parsed = await testing.parseAccountUpload(new Request(
        "https://push.example/provider-upload-test",
        { method: "PUT", body: JSON.stringify(accountRequestBody(providerID)) },
      ));
      expect(parsed?.provider_id).toBe(providerID);
      expect(parsed?.credentials.access_token).toBe("access-secret");
    }
  });

  it("canonicalizes Fireworks account uploads and rejects legacy synthetic prefixes", async () => {
    for (const workspaceID of ["accounts/team-one", "team-one"]) {
      const body = { ...accountRequestBody("fireworks"), workspace_id: workspaceID };
      const parsed = await testing.parseAccountUpload(new Request(
        "https://push.example/provider-upload-test",
        { method: "PUT", body: JSON.stringify(body) },
      ));
      expect(parsed?.workspace_id).toBe("accounts/team-one");
    }

    const legacyBody = {
      ...accountRequestBody("fireworks"),
      workspace_id: "fireworks-accounts/team-one",
    };
    await expect(testing.parseAccountUpload(new Request(
      "https://push.example/provider-upload-test",
      { method: "PUT", body: JSON.stringify(legacyBody) },
    ))).resolves.toBeNull();
  });
});
