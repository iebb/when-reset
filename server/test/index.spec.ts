import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { testing } from "../src/index";

const deviceID = "019f724a-3414-4d52-ae37-0c7024a1ab97";
const deviceSecret = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
const apnsToken = "a".repeat(64);
const FIVE_MINUTES_SECONDS = 5 * 60;
const FIVE_MINUTES_MILLISECONDS = FIVE_MINUTES_SECONDS * 1_000;

beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare("DROP TABLE IF EXISTS usage_history"),
    env.DB.prepare("DROP TABLE IF EXISTS monitor_run_targets"),
    env.DB.prepare("DROP TABLE IF EXISTS monitor_runs"),
    env.DB.prepare("DROP TABLE IF EXISTS monitored_accounts"),
    env.DB.prepare("DROP TABLE IF EXISTS account_monitoring_consent"),
    env.DB.prepare("DROP TABLE IF EXISTS link_sessions"),
    env.DB.prepare("DROP TABLE IF EXISTS device_deletion_tombstones"),
    env.DB.prepare("DROP TABLE IF EXISTS devices"),
    env.DB.prepare(`CREATE TABLE devices (
      device_id TEXT PRIMARY KEY NOT NULL,
      secret_hash TEXT NOT NULL,
      apns_token TEXT NOT NULL UNIQUE,
      created_at INTEGER NOT NULL,
      last_seen_at INTEGER NOT NULL,
      last_push_at INTEGER
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
    env.DB.prepare(`CREATE TABLE account_monitoring_consent (
      device_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
      consent_revision INTEGER NOT NULL CHECK(consent_revision > 0),
      enabled INTEGER NOT NULL CHECK(enabled IN (0, 1)),
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (device_id, account_id),
      FOREIGN KEY (device_id) REFERENCES devices(device_id) ON DELETE CASCADE
    )`),
    env.DB.prepare(`CREATE TABLE monitored_accounts (
      device_id TEXT NOT NULL,
      account_id TEXT NOT NULL,
      provider_id TEXT NOT NULL,
      workspace_id TEXT NOT NULL,
      plan TEXT,
      missing_quotas TEXT NOT NULL DEFAULT '[]',
      encrypted_credentials TEXT NOT NULL,
      credential_fingerprint TEXT,
      scheduled_monitor_at INTEGER,
      refresh_interval_seconds INTEGER NOT NULL,
      next_refresh_at INTEGER NOT NULL,
      last_refresh_at INTEGER,
      last_success_at INTEGER,
      last_error TEXT,
      latest_snapshot TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (device_id, account_id),
      FOREIGN KEY (device_id) REFERENCES devices(device_id) ON DELETE CASCADE
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
          completed_at = COALESCE(completed_at, occurrence_at)
        WHERE run_id = OLD.run_id;
      END`),
    env.DB.prepare(`CREATE TABLE usage_history (
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
        REFERENCES monitored_accounts(device_id, account_id) ON DELETE CASCADE
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
    plan: "Plus",
    refresh_interval_seconds: FIVE_MINUTES_SECONDS,
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

describe("one-use Worker linking", () => {
  it("serves a same-origin access-key form with no-store security headers", async () => {
    for (const path of ["/", "/link"]) {
      const response = await SELF.fetch(`https://push.example${path}`);
      const body = await response.text();
      expect(response.status).toBe(200);
      expect(response.headers.get("cache-control")).toBe("no-store");
      expect(response.headers.get("content-security-policy")).toContain("default-src 'none'");
      expect(response.headers.get("referrer-policy")).toBe("no-referrer");
      expect(response.headers.get("x-frame-options")).toBe("DENY");
      expect(body).toContain("Link When Reset");
      expect(body).toContain("push.example");
      expect(body).toContain("method=\"post\" action=\"/v1/link-sessions\"");
      expect(body).toContain("X-When-Reset-Server-Key");
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

  it("rejects an APNs token owned by another device without consuming the link", async () => {
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

    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: "apns_token_conflict" });
    expect(await env.DB.prepare("SELECT device_id FROM devices WHERE apns_token = ?")
      .bind(apnsToken).first<{ device_id: string }>()).toEqual({ device_id: deviceID });
    expect(await env.DB.prepare("SELECT consumed_at FROM link_sessions WHERE session_id = ?")
      .bind(session.session_id).first<{ consumed_at: number | null }>()).toEqual({ consumed_at: null });
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
      }),
    });

    expect(response.status).toBe(201);
    const row = await env.DB.prepare(
      "SELECT secret_hash, apns_token FROM devices WHERE device_id = ?"
    ).bind(deviceID).first<{ secret_hash: string; apns_token: string }>();
    expect(row?.secret_hash).toBe(await testing.hashSecret(deviceSecret));
    expect(row?.secret_hash).not.toBe(deviceSecret);
    expect(row?.apns_token).toBe(apnsToken);
  });

  it("rotates an existing APNs token using only the device secret", async () => {
    await registerDevice();
    const url = `https://push.example/v1/devices/${deviceID}`;
    expect((await SELF.fetch(url, {
      method: "PUT",
      headers: { authorization: `Bearer ${"B".repeat(43)}` },
      body: JSON.stringify({ apns_token: "b".repeat(64) }),
    })).status).toBe(401);

    const response = await SELF.fetch(url, {
      method: "PUT",
      headers: { authorization: `Bearer ${deviceSecret}` },
      body: JSON.stringify({ apns_token: "b".repeat(64) }),
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
    expect(await env.DB.prepare("SELECT apns_token FROM devices WHERE device_id = ?")
      .bind(deviceID).first<{ apns_token: string }>()).toEqual({ apns_token: "b".repeat(64) });
  });

  it("returns a deliberate conflict when registrations reuse another device’s APNs token", async () => {
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

    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: "apns_token_conflict" });
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM devices")
      .first<{ count: number }>()).toEqual({ count: 1 });
  });

  it("returns a deliberate conflict when token rotation targets another device", async () => {
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
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: "apns_token_conflict" });
    expect(await env.DB.prepare("SELECT apns_token FROM devices WHERE device_id = ?")
      .bind(deviceID).first<{ apns_token: string }>()).toEqual({ apns_token: apnsToken });
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

  it("tombstones permanent APNs rejection so a later authenticated unregister is idempotent", async () => {
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
        .first<{ count: number }>()).toEqual({ count: 0 });
    }
    expect(await env.DB.prepare(
      "SELECT secret_hash FROM device_deletion_tombstones WHERE device_id = ?"
    ).bind(deviceID).first<{ secret_hash: string }>()).toEqual({
      secret_hash: await testing.hashSecret(deviceSecret),
    });
    expect((await SELF.fetch(`https://push.example/v1/devices/${deviceID}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${deviceSecret}` },
    })).status).toBe(204);
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
    });
    expect(responseBody).not.toHaveProperty("credentials");
    expect(JSON.stringify(responseBody)).not.toContain("access-secret");
    expect(JSON.stringify(responseBody)).not.toContain("refresh-secret");
    expect(JSON.stringify(responseBody)).not.toContain("id-secret");
    const row = await env.DB.prepare(
      "SELECT encrypted_credentials FROM monitored_accounts WHERE device_id = ? AND account_id = ?"
    ).bind(deviceID, accountID).first<{ encrypted_credentials: string }>();
    expect(row?.encrypted_credentials).not.toContain("access-secret");
    expect(row?.encrypted_credentials).not.toContain("refresh-secret");
    expect(JSON.parse(row!.encrypted_credentials)).toMatchObject({ v: 1 });
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
});
