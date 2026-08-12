import APNSPrivateKey from "../apns/WhenResetSharedAPNs.p8";
import {
  fetchProviderUsage,
  normalizeFireworksAccountResource,
  providerRetryDelaySeconds,
  ProviderFetchError,
  type ProviderAccount,
  type ProviderCredentials,
  type ProviderFetchResult,
  type ProviderID,
  type ProviderSnapshot,
} from "./providers";
import { renderLinkPage, renderLinkQRCode } from "./link-page";

const MAX_REGISTRATION_BODY_BYTES = 2_048;
const MAX_DEVICE_TOKEN_BODY_BYTES = 1_024;
const MAX_ACCOUNT_BODY_BYTES = 64 * 1_024;
const MAX_ACCOUNT_POLICY_BODY_BYTES = 2_048;
const MAX_HISTORY_UPLOAD_BODY_BYTES = 512 * 1_024;
const MAX_HISTORY_UPLOAD_ROWS = 250;
const MAX_REMOTE_ACCOUNT_IMPORT_BODY_BYTES = 16 * 1_024;
const MAX_REMOTE_ACCOUNT_IMPORTS = 50;
const LINK_SESSION_TTL_SECONDS = 5 * 60;
const ACTIVE_DEVICE_DAYS = 45;
const DEFAULT_HISTORY_RETENTION_DAYS = 35;
const MIN_HISTORY_RETENTION_DAYS = 1;
const MAX_HISTORY_RETENTION_DAYS = 3_650;
const DEVICE_DELETION_TOMBSTONE_RETENTION_DAYS = 90;
const MONITOR_RUN_RETENTION_DAYS = 7;
const MONITOR_RUN_STALE_SECONDS = 10 * 60;
const DATABASE_BATCH_SIZE = 500;
const QUEUE_BATCH_SIZE = 100;
const HISTORY_PAGE_SIZE = 1_000;
const MIN_MONITOR_INTERVAL_SECONDS = 5 * 60;
const MAX_MONITOR_INTERVAL_SECONDS = 8 * 60 * 60;
const APNS_TOKEN_REFRESH_SECONDS = 50 * 60;
const APNS_PRODUCTION_HOST = "https://api.push.apple.com";
const APNS_DEVELOPMENT_HOST = "https://api.sandbox.push.apple.com";
const APNS_KEY_ID = "Y35ZLFTW8W";
const APNS_TEAM_ID = "7P8CLHDH5G";
const APNS_TOPIC = "ad.neko.when";

type APNSEnvironment = "development" | "production";

type DeviceRegistration = {
  device_id: string;
  device_secret: string;
  apns_token: string;
  apns_environment: APNSEnvironment;
};

type DeviceRow = {
  device_id: string;
  secret_hash: string;
  apns_token: string;
  apns_environment: APNSEnvironment;
  push_disabled_at: number | null;
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
  apns_environment?: APNSEnvironment;
};

type MonitorRunTarget = {
  kind: "monitor_run";
  run_id: string;
};

type QueueTarget = PushTarget | MonitorRunTarget;

type AccountUpload = {
  provider_id: ProviderID;
  workspace_id: string;
  display_name: string | null;
  profile_name: string | null;
  email: string | null;
  plan: string | null;
  plan_expires_at: number | null;
  trial_expires_at: number | null;
  refresh_interval_seconds: number;
  history_retention_days: number;
  consent_revision: number;
  credentials: ProviderCredentials;
  missing_quotas: MissingQuotaDescriptor[];
};

type AccountPolicyUpdate = {
  refresh_interval_seconds: number;
  history_retention_days: number;
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
  display_name: string | null;
  encrypted_credentials: string;
  refresh_interval_seconds: number;
  history_retention_days: number;
  next_refresh_at: number;
  last_refresh_at: number | null;
  last_success_at: number | null;
  last_error: string | null;
  latest_snapshot: string | null;
  missing_quotas: string;
  consent_revision: number;
  credential_fingerprint: string | null;
  credential_revision: number;
  consecutive_failures: number;
  scheduled_monitor_at: number | null;
};

type AccountSyncRow = {
  provider_id: ProviderID;
  workspace_id: string;
  profile_name: string | null;
  email: string | null;
  plan: string | null;
  plan_expires_at: number | null;
  trial_expires_at: number | null;
  latest_snapshot: string | null;
  last_refresh_at: number | null;
  last_success_at: number | null;
  last_error: string | null;
  consent_revision: number;
  history_retention_days: number;
};

type AccountSyncSourceRow = AccountSyncRow & {
  source_device_id: string;
  source_account_id: string;
};

type RemoteAccountCandidateRow = {
  device_id: string;
  account_id: string;
  provider_id: ProviderID;
  workspace_id: string;
  display_name: string | null;
  profile_name: string | null;
  email: string | null;
  plan: string | null;
  plan_expires_at: number | null;
  trial_expires_at: number | null;
  credential_fingerprint: string;
  latest_snapshot: string | null;
  last_refresh_at: number | null;
  last_success_at: number | null;
  last_error: string | null;
};

type RemoteAccountCandidate = RemoteAccountCandidateRow & {
  remote_account_id: string;
  synced_account_reference: string;
  account_reference: string;
};

type WorkerSessionStatus = "active" | "expired" | "error" | "unchecked";

type RemoteAccountImport = {
  remote_account_id: string;
  local_account_id: string;
};

type CredentialTargetRow = ProviderAccount & {
  device_id: string;
  account_id: string;
  refresh_interval_seconds: number;
  credential_revision: number;
  latest_snapshot: string | null;
  history_retention_days: number;
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
  failure_retry_after_seconds: number | null;
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
  row_tag: string | null;
  history_source: "worker" | "device";
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

type HistoryUpload = {
  history: HistoryUploadRow[];
};

type HistoryUploadRow = {
  row_tag: string;
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

  const remoteAccountsMatch = /^\/v1\/devices\/([0-9a-f-]{36})\/remote-accounts$/.exec(
    url.pathname
  );
  if (remoteAccountsMatch) {
    const deviceID = remoteAccountsMatch[1];
    if (!isUUID(deviceID)) return json({ error: "invalid_device_id" }, 400);
    const device = await authorizeDevice(request, env, deviceID);
    if (!device) return json({ error: "unauthorized" }, 401);
    if (request.method === "GET") return listRemoteAccounts(env, deviceID);
    if (request.method === "POST") return importRemoteAccounts(request, env, deviceID);
    return json({ error: "method_not_allowed" }, 405, { Allow: "GET, POST" });
  }

  const accountMatch = /^\/v1\/devices\/([0-9a-f-]{36})\/accounts\/([0-9a-f-]{36})(?:\/(sync|history|settings))?$/.exec(
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
      return upsertMonitoredAccount(
        env,
        deviceID,
        accountID,
        upload,
        request.headers.get("x-when-reset-credential-update") === "replace-remote",
      );
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
    if (request.method === "POST" && accountMatch[3] === "history") {
      return uploadMonitoredAccountHistory(request, env, deviceID, accountID);
    }
    if (request.method === "PATCH" && accountMatch[3] === "settings") {
      return updateMonitoredAccountPolicy(request, env, deviceID, accountID);
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
    const tokenUpdate = await parseDeviceTokenUpdate(request);
    if (!tokenUpdate) return json({ error: "invalid_device_token" }, 400);
    const now = Math.floor(Date.now() / 1_000);
    const results = await env.DB.batch([
      releaseAPNSToken(env, tokenUpdate.apns_token, deviceID, now),
      env.DB.prepare(
        `UPDATE devices SET apns_token = ?, apns_environment = ?,
           last_seen_at = ?, push_disabled_at = NULL
         WHERE device_id = ?
           AND NOT EXISTS (
             SELECT 1 FROM devices AS token_owner
             WHERE token_owner.apns_token = ? AND token_owner.device_id <> ?
           )`
      ).bind(
        tokenUpdate.apns_token, tokenUpdate.apns_environment, now, deviceID,
        tokenUpdate.apns_token, deviceID,
      ),
    ]);
    const result = results[1];
    if ((result.meta.changes ?? 0) !== 1) {
      return json({ error: "apns_token_conflict" }, 409);
    }
    if ((results[0]?.meta.changes ?? 0) > 0) {
      console.log(JSON.stringify({ event: "apns_token_reassigned" }));
    }
    console.log(JSON.stringify({ event: "device_updated" }));
    return json({ ok: true });
  }

  if (request.method === "POST" && match[2] === "refresh") {
    if (row.push_disabled_at !== null) {
      return json({ error: "push_disabled" }, 409, { "cache-control": "no-store" });
    }
    const authorization = await currentAPNSAuthorization(env);
    const result = await sendSilentPush(
      env, row.apns_token, authorization, row.apns_environment
    );
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
    `SELECT device_id, secret_hash, apns_token, apns_environment, push_disabled_at
     FROM devices WHERE device_id = ?`
  ).bind(registration.device_id).first<DeviceRow>();
  if (existing && !(await secretsMatch(registration.device_secret, existing.secret_hash))) {
    return linkJSON({ error: "device_conflict" }, 409);
  }

  const now = Math.floor(Date.now() / 1_000);
  const tokenHash = await hashSecret(token);
  const deviceSecretHash = existing?.secret_hash ?? await hashSecret(registration.device_secret);
  const validSession = `session_id = ? AND token_hash = ? AND server_origin = ?
    AND expires_at > ? AND consumed_at IS NULL`;
  const sessionBindings = [session.session_id, tokenHash, session.server_origin, now] as const;
  const results = await env.DB.batch([
    env.DB.prepare(
      `UPDATE devices SET
         apns_token = 'retired:' || device_id,
         push_disabled_at = COALESCE(push_disabled_at, ?)
       WHERE apns_token = ? AND device_id <> ?
         AND EXISTS (SELECT 1 FROM link_sessions WHERE ${validSession})`
    ).bind(
      now, registration.apns_token, registration.device_id, ...sessionBindings,
    ),
    env.DB.prepare(
      `INSERT INTO devices (
         device_id, secret_hash, apns_token, apns_environment, created_at, last_seen_at
       ) SELECT ?, ?, ?, ?, ?, ?
       WHERE EXISTS (SELECT 1 FROM link_sessions WHERE ${validSession})
         AND NOT EXISTS (
           SELECT 1 FROM devices AS token_owner
           WHERE token_owner.apns_token = ? AND token_owner.device_id <> ?
         )
       ON CONFLICT(device_id) DO UPDATE SET
         apns_token = excluded.apns_token,
         apns_environment = excluded.apns_environment,
         last_seen_at = excluded.last_seen_at,
         push_disabled_at = NULL
       WHERE devices.secret_hash = excluded.secret_hash
         AND NOT EXISTS (
           SELECT 1 FROM devices AS token_owner
           WHERE token_owner.apns_token = ? AND token_owner.device_id <> ?
         )`
    ).bind(
      registration.device_id, deviceSecretHash, registration.apns_token,
      registration.apns_environment, now, now,
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
  const tokenReassignments = results[0]?.meta.changes ?? 0;
  const deviceChanges = results[1]?.meta.changes ?? 0;
  const sessionChanges = results[3]?.meta.changes ?? 0;
  if (deviceChanges !== 1 || sessionChanges !== 1) {
    if (await apnsTokenBelongsToAnotherDevice(
      env, registration.apns_token, registration.device_id
    )) {
      return linkJSON({ error: "apns_token_conflict" }, 409);
    }
    return linkJSON({ error: "link_session_used" }, 409);
  }
  if (tokenReassignments > 0) {
    console.log(JSON.stringify({ event: "apns_token_reassigned" }));
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
      `SELECT device_id, secret_hash, apns_token, apns_environment, push_disabled_at
       FROM devices WHERE device_id = ?`
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
    `SELECT device_id, secret_hash, apns_token, apns_environment, push_disabled_at
     FROM devices WHERE device_id = ?`
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

async function registerDevice(env: Env, registration: DeviceRegistration): Promise<Response> {
  const existing = await env.DB.prepare(
    `SELECT device_id, secret_hash, apns_token, apns_environment, push_disabled_at
     FROM devices WHERE device_id = ?`
  ).bind(registration.device_id).first<DeviceRow>();

  if (existing && !(await secretsMatch(registration.device_secret, existing.secret_hash))) {
    return json({ error: "unauthorized" }, 401);
  }

  const now = Math.floor(Date.now() / 1_000);
  const secretHash = existing?.secret_hash ?? await hashSecret(registration.device_secret);
  const results = await env.DB.batch([
    releaseAPNSToken(env, registration.apns_token, registration.device_id, now),
    env.DB.prepare(
      `INSERT INTO devices (
         device_id, secret_hash, apns_token, apns_environment, created_at, last_seen_at
       ) SELECT ?, ?, ?, ?, ?, ?
       WHERE NOT EXISTS (
         SELECT 1 FROM devices AS token_owner
         WHERE token_owner.apns_token = ? AND token_owner.device_id <> ?
       )
       ON CONFLICT(device_id) DO UPDATE SET
         apns_token = excluded.apns_token,
         apns_environment = excluded.apns_environment,
         last_seen_at = excluded.last_seen_at,
         push_disabled_at = NULL
       WHERE devices.secret_hash = excluded.secret_hash
         AND NOT EXISTS (
           SELECT 1 FROM devices AS token_owner
           WHERE token_owner.apns_token = ? AND token_owner.device_id <> ?
         )`
    ).bind(
      registration.device_id, secretHash, registration.apns_token,
      registration.apns_environment, now, now,
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
  const result = results[1];
  if ((result.meta.changes ?? 0) !== 1) {
    if (await apnsTokenBelongsToAnotherDevice(
      env, registration.apns_token, registration.device_id
    )) {
      return json({ error: "apns_token_conflict" }, 409);
    }
    return json({ error: "device_conflict" }, 409);
  }

  if ((results[0]?.meta.changes ?? 0) > 0) {
    console.log(JSON.stringify({ event: "apns_token_reassigned" }));
  }
  console.log(JSON.stringify({ event: existing ? "device_updated" : "device_registered" }));
  return json({ ok: true }, existing ? 200 : 201);
}

function releaseAPNSToken(
  env: Env,
  apnsToken: string,
  destinationDeviceID: string,
  disabledAt: number,
): D1PreparedStatement {
  return env.DB.prepare(
    `UPDATE devices SET
       apns_token = 'retired:' || device_id,
       push_disabled_at = COALESCE(push_disabled_at, ?)
     WHERE apns_token = ? AND device_id <> ?`
  ).bind(disabledAt, apnsToken, destinationDeviceID);
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
    `SELECT device_id, secret_hash, apns_token, apns_environment, push_disabled_at
     FROM devices WHERE device_id = ?`
  ).bind(deviceID).first<DeviceRow>();
  return row && await secretsMatch(secret, row.secret_hash) ? row : null;
}

async function listRemoteAccounts(env: Env, subscriberDeviceID: string): Promise<Response> {
  const candidates = await loadRemoteAccountCandidates(env, subscriberDeviceID);
  return json({
    accounts: candidates.map(remoteAccountPayload),
  }, 200, { "cache-control": "no-store" });
}

async function importRemoteAccounts(
  request: Request,
  env: Env,
  subscriberDeviceID: string,
): Promise<Response> {
  const imported = await parseRemoteAccountImport(request);
  if (!imported) return json({ error: "invalid_remote_account" }, 400);
  const subscribedSource = await env.DB.prepare(
    `SELECT monitored_accounts.device_id, monitored_accounts.account_id,
            monitored_accounts.provider_id, monitored_accounts.workspace_id,
            monitored_accounts.display_name, monitored_accounts.profile_name,
            monitored_accounts.email, monitored_accounts.plan,
            monitored_accounts.plan_expires_at, monitored_accounts.trial_expires_at,
            monitored_accounts.credential_fingerprint, monitored_accounts.latest_snapshot,
            monitored_accounts.last_refresh_at, monitored_accounts.last_success_at,
            monitored_accounts.last_error
     FROM remote_account_subscriptions
     INNER JOIN monitored_accounts
       ON monitored_accounts.device_id = remote_account_subscriptions.source_device_id
      AND monitored_accounts.account_id = remote_account_subscriptions.source_account_id
     WHERE remote_account_subscriptions.subscriber_device_id = ?
       AND remote_account_subscriptions.local_account_id = ?
       AND monitored_accounts.credential_fingerprint IS NOT NULL`
  ).bind(subscriberDeviceID, imported.local_account_id).first<RemoteAccountCandidateRow>();
  if (subscribedSource) {
    const existing = {
      ...subscribedSource,
      remote_account_id: await remoteAccountReference(
        env, subscribedSource.device_id, subscribedSource.account_id
      ),
      synced_account_reference: await syncedAccountReference(subscribedSource.account_id),
      account_reference: await accountReferenceForRow(env, subscribedSource),
    };
    if (existing.remote_account_id !== imported.remote_account_id) {
      return json({ error: "remote_account_conflict" }, 409);
    }
    return json({
      account: {
        ...remoteAccountPayload(existing),
        local_account_id: imported.local_account_id,
      },
    }, 200, { "cache-control": "no-store" });
  }
  const candidates = await loadRemoteAccountCandidates(env, subscriberDeviceID);
  const source = candidates.find(
    (candidate) => candidate.remote_account_id === imported.remote_account_id
  );
  if (!source) return json({ error: "remote_account_not_found" }, 404);
  const direct = await env.DB.prepare(
    "SELECT account_id FROM monitored_accounts WHERE device_id = ? AND account_id = ?"
  ).bind(subscriberDeviceID, imported.local_account_id).first<{ account_id: string }>();
  if (direct) return json({ error: "local_account_conflict" }, 409);
  const now = Math.floor(Date.now() / 1_000);
  const result = await env.DB.prepare(
    `INSERT INTO remote_account_subscriptions (
       subscriber_device_id, local_account_id, source_device_id, source_account_id, created_at
     )
     SELECT ?, ?, ?, ?, ?
     WHERE EXISTS (
       SELECT 1 FROM monitored_accounts
       INNER JOIN account_monitoring_consent
         ON account_monitoring_consent.device_id = monitored_accounts.device_id
        AND account_monitoring_consent.account_id = monitored_accounts.account_id
        AND account_monitoring_consent.enabled = 1
       WHERE monitored_accounts.device_id = ? AND monitored_accounts.account_id = ?
     )
     ON CONFLICT DO NOTHING`
  ).bind(
    subscriberDeviceID, imported.local_account_id, source.device_id, source.account_id, now,
    source.device_id, source.account_id,
  ).run();
  if ((result.meta.changes ?? 0) !== 1) {
    const existing = await env.DB.prepare(
      `SELECT source_device_id, source_account_id
       FROM remote_account_subscriptions
       WHERE subscriber_device_id = ? AND local_account_id = ?`
    ).bind(subscriberDeviceID, imported.local_account_id).first<{
      source_device_id: string;
      source_account_id: string;
    }>();
    if (existing?.source_device_id !== source.device_id
        || existing.source_account_id !== source.account_id) {
      return json({ error: "remote_account_conflict" }, 409);
    }
    return json({
      account: {
        ...remoteAccountPayload(source),
        local_account_id: imported.local_account_id,
      },
    }, 200, { "cache-control": "no-store" });
  }
  console.log(JSON.stringify({ event: "remote_account_imported", provider: source.provider_id }));
  return json({
    account: {
      ...remoteAccountPayload(source),
      local_account_id: imported.local_account_id,
    },
  }, 201, { "cache-control": "no-store" });
}

async function loadRemoteAccountCandidates(
  env: Env,
  subscriberDeviceID: string,
): Promise<RemoteAccountCandidate[]> {
  const [result, localResult, subscribedResult] = await Promise.all([env.DB.prepare(
    `SELECT monitored_accounts.device_id, monitored_accounts.account_id,
            monitored_accounts.provider_id, monitored_accounts.workspace_id,
            monitored_accounts.display_name, monitored_accounts.profile_name,
            monitored_accounts.email, monitored_accounts.plan,
            monitored_accounts.plan_expires_at, monitored_accounts.trial_expires_at,
            monitored_accounts.credential_fingerprint, monitored_accounts.latest_snapshot,
            monitored_accounts.last_refresh_at, monitored_accounts.last_success_at,
            monitored_accounts.last_error
     FROM monitored_accounts
     INNER JOIN account_monitoring_consent
       ON account_monitoring_consent.device_id = monitored_accounts.device_id
      AND account_monitoring_consent.account_id = monitored_accounts.account_id
      AND account_monitoring_consent.enabled = 1
     WHERE monitored_accounts.device_id <> ?
       AND monitored_accounts.credential_fingerprint IS NOT NULL
       AND monitored_accounts.latest_snapshot IS NOT NULL
       AND NOT EXISTS (
         SELECT 1 FROM remote_account_subscriptions
         WHERE remote_account_subscriptions.subscriber_device_id = ?
           AND remote_account_subscriptions.source_device_id = monitored_accounts.device_id
           AND remote_account_subscriptions.source_account_id = monitored_accounts.account_id
       )
     ORDER BY (monitored_accounts.last_error IS NOT NULL),
              monitored_accounts.last_success_at DESC,
              monitored_accounts.device_id, monitored_accounts.account_id
     LIMIT ?`
  ).bind(subscriberDeviceID, subscriberDeviceID, MAX_REMOTE_ACCOUNT_IMPORTS * 8)
    .all<RemoteAccountCandidateRow>(), env.DB.prepare(
    `SELECT monitored_accounts.device_id, monitored_accounts.account_id,
            monitored_accounts.provider_id, monitored_accounts.workspace_id,
            monitored_accounts.display_name, monitored_accounts.profile_name,
            monitored_accounts.email, monitored_accounts.plan,
            monitored_accounts.plan_expires_at, monitored_accounts.trial_expires_at,
            monitored_accounts.credential_fingerprint, monitored_accounts.latest_snapshot,
            monitored_accounts.last_refresh_at, monitored_accounts.last_success_at,
            monitored_accounts.last_error
     FROM monitored_accounts
     INNER JOIN account_monitoring_consent
       ON account_monitoring_consent.device_id = monitored_accounts.device_id
      AND account_monitoring_consent.account_id = monitored_accounts.account_id
      AND account_monitoring_consent.enabled = 1
     WHERE monitored_accounts.device_id = ?
       AND monitored_accounts.credential_fingerprint IS NOT NULL`
  ).bind(subscriberDeviceID).all<RemoteAccountCandidateRow>(), env.DB.prepare(
    `SELECT monitored_accounts.device_id, monitored_accounts.account_id,
            monitored_accounts.provider_id, monitored_accounts.workspace_id,
            monitored_accounts.display_name, monitored_accounts.profile_name,
            monitored_accounts.email, monitored_accounts.plan,
            monitored_accounts.plan_expires_at, monitored_accounts.trial_expires_at,
            monitored_accounts.credential_fingerprint, monitored_accounts.latest_snapshot,
            monitored_accounts.last_refresh_at, monitored_accounts.last_success_at,
            monitored_accounts.last_error
     FROM remote_account_subscriptions
     INNER JOIN monitored_accounts
       ON monitored_accounts.device_id = remote_account_subscriptions.source_device_id
      AND monitored_accounts.account_id = remote_account_subscriptions.source_account_id
     INNER JOIN account_monitoring_consent
       ON account_monitoring_consent.device_id = monitored_accounts.device_id
      AND account_monitoring_consent.account_id = monitored_accounts.account_id
      AND account_monitoring_consent.enabled = 1
     WHERE remote_account_subscriptions.subscriber_device_id = ?
       AND monitored_accounts.credential_fingerprint IS NOT NULL`
  ).bind(subscriberDeviceID).all<RemoteAccountCandidateRow>()]);
  const localReferences = new Set<string>();
  for (const row of [...localResult.results, ...subscribedResult.results]) {
    localReferences.add(await accountReferenceForRow(env, row));
  }
  const seen = new Set<string>();
  const candidates: RemoteAccountCandidate[] = [];
  for (const row of result.results) {
    const accountReference = await accountReferenceForRow(env, row);
    if (localReferences.has(accountReference) || seen.has(accountReference)) continue;
    seen.add(accountReference);
    candidates.push({
      ...row,
      remote_account_id: await remoteAccountReference(env, row.device_id, row.account_id),
      synced_account_reference: await syncedAccountReference(row.account_id),
      account_reference: accountReference,
    });
    if (candidates.length >= MAX_REMOTE_ACCOUNT_IMPORTS) break;
  }
  return candidates;
}

async function parseRemoteAccountImport(request: Request): Promise<RemoteAccountImport | null> {
  const value = await boundedRequestJSON(request, MAX_REMOTE_ACCOUNT_IMPORT_BODY_BYTES);
  if (!isRecord(value)) return null;
  const remoteAccountID = requiredBoundedString(value.remote_account_id, 64, false);
  const localAccountID = requiredBoundedString(value.local_account_id, 36, false);
  if (remoteAccountID === null || !/^[A-Za-z0-9_-]{43}$/.test(remoteAccountID)
      || localAccountID === null || !isUUID(localAccountID)) return null;
  return {
    remote_account_id: remoteAccountID,
    local_account_id: localAccountID.toLowerCase(),
  };
}

function remoteAccountPayload(candidate: RemoteAccountCandidate): Record<string, unknown> {
  const session = workerSession(candidate);
  return {
    remote_account_id: candidate.remote_account_id,
    synced_account_reference: candidate.synced_account_reference,
    account_reference: candidate.account_reference,
    provider_id: candidate.provider_id,
    display_name: candidate.display_name ?? providerDisplayName(candidate.provider_id),
    plan: candidate.plan,
    metadata: accountMetadataPayload(candidate),
    last_success_at: candidate.last_success_at,
    session_status: session.status,
    session_checked_at: session.checkedAt,
  };
}

async function syncedAccountReference(accountID: string): Promise<string> {
  return hashSecret(`when-reset:synced-account:v1:${accountID.toLowerCase()}`);
}

async function accountReferenceForRow(
  env: Env,
  row: { provider_id: ProviderID; workspace_id: string; latest_snapshot: string | null },
): Promise<string> {
  if (row.latest_snapshot) {
    try {
      const snapshot = JSON.parse(row.latest_snapshot) as ProviderSnapshot;
      if (typeof snapshot.account_reference === "string"
          && /^[A-Za-z0-9_-]{43}$/.test(snapshot.account_reference)) {
        return snapshot.account_reference;
      }
    } catch { /* Fall back to the uploaded provider account identifier. */ }
  }
  return providerIdentityReference(env, row.provider_id, `workspace:${row.workspace_id}`);
}

async function providerIdentityReference(
  env: Env,
  providerID: ProviderID,
  identity: string,
): Promise<string> {
  const signature = await crypto.subtle.sign(
    "HMAC",
    await credentialFingerprintKey(env),
    new TextEncoder().encode(`when-reset:provider-account:v1:${providerID}:${identity}`),
  );
  return base64URL(new Uint8Array(signature));
}

function workerSession(row: {
  last_refresh_at: number | null;
  last_success_at: number | null;
  last_error: string | null;
}): { status: WorkerSessionStatus; checkedAt: number | null } {
  const checkedAt = row.last_refresh_at ?? row.last_success_at;
  if (row.last_error) {
    const normalized = row.last_error.toLowerCase();
    const expired = /http\s*(401|403)|refresh token is missing|authorization expired|session expired|invalid[_ -]?grant|unauthori[sz]ed|revoked/.test(normalized);
    return { status: expired ? "expired" : "error", checkedAt };
  }
  if (checkedAt !== null) return { status: "active", checkedAt };
  return { status: "unchecked", checkedAt: null };
}

function accountMetadataPayload(row: {
  profile_name: string | null;
  email: string | null;
  plan: string | null;
  plan_expires_at: number | null;
  trial_expires_at: number | null;
}): Record<string, unknown> {
  return {
    name: row.profile_name,
    email: row.email,
    plan: row.plan,
    plan_expires_at: row.plan_expires_at,
    trial_expires_at: row.trial_expires_at,
  };
}

function providerDisplayName(providerID: ProviderID): string {
  switch (providerID) {
    case "chatgpt": return "ChatGPT";
    case "claude": return "Claude";
    case "grok": return "Grok";
    case "kimi": return "Kimi Code";
    case "github_copilot": return "GitHub Copilot";
    case "zai": return "Z.AI Coding Plan";
    case "minimax": return "MiniMax Token Plan";
    case "synthetic": return "Synthetic";
    case "warp": return "Warp";
    case "openai_api": return "OpenAI API";
    case "anthropic_api": return "Anthropic API";
    case "openrouter": return "OpenRouter";
    case "fireworks": return "Fireworks AI";
    case "deepseek": return "DeepSeek API";
    case "poe": return "Poe API";
  }
}

async function remoteAccountReference(
  env: Env,
  sourceDeviceID: string,
  sourceAccountID: string,
): Promise<string> {
  const signature = await crypto.subtle.sign(
    "HMAC",
    await credentialFingerprintKey(env),
    new TextEncoder().encode(
      `when-reset:remote-account:v1:${sourceDeviceID}:${sourceAccountID}`
    ),
  );
  return base64URL(new Uint8Array(signature));
}

async function parseAccountUpload(request: Request): Promise<AccountUpload | null> {
  const value = await boundedRequestJSON(request, MAX_ACCOUNT_BODY_BYTES);
  if (!isRecord(value) || !isProviderID(value.provider_id)) return null;
  const workspaceID = requiredBoundedString(value.workspace_id, 512, true);
  const displayName = optionalBoundedString(value.display_name, 128);
  const plan = optionalBoundedString(value.plan, 200);
  const metadata = parseAccountMetadata(value.metadata);
  const interval = value.refresh_interval_seconds;
  const consentRevision = parseUploadConsentRevision(value.consent_revision);
  const historyRetentionDays = value.history_retention_days ?? DEFAULT_HISTORY_RETENTION_DAYS;
  const rawCredentials = value.credentials;
  const missingQuotas = parseMissingQuotas(value.missing_quotas);
  if (workspaceID === null || displayName === undefined || plan === undefined
      || metadata === null
      || typeof interval !== "number" || !Number.isInteger(interval)
      || interval < MIN_MONITOR_INTERVAL_SECONDS || interval > MAX_MONITOR_INTERVAL_SECONDS
      || typeof historyRetentionDays !== "number" || !Number.isInteger(historyRetentionDays)
      || historyRetentionDays < MIN_HISTORY_RETENTION_DAYS
      || historyRetentionDays > MAX_HISTORY_RETENTION_DAYS
      || consentRevision === null || !isRecord(rawCredentials) || missingQuotas === null) return null;
  const normalizedWorkspaceID = value.provider_id === "fireworks"
    ? normalizeFireworksAccountResource(workspaceID)
    : workspaceID;
  if (normalizedWorkspaceID === null) return null;
  const accessToken = requiredBoundedString(rawCredentials.access_token, 32_768, true);
  const refreshToken = requiredBoundedString(rawCredentials.refresh_token, 32_768, true);
  const idToken = requiredBoundedString(rawCredentials.id_token, 32_768, true);
  const expiresAt = nullableTimestamp(rawCredentials.expires_at);
  const monthlyBudget = nullablePositiveNumber(rawCredentials.monthly_budget);
  const currencyCode = optionalBoundedString(rawCredentials.currency_code, 8);
  if (accessToken === null || refreshToken === null || idToken === null || expiresAt === undefined
      || monthlyBudget === undefined || currencyCode === undefined
      || (currencyCode !== null && !/^[A-Za-z]{3}$/.test(currencyCode))
      || !credentialsSufficient(value.provider_id, accessToken, refreshToken)) return null;
  return {
    provider_id: value.provider_id,
    workspace_id: normalizedWorkspaceID,
    display_name: displayName,
    profile_name: metadata.profile_name,
    email: metadata.email,
    plan,
    plan_expires_at: metadata.plan_expires_at,
    trial_expires_at: metadata.trial_expires_at,
    refresh_interval_seconds: interval,
    consent_revision: consentRevision,
    history_retention_days: historyRetentionDays,
    missing_quotas: missingQuotas,
    credentials: {
      access_token: accessToken,
      refresh_token: refreshToken,
      id_token: idToken,
      expires_at: expiresAt,
      monthly_budget: monthlyBudget,
      currency_code: currencyCode?.toUpperCase() ?? null,
    },
  };
}

async function parseAccountPolicyUpdate(request: Request): Promise<AccountPolicyUpdate | null> {
  const value = await boundedRequestJSON(request, MAX_ACCOUNT_POLICY_BODY_BYTES);
  if (!isRecord(value)) return null;
  const interval = value.refresh_interval_seconds;
  const historyRetentionDays = value.history_retention_days;
  if (typeof interval !== "number" || !Number.isInteger(interval)
      || interval < MIN_MONITOR_INTERVAL_SECONDS || interval > MAX_MONITOR_INTERVAL_SECONDS
      || typeof historyRetentionDays !== "number" || !Number.isInteger(historyRetentionDays)
      || historyRetentionDays < MIN_HISTORY_RETENTION_DAYS
      || historyRetentionDays > MAX_HISTORY_RETENTION_DAYS) return null;
  return {
    refresh_interval_seconds: interval,
    history_retention_days: historyRetentionDays,
  };
}

async function parseHistoryUpload(
  request: Request,
  accountID: string,
  providerID: ProviderID,
): Promise<HistoryUpload | null> {
  const value = await boundedRequestJSON(request, MAX_HISTORY_UPLOAD_BODY_BYTES);
  if (!isRecord(value) || !Array.isArray(value.history)
      || value.history.length === 0 || value.history.length > MAX_HISTORY_UPLOAD_ROWS) return null;
  const history: HistoryUploadRow[] = [];
  for (const raw of value.history) {
    if (!isRecord(raw) || raw.provider_id !== providerID) return null;
    const metricID = requiredBoundedString(raw.metric_id, 512, false);
    const metricTitle = requiredBoundedString(raw.metric_title, 256, false);
    const rowTag = requiredBoundedString(raw.row_tag, 1_024, false);
    const kind = raw.kind === null || raw.kind === undefined ? null : raw.kind;
    const windowMinutes = raw.window_minutes === null || raw.window_minutes === undefined
      ? null : raw.window_minutes;
    const remainingPercent = raw.remaining_percent;
    const recordedAt = numericUnixSeconds(raw.recorded_at);
    const resetsAt = numericUnixSeconds(raw.resets_at);
    const secondsUntilReset = raw.seconds_until_reset;
    const plan = optionalBoundedString(raw.plan, 200);
    if (metricID === null || metricTitle === null || rowTag === null
        || (kind !== null && kind !== "fiveHour" && kind !== "weekly" && kind !== "additional")
        || (windowMinutes !== null && (typeof windowMinutes !== "number"
          || !Number.isInteger(windowMinutes) || windowMinutes <= 0))
        || typeof remainingPercent !== "number" || !Number.isFinite(remainingPercent)
        || remainingPercent < 0 || remainingPercent > 100
        || recordedAt === null || resetsAt === null
        || resetsAt < recordedAt - 5 * 60
        || typeof secondsUntilReset !== "number" || !Number.isFinite(secondsUntilReset)
        || secondsUntilReset < 0 || plan === undefined
        || rowTag !== historyRowTag(accountID, metricID, recordedAt)) return null;
    history.push({
      row_tag: rowTag,
      provider_id: providerID,
      metric_id: metricID,
      metric_title: metricTitle,
      kind,
      window_minutes: windowMinutes,
      remaining_percent: remainingPercent,
      recorded_at: recordedAt,
      resets_at: resetsAt,
      seconds_until_reset: secondsUntilReset,
      plan,
    });
  }
  const uniqueTags = new Set(history.map((point) => point.row_tag));
  if (uniqueTags.size !== history.length) return null;
  return { history };
}

async function upsertMonitoredAccount(
  env: Env,
  deviceID: string,
  accountID: string,
  upload: AccountUpload,
  replaceRemoteCredential: boolean,
  fetchUsage: typeof fetchProviderUsage = fetchProviderUsage,
): Promise<Response> {
  const remoteSubscription = await env.DB.prepare(
    `SELECT monitored_accounts.device_id, monitored_accounts.account_id,
            monitored_accounts.provider_id, monitored_accounts.workspace_id,
            monitored_accounts.plan, monitored_accounts.refresh_interval_seconds,
            monitored_accounts.credential_revision, monitored_accounts.latest_snapshot,
            monitored_accounts.history_retention_days
     FROM remote_account_subscriptions
     INNER JOIN monitored_accounts
       ON monitored_accounts.device_id = remote_account_subscriptions.source_device_id
      AND monitored_accounts.account_id = remote_account_subscriptions.source_account_id
     INNER JOIN account_monitoring_consent
       ON account_monitoring_consent.device_id = monitored_accounts.device_id
      AND account_monitoring_consent.account_id = monitored_accounts.account_id
      AND account_monitoring_consent.enabled = 1
     WHERE remote_account_subscriptions.subscriber_device_id = ?
       AND remote_account_subscriptions.local_account_id = ?`
  ).bind(deviceID, accountID).first<CredentialTargetRow>();
  if (remoteSubscription) {
    if (replaceRemoteCredential) {
      return replaceAccountCredential(
        env,
        deviceID,
        accountID,
        remoteSubscription,
        upload,
        false,
        fetchUsage,
      );
    }
    return json({ error: "remote_account_is_read_only" }, 409, {
      "cache-control": "no-store",
    });
  }
  if (replaceRemoteCredential) {
    const directTarget = await loadCredentialTarget(env, deviceID, accountID);
    if (directTarget) {
      return replaceAccountCredential(
        env,
        deviceID,
        accountID,
        directTarget,
        upload,
        true,
        fetchUsage,
      );
    }
    return json({ error: "remote_account_not_found" }, 404, {
      "cache-control": "no-store",
    });
  }
  const now = Math.floor(Date.now() / 1_000);
  const encrypted = await encryptCredentials(
    env, deviceID, accountID, upload.provider_id, upload.credentials
  );
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
         device_id, account_id, provider_id, workspace_id, display_name, profile_name, email,
         plan, plan_expires_at, trial_expires_at, missing_quotas,
         encrypted_credentials, credential_fingerprint, credential_revision,
         refresh_interval_seconds, history_retention_days,
         next_refresh_at, created_at, updated_at
       )
       SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
       WHERE EXISTS (
         SELECT 1 FROM account_monitoring_consent
         WHERE device_id = ? AND account_id = ? AND consent_revision = ? AND enabled = 1
       )
       ON CONFLICT(device_id, account_id) DO UPDATE SET
         provider_id = excluded.provider_id,
         workspace_id = excluded.workspace_id,
         display_name = excluded.display_name,
         profile_name = excluded.profile_name,
         email = excluded.email,
         plan = excluded.plan,
         plan_expires_at = excluded.plan_expires_at,
         trial_expires_at = excluded.trial_expires_at,
         missing_quotas = excluded.missing_quotas,
         encrypted_credentials = CASE
           WHEN excluded.credential_revision > monitored_accounts.credential_revision
             THEN excluded.encrypted_credentials
           ELSE monitored_accounts.encrypted_credentials
         END,
         credential_fingerprint = CASE
           WHEN excluded.credential_revision > monitored_accounts.credential_revision
             THEN excluded.credential_fingerprint
           ELSE monitored_accounts.credential_fingerprint
         END,
         credential_revision = MAX(
           monitored_accounts.credential_revision,
           excluded.credential_revision
         ),
         refresh_interval_seconds = excluded.refresh_interval_seconds,
         history_retention_days = excluded.history_retention_days,
         next_refresh_at = CASE
           WHEN excluded.credential_revision > monitored_accounts.credential_revision
             THEN MIN(monitored_accounts.next_refresh_at, excluded.next_refresh_at)
           WHEN monitored_accounts.last_error IS NULL
             AND excluded.refresh_interval_seconds < monitored_accounts.refresh_interval_seconds
             THEN MIN(
               monitored_accounts.next_refresh_at,
               excluded.next_refresh_at + excluded.refresh_interval_seconds
             )
           ELSE monitored_accounts.next_refresh_at
         END,
         updated_at = excluded.updated_at`
    ).bind(
      deviceID, accountID, upload.provider_id, upload.workspace_id, upload.display_name,
      upload.profile_name, upload.email, upload.plan, upload.plan_expires_at,
      upload.trial_expires_at,
      JSON.stringify(upload.missing_quotas),
      encrypted, fingerprint, upload.consent_revision,
      upload.refresh_interval_seconds, upload.history_retention_days, now, now, now,
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
  return accountSyncResponse(env, row, [], existing ? 200 : 201, null);
}

async function replaceAccountCredential(
  env: Env,
  subscriberDeviceID: string,
  localAccountID: string,
  source: CredentialTargetRow,
  upload: AccountUpload,
  requiresWorkspaceMatch: boolean,
  fetchUsage: typeof fetchProviderUsage = fetchProviderUsage,
): Promise<Response> {
  if (source.provider_id !== upload.provider_id
      || (requiresWorkspaceMatch && source.workspace_id !== upload.workspace_id)) {
    return json({ error: "provider_account_mismatch" }, 409, {
      "cache-control": "no-store",
    });
  }
  const now = Math.floor(Date.now() / 1_000);
  let result: ProviderFetchResult;
  try {
    result = await fetchUsage(source, upload.credentials, now);
    result.snapshot.account_reference = await providerIdentityReference(
      env,
      source.provider_id,
      result.account_identity ?? `workspace:${source.workspace_id}`,
    );
  } catch (error) {
    console.warn(JSON.stringify({
      event: "remote_account_credential_check_failed",
      provider: source.provider_id,
      error: safeError(error),
    }));
    return providerCredentialErrorResponse(error);
  }
  const previousReference = explicitSnapshotAccountReference(source.latest_snapshot);
  if (previousReference && previousReference !== result.snapshot.account_reference) {
    return json({ error: "provider_account_mismatch" }, 409, {
      "cache-control": "no-store",
    });
  }
  await env.DB.prepare(
    `UPDATE monitored_accounts SET display_name = ?, profile_name = ?, email = ?,
       plan_expires_at = ?, trial_expires_at = ?, missing_quotas = ?,
       refresh_interval_seconds = ?, history_retention_days = ?, updated_at = ?
     WHERE device_id = ? AND account_id = ?`
  ).bind(
    upload.display_name, upload.profile_name, upload.email,
    upload.plan_expires_at, upload.trial_expires_at, JSON.stringify(upload.missing_quotas),
    upload.refresh_interval_seconds, upload.history_retention_days, now,
    source.device_id, source.account_id,
  ).run();
  await applyVerifiedCredentialResult(env, source, result);
  const mergedAccounts = 1 + await propagateVerifiedCredentialToSameAccount(
    env,
    source,
    result,
  );
  const row = await loadAccountSyncSourceRow(env, subscriberDeviceID, localAccountID);
  if (!row) return json({ error: "remote_account_not_found" }, 404);
  console.log(JSON.stringify({
    event: "account_credential_replaced",
    provider: source.provider_id,
    merged_accounts: mergedAccounts,
  }));
  return accountSyncResponse(env, row, [], 200, null);
}

function providerCredentialErrorResponse(error: unknown): Response {
  const providerError = error instanceof ProviderFetchError ? error : null;
  const status = providerError?.status === 401 || providerError?.status === 403 ? 401 : 502;
  return json({ error: status === 401 ? "provider_session_expired" : "provider_check_failed" }, status, {
    "cache-control": "no-store",
  });
}

function explicitSnapshotAccountReference(snapshotJSON: string | null): string | null {
  if (!snapshotJSON) return null;
  try {
    const snapshot = JSON.parse(snapshotJSON) as ProviderSnapshot;
    return typeof snapshot.account_reference === "string"
        && /^[A-Za-z0-9_-]{43}$/.test(snapshot.account_reference)
      ? snapshot.account_reference : null;
  } catch {
    return null;
  }
}

async function loadCredentialTarget(
  env: Env,
  deviceID: string,
  accountID: string,
): Promise<CredentialTargetRow | null> {
  return env.DB.prepare(
    `SELECT monitored_accounts.device_id, monitored_accounts.account_id,
            monitored_accounts.provider_id, monitored_accounts.workspace_id,
            monitored_accounts.plan, monitored_accounts.refresh_interval_seconds,
            monitored_accounts.credential_revision, monitored_accounts.latest_snapshot,
            monitored_accounts.history_retention_days
     FROM monitored_accounts
     INNER JOIN account_monitoring_consent
       ON account_monitoring_consent.device_id = monitored_accounts.device_id
      AND account_monitoring_consent.account_id = monitored_accounts.account_id
      AND account_monitoring_consent.enabled = 1
     WHERE monitored_accounts.device_id = ? AND monitored_accounts.account_id = ?`
  ).bind(deviceID, accountID).first<CredentialTargetRow>();
}

async function loadSameAccountCredentialTargets(
  env: Env,
  providerID: ProviderID,
  workspaceID: string,
  excludedDeviceID: string,
  excludedAccountID: string,
): Promise<CredentialTargetRow[]> {
  const result = await env.DB.prepare(
    `SELECT monitored_accounts.device_id, monitored_accounts.account_id,
            monitored_accounts.provider_id, monitored_accounts.workspace_id,
            monitored_accounts.plan, monitored_accounts.refresh_interval_seconds,
            monitored_accounts.credential_revision, monitored_accounts.latest_snapshot,
            monitored_accounts.history_retention_days
     FROM monitored_accounts
     INNER JOIN account_monitoring_consent
       ON account_monitoring_consent.device_id = monitored_accounts.device_id
      AND account_monitoring_consent.account_id = monitored_accounts.account_id
      AND account_monitoring_consent.enabled = 1
     WHERE monitored_accounts.provider_id = ? AND monitored_accounts.workspace_id = ?
       AND NOT (monitored_accounts.device_id = ? AND monitored_accounts.account_id = ?)
     ORDER BY monitored_accounts.device_id, monitored_accounts.account_id
     LIMIT ?`
  ).bind(
    providerID, workspaceID, excludedDeviceID, excludedAccountID, MAX_REMOTE_ACCOUNT_IMPORTS
  ).all<CredentialTargetRow>();
  return result.results;
}

async function applyVerifiedCredentialResult(
  env: Env,
  target: CredentialTargetRow,
  result: ProviderFetchResult,
): Promise<void> {
  const appliedAt = result.snapshot.fetched_at;
  const effectivePlan = result.snapshot.plan ?? target.plan;
  const snapshot: ProviderSnapshot = { ...result.snapshot, plan: effectivePlan };
  const fingerprint = await credentialFingerprint(env, {
    provider_id: target.provider_id,
    workspace_id: target.workspace_id,
    plan: effectivePlan,
  }, result.credentials);
  const encrypted = await encryptCredentials(
    env, target.device_id, target.account_id, target.provider_id, result.credentials
  );
  const statements: D1PreparedStatement[] = [
    env.DB.prepare(
      `DELETE FROM monitor_run_targets
       WHERE device_id = ? AND account_id = ? AND applied_at IS NULL`
    ).bind(target.device_id, target.account_id),
    env.DB.prepare(
      `UPDATE monitored_accounts SET plan = ?, encrypted_credentials = ?,
         credential_fingerprint = ?, latest_snapshot = ?, scheduled_monitor_at = NULL,
         last_refresh_at = ?, last_success_at = ?, last_error = NULL,
         consecutive_failures = 0, next_refresh_at = ?, updated_at = ?
       WHERE device_id = ? AND account_id = ?`
    ).bind(
      effectivePlan, encrypted, fingerprint, JSON.stringify(snapshot),
      appliedAt, appliedAt, appliedAt + target.refresh_interval_seconds, appliedAt,
      target.device_id, target.account_id,
    ),
    ...snapshot.windows.map((window) => env.DB.prepare(
      `INSERT INTO usage_history (
         device_id, account_id, row_tag, history_source,
         provider_id, metric_id, metric_title, kind, window_minutes,
         remaining_percent, recorded_at, resets_at, seconds_until_reset, plan
       ) VALUES (?, ?, ?, 'worker', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(device_id, account_id, metric_id, recorded_at) DO UPDATE SET
         row_tag = excluded.row_tag,
         history_source = 'worker',
         remaining_percent = excluded.remaining_percent,
         resets_at = excluded.resets_at,
         seconds_until_reset = excluded.seconds_until_reset,
         plan = excluded.plan`
    ).bind(
      target.device_id, target.account_id,
      historyRowTag(target.account_id, window.metric_id, snapshot.fetched_at),
      snapshot.provider_id, window.metric_id,
      window.title, window.kind, window.window_minutes, window.remaining_percent,
      snapshot.fetched_at, window.resets_at,
      Math.max(0, window.resets_at - snapshot.fetched_at), effectivePlan,
    )),
  ];
  await env.DB.batch(statements);
  await enqueueRemoteAccountRefreshHints(env, target.device_id, target.account_id);
}

async function disableMonitoredAccount(
  env: Env,
  deviceID: string,
  accountID: string,
  consentRevision: number,
): Promise<Response> {
  const remoteSubscription = await env.DB.prepare(
    `DELETE FROM remote_account_subscriptions
     WHERE subscriber_device_id = ? AND local_account_id = ?`
  ).bind(deviceID, accountID).run();
  if ((remoteSubscription.meta.changes ?? 0) === 1) {
    console.log(JSON.stringify({ event: "remote_account_removed" }));
    return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
  }
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

async function uploadMonitoredAccountHistory(
  request: Request,
  env: Env,
  deviceID: string,
  accountID: string,
): Promise<Response> {
  const source = await loadCredentialTarget(env, deviceID, accountID);
  if (!source) {
    const subscription = await loadAccountSyncSourceRow(env, deviceID, accountID);
    return json(
      { error: subscription ? "remote_account_is_read_only" : "account_not_found" },
      subscription ? 409 : 404,
      { "cache-control": "no-store" },
    );
  }
  const upload = await parseHistoryUpload(request, accountID, source.provider_id);
  if (!upload) return json({ error: "invalid_history" }, 400, { "cache-control": "no-store" });

  const now = Math.floor(Date.now() / 1_000);
  const sourceCutoff = now - source.history_retention_days * 86_400;
  if (upload.history.some((point) => point.recorded_at < sourceCutoff
      || point.recorded_at > now + 5 * 60)) {
    return json({ error: "history_outside_retention" }, 400, {
      "cache-control": "no-store",
    });
  }

  const sourceReference = explicitSnapshotAccountReference(source.latest_snapshot);
  const duplicates = sourceReference
    ? (await loadSameAccountCredentialTargets(
        env,
        source.provider_id,
        source.workspace_id,
        source.device_id,
        source.account_id,
      )).filter((target) => {
        if (target.account_id !== source.account_id) return false;
        const targetReference = explicitSnapshotAccountReference(target.latest_snapshot);
        return targetReference === null || targetReference === sourceReference;
      })
    : [];
  const targets = [source, ...duplicates];
  let accepted = 0;
  for (const target of targets) {
    const cutoff = now - target.history_retention_days * 86_400;
    const rows = upload.history.filter((point) => point.recorded_at >= cutoff);
    const inserted = await insertHistoryRows(env, target, rows);
    if (target.device_id === source.device_id && target.account_id === source.account_id) {
      accepted = inserted;
    }
  }
  console.log(JSON.stringify({
    event: "device_history_uploaded",
    rows: upload.history.length,
    accounts: targets.length,
  }));
  return json({
    accepted,
    deduplicated: upload.history.length - accepted,
  }, 200, { "cache-control": "no-store" });
}

async function updateMonitoredAccountPolicy(
  request: Request,
  env: Env,
  deviceID: string,
  accountID: string,
): Promise<Response> {
  const policy = await parseAccountPolicyUpdate(request);
  if (!policy) {
    return json({ error: "invalid_account_settings" }, 400, { "cache-control": "no-store" });
  }
  if (!await loadCredentialTarget(env, deviceID, accountID)) {
    const subscription = await loadAccountSyncSourceRow(env, deviceID, accountID);
    return json(
      { error: subscription ? "remote_account_is_read_only" : "account_not_found" },
      subscription ? 409 : 404,
      { "cache-control": "no-store" },
    );
  }
  const now = Math.floor(Date.now() / 1_000);
  const update = await env.DB.prepare(
    `UPDATE monitored_accounts SET
       refresh_interval_seconds = ?,
       history_retention_days = ?,
       next_refresh_at = CASE
         WHEN ? < refresh_interval_seconds THEN MIN(next_refresh_at, ? + ?)
         ELSE next_refresh_at
       END,
       updated_at = ?
     WHERE device_id = ? AND account_id = ?
       AND EXISTS (
         SELECT 1 FROM account_monitoring_consent
         WHERE device_id = ? AND account_id = ? AND enabled = 1
       )`
  ).bind(
    policy.refresh_interval_seconds,
    policy.history_retention_days,
    policy.refresh_interval_seconds,
    now,
    policy.refresh_interval_seconds,
    now,
    deviceID,
    accountID,
    deviceID,
    accountID,
  ).run();
  if ((update.meta.changes ?? 0) !== 1) {
    return json({ error: "account_not_found" }, 404, { "cache-control": "no-store" });
  }
  const row = await loadAccountSyncRow(env, deviceID, accountID);
  if (!row) throw new Error("Could not update monitored account settings");
  console.log(JSON.stringify({ event: "account_monitor_settings_updated" }));
  return accountSyncResponse(env, row, [], 200, null);
}

async function insertHistoryRows(
  env: Env,
  target: CredentialTargetRow,
  rows: HistoryUploadRow[],
): Promise<number> {
  let inserted = 0;
  for (let offset = 0; offset < rows.length; offset += 40) {
    const results = await env.DB.batch(rows.slice(offset, offset + 40).map((point) =>
      env.DB.prepare(
        `INSERT INTO usage_history (
           device_id, account_id, row_tag, history_source,
           provider_id, metric_id, metric_title, kind, window_minutes,
           remaining_percent, recorded_at, resets_at, seconds_until_reset, plan
         ) VALUES (?, ?, ?, 'device', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT DO NOTHING`
      ).bind(
        target.device_id, target.account_id, point.row_tag,
        point.provider_id, point.metric_id, point.metric_title, point.kind,
        point.window_minutes, point.remaining_percent, point.recorded_at,
        point.resets_at, point.seconds_until_reset, point.plan,
      )
    ));
    inserted += results.reduce((sum, result) => sum + (result.meta.changes ?? 0), 0);
  }
  return inserted;
}

async function syncMonitoredAccount(
  env: Env,
  deviceID: string,
  accountID: string,
  url: URL,
): Promise<Response> {
  const row = await loadAccountSyncSourceRow(env, deviceID, accountID);
  if (!row) return json({ error: "account_not_found" }, 404);
  const sinceValue = url.searchParams.get("since");
  const parsedSince = parseUnixSeconds(sinceValue);
  if (sinceValue !== null && parsedSince === null) return json({ error: "invalid_since" }, 400);
  const since = parsedSince
    ?? Math.floor(Date.now() / 1_000) - row.history_retention_days * 86_400;
  const cursor = decodeHistoryCursor(url.searchParams.get("cursor"));
  if (url.searchParams.has("cursor") && cursor === null) return json({ error: "invalid_cursor" }, 400);
  const effectiveSince = Math.max(
    since,
    Math.floor(Date.now() / 1_000) - row.history_retention_days * 86_400,
  );
  const query = cursor
    ? `SELECT row_tag, history_source, provider_id, metric_id, metric_title,
              kind, window_minutes, remaining_percent,
              recorded_at, resets_at, seconds_until_reset, plan
       FROM usage_history
       WHERE device_id = ? AND account_id = ? AND recorded_at >= ?
         AND (recorded_at > ? OR (recorded_at = ? AND metric_id > ?))
       ORDER BY recorded_at, metric_id LIMIT ?`
    : `SELECT row_tag, history_source, provider_id, metric_id, metric_title,
              kind, window_minutes, remaining_percent,
              recorded_at, resets_at, seconds_until_reset, plan
       FROM usage_history
       WHERE device_id = ? AND account_id = ? AND recorded_at >= ?
       ORDER BY recorded_at, metric_id LIMIT ?`;
  const statement = cursor
    ? env.DB.prepare(query).bind(row.source_device_id, row.source_account_id, effectiveSince,
        cursor.recordedAt, cursor.recordedAt, cursor.metricID, HISTORY_PAGE_SIZE + 1)
    : env.DB.prepare(query).bind(
        row.source_device_id, row.source_account_id, effectiveSince, HISTORY_PAGE_SIZE + 1
      );
  const result = await statement.all<HistoryRow>();
  const rows = result.results;
  const hasMore = rows.length > HISTORY_PAGE_SIZE;
  const history = rows.slice(0, HISTORY_PAGE_SIZE);
  const last = history.at(-1);
  const nextCursor = hasMore && last
    ? encodeHistoryCursor(last.recorded_at, last.metric_id) : null;
  return accountSyncResponse(env, row, history, 200, nextCursor);
}

async function accountSyncResponse(
  env: Env,
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
  const session = workerSession(row);
  return json({
    snapshot,
    metadata: accountMetadataPayload(row),
    history,
    consent_revision: row.consent_revision,
    next_cursor: nextCursor,
    account_reference: await accountReferenceForRow(env, row),
    last_success_at: row.last_success_at,
    last_error: row.last_error,
    session_status: session.status,
    session_checked_at: session.checkedAt,
    history_retention_days: row.history_retention_days,
  }, status, { "cache-control": "no-store" });
}

async function loadAccountSyncRow(
  env: Env,
  deviceID: string,
  accountID: string,
): Promise<AccountSyncRow | null> {
  return env.DB.prepare(
    `SELECT monitored_accounts.provider_id, monitored_accounts.workspace_id,
            monitored_accounts.profile_name, monitored_accounts.email,
            monitored_accounts.plan, monitored_accounts.plan_expires_at,
            monitored_accounts.trial_expires_at,
            monitored_accounts.last_refresh_at, monitored_accounts.last_success_at,
            monitored_accounts.last_error,
            monitored_accounts.latest_snapshot, monitored_accounts.history_retention_days,
            account_monitoring_consent.consent_revision
     FROM monitored_accounts
     INNER JOIN account_monitoring_consent
       ON account_monitoring_consent.device_id = monitored_accounts.device_id
      AND account_monitoring_consent.account_id = monitored_accounts.account_id
      AND account_monitoring_consent.enabled = 1
     WHERE monitored_accounts.device_id = ? AND monitored_accounts.account_id = ?`
  ).bind(deviceID, accountID).first<AccountSyncRow>();
}

async function loadAccountSyncSourceRow(
  env: Env,
  deviceID: string,
  accountID: string,
): Promise<AccountSyncSourceRow | null> {
  const direct = await env.DB.prepare(
    `SELECT monitored_accounts.device_id AS source_device_id,
            monitored_accounts.account_id AS source_account_id,
            monitored_accounts.provider_id, monitored_accounts.workspace_id,
            monitored_accounts.profile_name, monitored_accounts.email,
            monitored_accounts.plan, monitored_accounts.plan_expires_at,
            monitored_accounts.trial_expires_at,
            monitored_accounts.last_refresh_at, monitored_accounts.last_success_at,
            monitored_accounts.last_error,
            monitored_accounts.latest_snapshot, monitored_accounts.history_retention_days,
            account_monitoring_consent.consent_revision
     FROM monitored_accounts
     INNER JOIN account_monitoring_consent
       ON account_monitoring_consent.device_id = monitored_accounts.device_id
      AND account_monitoring_consent.account_id = monitored_accounts.account_id
      AND account_monitoring_consent.enabled = 1
     WHERE monitored_accounts.device_id = ? AND monitored_accounts.account_id = ?`
  ).bind(deviceID, accountID).first<AccountSyncSourceRow>();
  if (direct) return direct;
  return env.DB.prepare(
    `SELECT monitored_accounts.device_id AS source_device_id,
            monitored_accounts.account_id AS source_account_id,
            monitored_accounts.provider_id, monitored_accounts.workspace_id,
            monitored_accounts.profile_name, monitored_accounts.email,
            monitored_accounts.plan, monitored_accounts.plan_expires_at,
            monitored_accounts.trial_expires_at,
            monitored_accounts.last_refresh_at, monitored_accounts.last_success_at,
            monitored_accounts.last_error,
            monitored_accounts.latest_snapshot, monitored_accounts.history_retention_days,
            1 AS consent_revision
     FROM remote_account_subscriptions
     INNER JOIN monitored_accounts
       ON monitored_accounts.device_id = remote_account_subscriptions.source_device_id
      AND monitored_accounts.account_id = remote_account_subscriptions.source_account_id
     INNER JOIN account_monitoring_consent
       ON account_monitoring_consent.device_id = monitored_accounts.device_id
      AND account_monitoring_consent.account_id = monitored_accounts.account_id
      AND account_monitoring_consent.enabled = 1
     WHERE remote_account_subscriptions.subscriber_device_id = ?
       AND remote_account_subscriptions.local_account_id = ?`
  ).bind(deviceID, accountID).first<AccountSyncSourceRow>();
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
              monitored_accounts.display_name,
              monitored_accounts.plan, monitored_accounts.missing_quotas,
              CASE WHEN monitored_accounts.credential_fingerprint IS NULL
                THEN monitored_accounts.encrypted_credentials ELSE ''
              END AS encrypted_credentials,
              monitored_accounts.credential_fingerprint,
              monitored_accounts.credential_revision, monitored_accounts.consecutive_failures,
              monitored_accounts.scheduled_monitor_at,
              monitored_accounts.refresh_interval_seconds,
              monitored_accounts.history_retention_days, monitored_accounts.next_refresh_at,
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
       failure_retryable = 0, failure_retry_after_seconds = NULL, completed_at = ?
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
      `SELECT device_id, apns_token, apns_environment FROM devices
       WHERE last_seen_at >= ? AND push_disabled_at IS NULL AND device_id > ?
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

async function processQueue(
  batch: MessageBatch<QueueTarget>,
  env: Env,
  refreshMonitor: typeof refreshMonitorRun = refreshMonitorRun,
): Promise<void> {
  const pushMessages = batch.messages.filter((message) => message.body.kind === "push");
  const monitorMessages = batch.messages.filter((message) => message.body.kind === "monitor_run");
  const pushDelivery = pushMessages.length
    ? deliverQueuedPushes(pushMessages, env)
    : Promise.resolve();
  try {
    // Provider quota endpoints commonly rate-limit by account or connector. Keep APNs fan-out
    // parallel, but never burst independent provider refreshes from the same queue invocation.
    for (const message of monitorMessages) await refreshMonitor(message, env);
  } finally {
    await pushDelivery;
  }
}

async function deliverQueuedPushes(messages: Message<QueueTarget>[], env: Env): Promise<void> {
  validateAPNSConfiguration();
  const authorization = await currentAPNSAuthorization(env);
  let delivered = 0;
  let rejected = 0;
  await Promise.all(messages.map(async (message) => {
    if (message.body.kind !== "push") return;
    try {
      const outcome = await sendSilentPush(
        env, message.body.apns_token, authorization, message.body.apns_environment
      );
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
        run.failure_retry_after_seconds,
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
          run.failure_retry_after_seconds,
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

  let result: ProviderFetchResult;
  try {
    const credentials = await decryptCredentials(env, source);
    const actualFingerprint = await credentialFingerprint(env, source, credentials);
    if (actualFingerprint !== run.credential_fingerprint
        || source.target_credential_fingerprint !== run.credential_fingerprint) {
      throw new Error("Scheduled credentials changed before refresh");
    }
    result = await fetchUsage(source, credentials, startedAt);
    result.snapshot.account_reference = await providerIdentityReference(
      env,
      source.provider_id,
      result.account_identity ?? `workspace:${source.workspace_id}`,
    );
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
    const retryAfterSeconds = providerError ? providerRetryDelaySeconds(providerError) : null;
    await env.DB.prepare(
      `UPDATE monitor_runs SET status = 'failed', result_error = ?, completed_at = ?,
         failure_retryable = ?, failure_retry_after_seconds = ?
       WHERE run_id = ? AND status = 'running'`
    ).bind(
      errorText, startedAt, providerError?.retryable === true ? 1 : 0,
      retryAfterSeconds, runID,
    ).run();
    try {
      await applyMonitorRunFailure(
        env, runID, errorText, providerError?.retryable === true,
        retryAfterSeconds, startedAt,
      );
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
            encrypted_result_credentials, result_snapshot, result_error, failure_retryable,
            failure_retry_after_seconds
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
            monitored_accounts.display_name,
            monitored_accounts.plan, monitored_accounts.missing_quotas,
            monitored_accounts.encrypted_credentials,
            monitored_accounts.credential_fingerprint,
            monitored_accounts.credential_revision, monitored_accounts.consecutive_failures,
            monitored_accounts.scheduled_monitor_at,
            monitored_accounts.refresh_interval_seconds,
            monitored_accounts.history_retention_days, monitored_accounts.next_refresh_at,
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
         failure_retry_after_seconds = NULL,
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
  const storedCredentials = await decryptCredentials(env, row);
  const targetCredentials: ProviderCredentials = {
    ...credentials,
    monthly_budget: storedCredentials.monthly_budget ?? null,
    currency_code: storedCredentials.currency_code ?? credentials.currency_code ?? null,
  };
  const targetSnapshot = snapshotForCredentials(snapshot, targetCredentials);
  const effectivePlan = snapshot.plan ?? row.plan;
  const effectiveSnapshot = mergeSupplementarySnapshot(
    { ...targetSnapshot, plan: effectivePlan },
    row.latest_snapshot,
  );
  const nextFingerprint = await credentialFingerprint(env, {
    provider_id: row.provider_id,
    workspace_id: row.workspace_id,
    plan: effectivePlan,
  }, targetCredentials);
  const encrypted = await encryptCredentials(
    env, row.device_id, row.account_id, row.provider_id, targetCredentials
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
         consecutive_failures = 0, next_refresh_at = ?, updated_at = ?
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
         device_id, account_id, row_tag, history_source,
         provider_id, metric_id, metric_title, kind, window_minutes,
         remaining_percent, recorded_at, resets_at, seconds_until_reset, plan
       )
       SELECT ?, ?, ?, 'worker', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
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
         row_tag = excluded.row_tag,
         history_source = 'worker',
         remaining_percent = excluded.remaining_percent,
         resets_at = excluded.resets_at,
         seconds_until_reset = excluded.seconds_until_reset,
         plan = excluded.plan`
    ).bind(
      row.device_id, row.account_id,
      historyRowTag(row.account_id, window.metric_id, snapshot.fetched_at),
      snapshot.provider_id, window.metric_id, window.title,
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
  const results = await env.DB.batch(statements);
  if ((results[0]?.meta.changes ?? 0) === 1) {
    await enqueueRemoteAccountRefreshHints(env, row.device_id, row.account_id);
    await propagateVerifiedCredentialToSameAccount(env, row, {
      credentials: targetCredentials,
      snapshot: effectiveSnapshot,
    });
  }
}

async function propagateVerifiedCredentialToSameAccount(
  env: Env,
  source: CredentialTargetRow,
  result: ProviderFetchResult,
): Promise<number> {
  const reference = result.snapshot.account_reference;
  if (!reference) return 0;
  const targets = await loadSameAccountCredentialTargets(
    env,
    source.provider_id,
    source.workspace_id,
    source.device_id,
    source.account_id,
  );
  let updated = 0;
  const updatedDeviceIDs = new Set<string>();
  for (const target of targets) {
    const knownReference = explicitSnapshotAccountReference(target.latest_snapshot);
    if (knownReference && knownReference !== reference) continue;
    await applyVerifiedCredentialResult(env, target, result);
    updated += 1;
    updatedDeviceIDs.add(target.device_id);
  }
  await enqueueDeviceRefreshHints(env, updatedDeviceIDs);
  if (updated > 0) {
    console.log(JSON.stringify({
      event: "same_provider_account_credentials_merged",
      provider: source.provider_id,
      accounts: updated + 1,
    }));
  }
  return updated;
}

async function enqueueDeviceRefreshHints(env: Env, deviceIDs: Set<string>): Promise<void> {
  if (deviceIDs.size === 0) return;
  const ids = [...deviceIDs];
  const targets: Array<Omit<PushTarget, "kind">> = [];
  for (let offset = 0; offset < ids.length; offset += 40) {
    const slice = ids.slice(offset, offset + 40);
    const placeholders = slice.map(() => "?").join(", ");
    const result = await env.DB.prepare(
      `SELECT device_id, apns_token, apns_environment FROM devices
       WHERE push_disabled_at IS NULL AND device_id IN (${placeholders})`
    ).bind(...slice).all<Omit<PushTarget, "kind">>();
    targets.push(...result.results);
  }
  for (let offset = 0; offset < targets.length; offset += QUEUE_BATCH_SIZE) {
    await env.PUSH_QUEUE.sendBatch(
      targets.slice(offset, offset + QUEUE_BATCH_SIZE).map((row) => ({
        body: { kind: "push" as const, ...row },
      }))
    );
  }
}

function snapshotForCredentials(
  snapshot: ProviderSnapshot,
  credentials: ProviderCredentials,
): ProviderSnapshot {
  if (!snapshot.api_balance
      || (snapshot.provider_id !== "openai_api" && snapshot.provider_id !== "anthropic_api")) {
    return snapshot;
  }
  const budget = credentials.monthly_budget;
  const limit = typeof budget === "number" && Number.isFinite(budget) && budget > 0
    ? budget : null;
  return {
    ...snapshot,
    api_balance: {
      ...snapshot.api_balance,
      title: limit === null ? "API spend this month" : "Monthly API budget",
      limit,
      remaining: limit === null ? null : Math.max(0, limit - snapshot.api_balance.spent),
    },
  };
}

async function enqueueRemoteAccountRefreshHints(
  env: Env,
  sourceDeviceID: string,
  sourceAccountID: string,
): Promise<void> {
  const result = await env.DB.prepare(
    `SELECT DISTINCT devices.device_id, devices.apns_token, devices.apns_environment
     FROM remote_account_subscriptions
     INNER JOIN devices
       ON devices.device_id = remote_account_subscriptions.subscriber_device_id
     WHERE remote_account_subscriptions.source_device_id = ?
       AND remote_account_subscriptions.source_account_id = ?
       AND devices.push_disabled_at IS NULL`
  ).bind(sourceDeviceID, sourceAccountID).all<Omit<PushTarget, "kind">>();
  for (let offset = 0; offset < result.results.length; offset += QUEUE_BATCH_SIZE) {
    await env.PUSH_QUEUE.sendBatch(
      result.results.slice(offset, offset + QUEUE_BATCH_SIZE).map((row) => ({
        body: { kind: "push" as const, ...row },
      }))
    );
  }
  if (result.results.length > 0) {
    console.log(JSON.stringify({
      event: "remote_account_refresh_hints_enqueued",
      devices: result.results.length,
    }));
  }
}

async function applyMonitorRunFailure(
  env: Env,
  runID: string,
  error: string,
  retryable: boolean,
  retryAfterSeconds: number | null,
  failedAt: number,
): Promise<void> {
  const run = await loadMonitorRun(env, runID);
  if (!run) return;
  while (true) {
    const targets = await loadPendingMonitorRunTargets(env, runID);
    if (targets.length === 0) break;
    for (const row of targets) {
      const delay = monitorRetryDelaySeconds(
        retryable,
        retryAfterSeconds,
        row.refresh_interval_seconds,
        row.consecutive_failures,
      );
      await env.DB.batch([
        env.DB.prepare(
          `UPDATE monitored_accounts SET last_refresh_at = ?, last_error = ?,
             consecutive_failures = consecutive_failures + 1,
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

function monitorRetryDelaySeconds(
  retryable: boolean,
  retryAfterSeconds: number | null,
  refreshIntervalSeconds: number,
  consecutiveFailures: number,
): number {
  const baseDelay = retryAfterSeconds
    ?? (retryable ? 15 * 60 : refreshIntervalSeconds);
  if (!retryable && retryAfterSeconds === null) return baseDelay;
  return Math.min(
    MAX_MONITOR_INTERVAL_SECONDS,
    baseDelay * (2 ** Math.min(Math.max(0, consecutiveFailures), 4)),
  );
}

function mergeSupplementarySnapshot(
  snapshot: ProviderSnapshot,
  previousJSON: string | null,
): ProviderSnapshot {
  if (snapshot.provider_id !== "chatgpt"
      || snapshot.reset_credits_authoritative !== false
      || snapshot.available_reset_count <= 0
      || !previousJSON) return snapshot;
  try {
    const previous = JSON.parse(previousJSON) as ProviderSnapshot;
    if (previous.provider_id !== "chatgpt" || !Array.isArray(previous.reset_credits)) {
      return snapshot;
    }
    return {
      ...snapshot,
      reset_credits: previous.reset_credits.slice(0, snapshot.available_reset_count),
    };
  } catch {
    return snapshot;
  }
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
       failure_retry_after_seconds = NULL,
       completed_at = ? WHERE run_id = ?`
  ).bind(status, completedAt, runID).run();
}

async function pruneHistory(env: Env, now: number): Promise<void> {
  await env.DB.prepare(
    `DELETE FROM usage_history
     WHERE EXISTS (
       SELECT 1 FROM monitored_accounts
       WHERE monitored_accounts.device_id = usage_history.device_id
         AND monitored_accounts.account_id = usage_history.account_id
         AND usage_history.recorded_at
           < ? - monitored_accounts.history_retention_days * 86400
     )`
  ).bind(now).run();
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
  row: {
    device_id: string;
    apns_token: string;
    apns_environment?: APNSEnvironment;
  },
  result: APNSResult,
): Promise<void> {
  const environment = row.apns_environment ?? null;
  if (result.ok) {
    await env.DB.prepare(
      `UPDATE devices SET last_push_at = ?, push_disabled_at = NULL
       WHERE device_id = ? AND apns_token = ?
         AND (? IS NULL OR apns_environment = ?)`
    ).bind(
      Math.floor(Date.now() / 1_000), row.device_id, row.apns_token,
      environment, environment,
    ).run();
  } else if (isPermanentAPNSRejection(result)) {
    const disabled = await env.DB.prepare(
      `UPDATE devices SET push_disabled_at = ?
       WHERE device_id = ? AND apns_token = ?
         AND (? IS NULL OR apns_environment = ?)`
    ).bind(
      Math.floor(Date.now() / 1_000), row.device_id, row.apns_token,
      environment, environment,
    ).run();
    if ((disabled.meta.changes ?? 0) === 1) {
      console.log(JSON.stringify({ event: "device_push_disabled_after_apns_rejection" }));
    }
  }
}

async function sendSilentPush(
  env: Env,
  token: string,
  authorization: string,
  environment: APNSEnvironment = "production",
): Promise<APNSResult> {
  validateAPNSConfiguration();
  const host = environment === "development" ? APNS_DEVELOPMENT_HOST : APNS_PRODUCTION_HOST;
  const response = await fetch(`${host}/3/device/${token}`, {
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
  return result.status === 410
    || result.reason === "BadDeviceToken"
    || result.reason === "Unregistered"
    || result.reason === "BadEnvironmentKeyInToken";
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
  const apnsEnvironment = value.apns_environment ?? "production";
  if (typeof deviceID !== "string" || !isUUID(deviceID)) return null;
  if (typeof deviceSecret !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(deviceSecret)) return null;
  if (typeof apnsToken !== "string" || !/^[0-9a-fA-F]{64,200}$/.test(apnsToken)) return null;
  if (apnsEnvironment !== "development" && apnsEnvironment !== "production") return null;
  return {
    device_id: deviceID.toLowerCase(),
    device_secret: deviceSecret,
    apns_token: apnsToken.toLowerCase(),
    apns_environment: apnsEnvironment,
  };
}

async function parseDeviceTokenUpdate(request: Request): Promise<{
  apns_token: string;
  apns_environment: APNSEnvironment;
} | null> {
  const value = await boundedRequestJSON(request, MAX_DEVICE_TOKEN_BODY_BYTES);
  if (!isRecord(value) || typeof value.apns_token !== "string"
      || !/^[0-9a-fA-F]{64,200}$/.test(value.apns_token)) return null;
  const environment = value.apns_environment ?? "production";
  if (environment !== "development" && environment !== "production") return null;
  return {
    apns_token: value.apns_token.toLowerCase(),
    apns_environment: environment,
  };
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
  const monthlyBudget = nullablePositiveNumber(value.monthly_budget);
  const currencyCode = optionalBoundedString(value.currency_code, 8);
  if (accessToken === null || refreshToken === null || idToken === null || expiresAt === undefined
      || monthlyBudget === undefined || currencyCode === undefined
      || (currencyCode !== null && !/^[A-Za-z]{3}$/.test(currencyCode))) {
    throw new Error("Stored credentials are invalid");
  }
  return {
    access_token: accessToken,
    refresh_token: refreshToken,
    id_token: idToken,
    expires_at: expiresAt,
    monthly_budget: monthlyBudget,
    currency_code: currencyCode?.toUpperCase() ?? null,
  };
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
  const monthlyBudget = nullablePositiveNumber(value.monthly_budget);
  const currencyCode = optionalBoundedString(value.currency_code, 8);
  if (accessToken === null || refreshToken === null || idToken === null || expiresAt === undefined
      || monthlyBudget === undefined || currencyCode === undefined
      || (currencyCode !== null && !/^[A-Za-z]{3}$/.test(currencyCode))) {
    throw new Error("Stored monitor result credentials are invalid");
  }
  return {
    access_token: accessToken,
    refresh_token: refreshToken,
    id_token: idToken,
    expires_at: expiresAt,
    monthly_budget: monthlyBudget,
    currency_code: currencyCode?.toUpperCase() ?? null,
  };
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
    && ["chatgpt", "claude", "grok", "kimi", "github_copilot", "zai", "minimax", "synthetic", "warp",
      "openai_api", "anthropic_api", "openrouter", "fireworks", "deepseek", "poe"]
      .includes(value);
}

function credentialsSufficient(providerID: ProviderID, accessToken: string, refreshToken: string): boolean {
  if (!accessToken) return false;
  return !["chatgpt", "claude", "grok", "kimi"].includes(providerID) || refreshToken.length > 0;
}

function parseAccountMetadata(value: unknown): {
  profile_name: string | null;
  email: string | null;
  plan_expires_at: number | null;
  trial_expires_at: number | null;
} | null {
  if (value === null || value === undefined) {
    return {
      profile_name: null,
      email: null,
      plan_expires_at: null,
      trial_expires_at: null,
    };
  }
  if (!isRecord(value)) return null;
  const profileName = optionalBoundedString(value.name, 128);
  const email = optionalBoundedString(value.email, 320);
  const planExpiresAt = nullableTimestamp(value.plan_expires_at);
  const trialExpiresAt = nullableTimestamp(value.trial_expires_at);
  if (profileName === undefined || email === undefined
      || planExpiresAt === undefined || trialExpiresAt === undefined) return null;
  return {
    profile_name: profileName,
    email,
    plan_expires_at: planExpiresAt,
    trial_expires_at: trialExpiresAt,
  };
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

function nullablePositiveNumber(value: unknown): number | null | undefined {
  if (value === null || value === undefined) return null;
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : undefined;
}

function numericUnixSeconds(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) && value >= 0
    ? Math.floor(value) : null;
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

function historyRowTag(accountID: string, metricID: string, recordedAt: number): string {
  return `h1.${accountID.toLowerCase()}.${base64URL(metricID)}.${Math.floor(recordedAt)}`;
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
  monitorRetryDelaySeconds,
  parseAccountUpload,
  parseRegistration,
  processQueue,
  pruneDeviceDeletionTombstones,
  pruneLinkSessions,
  pruneMonitorRuns,
  refreshMonitorRun,
  runScheduledRefresh,
  snapshotForCredentials,
  syntheticResetAt,
  upsertMonitoredAccount,
};
