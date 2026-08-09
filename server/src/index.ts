import APNSPrivateKey from "../apns/WhenResetSharedAPNs.p8";
import {
  fetchProviderUsage,
  ProviderFetchError,
  type ProviderAccount,
  type ProviderCredentials,
  type ProviderID,
  type ProviderSnapshot,
} from "./providers";
import { renderLinkPage, renderLinkQRCode } from "./link-page";

const MAX_REGISTRATION_BODY_BYTES = 2_048;
const MAX_DEVICE_TOKEN_BODY_BYTES = 1_024;
const MAX_ACCOUNT_BODY_BYTES = 64 * 1_024;
const LINK_SESSION_TTL_SECONDS = 5 * 60;
const ACTIVE_DEVICE_DAYS = 45;
const HISTORY_RETENTION_DAYS = 35;
const DEVICE_DELETION_TOMBSTONE_RETENTION_DAYS = 90;
const MONITOR_RUN_RETENTION_DAYS = 7;
const MONITOR_RUN_STALE_SECONDS = 10 * 60;
const DATABASE_BATCH_SIZE = 500;
const QUEUE_BATCH_SIZE = 100;
const HISTORY_PAGE_SIZE = 1_000;
const MIN_MONITOR_INTERVAL_SECONDS = 5 * 60;
const MAX_MONITOR_INTERVAL_SECONDS = 8 * 60 * 60;
const APNS_TOKEN_REFRESH_SECONDS = 50 * 60;
const APNS_HOST = "https://api.push.apple.com";
const APNS_KEY_ID = "Y35ZLFTW8W";
const APNS_TEAM_ID = "7P8CLHDH5G";
const APNS_TOPIC = "ad.neko.when";

type DeviceRegistration = {
  device_id: string;
  device_secret: string;
  apns_token: string;
};

type DeviceRow = {
  device_id: string;
  secret_hash: string;
  apns_token: string;
};

type DeviceDeletionTombstoneRow = {
  device_id: string;
  secret_hash: string;
  deleted_at: number;
};

type LinkSessionRow = {
  session_id: string;
  token_hash: string;
  server_origin: string;
  display_name: string;
  expires_at: number;
  consumed_at: number | null;
  claimed_device_id: string | null;
};

type LinkSessionAuthorization =
  | { ok: true; session: LinkSessionRow }
  | { ok: false; response: Response };

type PushTarget = {
  kind: "push";
  device_id: string;
  apns_token: string;
};

type MonitorRunTarget = {
  kind: "monitor_run";
  run_id: string;
};

type QueueTarget = PushTarget | MonitorRunTarget;

type AccountUpload = {
  provider_id: ProviderID;
  workspace_id: string;
  plan: string | null;
  refresh_interval_seconds: number;
  consent_revision: number;
  credentials: ProviderCredentials;
  missing_quotas: MissingQuotaDescriptor[];
};

type MissingQuotaDescriptor = {
  metric_id: string;
  title: string;
  kind: "fiveHour" | "weekly" | "additional" | null;
  window_minutes: number | null;
  resets_at: number | null;
};

type MonitoredAccountRow = ProviderAccount & {
  device_id: string;
  account_id: string;
  encrypted_credentials: string;
  refresh_interval_seconds: number;
  next_refresh_at: number;
  last_success_at: number | null;
  last_error: string | null;
  latest_snapshot: string | null;
  missing_quotas: string;
  consent_revision: number;
  credential_fingerprint: string | null;
  scheduled_monitor_at: number | null;
};

type AccountSyncRow = {
  latest_snapshot: string | null;
  last_success_at: number | null;
  last_error: string | null;
  consent_revision: number;
};

type MonitorRunRow = {
  run_id: string;
  occurrence_at: number;
  credential_fingerprint: string;
  status: "pending" | "running" | "fetched" | "succeeded" | "failed";
  encrypted_result_credentials: string | null;
  result_snapshot: string | null;
  result_error: string | null;
  failure_retryable: number | null;
};

type MonitorRunTargetRow = MonitoredAccountRow & {
  target_consent_revision: number;
  target_credential_fingerprint: string;
  applied_at: number | null;
};

type EncryptedEnvelope = {
  v: 1;
  nonce: string;
  ciphertext: string;
};

type HistoryRow = {
  provider_id: ProviderID;
  metric_id: string;
  metric_title: string;
  kind: string | null;
  window_minutes: number | null;
  remaining_percent: number;
  recorded_at: number;
  resets_at: number;
  seconds_until_reset: number;
  plan: string | null;
};

type APNSResult = {
  ok: boolean;
  status: number;
  reason?: string;
};

type APNSTokenRow = {
  token: string;
  issued_at: number;
};

export default {
  async fetch(request, env): Promise<Response> {
    try {
      return await route(request, env);
    } catch (error) {
      console.error(JSON.stringify({ event: "request_failed", error: safeError(error) }));
      const pathname = new URL(request.url).pathname;
      if (["/", "/link", "/link/"].includes(pathname)
          || pathname.startsWith("/v1/link-sessions")) {
        return linkJSON({ error: "internal_error" }, 500);
      }
      return json({ error: "internal_error" }, 500);
    }
  },

  async scheduled(controller, env, context): Promise<void> {
    context.waitUntil(runScheduledRefresh(env, controller.scheduledTime));
  },

  async queue(batch, env): Promise<void> {
    await processQueue(batch as MessageBatch<QueueTarget>, env);
  },
} satisfies ExportedHandler<Env>;

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (request.method === "GET" && ["/", "/link", "/link/"].includes(url.pathname)) {
    return linkPageResponse(url);
  }

  if (request.method === "GET" && url.pathname === "/healthz") {
    return json({ ok: true, mode: "self_hosted", topic: APNS_TOPIC });
  }

  if (request.method === "POST" && url.pathname === "/v1/link-sessions") {
    if (!sameOriginRequest(request, url.origin)) {
      return linkJSON({ error: "forbidden_origin" }, 403);
    }
    if (!(await registrationAccessAllowed(request, env))) {
      return linkJSON({ error: "unauthorized" }, 401);
    }
    return createLinkSession(env, url);
  }

  const linkMatch = /^\/v1\/link-sessions\/([0-9a-f-]{36})(?:\/(claim))?$/.exec(url.pathname);
  if (linkMatch) {
    const sessionID = linkMatch[1];
    if (!isUUID(sessionID)) return linkJSON({ error: "invalid_session_id" }, 400);
    const token = bearerToken(request);
    if (!token) return linkJSON({ error: "unauthorized" }, 401);
    const authorization = await authorizeLinkSession(env, sessionID, token, url.origin);
    if (!authorization.ok) return authorization.response;
    const session = authorization.session;

    if (request.method === "GET" && !linkMatch[2]) {
      return linkJSON(linkSessionMetadata(session));
    }
    if (request.method === "POST" && linkMatch[2] === "claim") {
      const registration = await parseRegistration(request);
      if (!registration) return linkJSON({ error: "invalid_registration" }, 400);
      return claimLinkSession(env, session, token, registration);
    }
    return linkJSON({ error: "method_not_allowed" }, 405, {
      Allow: linkMatch[2] ? "POST" : "GET",
    });
  }

  if (request.method === "POST" && url.pathname === "/v1/devices") {
    if (!(await registrationAccessAllowed(request, env))) {
      return json({ error: "unauthorized" }, 401);
    }
    const registration = await parseRegistration(request);
    if (!registration) return json({ error: "invalid_registration" }, 400);
    return registerDevice(env, registration);
  }

  const accountMatch = /^\/v1\/devices\/([0-9a-f-]{36})\/accounts\/([0-9a-f-]{36})(?:\/(sync))?$/.exec(
    url.pathname
  );
  if (accountMatch) {
    const deviceID = accountMatch[1];
    const accountID = accountMatch[2];
    if (!isUUID(deviceID) || !isUUID(accountID)) return json({ error: "invalid_id" }, 400);
    const device = await authorizeDevice(request, env, deviceID);
    if (!device) return json({ error: "unauthorized" }, 401);

    if (request.method === "PUT" && !accountMatch[3]) {
      const upload = await parseAccountUpload(request);
      if (!upload) return json({ error: "invalid_account" }, 400);
      return upsertMonitoredAccount(env, deviceID, accountID, upload);
    }
    if (request.method === "DELETE" && !accountMatch[3]) {
      const consentRevision = parseDeleteConsentRevision(url);
      if (consentRevision === null) {
        return json({ error: "invalid_consent_revision" }, 400, { "cache-control": "no-store" });
      }
      return disableMonitoredAccount(env, deviceID, accountID, consentRevision);
    }
    if (request.method === "GET" && accountMatch[3] === "sync") {
      return syncMonitoredAccount(env, deviceID, accountID, url);
    }
    return json({ error: "method_not_allowed" }, 405);
  }

  const match = /^\/v1\/devices\/([0-9a-f-]{36})(?:\/(refresh))?$/.exec(url.pathname);
  if (!match) return json({ error: "not_found" }, 404);

  const deviceID = match[1];
  if (!isUUID(deviceID)) return json({ error: "invalid_device_id" }, 400);

  if (request.method === "DELETE" && !match[2]) {
    const secret = bearerToken(request);
    if (!secret) return json({ error: "unauthorized" }, 401);
    return unregisterDevice(env, deviceID, secret);
  }

  const row = await authorizeDevice(request, env, deviceID);
  if (!row) return json({ error: "unauthorized" }, 401);

  if (request.method === "PUT" && !match[2]) {
    const apnsToken = await parseDeviceTokenUpdate(request);
    if (!apnsToken) return json({ error: "invalid_device_token" }, 400);
    const now = Math.floor(Date.now() / 1_000);
    const result = await env.DB.prepare(
      `UPDATE devices SET apns_token = ?, last_seen_at = ?
       WHERE device_id = ?
         AND NOT EXISTS (
           SELECT 1 FROM devices AS token_owner
           WHERE token_owner.apns_token = ? AND token_owner.device_id <> ?
         )`
    ).bind(apnsToken, now, deviceID, apnsToken, deviceID).run();
    if ((result.meta.changes ?? 0) !== 1) {
      return json({ error: "apns_token_conflict" }, 409);
    }
    console.log(JSON.stringify({ event: "device_updated" }));
    return json({ ok: true });
  }

  if (request.method === "POST" && match[2] === "refresh") {
    const authorization = await currentAPNSAuthorization(env);
    const result = await sendSilentPush(env, row.apns_token, authorization);
    await handleAPNSResult(env, row, result);
    if (!result.ok) return json({ error: "apns_rejected", reason: result.reason }, 502);
    return json({ ok: true });
  }

  return json({ error: "method_not_allowed" }, 405, {
    Allow: match[2] ? "POST" : "DELETE, PUT",
  });
}

function linkPageResponse(url: URL): Response {
  if (url.protocol !== "https:") {
    return linkJSON({ error: "https_required" }, 400);
  }
  const nonce = randomBase64URL(16);
  return new Response(renderLinkPage(url.origin, url.host, nonce), {
    status: 200,
    headers: linkSecurityHeaders({
      "content-type": "text/html; charset=utf-8",
      "content-security-policy": [
        "default-src 'none'",
        `script-src 'nonce-${nonce}'`,
        `style-src 'nonce-${nonce}'`,
        "connect-src 'self'",
        "form-action 'self'",
        "base-uri 'none'",
        "frame-ancestors 'none'",
      ].join("; "),
    }),
  });
}

async function createLinkSession(env: Env, url: URL): Promise<Response> {
  if (url.protocol !== "https:") return linkJSON({ error: "https_required" }, 400);
  const now = Math.floor(Date.now() / 1_000);
  await pruneLinkSessions(env, now);
  const sessionID = crypto.randomUUID().toLowerCase();
  const token = randomBase64URL(32);
  const expiresAt = now + LINK_SESSION_TTL_SECONDS;
  const displayName = url.host;
  await env.DB.prepare(
    `INSERT INTO link_sessions (
       session_id, token_hash, server_origin, display_name, created_at, expires_at
     ) VALUES (?, ?, ?, ?, ?, ?)`
  ).bind(sessionID, await hashSecret(token), url.origin, displayName, now, expiresAt).run();

  const link = new URL("whenreset://link-worker");
  link.searchParams.set("v", "1");
  link.searchParams.set("server", url.origin);
  link.searchParams.set("session", sessionID);
  link.searchParams.set("token", token);
  link.searchParams.set("expires", String(expiresAt));
  const linkURI = link.toString();
  console.log(JSON.stringify({ event: "link_session_created" }));
  return linkJSON({
    version: 1,
    session_id: sessionID,
    server_origin: url.origin,
    display_name: displayName,
    expires_at: expiresAt,
    link_uri: linkURI,
    qr_svg: renderLinkQRCode(linkURI),
  }, 201);
}

async function authorizeLinkSession(
  env: Env,
  sessionID: string,
  token: string,
  requestOrigin: string,
): Promise<LinkSessionAuthorization> {
  const session = await env.DB.prepare(
    `SELECT session_id, token_hash, server_origin, display_name, expires_at,
            consumed_at, claimed_device_id
     FROM link_sessions WHERE session_id = ?`
  ).bind(sessionID).first<LinkSessionRow>();
  if (!session || !(await secretsMatch(token, session.token_hash))) {
    return { ok: false, response: linkJSON({ error: "unauthorized" }, 401) };
  }
  if (session.server_origin !== requestOrigin) {
    return { ok: false, response: linkJSON({ error: "wrong_server_origin" }, 403) };
  }
  const now = Math.floor(Date.now() / 1_000);
  if (session.consumed_at !== null) {
    return { ok: false, response: linkJSON({ error: "link_session_used" }, 409) };
  }
  if (session.expires_at <= now) {
    return { ok: false, response: linkJSON({ error: "link_session_expired" }, 410) };
  }
  return { ok: true, session };
}

function linkSessionMetadata(session: LinkSessionRow): Record<string, unknown> {
  return {
    version: 1,
    mode: "self_hosted",
    topic: APNS_TOPIC,
    server_origin: session.server_origin,
    display_name: session.display_name,
    expires_at: session.expires_at,
  };
}

async function claimLinkSession(
  env: Env,
  session: LinkSessionRow,
  token: string,
  registration: DeviceRegistration,
): Promise<Response> {
  const existing = await env.DB.prepare(
    "SELECT device_id, secret_hash, apns_token FROM devices WHERE device_id = ?"
  ).bind(registration.device_id).first<DeviceRow>();
  if (existing && !(await secretsMatch(registration.device_secret, existing.secret_hash))) {
    return linkJSON({ error: "device_conflict" }, 409);
  }
  if (await apnsTokenBelongsToAnotherDevice(env, registration.apns_token, registration.device_id)) {
    return linkJSON({ error: "apns_token_conflict" }, 409);
  }

  const now = Math.floor(Date.now() / 1_000);
  const tokenHash = await hashSecret(token);
  const deviceSecretHash = existing?.secret_hash ?? await hashSecret(registration.device_secret);
  const validSession = `session_id = ? AND token_hash = ? AND server_origin = ?
    AND expires_at > ? AND consumed_at IS NULL`;
  const sessionBindings = [session.session_id, tokenHash, session.server_origin, now] as const;
  const results = await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO devices (device_id, secret_hash, apns_token, created_at, last_seen_at)
       SELECT ?, ?, ?, ?, ?
       WHERE EXISTS (SELECT 1 FROM link_sessions WHERE ${validSession})
         AND NOT EXISTS (
           SELECT 1 FROM devices AS token_owner
           WHERE token_owner.apns_token = ? AND token_owner.device_id <> ?
         )
       ON CONFLICT(device_id) DO UPDATE SET
         apns_token = excluded.apns_token,
         last_seen_at = excluded.last_seen_at
       WHERE devices.secret_hash = excluded.secret_hash
         AND NOT EXISTS (
           SELECT 1 FROM devices AS token_owner
           WHERE token_owner.apns_token = ? AND token_owner.device_id <> ?
         )`
    ).bind(
      registration.device_id, deviceSecretHash, registration.apns_token, now, now,
      ...sessionBindings,
      registration.apns_token, registration.device_id,
      registration.apns_token, registration.device_id,
    ),
    env.DB.prepare(
      `DELETE FROM device_deletion_tombstones
       WHERE device_id = ?
         AND EXISTS (
           SELECT 1 FROM devices
           WHERE device_id = ? AND secret_hash = ?
         )
         AND EXISTS (SELECT 1 FROM link_sessions WHERE ${validSession})`
    ).bind(
      registration.device_id, registration.device_id, deviceSecretHash,
      ...sessionBindings,
    ),
    env.DB.prepare(
      `UPDATE link_sessions SET consumed_at = ?, claimed_device_id = ?
       WHERE ${validSession}
         AND EXISTS (
           SELECT 1 FROM devices
           WHERE device_id = ? AND secret_hash = ? AND apns_token = ?
         )`
    ).bind(
      now, registration.device_id, ...sessionBindings,
      registration.device_id, deviceSecretHash, registration.apns_token,
    ),
  ]);
  const deviceChanges = results[0]?.meta.changes ?? 0;
  const sessionChanges = results[2]?.meta.changes ?? 0;
  if (deviceChanges !== 1 || sessionChanges !== 1) {
    if (await apnsTokenBelongsToAnotherDevice(
      env, registration.apns_token, registration.device_id
    )) {
      return linkJSON({ error: "apns_token_conflict" }, 409);
    }
    return linkJSON({ error: "link_session_used" }, 409);
  }
  console.log(JSON.stringify({ event: "device_linked" }));
  return linkJSON({ ok: true }, 201);
}

function sameOriginRequest(request: Request, origin: string): boolean {
  const supplied = request.headers.get("origin");
  return supplied === null || supplied === origin;
}

async function unregisterDevice(env: Env, deviceID: string, secret: string): Promise<Response> {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const live = await env.DB.prepare(
      "SELECT device_id, secret_hash, apns_token FROM devices WHERE device_id = ?"
    ).bind(deviceID).first<DeviceRow>();
    if (!live) return deletedDeviceRetryResponse(env, deviceID, secret);
    if (!(await secretsMatch(secret, live.secret_hash))) {
      return json({ error: "unauthorized" }, 401, { "cache-control": "no-store" });
    }

    if (await tombstoneAndDeleteDeviceBySecretHash(
      env, deviceID, live.secret_hash, Math.floor(Date.now() / 1_000)
    )) {
      console.log(JSON.stringify({ event: "device_unregistered" }));
      return deviceDeletedResponse();
    }
  }
  return deletedDeviceRetryResponse(env, deviceID, secret);
}

async function deletedDeviceRetryResponse(
  env: Env,
  deviceID: string,
  secret: string,
): Promise<Response> {
  const live = await env.DB.prepare(
    "SELECT device_id, secret_hash, apns_token FROM devices WHERE device_id = ?"
  ).bind(deviceID).first<DeviceRow>();
  if (live) {
    return json({ error: "unauthorized" }, 401, { "cache-control": "no-store" });
  }
  const tombstone = await env.DB.prepare(
    `SELECT device_id, secret_hash, deleted_at
     FROM device_deletion_tombstones WHERE device_id = ?`
  ).bind(deviceID).first<DeviceDeletionTombstoneRow>();
  if (!tombstone || !(await secretsMatch(secret, tombstone.secret_hash))) {
    return json({ error: "unauthorized" }, 401, { "cache-control": "no-store" });
  }
  return deviceDeletedResponse();
}

function deviceDeletedResponse(): Response {
  return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
}

async function tombstoneAndDeleteDeviceBySecretHash(
  env: Env,
  deviceID: string,
  secretHash: string,
  deletedAt: number,
): Promise<boolean> {
  const results = await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO device_deletion_tombstones (device_id, secret_hash, deleted_at)
       SELECT device_id, secret_hash, ? FROM devices
       WHERE device_id = ? AND secret_hash = ?
       ON CONFLICT(device_id) DO UPDATE SET
         secret_hash = excluded.secret_hash,
         deleted_at = excluded.deleted_at`
    ).bind(deletedAt, deviceID, secretHash),
    env.DB.prepare(
      `DELETE FROM devices
       WHERE device_id = ? AND secret_hash = ?
         AND EXISTS (
           SELECT 1 FROM device_deletion_tombstones
           WHERE device_id = devices.device_id AND secret_hash = devices.secret_hash
         )`
    ).bind(deviceID, secretHash),
  ]);
  return (results[1]?.meta.changes ?? 0) === 1;
}

async function tombstoneAndDeleteDeviceByAPNSToken(
  env: Env,
  deviceID: string,
  apnsToken: string,
  deletedAt: number,
): Promise<boolean> {
  const results = await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO device_deletion_tombstones (device_id, secret_hash, deleted_at)
       SELECT device_id, secret_hash, ? FROM devices
       WHERE device_id = ? AND apns_token = ?
       ON CONFLICT(device_id) DO UPDATE SET
         secret_hash = excluded.secret_hash,
         deleted_at = excluded.deleted_at`
    ).bind(deletedAt, deviceID, apnsToken),
    env.DB.prepare(
      `DELETE FROM devices
       WHERE device_id = ? AND apns_token = ?
         AND EXISTS (
           SELECT 1 FROM device_deletion_tombstones
           WHERE device_id = devices.device_id AND secret_hash = devices.secret_hash
         )`
    ).bind(deviceID, apnsToken),
  ]);
  return (results[1]?.meta.changes ?? 0) === 1;
}

async function registerDevice(env: Env, registration: DeviceRegistration): Promise<Response> {
  const existing = await env.DB.prepare(
    "SELECT device_id, secret_hash, apns_token FROM devices WHERE device_id = ?"
  ).bind(registration.device_id).first<DeviceRow>();

  if (existing && !(await secretsMatch(registration.device_secret, existing.secret_hash))) {
    return json({ error: "unauthorized" }, 401);
  }
  if (await apnsTokenBelongsToAnotherDevice(env, registration.apns_token, registration.device_id)) {
    return json({ error: "apns_token_conflict" }, 409);
  }

  const now = Math.floor(Date.now() / 1_000);
  const secretHash = existing?.secret_hash ?? await hashSecret(registration.device_secret);
  const results = await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO devices (device_id, secret_hash, apns_token, created_at, last_seen_at)
       SELECT ?, ?, ?, ?, ?
       WHERE NOT EXISTS (
         SELECT 1 FROM devices AS token_owner
         WHERE token_owner.apns_token = ? AND token_owner.device_id <> ?
       )
       ON CONFLICT(device_id) DO UPDATE SET
         apns_token = excluded.apns_token,
         last_seen_at = excluded.last_seen_at
       WHERE devices.secret_hash = excluded.secret_hash
         AND NOT EXISTS (
           SELECT 1 FROM devices AS token_owner
           WHERE token_owner.apns_token = ? AND token_owner.device_id <> ?
         )`
    ).bind(
      registration.device_id, secretHash, registration.apns_token, now, now,
      registration.apns_token, registration.device_id,
      registration.apns_token, registration.device_id,
    ),
    env.DB.prepare(
      `DELETE FROM device_deletion_tombstones
       WHERE device_id = ?
         AND EXISTS (
           SELECT 1 FROM devices
           WHERE device_id = ? AND secret_hash = ?
         )`
    ).bind(registration.device_id, registration.device_id, secretHash),
  ]);
  const result = results[0];
  if ((result.meta.changes ?? 0) !== 1) {
    if (await apnsTokenBelongsToAnotherDevice(
      env, registration.apns_token, registration.device_id
    )) {
      return json({ error: "apns_token_conflict" }, 409);
    }
    return json({ error: "device_conflict" }, 409);
  }

  console.log(JSON.stringify({ event: existing ? "device_updated" : "device_registered" }));
  return json({ ok: true }, existing ? 200 : 201);
}

async function apnsTokenBelongsToAnotherDevice(
  env: Env,
  apnsToken: string,
  deviceID: string,
): Promise<boolean> {
  const owner = await env.DB.prepare(
    "SELECT device_id FROM devices WHERE apns_token = ? AND device_id <> ?"
  ).bind(apnsToken, deviceID).first<{ device_id: string }>();
  return owner !== null;
}

async function authorizeDevice(request: Request, env: Env, deviceID: string): Promise<DeviceRow | null> {
  const secret = bearerToken(request);
  if (!secret) return null;
  const row = await env.DB.prepare(
    "SELECT device_id, secret_hash, apns_token FROM devices WHERE device_id = ?"
  ).bind(deviceID).first<DeviceRow>();
  return row && await secretsMatch(secret, row.secret_hash) ? row : null;
}

async function parseAccountUpload(request: Request): Promise<AccountUpload | null> {
  const value = await boundedRequestJSON(request, MAX_ACCOUNT_BODY_BYTES);
  if (!isRecord(value) || !isProviderID(value.provider_id)) return null;
  const workspaceID = requiredBoundedString(value.workspace_id, 512, true);
  const plan = optionalBoundedString(value.plan, 200);
  const interval = value.refresh_interval_seconds;
  const consentRevision = parseUploadConsentRevision(value.consent_revision);
  const rawCredentials = value.credentials;
  const missingQuotas = parseMissingQuotas(value.missing_quotas);
  if (workspaceID === null || plan === undefined
      || typeof interval !== "number" || !Number.isInteger(interval)
      || interval < MIN_MONITOR_INTERVAL_SECONDS || interval > MAX_MONITOR_INTERVAL_SECONDS
      || consentRevision === null || !isRecord(rawCredentials) || missingQuotas === null) return null;
  const accessToken = requiredBoundedString(rawCredentials.access_token, 32_768, true);
  const refreshToken = requiredBoundedString(rawCredentials.refresh_token, 32_768, true);
  const idToken = requiredBoundedString(rawCredentials.id_token, 32_768, true);
  const expiresAt = nullableTimestamp(rawCredentials.expires_at);
  if (accessToken === null || refreshToken === null || idToken === null || expiresAt === undefined
      || !credentialsSufficient(value.provider_id, accessToken, refreshToken)) return null;
  return {
    provider_id: value.provider_id,
    workspace_id: workspaceID,
    plan,
    refresh_interval_seconds: interval,
    consent_revision: consentRevision,
    missing_quotas: missingQuotas,
    credentials: {
      access_token: accessToken,
      refresh_token: refreshToken,
      id_token: idToken,
      expires_at: expiresAt,
    },
  };
}

async function upsertMonitoredAccount(
  env: Env,
  deviceID: string,
  accountID: string,
  upload: AccountUpload,
): Promise<Response> {
  const now = Math.floor(Date.now() / 1_000);
  const encrypted = await encryptCredentials(env, deviceID, accountID, upload.provider_id, upload.credentials);
  const fingerprint = await credentialFingerprint(env, upload, upload.credentials);
  const existing = await env.DB.prepare(
    "SELECT account_id FROM monitored_accounts WHERE device_id = ? AND account_id = ?"
  ).bind(deviceID, accountID).first<{ account_id: string }>();
  const results = await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO account_monitoring_consent (
         device_id, account_id, consent_revision, enabled, updated_at
       ) VALUES (?, ?, ?, 1, ?)
       ON CONFLICT(device_id, account_id) DO UPDATE SET
         consent_revision = excluded.consent_revision,
         enabled = 1,
         updated_at = excluded.updated_at
       WHERE excluded.consent_revision > account_monitoring_consent.consent_revision
          OR (
            excluded.consent_revision = account_monitoring_consent.consent_revision
            AND account_monitoring_consent.enabled = 1
          )`
    ).bind(deviceID, accountID, upload.consent_revision, now),
    env.DB.prepare(
      `INSERT INTO monitored_accounts (
         device_id, account_id, provider_id, workspace_id, plan, missing_quotas,
         encrypted_credentials, credential_fingerprint,
         refresh_interval_seconds, next_refresh_at, created_at, updated_at
       )
       SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
       WHERE EXISTS (
         SELECT 1 FROM account_monitoring_consent
         WHERE device_id = ? AND account_id = ? AND consent_revision = ? AND enabled = 1
       )
       ON CONFLICT(device_id, account_id) DO UPDATE SET
         provider_id = excluded.provider_id,
         workspace_id = excluded.workspace_id,
         plan = excluded.plan,
         missing_quotas = excluded.missing_quotas,
         encrypted_credentials = excluded.encrypted_credentials,
         credential_fingerprint = excluded.credential_fingerprint,
         refresh_interval_seconds = excluded.refresh_interval_seconds,
         next_refresh_at = MIN(monitored_accounts.next_refresh_at, excluded.next_refresh_at),
         updated_at = excluded.updated_at`
    ).bind(
      deviceID, accountID, upload.provider_id, upload.workspace_id, upload.plan,
      JSON.stringify(upload.missing_quotas),
      encrypted, fingerprint, upload.refresh_interval_seconds, now, now, now,
      deviceID, accountID, upload.consent_revision,
    ),
  ]);
  const consentChanges = results[0]?.meta.changes ?? 0;
  const accountChanges = results[1]?.meta.changes ?? 0;
  if (consentChanges === 0 && accountChanges === 0) {
    return json({ error: "consent_revision_conflict" }, 409, { "cache-control": "no-store" });
  }
  if (consentChanges !== 1 || accountChanges !== 1) {
    throw new Error("Could not atomically save monitored account consent");
  }
  const row = await loadAccountSyncRow(env, deviceID, accountID);
  if (!row) throw new Error("Could not save monitored account");
  console.log(JSON.stringify({ event: existing ? "account_monitor_updated" : "account_monitor_created" }));
  return accountSyncResponse(row, [], existing ? 200 : 201, null);
}

async function disableMonitoredAccount(
  env: Env,
  deviceID: string,
  accountID: string,
  consentRevision: number,
): Promise<Response> {
  const now = Math.floor(Date.now() / 1_000);
  const results = await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO account_monitoring_consent (
         device_id, account_id, consent_revision, enabled, updated_at
       ) VALUES (?, ?, ?, 0, ?)
       ON CONFLICT(device_id, account_id) DO UPDATE SET
         consent_revision = excluded.consent_revision,
         enabled = 0,
         updated_at = excluded.updated_at
       WHERE excluded.consent_revision >= account_monitoring_consent.consent_revision`
    ).bind(deviceID, accountID, consentRevision, now),
    env.DB.prepare(
      `DELETE FROM usage_history
       WHERE device_id = ? AND account_id = ?
         AND EXISTS (
           SELECT 1 FROM account_monitoring_consent
           WHERE device_id = ? AND account_id = ? AND consent_revision = ? AND enabled = 0
         )`
    ).bind(deviceID, accountID, deviceID, accountID, consentRevision),
    env.DB.prepare(
      `DELETE FROM monitored_accounts
       WHERE device_id = ? AND account_id = ?
         AND EXISTS (
           SELECT 1 FROM account_monitoring_consent
           WHERE device_id = ? AND account_id = ? AND consent_revision = ? AND enabled = 0
         )`
    ).bind(deviceID, accountID, deviceID, accountID, consentRevision),
  ]);
  if ((results[0]?.meta.changes ?? 0) !== 1) {
    return json({ error: "consent_revision_conflict" }, 409, { "cache-control": "no-store" });
  }
  console.log(JSON.stringify({ event: "account_monitor_disabled" }));
  return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
}

async function syncMonitoredAccount(
  env: Env,
  deviceID: string,
  accountID: string,
  url: URL,
): Promise<Response> {
  const row = await loadAccountSyncRow(env, deviceID, accountID);
  if (!row) return json({ error: "account_not_found" }, 404);
  const sinceValue = url.searchParams.get("since");
  const parsedSince = parseUnixSeconds(sinceValue);
  if (sinceValue !== null && parsedSince === null) return json({ error: "invalid_since" }, 400);
  const since = parsedSince
    ?? Math.floor(Date.now() / 1_000) - HISTORY_RETENTION_DAYS * 86_400;
  const cursor = decodeHistoryCursor(url.searchParams.get("cursor"));
  if (url.searchParams.has("cursor") && cursor === null) return json({ error: "invalid_cursor" }, 400);
  const effectiveSince = Math.max(since, Math.floor(Date.now() / 1_000) - HISTORY_RETENTION_DAYS * 86_400);
  const query = cursor
    ? `SELECT provider_id, metric_id, metric_title, kind, window_minutes, remaining_percent,
              recorded_at, resets_at, seconds_until_reset, plan
       FROM usage_history
       WHERE device_id = ? AND account_id = ? AND recorded_at >= ?
         AND (recorded_at > ? OR (recorded_at = ? AND metric_id > ?))
       ORDER BY recorded_at, metric_id LIMIT ?`
    : `SELECT provider_id, metric_id, metric_title, kind, window_minutes, remaining_percent,
              recorded_at, resets_at, seconds_until_reset, plan
       FROM usage_history
       WHERE device_id = ? AND account_id = ? AND recorded_at >= ?
       ORDER BY recorded_at, metric_id LIMIT ?`;
  const statement = cursor
    ? env.DB.prepare(query).bind(deviceID, accountID, effectiveSince,
        cursor.recordedAt, cursor.recordedAt, cursor.metricID, HISTORY_PAGE_SIZE + 1)
    : env.DB.prepare(query).bind(deviceID, accountID, effectiveSince, HISTORY_PAGE_SIZE + 1);
  const result = await statement.all<HistoryRow>();
  const rows = result.results;
  const hasMore = rows.length > HISTORY_PAGE_SIZE;
  const history = rows.slice(0, HISTORY_PAGE_SIZE);
  const last = history.at(-1);
  const nextCursor = hasMore && last
    ? encodeHistoryCursor(last.recorded_at, last.metric_id) : null;
  return accountSyncResponse(row, history, 200, nextCursor);
}

async function accountSyncResponse(
  row: AccountSyncRow,
  history: HistoryRow[],
  status: number,
  nextCursor: string | null,
): Promise<Response> {
  let snapshot: ProviderSnapshot | null = null;
  if (row.latest_snapshot) {
    try { snapshot = JSON.parse(row.latest_snapshot) as ProviderSnapshot; }
    catch { snapshot = null; }
  }
  return json({
    snapshot,
    history,
    consent_revision: row.consent_revision,
    next_cursor: nextCursor,
    last_success_at: row.last_success_at,
    last_error: row.last_error,
  }, status, { "cache-control": "no-store" });
}

async function loadAccountSyncRow(
  env: Env,
  deviceID: string,
  accountID: string,
): Promise<AccountSyncRow | null> {
  return env.DB.prepare(
    `SELECT monitored_accounts.last_success_at, monitored_accounts.last_error,
            monitored_accounts.latest_snapshot, account_monitoring_consent.consent_revision
     FROM monitored_accounts
     INNER JOIN account_monitoring_consent
       ON account_monitoring_consent.device_id = monitored_accounts.device_id
      AND account_monitoring_consent.account_id = monitored_accounts.account_id
      AND account_monitoring_consent.enabled = 1
     WHERE monitored_accounts.device_id = ? AND monitored_accounts.account_id = ?`
  ).bind(deviceID, accountID).first<AccountSyncRow>();
}

async function runScheduledRefresh(env: Env, scheduledTime: number): Promise<void> {
  const now = Math.floor(scheduledTime / 1_000);
  await enqueueRecoverableMonitorRuns(env, now);
  await Promise.all([
    enqueueDueAccounts(env, now),
    new Date(scheduledTime).getUTCMinutes() === 0 ? enqueueActiveDevices(env) : Promise.resolve(),
    pruneHistory(env, now),
    pruneLinkSessions(env, now),
    pruneDeviceDeletionTombstones(env, now),
    pruneMonitorRuns(env, now),
  ]);
}

async function enqueueDueAccounts(env: Env, now: number): Promise<void> {
  let cursorDevice = "";
  let cursorAccount = "";
  const groups = new Map<string, Array<{
    deviceID: string;
    accountID: string;
    consentRevision: number;
  }>>();
  while (true) {
    const result = await env.DB.prepare(
      `SELECT monitored_accounts.device_id, monitored_accounts.account_id,
              monitored_accounts.provider_id, monitored_accounts.workspace_id,
              monitored_accounts.plan, monitored_accounts.missing_quotas,
              CASE WHEN monitored_accounts.credential_fingerprint IS NULL
                THEN monitored_accounts.encrypted_credentials ELSE ''
              END AS encrypted_credentials,
              monitored_accounts.credential_fingerprint,
              monitored_accounts.scheduled_monitor_at,
              monitored_accounts.refresh_interval_seconds, monitored_accounts.next_refresh_at,
              monitored_accounts.last_success_at, monitored_accounts.last_error,
              monitored_accounts.latest_snapshot, account_monitoring_consent.consent_revision
       FROM monitored_accounts
       INNER JOIN account_monitoring_consent
         ON account_monitoring_consent.device_id = monitored_accounts.device_id
        AND account_monitoring_consent.account_id = monitored_accounts.account_id
        AND account_monitoring_consent.enabled = 1
       WHERE monitored_accounts.next_refresh_at <= ?
         AND NOT EXISTS (
           SELECT 1 FROM monitor_run_targets
           WHERE monitor_run_targets.device_id = monitored_accounts.device_id
             AND monitor_run_targets.account_id = monitored_accounts.account_id
             AND monitor_run_targets.applied_at IS NULL
         )
         AND (
           monitored_accounts.device_id > ?
           OR (
             monitored_accounts.device_id = ? AND monitored_accounts.account_id > ?
           )
         )
       ORDER BY monitored_accounts.device_id, monitored_accounts.account_id LIMIT ?`
    ).bind(now, cursorDevice, cursorDevice, cursorAccount, DATABASE_BATCH_SIZE).all<MonitoredAccountRow>();
    const rows = result.results;
    const fingerprintUpdates: D1PreparedStatement[] = [];
    for (const row of rows) {
      let fingerprint = row.credential_fingerprint;
      if (!fingerprint) {
        const credentials = await decryptCredentials(env, row);
        fingerprint = await credentialFingerprint(env, row, credentials);
        fingerprintUpdates.push(env.DB.prepare(
          `UPDATE monitored_accounts SET credential_fingerprint = ?
           WHERE device_id = ? AND account_id = ? AND encrypted_credentials = ?`
        ).bind(fingerprint, row.device_id, row.account_id, row.encrypted_credentials));
      }
      const targets = groups.get(fingerprint) ?? [];
      targets.push({
        deviceID: row.device_id,
        accountID: row.account_id,
        consentRevision: row.consent_revision,
      });
      groups.set(fingerprint, targets);
    }
    for (let offset = 0; offset < fingerprintUpdates.length; offset += 40) {
      await env.DB.batch(fingerprintUpdates.slice(offset, offset + 40));
    }
    if (rows.length < DATABASE_BATCH_SIZE) break;
    const last = rows.at(-1);
    cursorDevice = last?.device_id ?? cursorDevice;
    cursorAccount = last?.account_id ?? cursorAccount;
  }

  const queueTargets: MonitorRunTarget[] = [];
  let accountCount = 0;
  for (const [fingerprint, targets] of groups) {
    const runID = await monitorRunID(env, now, fingerprint);
    await env.DB.prepare(
      `INSERT OR IGNORE INTO monitor_runs (
         run_id, occurrence_at, credential_fingerprint, status, created_at
       ) VALUES (?, ?, ?, 'pending', ?)`
    ).bind(runID, now, fingerprint, now).run();
    for (let offset = 0; offset < targets.length; offset += 20) {
      const statements = targets.slice(offset, offset + 20).flatMap((target) => [
        env.DB.prepare(
          `INSERT OR IGNORE INTO monitor_run_targets (
             run_id, device_id, account_id, consent_revision, credential_fingerprint
           )
           SELECT ?, ?, ?, ?, ?
           WHERE EXISTS (
             SELECT 1 FROM monitor_runs
             WHERE run_id = ? AND status = 'pending'
           ) AND EXISTS (
             SELECT 1 FROM monitored_accounts
             INNER JOIN account_monitoring_consent
               ON account_monitoring_consent.device_id = monitored_accounts.device_id
              AND account_monitoring_consent.account_id = monitored_accounts.account_id
             WHERE monitored_accounts.device_id = ? AND monitored_accounts.account_id = ?
               AND monitored_accounts.credential_fingerprint = ?
               AND account_monitoring_consent.consent_revision = ?
               AND account_monitoring_consent.enabled = 1
           )`
        ).bind(
          runID, target.deviceID, target.accountID, target.consentRevision, fingerprint,
          runID, target.deviceID, target.accountID, fingerprint, target.consentRevision,
        ),
        env.DB.prepare(
          `UPDATE monitored_accounts SET
             scheduled_monitor_at = ?,
             next_refresh_at = ? + refresh_interval_seconds
           WHERE device_id = ? AND account_id = ? AND credential_fingerprint = ?
             AND COALESCE(scheduled_monitor_at, 0) <= ?
             AND EXISTS (
               SELECT 1 FROM account_monitoring_consent
               WHERE device_id = ? AND account_id = ?
                 AND consent_revision = ? AND enabled = 1
             )
             AND EXISTS (
               SELECT 1
               FROM monitor_run_targets
               INNER JOIN monitor_runs
                 ON monitor_runs.run_id = monitor_run_targets.run_id
               WHERE monitor_run_targets.run_id = ?
                 AND monitor_run_targets.device_id = ?
                 AND monitor_run_targets.account_id = ?
                 AND monitor_run_targets.applied_at IS NULL
                 AND monitor_runs.status = 'pending'
             )`
        ).bind(
          now, now, target.deviceID, target.accountID, fingerprint, now,
          target.deviceID, target.accountID, target.consentRevision,
          runID, target.deviceID, target.accountID,
        ),
      ]);
      await env.DB.batch(statements);
    }
    accountCount += targets.length;
    queueTargets.push({ kind: "monitor_run", run_id: runID });
  }
  for (let offset = 0; offset < queueTargets.length; offset += QUEUE_BATCH_SIZE) {
    await env.PUSH_QUEUE.sendBatch(queueTargets.slice(offset, offset + QUEUE_BATCH_SIZE).map((body) => ({ body })));
  }
  console.log(JSON.stringify({
    event: "scheduled_monitors_enqueued",
    runs: queueTargets.length,
    accounts: accountCount,
  }));
}

async function enqueueRecoverableMonitorRuns(env: Env, now: number): Promise<void> {
  await env.DB.prepare(
    `UPDATE monitor_runs SET status = 'succeeded', completed_at = ?
     WHERE status = 'pending' AND created_at <= ?
       AND NOT EXISTS (
         SELECT 1 FROM monitor_run_targets
         WHERE monitor_run_targets.run_id = monitor_runs.run_id
       )`
  ).bind(now, now - MONITOR_RUN_STALE_SECONDS).run();
  await env.DB.prepare(
    `UPDATE monitor_runs SET status = 'failed',
       encrypted_result_credentials = NULL, result_snapshot = NULL,
       result_error = 'Scheduled refresh did not finish; the next interval will retry.',
       failure_retryable = 0, completed_at = ?
     WHERE status = 'running' AND started_at IS NOT NULL AND started_at <= ?`
  ).bind(now, now - MONITOR_RUN_STALE_SECONDS).run();
  await env.DB.prepare(
    `UPDATE monitor_run_targets SET applied_at = ?
     WHERE applied_at IS NULL AND EXISTS (
       SELECT 1 FROM monitor_runs
       WHERE monitor_runs.run_id = monitor_run_targets.run_id
         AND monitor_runs.status = 'succeeded'
     )`
  ).bind(now).run();

  let cursor = "";
  let enqueued = 0;
  while (true) {
    const result = await env.DB.prepare(
      `SELECT monitor_runs.run_id
       FROM monitor_runs
       WHERE monitor_runs.run_id > ?
         AND monitor_runs.status IN ('pending', 'fetched', 'failed')
         AND EXISTS (
           SELECT 1 FROM monitor_run_targets
           WHERE monitor_run_targets.run_id = monitor_runs.run_id
             AND monitor_run_targets.applied_at IS NULL
         )
       ORDER BY monitor_runs.run_id LIMIT ?`
    ).bind(cursor, DATABASE_BATCH_SIZE).all<{ run_id: string }>();
    const rows = result.results;
    for (let offset = 0; offset < rows.length; offset += QUEUE_BATCH_SIZE) {
      await env.PUSH_QUEUE.sendBatch(rows.slice(offset, offset + QUEUE_BATCH_SIZE).map((row) => ({
        body: { kind: "monitor_run" as const, run_id: row.run_id },
      })));
    }
    enqueued += rows.length;
    if (rows.length < DATABASE_BATCH_SIZE) break;
    cursor = rows.at(-1)?.run_id ?? cursor;
  }
  if (enqueued > 0) {
    console.log(JSON.stringify({ event: "recoverable_monitors_enqueued", runs: enqueued }));
  }
}

async function enqueueActiveDevices(env: Env): Promise<void> {
  const activeSince = Math.floor(Date.now() / 1_000) - ACTIVE_DEVICE_DAYS * 86_400;
  let cursor = "";
  let enqueued = 0;

  while (true) {
    const result = await env.DB.prepare(
      `SELECT device_id, apns_token FROM devices
       WHERE last_seen_at >= ? AND device_id > ?
       ORDER BY device_id LIMIT ?`
    ).bind(activeSince, cursor, DATABASE_BATCH_SIZE).all<Omit<PushTarget, "kind">>();
    const rows = result.results;
    for (let offset = 0; offset < rows.length; offset += QUEUE_BATCH_SIZE) {
      await env.PUSH_QUEUE.sendBatch(
        rows.slice(offset, offset + QUEUE_BATCH_SIZE).map((row) => ({
          body: { kind: "push" as const, ...row },
        }))
      );
    }
    enqueued += rows.length;
    if (rows.length < DATABASE_BATCH_SIZE) break;
    cursor = rows.at(-1)?.device_id ?? cursor;
  }

  console.log(JSON.stringify({ event: "scheduled_push_enqueued", enqueued }));
}

async function processQueue(batch: MessageBatch<QueueTarget>, env: Env): Promise<void> {
  const pushMessages = batch.messages.filter((message) => message.body.kind === "push");
  const monitorMessages = batch.messages.filter((message) => message.body.kind === "monitor_run");
  await Promise.all([
    pushMessages.length ? deliverQueuedPushes(pushMessages, env) : Promise.resolve(),
    ...monitorMessages.map((message) => refreshMonitorRun(message, env)),
  ]);
}

async function deliverQueuedPushes(messages: Message<QueueTarget>[], env: Env): Promise<void> {
  validateAPNSConfiguration();
  const authorization = await currentAPNSAuthorization(env);
  let delivered = 0;
  let rejected = 0;
  await Promise.all(messages.map(async (message) => {
    if (message.body.kind !== "push") return;
    try {
      const outcome = await sendSilentPush(env, message.body.apns_token, authorization);
      await handleAPNSResult(env, message.body, outcome);
      if (outcome.ok || isPermanentAPNSRejection(outcome)) {
        message.ack();
      } else {
        message.retry();
      }
      if (outcome.ok) delivered += 1;
      else rejected += 1;
    } catch (error) {
      console.error(JSON.stringify({ event: "queued_push_failed", error: safeError(error) }));
      message.retry();
      rejected += 1;
    }
  }));
  console.log(JSON.stringify({
    event: "queued_push_complete",
    attempted: messages.length,
    delivered,
    rejected,
  }));
}

async function refreshMonitorRun(
  message: Message<QueueTarget>,
  env: Env,
  fetchUsage: typeof fetchProviderUsage = fetchProviderUsage,
): Promise<void> {
  if (message.body.kind !== "monitor_run") return;
  const runID = message.body.run_id;
  let run = await loadMonitorRun(env, runID);
  if (!run || run.status === "succeeded") {
    message.ack();
    return;
  }

  if (run.status === "failed") {
    try {
      await applyMonitorRunFailure(
        env,
        runID,
        run.result_error ?? "Server monitoring failed.",
        run.failure_retryable === 1,
        Math.floor(Date.now() / 1_000),
      );
      message.ack();
    } catch {
      message.retry({ delaySeconds: 60 });
    }
    return;
  }

  if (run.status === "fetched") {
    try {
      await fanOutMonitorRun(env, run);
      message.ack();
    } catch (error) {
      console.warn(JSON.stringify({ event: "monitor_fanout_failed", error: safeError(error) }));
      message.retry({ delaySeconds: 60 });
    }
    return;
  }

  const startedAt = Math.floor(Date.now() / 1_000);
  const claim = await env.DB.prepare(
    `UPDATE monitor_runs SET status = 'running', started_at = ?
     WHERE run_id = ? AND status = 'pending'`
  ).bind(startedAt, runID).run();
  if ((claim.meta.changes ?? 0) !== 1) {
    run = await loadMonitorRun(env, runID);
    if (run?.status === "fetched") {
      try {
        await fanOutMonitorRun(env, run);
      } catch (error) {
        console.warn(JSON.stringify({ event: "monitor_fanout_failed", error: safeError(error) }));
        message.retry({ delaySeconds: 60 });
        return;
      }
    } else if (run?.status === "failed") {
      try {
        await applyMonitorRunFailure(
          env,
          runID,
          run.result_error ?? "Server monitoring failed.",
          run.failure_retryable === 1,
          startedAt,
        );
      } catch {
        message.retry({ delaySeconds: 60 });
        return;
      }
    }
    message.ack();
    return;
  }

  const source = await loadPendingMonitorRunTargets(env, runID, 1).then((rows) => rows[0] ?? null);
  if (!source) {
    await finishMonitorRun(env, runID, "succeeded", startedAt);
    message.ack();
    return;
  }

  let result: { credentials: ProviderCredentials; snapshot: ProviderSnapshot };
  try {
    const credentials = await decryptCredentials(env, source);
    const actualFingerprint = await credentialFingerprint(env, source, credentials);
    if (actualFingerprint !== run.credential_fingerprint
        || source.target_credential_fingerprint !== run.credential_fingerprint) {
      throw new Error("Scheduled credentials changed before refresh");
    }
    result = await fetchUsage(source, credentials, startedAt);
    const encryptedResult = await encryptRunCredentials(
      env, runID, source.provider_id, result.credentials
    );
    const persisted = await env.DB.prepare(
      `UPDATE monitor_runs SET status = 'fetched', encrypted_result_credentials = ?,
         result_snapshot = ?, fetched_at = ?
       WHERE run_id = ? AND status = 'running'`
    ).bind(encryptedResult, JSON.stringify(result.snapshot), startedAt, runID).run();
    if ((persisted.meta.changes ?? 0) !== 1) {
      message.ack();
      return;
    }
  } catch (error) {
    const providerError = error instanceof ProviderFetchError ? error : null;
    const errorText = monitorError(error);
    await env.DB.prepare(
      `UPDATE monitor_runs SET status = 'failed', result_error = ?, completed_at = ?,
         failure_retryable = ?
       WHERE run_id = ? AND status = 'running'`
    ).bind(errorText, startedAt, providerError?.retryable === true ? 1 : 0, runID).run();
    try {
      await applyMonitorRunFailure(env, runID, errorText, providerError?.retryable === true, startedAt);
    } catch {
      message.retry({ delaySeconds: 60 });
      return;
    }
    console.warn(JSON.stringify({
      event: "account_monitor_failed",
      provider: source.provider_id,
      retryable: providerError?.retryable === true,
      status: providerError?.status ?? 0,
    }));
    message.ack();
    return;
  }

  run = await loadMonitorRun(env, runID);
  if (!run || run.status !== "fetched") {
    message.ack();
    return;
  }
  try {
    await fanOutMonitorRun(env, run);
    message.ack();
  } catch (error) {
    console.warn(JSON.stringify({ event: "monitor_fanout_failed", error: safeError(error) }));
    message.retry({ delaySeconds: 60 });
  }
}

async function loadMonitorRun(env: Env, runID: string): Promise<MonitorRunRow | null> {
  return env.DB.prepare(
    `SELECT run_id, occurrence_at, credential_fingerprint, status,
            encrypted_result_credentials, result_snapshot, result_error, failure_retryable
     FROM monitor_runs WHERE run_id = ?`
  ).bind(runID).first<MonitorRunRow>();
}

async function loadPendingMonitorRunTargets(
  env: Env,
  runID: string,
  limit = 100,
): Promise<MonitorRunTargetRow[]> {
  const result = await env.DB.prepare(
    `SELECT monitored_accounts.device_id, monitored_accounts.account_id,
            monitored_accounts.provider_id, monitored_accounts.workspace_id,
            monitored_accounts.plan, monitored_accounts.missing_quotas,
            monitored_accounts.encrypted_credentials,
            monitored_accounts.credential_fingerprint,
            monitored_accounts.scheduled_monitor_at,
            monitored_accounts.refresh_interval_seconds, monitored_accounts.next_refresh_at,
            monitored_accounts.last_success_at, monitored_accounts.last_error,
            monitored_accounts.latest_snapshot, account_monitoring_consent.consent_revision,
            monitor_run_targets.consent_revision AS target_consent_revision,
            monitor_run_targets.credential_fingerprint AS target_credential_fingerprint,
            monitor_run_targets.applied_at
     FROM monitor_run_targets
     INNER JOIN monitor_runs
       ON monitor_runs.run_id = monitor_run_targets.run_id
     INNER JOIN monitored_accounts
       ON monitored_accounts.device_id = monitor_run_targets.device_id
      AND monitored_accounts.account_id = monitor_run_targets.account_id
      AND monitored_accounts.credential_fingerprint = monitor_run_targets.credential_fingerprint
      AND monitored_accounts.scheduled_monitor_at = monitor_runs.occurrence_at
     INNER JOIN account_monitoring_consent
       ON account_monitoring_consent.device_id = monitored_accounts.device_id
      AND account_monitoring_consent.account_id = monitored_accounts.account_id
      AND account_monitoring_consent.consent_revision = monitor_run_targets.consent_revision
      AND account_monitoring_consent.enabled = 1
     WHERE monitor_run_targets.run_id = ? AND monitor_run_targets.applied_at IS NULL
     ORDER BY monitored_accounts.device_id, monitored_accounts.account_id LIMIT ?`
  ).bind(runID, limit).all<MonitorRunTargetRow>();
  return result.results;
}

async function fanOutMonitorRun(env: Env, run: MonitorRunRow): Promise<void> {
  if (!run.encrypted_result_credentials || !run.result_snapshot) {
    throw new Error("Stored monitor result is incomplete");
  }
  const snapshot = JSON.parse(run.result_snapshot) as ProviderSnapshot;
  const credentials = await decryptRunCredentials(env, run.run_id, snapshot.provider_id,
    run.encrypted_result_credentials);
  let applied = 0;
  while (true) {
    const targets = await loadPendingMonitorRunTargets(env, run.run_id);
    if (targets.length === 0) break;
    for (const target of targets) {
      await applyMonitorResultToTarget(env, run, target, credentials, snapshot);
      applied += 1;
    }
  }
  const completedAt = Math.floor(Date.now() / 1_000);
  await env.DB.batch([
    env.DB.prepare(
      `UPDATE monitor_run_targets SET applied_at = ?
       WHERE run_id = ? AND applied_at IS NULL`
    ).bind(completedAt, run.run_id),
    env.DB.prepare(
      `UPDATE monitor_runs SET status = 'succeeded', encrypted_result_credentials = NULL,
         result_snapshot = NULL, result_error = NULL, failure_retryable = NULL,
         completed_at = ?
       WHERE run_id = ? AND status = 'fetched'`
    ).bind(completedAt, run.run_id),
  ]);
  console.log(JSON.stringify({ event: "account_monitor_refreshed", accounts: applied }));
}

async function applyMonitorResultToTarget(
  env: Env,
  run: MonitorRunRow,
  row: MonitorRunTargetRow,
  credentials: ProviderCredentials,
  snapshot: ProviderSnapshot,
): Promise<void> {
  const appliedAt = Math.floor(Date.now() / 1_000);
  const effectivePlan = snapshot.plan ?? row.plan;
  const effectiveSnapshot = { ...snapshot, plan: effectivePlan };
  const nextFingerprint = await credentialFingerprint(env, {
    provider_id: row.provider_id,
    workspace_id: row.workspace_id,
    plan: effectivePlan,
  }, credentials);
  const encrypted = await encryptCredentials(
    env, row.device_id, row.account_id, row.provider_id, credentials
  );
  const actualMetricIDs = new Set(snapshot.windows.map((window) => window.metric_id));
  const syntheticWindows = storedMissingQuotas(row.missing_quotas)
    .filter((descriptor) => !actualMetricIDs.has(descriptor.metric_id))
    .map((descriptor) => ({
      metric_id: descriptor.metric_id,
      title: descriptor.title,
      kind: descriptor.kind,
      window_minutes: descriptor.window_minutes,
      remaining_percent: 100,
      resets_at: syntheticResetAt(descriptor, snapshot.fetched_at),
    }));
  const historyWindows = [...snapshot.windows, ...syntheticWindows];
  const statements: D1PreparedStatement[] = [
    env.DB.prepare(
      `UPDATE monitored_accounts SET
         plan = ?, encrypted_credentials = ?, credential_fingerprint = ?, latest_snapshot = ?,
         last_refresh_at = ?, last_success_at = ?, last_error = NULL,
         next_refresh_at = ?, updated_at = ?
       WHERE device_id = ? AND account_id = ? AND credential_fingerprint = ?
         AND scheduled_monitor_at = ?
         AND EXISTS (
           SELECT 1 FROM account_monitoring_consent
           WHERE device_id = ? AND account_id = ?
             AND consent_revision = ? AND enabled = 1
         )`
    ).bind(
      effectivePlan, encrypted, nextFingerprint, JSON.stringify(effectiveSnapshot),
      appliedAt, appliedAt, appliedAt + row.refresh_interval_seconds, appliedAt,
      row.device_id, row.account_id, run.credential_fingerprint, run.occurrence_at,
      row.device_id, row.account_id, row.target_consent_revision,
    ),
    ...historyWindows.map((window) => env.DB.prepare(
      `INSERT INTO usage_history (
         device_id, account_id, provider_id, metric_id, metric_title, kind, window_minutes,
         remaining_percent, recorded_at, resets_at, seconds_until_reset, plan
       )
       SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
       WHERE EXISTS (
         SELECT 1 FROM monitored_accounts
         INNER JOIN account_monitoring_consent
           ON account_monitoring_consent.device_id = monitored_accounts.device_id
          AND account_monitoring_consent.account_id = monitored_accounts.account_id
         WHERE monitored_accounts.device_id = ? AND monitored_accounts.account_id = ?
           AND monitored_accounts.credential_fingerprint = ?
           AND monitored_accounts.scheduled_monitor_at = ?
           AND account_monitoring_consent.consent_revision = ?
           AND account_monitoring_consent.enabled = 1
       )
       ON CONFLICT(device_id, account_id, metric_id, recorded_at) DO UPDATE SET
         remaining_percent = excluded.remaining_percent,
         resets_at = excluded.resets_at,
         seconds_until_reset = excluded.seconds_until_reset,
         plan = excluded.plan`
    ).bind(
      row.device_id, row.account_id, snapshot.provider_id, window.metric_id, window.title,
      window.kind, window.window_minutes, window.remaining_percent, snapshot.fetched_at,
      window.resets_at, Math.max(0, window.resets_at - snapshot.fetched_at),
      effectivePlan, row.device_id, row.account_id, nextFingerprint, run.occurrence_at,
      row.target_consent_revision,
    )),
    env.DB.prepare(
      `UPDATE monitor_run_targets SET applied_at = ?
       WHERE run_id = ? AND device_id = ? AND account_id = ? AND applied_at IS NULL
         AND EXISTS (
           SELECT 1 FROM monitored_accounts
           INNER JOIN account_monitoring_consent
             ON account_monitoring_consent.device_id = monitored_accounts.device_id
            AND account_monitoring_consent.account_id = monitored_accounts.account_id
           WHERE monitored_accounts.device_id = ? AND monitored_accounts.account_id = ?
             AND monitored_accounts.credential_fingerprint = ?
             AND monitored_accounts.scheduled_monitor_at = ?
             AND account_monitoring_consent.consent_revision = ?
             AND account_monitoring_consent.enabled = 1
         )`
    ).bind(
      appliedAt, run.run_id, row.device_id, row.account_id,
      row.device_id, row.account_id, nextFingerprint, run.occurrence_at,
      row.target_consent_revision,
    ),
  ];
  await env.DB.batch(statements);
}

async function applyMonitorRunFailure(
  env: Env,
  runID: string,
  error: string,
  retryable: boolean,
  failedAt: number,
): Promise<void> {
  const run = await loadMonitorRun(env, runID);
  if (!run) return;
  while (true) {
    const targets = await loadPendingMonitorRunTargets(env, runID);
    if (targets.length === 0) break;
    for (const row of targets) {
      const delay = retryable ? 5 * 60 : row.refresh_interval_seconds;
      await env.DB.batch([
        env.DB.prepare(
          `UPDATE monitored_accounts SET last_refresh_at = ?, last_error = ?,
             next_refresh_at = ?, updated_at = ?
           WHERE device_id = ? AND account_id = ? AND credential_fingerprint = ?
             AND scheduled_monitor_at = ?
             AND EXISTS (
               SELECT 1 FROM account_monitoring_consent
               WHERE device_id = ? AND account_id = ?
                 AND consent_revision = ? AND enabled = 1
             )`
        ).bind(
          failedAt, error, failedAt + delay, failedAt,
          row.device_id, row.account_id, row.target_credential_fingerprint,
          run.occurrence_at,
          row.device_id, row.account_id, row.target_consent_revision,
        ),
        env.DB.prepare(
          `UPDATE monitor_run_targets SET applied_at = ?
           WHERE run_id = ? AND device_id = ? AND account_id = ?`
        ).bind(failedAt, runID, row.device_id, row.account_id),
      ]);
    }
  }
  await env.DB.prepare(
    `UPDATE monitor_run_targets SET applied_at = ? WHERE run_id = ? AND applied_at IS NULL`
  ).bind(failedAt, runID).run();
}

async function finishMonitorRun(
  env: Env,
  runID: string,
  status: "succeeded" | "failed",
  completedAt: number,
): Promise<void> {
  await env.DB.prepare(
    `UPDATE monitor_runs SET status = ?, encrypted_result_credentials = NULL,
       result_snapshot = NULL, result_error = NULL, failure_retryable = NULL,
       completed_at = ? WHERE run_id = ?`
  ).bind(status, completedAt, runID).run();
}

async function pruneHistory(env: Env, now: number): Promise<void> {
  await env.DB.prepare("DELETE FROM usage_history WHERE recorded_at < ?")
    .bind(now - HISTORY_RETENTION_DAYS * 86_400).run();
}

async function pruneLinkSessions(env: Env, now: number): Promise<void> {
  await env.DB.prepare("DELETE FROM link_sessions WHERE expires_at <= ?").bind(now).run();
}

async function pruneDeviceDeletionTombstones(env: Env, now: number): Promise<void> {
  await env.DB.prepare("DELETE FROM device_deletion_tombstones WHERE deleted_at < ?")
    .bind(now - DEVICE_DELETION_TOMBSTONE_RETENTION_DAYS * 86_400).run();
}

async function pruneMonitorRuns(env: Env, now: number): Promise<void> {
  await env.DB.prepare(
    `DELETE FROM monitor_runs
     WHERE created_at < ? AND status IN ('succeeded', 'failed')
       AND NOT EXISTS (
         SELECT 1 FROM monitor_run_targets
         WHERE monitor_run_targets.run_id = monitor_runs.run_id
           AND monitor_run_targets.applied_at IS NULL
       )`
  )
    .bind(now - MONITOR_RUN_RETENTION_DAYS * 86_400).run();
}

async function handleAPNSResult(
  env: Env,
  row: { device_id: string; apns_token: string },
  result: APNSResult,
): Promise<void> {
  if (result.ok) {
    await env.DB.prepare(
      "UPDATE devices SET last_push_at = ? WHERE device_id = ? AND apns_token = ?"
    ).bind(Math.floor(Date.now() / 1_000), row.device_id, row.apns_token).run();
  } else if (isPermanentAPNSRejection(result)) {
    const deleted = await tombstoneAndDeleteDeviceByAPNSToken(
      env, row.device_id, row.apns_token, Math.floor(Date.now() / 1_000)
    );
    if (deleted) console.log(JSON.stringify({ event: "device_unregistered_after_apns_rejection" }));
  }
}

async function sendSilentPush(env: Env, token: string, authorization: string): Promise<APNSResult> {
  validateAPNSConfiguration();
  const response = await fetch(`${APNS_HOST}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${authorization}`,
      "apns-topic": APNS_TOPIC,
      "apns-push-type": "background",
      "apns-priority": "5",
      "apns-expiration": "0",
      "apns-collapse-id": "when-reset-refresh",
      "content-type": "application/json",
    },
    body: JSON.stringify({ aps: { "content-available": 1 }, when_reset: { action: "refresh" } }),
  });

  if (response.ok) return { ok: true, status: response.status };
  const body = (await response.text()).slice(0, 512);
  let reason: string | undefined;
  try { reason = (JSON.parse(body) as { reason?: string }).reason; } catch { reason = undefined; }
  console.warn(JSON.stringify({ event: "apns_rejected", status: response.status, reason }));
  return { ok: false, status: response.status, reason };
}

function isPermanentAPNSRejection(result: APNSResult): boolean {
  return result.status === 410 || result.reason === "BadDeviceToken" || result.reason === "Unregistered";
}

async function createAPNSAuthorization(): Promise<string> {
  const header = base64URL(JSON.stringify({ alg: "ES256", kid: APNS_KEY_ID }));
  const claims = base64URL(JSON.stringify({ iss: APNS_TEAM_ID, iat: Math.floor(Date.now() / 1_000) }));
  const signingInput = `${header}.${claims}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemBytes(APNSPrivateKey),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput)
  );
  return `${signingInput}.${base64URL(new Uint8Array(signature))}`;
}

async function currentAPNSAuthorization(env: Env): Promise<string> {
  validateAPNSConfiguration();
  const now = Math.floor(Date.now() / 1_000);
  const minimumIssuedAt = now - APNS_TOKEN_REFRESH_SECONDS;
  const cached = await env.DB.prepare(
    "SELECT token, issued_at FROM apns_provider_tokens WHERE key_id = ?"
  ).bind(APNS_KEY_ID).first<APNSTokenRow>();
  if (cached && cached.issued_at > minimumIssuedAt) return cached.token;

  const candidate = await createAPNSAuthorization();
  await env.DB.prepare(
    `INSERT INTO apns_provider_tokens (key_id, token, issued_at) VALUES (?, ?, ?)
     ON CONFLICT(key_id) DO UPDATE SET token = excluded.token, issued_at = excluded.issued_at
     WHERE apns_provider_tokens.issued_at <= ?`
  ).bind(APNS_KEY_ID, candidate, now, minimumIssuedAt).run();
  const current = await env.DB.prepare(
    "SELECT token, issued_at FROM apns_provider_tokens WHERE key_id = ?"
  ).bind(APNS_KEY_ID).first<APNSTokenRow>();
  if (!current) throw new Error("Could not cache APNs provider token");
  return current.token;
}

async function parseRegistration(request: Request): Promise<DeviceRegistration | null> {
  const length = Number(request.headers.get("content-length") ?? "0");
  if (length > MAX_REGISTRATION_BODY_BYTES) return null;
  const text = await request.text();
  if (text.length > MAX_REGISTRATION_BODY_BYTES) return null;
  let value: unknown;
  try { value = JSON.parse(text); } catch { return null; }
  if (!isRecord(value)) return null;

  const deviceID = value.device_id;
  const deviceSecret = value.device_secret;
  const apnsToken = value.apns_token;
  if (typeof deviceID !== "string" || !isUUID(deviceID)) return null;
  if (typeof deviceSecret !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(deviceSecret)) return null;
  if (typeof apnsToken !== "string" || !/^[0-9a-fA-F]{64,200}$/.test(apnsToken)) return null;
  return { device_id: deviceID.toLowerCase(), device_secret: deviceSecret, apns_token: apnsToken.toLowerCase() };
}

async function parseDeviceTokenUpdate(request: Request): Promise<string | null> {
  const value = await boundedRequestJSON(request, MAX_DEVICE_TOKEN_BODY_BYTES);
  if (!isRecord(value) || typeof value.apns_token !== "string"
      || !/^[0-9a-fA-F]{64,200}$/.test(value.apns_token)) return null;
  return value.apns_token.toLowerCase();
}

async function boundedRequestJSON(request: Request, maximumBytes: number): Promise<unknown> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > maximumBytes) return null;
  if (!request.body) return null;
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const result = await reader.read();
    if (result.done) break;
    total += result.value.byteLength;
    if (total > maximumBytes) {
      await reader.cancel();
      return null;
    }
    chunks.push(result.value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try { return JSON.parse(new TextDecoder().decode(bytes)) as unknown; }
  catch { return null; }
}

async function encryptCredentials(
  env: Env,
  deviceID: string,
  accountID: string,
  providerID: ProviderID,
  credentials: ProviderCredentials,
): Promise<string> {
  const key = await credentialEncryptionKey(env);
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt({
    name: "AES-GCM",
    iv: nonce,
    additionalData: credentialAAD(deviceID, accountID, providerID),
  }, key, new TextEncoder().encode(JSON.stringify(credentials)));
  const envelope: EncryptedEnvelope = {
    v: 1,
    nonce: base64URL(nonce),
    ciphertext: base64URL(new Uint8Array(ciphertext)),
  };
  return JSON.stringify(envelope);
}

async function decryptCredentials(env: Env, row: MonitoredAccountRow): Promise<ProviderCredentials> {
  let envelope: EncryptedEnvelope;
  try { envelope = JSON.parse(row.encrypted_credentials) as EncryptedEnvelope; }
  catch { throw new Error("Stored credential envelope is invalid"); }
  if (envelope.v !== 1 || typeof envelope.nonce !== "string" || typeof envelope.ciphertext !== "string") {
    throw new Error("Stored credential envelope is invalid");
  }
  const plaintext = await crypto.subtle.decrypt({
    name: "AES-GCM",
    iv: decodeBase64URL(envelope.nonce),
    additionalData: credentialAAD(row.device_id, row.account_id, row.provider_id),
  }, await credentialEncryptionKey(env), decodeBase64URL(envelope.ciphertext));
  const value = JSON.parse(new TextDecoder().decode(plaintext)) as unknown;
  if (!isRecord(value)) throw new Error("Stored credentials are invalid");
  const accessToken = requiredBoundedString(value.access_token, 32_768, true);
  const refreshToken = requiredBoundedString(value.refresh_token, 32_768, true);
  const idToken = requiredBoundedString(value.id_token, 32_768, true);
  const expiresAt = nullableTimestamp(value.expires_at);
  if (accessToken === null || refreshToken === null || idToken === null || expiresAt === undefined) {
    throw new Error("Stored credentials are invalid");
  }
  return { access_token: accessToken, refresh_token: refreshToken, id_token: idToken, expires_at: expiresAt };
}

async function encryptRunCredentials(
  env: Env,
  runID: string,
  providerID: ProviderID,
  credentials: ProviderCredentials,
): Promise<string> {
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt({
    name: "AES-GCM",
    iv: nonce,
    additionalData: runCredentialAAD(runID, providerID),
  }, await credentialEncryptionKey(env), new TextEncoder().encode(JSON.stringify(credentials)));
  return JSON.stringify({
    v: 1,
    nonce: base64URL(nonce),
    ciphertext: base64URL(new Uint8Array(ciphertext)),
  } satisfies EncryptedEnvelope);
}

async function decryptRunCredentials(
  env: Env,
  runID: string,
  providerID: ProviderID,
  encrypted: string,
): Promise<ProviderCredentials> {
  let envelope: EncryptedEnvelope;
  try { envelope = JSON.parse(encrypted) as EncryptedEnvelope; }
  catch { throw new Error("Stored monitor result envelope is invalid"); }
  if (envelope.v !== 1 || typeof envelope.nonce !== "string" || typeof envelope.ciphertext !== "string") {
    throw new Error("Stored monitor result envelope is invalid");
  }
  const plaintext = await crypto.subtle.decrypt({
    name: "AES-GCM",
    iv: decodeBase64URL(envelope.nonce),
    additionalData: runCredentialAAD(runID, providerID),
  }, await credentialEncryptionKey(env), decodeBase64URL(envelope.ciphertext));
  const value = JSON.parse(new TextDecoder().decode(plaintext)) as unknown;
  if (!isRecord(value)) throw new Error("Stored monitor result credentials are invalid");
  const accessToken = requiredBoundedString(value.access_token, 32_768, true);
  const refreshToken = requiredBoundedString(value.refresh_token, 32_768, true);
  const idToken = requiredBoundedString(value.id_token, 32_768, true);
  const expiresAt = nullableTimestamp(value.expires_at);
  if (accessToken === null || refreshToken === null || idToken === null || expiresAt === undefined) {
    throw new Error("Stored monitor result credentials are invalid");
  }
  return { access_token: accessToken, refresh_token: refreshToken, id_token: idToken, expires_at: expiresAt };
}

async function credentialFingerprint(
  env: Env,
  account: ProviderAccount,
  credentials: ProviderCredentials,
): Promise<string> {
  const key = await credentialFingerprintKey(env);
  const canonical = JSON.stringify({
    version: 1,
    provider_id: account.provider_id,
    workspace_id: account.workspace_id,
    plan: account.plan,
    access_token: credentials.access_token,
    refresh_token: credentials.refresh_token,
    id_token: credentials.id_token,
    expires_at: credentials.expires_at,
  });
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(canonical));
  return base64URL(new Uint8Array(signature));
}

async function credentialFingerprintKey(env: Env): Promise<CryptoKey> {
  const secret = credentialEncryptionSecret(env);
  const material = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`when-reset:credential-fingerprint:v1:${secret}`),
  );
  return crypto.subtle.importKey("raw", material, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
}

async function monitorRunID(env: Env, occurrenceAt: number, fingerprint: string): Promise<string> {
  const key = await credentialFingerprintKey(env);
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`when-reset:monitor-run:v1:${occurrenceAt}:${fingerprint}`),
  );
  return base64URL(new Uint8Array(signature));
}

async function credentialEncryptionKey(env: Env): Promise<CryptoKey> {
  const secret = credentialEncryptionSecret(env);
  const digest = await crypto.subtle.digest(
    "SHA-256", new TextEncoder().encode(secret)
  );
  return crypto.subtle.importKey("raw", digest, "AES-GCM", false, ["encrypt", "decrypt"]);
}

function credentialEncryptionSecret(env: Env): string {
  if (typeof env.CREDENTIAL_ENCRYPTION_KEY !== "string" || env.CREDENTIAL_ENCRYPTION_KEY.length < 32) {
    throw new Error("Credential encryption key is not configured");
  }
  return env.CREDENTIAL_ENCRYPTION_KEY;
}

function credentialAAD(deviceID: string, accountID: string, providerID: ProviderID): Uint8Array<ArrayBuffer> {
  return new Uint8Array(
    new TextEncoder().encode(`when-reset:v1:${deviceID}:${accountID}:${providerID}`)
  );
}

function runCredentialAAD(runID: string, providerID: ProviderID): Uint8Array<ArrayBuffer> {
  return new Uint8Array(
    new TextEncoder().encode(`when-reset:monitor-run:v1:${runID}:${providerID}`)
  );
}

function decodeBase64URL(value: string): Uint8Array<ArrayBuffer> {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64 + "=".repeat((4 - base64.length % 4) % 4);
  const binary = atob(padded);
  const result = new Uint8Array(new ArrayBuffer(binary.length));
  for (let index = 0; index < binary.length; index += 1) result[index] = binary.charCodeAt(index);
  return result;
}

function isProviderID(value: unknown): value is ProviderID {
  return typeof value === "string"
    && ["chatgpt", "claude", "kimi", "github_copilot", "zai", "minimax", "synthetic", "warp"]
      .includes(value);
}

function credentialsSufficient(providerID: ProviderID, accessToken: string, refreshToken: string): boolean {
  if (!accessToken) return false;
  return !["chatgpt", "claude", "kimi"].includes(providerID) || refreshToken.length > 0;
}

function parseMissingQuotas(value: unknown): MissingQuotaDescriptor[] | null {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > 50) return null;
  const seen = new Set<string>();
  const result: MissingQuotaDescriptor[] = [];
  for (const item of value) {
    if (!isRecord(item)) return null;
    const metricID = requiredBoundedString(item.metric_id, 256, false);
    const title = requiredBoundedString(item.title, 200, false);
    const kind = item.kind === null || item.kind === undefined ? null : item.kind;
    const minutes = item.window_minutes === null || item.window_minutes === undefined
      ? null : item.window_minutes;
    const resetsAt = nullableTimestamp(item.resets_at);
    if (metricID === null || title === null || seen.has(metricID)
        || (kind !== null && !["fiveHour", "weekly", "additional"].includes(String(kind)))
        || (minutes !== null && (typeof minutes !== "number" || !Number.isInteger(minutes)
          || minutes <= 0 || minutes > 525_600))
        || resetsAt === undefined) return null;
    seen.add(metricID);
    result.push({
      metric_id: metricID,
      title,
      kind: kind as MissingQuotaDescriptor["kind"],
      window_minutes: minutes,
      resets_at: resetsAt,
    });
  }
  return result;
}

function storedMissingQuotas(value: string): MissingQuotaDescriptor[] {
  try { return parseMissingQuotas(JSON.parse(value) as unknown) ?? []; }
  catch { return []; }
}

function syntheticResetAt(descriptor: MissingQuotaDescriptor, fetchedAt: number): number {
  const original = descriptor.resets_at;
  if (original === null || original >= fetchedAt) return original ?? fetchedAt;
  if (descriptor.window_minutes === null) return fetchedAt;
  const period = descriptor.window_minutes * 60;
  const elapsedPeriods = Math.ceil((fetchedAt - original) / period);
  return Math.max(fetchedAt, original + elapsedPeriods * period);
}

function requiredBoundedString(value: unknown, maximum: number, allowEmpty: boolean): string | null {
  if (typeof value !== "string" || value.length > maximum || (!allowEmpty && !value.trim())) return null;
  return value;
}

function optionalBoundedString(value: unknown, maximum: number): string | null | undefined {
  if (value === null || value === undefined) return null;
  if (typeof value !== "string" || value.length > maximum) return undefined;
  return value.trim() || null;
}

function nullableTimestamp(value: unknown): number | null | undefined {
  if (value === null || value === undefined) return null;
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : undefined;
}

function parseUploadConsentRevision(value: unknown): number | null {
  if (value === undefined) return 1;
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0 ? value : null;
}

function parseDeleteConsentRevision(url: URL): number | null {
  const values = url.searchParams.getAll("consent_revision");
  if (values.length === 0) return 1;
  if (values.length !== 1 || !/^[1-9][0-9]*$/.test(values[0])) return null;
  const revision = Number(values[0]);
  return Number.isSafeInteger(revision) ? revision : null;
}

function parseUnixSeconds(value: string | null): number | null {
  if (value === null) return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? Math.floor(parsed) : null;
}

function encodeHistoryCursor(recordedAt: number, metricID: string): string {
  return base64URL(JSON.stringify({ recorded_at: recordedAt, metric_id: metricID }));
}

function decodeHistoryCursor(value: string | null): { recordedAt: number; metricID: string } | null {
  if (!value) return null;
  try {
    const parsed = JSON.parse(new TextDecoder().decode(decodeBase64URL(value))) as unknown;
    if (!isRecord(parsed) || typeof parsed.recorded_at !== "number"
        || !Number.isFinite(parsed.recorded_at) || typeof parsed.metric_id !== "string") return null;
    return { recordedAt: parsed.recorded_at, metricID: parsed.metric_id };
  } catch { return null; }
}

function monitorError(error: unknown): string {
  if (error instanceof ProviderFetchError) return error.message.slice(0, 240);
  return "Server monitoring failed.";
}

function bearerToken(request: Request): string | null {
  const value = request.headers.get("authorization");
  if (!value?.startsWith("Bearer ")) return null;
  const token = value.slice(7);
  return /^[A-Za-z0-9_-]{43}$/.test(token) ? token : null;
}

async function registrationAccessAllowed(request: Request, env: Env): Promise<boolean> {
  const configured = env.REGISTRATION_ACCESS_KEY;
  if (typeof configured !== "string" || configured.length < 32) {
    throw new Error("Registration access key is not configured");
  }
  const candidate = request.headers.get("x-when-reset-server-key") ?? "";
  return secretsMatch(candidate, await hashSecret(configured));
}

async function secretsMatch(candidate: string, storedHash: string): Promise<boolean> {
  const candidateHash = await hashSecret(candidate);
  if (candidateHash.length !== storedHash.length) return false;
  const encoder = new TextEncoder();
  return crypto.subtle.timingSafeEqual(
    encoder.encode(candidateHash),
    encoder.encode(storedHash)
  );
}

async function hashSecret(secret: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(secret));
  return base64URL(new Uint8Array(digest));
}

function validateAPNSConfiguration(): void {
  if (!APNSPrivateKey.includes("BEGIN PRIVATE KEY") || !APNSPrivateKey.includes("END PRIVATE KEY")) {
    throw new Error("Bundled APNs key is invalid");
  }
}

function pemBytes(pem: string): ArrayBuffer {
  const base64 = pem.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
  const binary = atob(base64);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0)).buffer;
}

function base64URL(value: string | Uint8Array): string {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function randomBase64URL(byteCount: number): string {
  return base64URL(crypto.getRandomValues(new Uint8Array(byteCount)));
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function safeError(error: unknown): string {
  return error instanceof Error ? error.message : "unknown_error";
}

function json(body: unknown, status = 200, headers: HeadersInit = {}): Response {
  return Response.json(body, { status, headers });
}

function linkJSON(body: unknown, status = 200, headers: HeadersInit = {}): Response {
  return Response.json(body, { status, headers: linkSecurityHeaders(headers) });
}

function linkSecurityHeaders(additional: HeadersInit = {}): Headers {
  const headers = new Headers(additional);
  headers.set("cache-control", "no-store");
  headers.set("cross-origin-opener-policy", "same-origin");
  headers.set("cross-origin-resource-policy", "same-origin");
  headers.set("permissions-policy", "camera=(), microphone=(), geolocation=(), payment=()");
  headers.set("referrer-policy", "no-referrer");
  headers.set("x-content-type-options", "nosniff");
  headers.set("x-frame-options", "DENY");
  return headers;
}

export const testing = {
  credentialFingerprint,
  createAPNSAuthorization,
  decryptCredentials,
  encryptCredentials,
  handleAPNSResult,
  hashSecret,
  isUUID,
  parseAccountUpload,
  parseRegistration,
  processQueue,
  pruneDeviceDeletionTombstones,
  pruneLinkSessions,
  pruneMonitorRuns,
  refreshMonitorRun,
  runScheduledRefresh,
  syntheticResetAt,
};
