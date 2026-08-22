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
import { renderDashboardPage } from "./dashboard-page";
import { renderLinkQRCode } from "./link-page";
import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
  type AuthenticationResponseJSON,
  type RegistrationResponseJSON,
} from "@simplewebauthn/server";

const MAX_REGISTRATION_BODY_BYTES = 2_048;
const MAX_DEVICE_TOKEN_BODY_BYTES = 1_024;
const MAX_ACCOUNT_BODY_BYTES = 64 * 1_024;
const MAX_ACCOUNT_POLICY_BODY_BYTES = 2_048;
const MAX_HISTORY_UPLOAD_BODY_BYTES = 512 * 1_024;
const MAX_HISTORY_UPLOAD_ROWS = 250;
const MAX_DEVICE_SNAPSHOT_BODY_BYTES = 32 * 1_024;
const MAX_DEVICE_SNAPSHOT_WINDOWS = 32;
const MAX_DEVICE_SNAPSHOT_RESET_CREDITS = 32;
const MAX_REMOTE_ACCOUNT_IMPORT_BODY_BYTES = 16 * 1_024;
const MAX_REMOTE_ACCOUNT_IMPORTS = 50;
const DASHBOARD_SESSION_TTL_SECONDS = 12 * 60 * 60;
const DASHBOARD_KEY_GRANT_TTL_SECONDS = 10 * 60;
const WEBAUTHN_CHALLENGE_TTL_SECONDS = 5 * 60;
const MAX_WEBAUTHN_BODY_BYTES = 32 * 1_024;
const MAX_ACTIVE_WEBAUTHN_CHALLENGES = 100;
const DASHBOARD_COOKIE_NAME = "__Host-when_reset_dashboard";
const DASHBOARD_ACCOUNT_LIMIT = 500;
const DASHBOARD_DEVICE_LIMIT = 200;
const DASHBOARD_HISTORY_LIMIT = 1_000;
const DASHBOARD_SNAPSHOT_LOAD_BATCH_SIZE = 25;
const MAX_DASHBOARD_SNAPSHOT_BYTES = 128 * 1_024;
const MAX_DASHBOARD_ACCOUNT_SOURCE_ROWS = 10_000;
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
const MAX_DEVICE_SNAPSHOT_CLOCK_SKEW_SECONDS = 5 * 60;
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
  source_device_id: string;
  source_account_id: string;
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
  consent_revision: number;
};

type RemoteAccountCandidate = RemoteAccountCandidateRow & {
  remote_account_id: string;
  synced_account_reference: string;
  account_reference: string;
};

type WorkerSessionStatus = "active" | "expired" | "error" | "unchecked";
type DashboardAccountStatus = WorkerSessionStatus | "stale";

type DashboardSessionRow = {
  token_hash: string;
  expires_at: number;
};

type DashboardSessionAuthorizationRow = {
  auth_method: "access_key" | "passkey";
  key_verified_until: number | null;
  passkey_rp_id: string | null;
};

type DashboardPasskeyRow = {
  credential_id: string;
  user_handle: string;
  public_key: ArrayBuffer;
  counter: number;
  transports_json: string;
};

type DashboardWebAuthnChallengeRow = {
  transaction_id: string;
  purpose: "authentication" | "registration";
  challenge: string;
  origin: string;
  rp_id: string;
  session_token_hash: string | null;
  expires_at: number;
};

type DashboardAccountRow = {
  source_kind: "worker" | "device";
  device_id: string;
  account_id: string;
  provider_id: ProviderID;
  workspace_id: string;
  display_name: string | null;
  plan: string | null;
  plan_expires_at: number | null;
  trial_expires_at: number | null;
  refresh_interval_seconds: number;
  history_retention_days: number;
  next_refresh_at: number | null;
  last_refresh_at: number | null;
  last_success_at: number | null;
  last_error: string | null;
  dashboard_account_reference: string | null;
};

type DashboardAccountSource = DashboardAccountRow;

type DashboardAccountGroup = {
  id: string;
  representative: DashboardAccountRow;
  rows: DashboardAccountSource[];
};

type DashboardHistoryRow = {
  metric_id: string;
  metric_title: string;
  kind: string | null;
  window_minutes: number | null;
  remaining_percent: number;
  recorded_at: number;
  resets_at: number;
  plan: string | null;
};

type DashboardWindow = {
  title: string;
  kind: string | null;
  window_minutes: number | null;
  remaining_percent: number;
  resets_at: number;
};

type DashboardResetCredit = {
  status: string | null;
  granted_at: number | null;
  expires_at: number | null;
};

type DashboardBalance = {
  title: string;
  currency_code: string;
  spent: number;
  limit: number | null;
  remaining: number | null;
  period_start: number | null;
  period_end: number | null;
  access_expires_at: number | null;
  is_unlimited: boolean;
  kind: "budget" | "wallet";
  unit_label: string | null;
};

type DashboardSnapshot = {
  fetched_at: number;
  windows: DashboardWindow[];
  available_reset_count: number;
  reset_credits: DashboardResetCredit[];
  reset_credits_authoritative: boolean;
  api_balance?: DashboardBalance;
};

type DashboardSnapshotSelection = {
  source: "worker" | "device";
  snapshot: DashboardSnapshot;
  row: DashboardAccountRow;
};

type RemoteAccountImport = {
  remote_account_id: string;
  local_account_id: string;
};

type CredentialTargetRow = ProviderAccount & {
  device_id: string;
  account_id: string;
  consent_revision: number;
  refresh_interval_seconds: number;
  credential_fingerprint: string | null;
  credential_revision: number;
  latest_snapshot: string | null;
  history_retention_days: number;
};

type RemoteCredentialReplacementAuthorization = {
  subscriberDeviceID: string;
  localAccountID: string;
};

type StoredProviderSnapshot = ProviderSnapshot & {
  account_reference_verified?: boolean;
  account_reference_scope?: "provider_account_v2";
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
  history_source?: "worker" | "device";
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

type DeviceSnapshotSourceUpload = {
  provider_id: ProviderID;
  display_name: string | null;
  refresh_interval_seconds: number;
  history_retention_days: number;
  consent_revision: number;
};

type DeviceSnapshotSourceRow = {
  device_id: string;
  account_id: string;
  provider_id: ProviderID;
  display_name: string | null;
  plan: string | null;
  refresh_interval_seconds: number;
  history_retention_days: number;
  next_sequence: number;
  last_payload_hash: string | null;
  latest_snapshot: string | null;
  last_observed_at: number | null;
  last_upload_at: number | null;
  consent_revision: number;
};

type DeviceSnapshotUpload = {
  consent_revision: number;
  sequence: number;
  observed_at: number;
  snapshot: ProviderSnapshot;
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
          || pathname.startsWith("/v1/link-sessions")
          || pathname.startsWith("/v1/dashboard")) {
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
    return dashboardPageResponse(url);
  }

  if (request.method === "GET" && url.pathname === "/healthz") {
    return json({ ok: true, mode: "self_hosted", topic: APNS_TOPIC });
  }

  if (url.pathname === "/v1/dashboard/session") {
    if (!strictSameOriginRequest(request, url.origin)) {
      return linkJSON({ error: "forbidden_origin" }, 403);
    }
    if (request.method === "POST") {
      if (!(await registrationAccessAllowed(request, env))) {
        return linkJSON({ error: "unauthorized" }, 401);
      }
      return createDashboardSession(env);
    }
    if (request.method === "DELETE") return deleteDashboardSession(request, env);
    return linkJSON({ error: "method_not_allowed" }, 405, { Allow: "POST, DELETE" });
  }

  if (request.method === "GET" && url.pathname === "/v1/dashboard/auth-methods") {
    return dashboardAuthMethods(env, url);
  }

  if (url.pathname === "/v1/dashboard/passkeys/authentication/options") {
    if (request.method !== "POST") {
      return linkJSON({ error: "method_not_allowed" }, 405, { Allow: "POST" });
    }
    if (!strictSameOriginRequest(request, url.origin)) {
      return linkJSON({ error: "forbidden_origin" }, 403);
    }
    return createPasskeyAuthenticationOptions(request, env, url);
  }

  if (url.pathname === "/v1/dashboard/passkeys/authentication/verify") {
    if (request.method !== "POST") {
      return linkJSON({ error: "method_not_allowed" }, 405, { Allow: "POST" });
    }
    if (!strictSameOriginRequest(request, url.origin)) {
      return linkJSON({ error: "forbidden_origin" }, 403);
    }
    return verifyPasskeyAuthentication(request, env, url);
  }

  if (url.pathname === "/v1/dashboard/passkeys/reverify") {
    if (request.method !== "POST") {
      return linkJSON({ error: "method_not_allowed" }, 405, { Allow: "POST" });
    }
    if (!strictSameOriginRequest(request, url.origin)) {
      return linkJSON({ error: "forbidden_origin" }, 403);
    }
    return reverifyDashboardAccessKey(request, env);
  }

  if (url.pathname === "/v1/dashboard/passkeys/registration/options") {
    if (request.method !== "POST") {
      return linkJSON({ error: "method_not_allowed" }, 405, { Allow: "POST" });
    }
    if (!strictSameOriginRequest(request, url.origin)) {
      return linkJSON({ error: "forbidden_origin" }, 403);
    }
    return createPasskeyRegistrationOptions(request, env, url);
  }

  if (url.pathname === "/v1/dashboard/passkeys/registration/verify") {
    if (request.method !== "POST") {
      return linkJSON({ error: "method_not_allowed" }, 405, { Allow: "POST" });
    }
    if (!strictSameOriginRequest(request, url.origin)) {
      return linkJSON({ error: "forbidden_origin" }, 403);
    }
    return verifyPasskeyRegistration(request, env, url);
  }

  if (url.pathname === "/v1/dashboard/passkeys") {
    if (request.method === "GET") return dashboardPasskeySummary(request, env, url);
    if (request.method === "DELETE") {
      if (!strictSameOriginRequest(request, url.origin)) {
        return linkJSON({ error: "forbidden_origin" }, 403);
      }
      return deleteDashboardPasskeys(request, env, url);
    }
    return linkJSON({ error: "method_not_allowed" }, 405, { Allow: "GET, DELETE" });
  }

  if (request.method === "GET" && url.pathname === "/v1/dashboard") {
    if (!(await authorizeDashboardSession(request, env))) {
      return linkJSON({ error: "unauthorized" }, 401);
    }
    return dashboardOverview(env);
  }

  if (url.pathname === "/v1/dashboard/devices") {
    if (request.method !== "GET") {
      return linkJSON({ error: "method_not_allowed" }, 405, { Allow: "GET" });
    }
    const authorization = await dashboardSessionAuthorization(request, env);
    if (!authorization) return linkJSON({ error: "unauthorized" }, 401);
    return dashboardDevices(env, authorization);
  }

  const dashboardDeviceActionMatch = /^\/v1\/dashboard\/devices\/([A-Za-z0-9_-]{43})$/
    .exec(url.pathname);
  if (dashboardDeviceActionMatch) {
    if (request.method !== "PATCH" && request.method !== "DELETE") {
      return linkJSON({ error: "method_not_allowed" }, 405, { Allow: "PATCH, DELETE" });
    }
    if (!strictSameOriginRequest(request, url.origin)) {
      return linkJSON({ error: "forbidden_origin" }, 403);
    }
    return request.method === "PATCH"
      ? updateDashboardDevice(request, env, dashboardDeviceActionMatch[1])
      : deleteDashboardDevice(request, env, dashboardDeviceActionMatch[1]);
  }

  const dashboardAccountActionMatch = /^\/v1\/dashboard\/accounts\/([A-Za-z0-9_-]{43})$/
    .exec(url.pathname);
  if (dashboardAccountActionMatch) {
    if (request.method !== "DELETE") {
      return linkJSON({ error: "method_not_allowed" }, 405, { Allow: "DELETE" });
    }
    if (!strictSameOriginRequest(request, url.origin)) {
      return linkJSON({ error: "forbidden_origin" }, 403);
    }
    return deleteDashboardAccount(request, env, dashboardAccountActionMatch[1], url);
  }

  const dashboardHistoryMatch = /^\/v1\/dashboard\/accounts\/([A-Za-z0-9_-]{43})\/history$/
    .exec(url.pathname);
  if (dashboardHistoryMatch) {
    if (request.method !== "GET") {
      return linkJSON({ error: "method_not_allowed" }, 405, { Allow: "GET" });
    }
    if (!(await authorizeDashboardSession(request, env))) {
      return linkJSON({ error: "unauthorized" }, 401);
    }
    return dashboardAccountHistory(env, dashboardHistoryMatch[1], url);
  }
  if (url.pathname.startsWith("/v1/dashboard")) {
    return linkJSON({ error: "not_found" }, 404);
  }

  if (request.method === "POST" && url.pathname === "/v1/link-sessions") {
    if (!sameOriginRequest(request, url.origin)) {
      return linkJSON({ error: "forbidden_origin" }, 403);
    }
    const hasServerKey = request.headers.has("x-when-reset-server-key");
    const keyAllowed = hasServerKey && await registrationAccessAllowed(request, env);
    const sessionAllowed = !hasServerKey && strictSameOriginRequest(request, url.origin)
      && await authorizeDashboardSession(request, env);
    if (!keyAllowed && !sessionAllowed) {
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

  const accountMatch = /^\/v1\/devices\/([0-9a-f-]{36})\/accounts\/([0-9a-f-]{36})(?:\/(sync|history|settings|snapshots))?$/.exec(
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
    if (accountMatch[3] === "snapshots") {
      if (request.method === "PUT") {
        return enableDeviceSnapshotSource(request, env, deviceID, accountID);
      }
      if (request.method === "POST") {
        return uploadDeviceSnapshot(request, env, deviceID, accountID);
      }
      if (request.method === "DELETE") {
        const consentRevision = parseDeleteConsentRevision(url);
        if (consentRevision === null) {
          return json({ error: "invalid_consent_revision" }, 400, {
            "cache-control": "no-store",
          });
        }
        return disableDeviceSnapshotSource(env, deviceID, accountID, consentRevision);
      }
      return json({ error: "method_not_allowed" }, 405, {
        Allow: "PUT, POST, DELETE",
        "cache-control": "no-store",
      });
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

function dashboardPageResponse(url: URL): Response {
  if (url.protocol !== "https:") {
    return linkJSON({ error: "https_required" }, 400);
  }
  const nonce = randomBase64URL(16);
  return new Response(renderDashboardPage(url.origin, url.host, nonce), {
    status: 200,
    headers: linkSecurityHeaders({
      "content-type": "text/html; charset=utf-8",
      "content-security-policy": [
        "default-src 'none'",
        `script-src 'nonce-${nonce}'`,
        `style-src 'nonce-${nonce}'`,
        "connect-src 'self'",
        "img-src 'self' data:",
        "form-action 'self'",
        "base-uri 'none'",
        "object-src 'none'",
        "frame-ancestors 'none'",
      ].join("; "),
    }),
  });
}

async function createDashboardSession(env: Env): Promise<Response> {
  const now = Math.floor(Date.now() / 1_000);
  await pruneDashboardSessions(env, now);
  const token = randomBase64URL(32);
  const tokenHash = await dashboardSessionHash(env, token);
  const expiresAt = now + DASHBOARD_SESSION_TTL_SECONDS;
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO dashboard_sessions (token_hash, created_at, expires_at)
       VALUES (?, ?, ?)`
    ).bind(tokenHash, now, expiresAt),
    env.DB.prepare(
      `INSERT INTO dashboard_session_authorizations (
         token_hash, auth_method, key_verified_until, passkey_rp_id
       ) VALUES (?, 'access_key', ?, NULL)`
    ).bind(tokenHash, now + DASHBOARD_KEY_GRANT_TTL_SECONDS),
  ]);
  console.log(JSON.stringify({ event: "dashboard_session_created" }));
  return new Response(null, {
    status: 204,
    headers: linkSecurityHeaders({
      "set-cookie": dashboardSessionCookie(token, DASHBOARD_SESSION_TTL_SECONDS),
    }),
  });
}

async function deleteDashboardSession(request: Request, env: Env): Promise<Response> {
  const token = dashboardCookieToken(request);
  if (token) {
    const tokenHash = await dashboardSessionHash(env, token);
    await env.DB.batch([
      env.DB.prepare("DELETE FROM dashboard_session_authorizations WHERE token_hash = ?")
        .bind(tokenHash),
      env.DB.prepare("DELETE FROM dashboard_sessions WHERE token_hash = ?").bind(tokenHash),
    ]);
  }
  console.log(JSON.stringify({ event: "dashboard_session_deleted" }));
  return new Response(null, {
    status: 204,
    headers: linkSecurityHeaders({
      "set-cookie": dashboardSessionCookie("", 0),
    }),
  });
}

async function authorizeDashboardSession(request: Request, env: Env): Promise<boolean> {
  const token = dashboardCookieToken(request);
  if (!token) return false;
  const now = Math.floor(Date.now() / 1_000);
  const tokenHash = await dashboardSessionHash(env, token);
  const session = await env.DB.prepare(
    `SELECT s.token_hash, s.expires_at
     FROM dashboard_sessions AS s
     INNER JOIN dashboard_session_authorizations AS a ON a.token_hash = s.token_hash
     WHERE s.token_hash = ? AND s.expires_at > ?`
  ).bind(tokenHash, now).first<DashboardSessionRow>();
  if (session) return true;
  await env.DB.prepare("DELETE FROM dashboard_sessions WHERE token_hash = ?")
    .bind(tokenHash).run();
  return false;
}

async function dashboardSessionAuthorization(
  request: Request,
  env: Env,
): Promise<(DashboardSessionAuthorizationRow & { token_hash: string }) | null> {
  const token = dashboardCookieToken(request);
  if (!token) return null;
  const now = Math.floor(Date.now() / 1_000);
  const tokenHash = await dashboardSessionHash(env, token);
  const row = await env.DB.prepare(
    `SELECT a.auth_method, a.key_verified_until, a.passkey_rp_id
     FROM dashboard_sessions AS s
     JOIN dashboard_session_authorizations AS a ON a.token_hash = s.token_hash
     WHERE s.token_hash = ? AND s.expires_at > ?`
  ).bind(tokenHash, now).first<DashboardSessionAuthorizationRow>();
  return row ? { ...row, token_hash: tokenHash } : null;
}

function dashboardManagementAllowed(
  authorization: DashboardSessionAuthorizationRow | null,
  now = Math.floor(Date.now() / 1_000),
): boolean {
  return authorization !== null
    && authorization.key_verified_until !== null
    && authorization.key_verified_until >= now;
}

// Passkey enrollment is already protected by the HttpOnly dashboard session and the
// user-verification ceremony itself. Do not force the user to type the recovery key again just
// to add a second device credential. Destructive account/Worker-data actions continue to use the
// stronger dashboardManagementAllowed step-up below.
function dashboardPasskeyManagementAllowed(
  authorization: DashboardSessionAuthorizationRow | null,
): boolean {
  return authorization !== null;
}

function dashboardCookieToken(request: Request): string | null {
  const cookie = request.headers.get("cookie");
  if (!cookie) return null;
  for (const part of cookie.split(";")) {
    const item = part.trim();
    const separator = item.indexOf("=");
    if (separator <= 0 || item.slice(0, separator) !== DASHBOARD_COOKIE_NAME) continue;
    const token = item.slice(separator + 1);
    return /^[A-Za-z0-9_-]{43}$/.test(token) ? token : null;
  }
  return null;
}

function dashboardSessionCookie(token: string, maximumAge: number): string {
  return `${DASHBOARD_COOKIE_NAME}=${token}; Path=/; Max-Age=${maximumAge}; HttpOnly; Secure; SameSite=Strict`;
}

async function dashboardSessionHash(
  env: Pick<Env, "REGISTRATION_ACCESS_KEY">,
  token: string,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(registrationAccessKey(env)),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`when-reset:dashboard-session:v1:${token}`),
  );
  return base64URL(new Uint8Array(signature));
}

async function dashboardAccessKeyGeneration(env: Env): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(registrationAccessKey(env)),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode("when-reset:dashboard-passkey-generation:v1"),
  );
  return base64URL(new Uint8Array(signature));
}

async function dashboardAuthMethods(env: Env, url: URL): Promise<Response> {
  const generation = await dashboardAccessKeyGeneration(env);
  const row = await env.DB.prepare(
    `SELECT 1 AS enabled FROM dashboard_passkeys
     WHERE rp_id = ? AND access_key_generation = ? LIMIT 1`
  ).bind(url.hostname, generation).first<{ enabled: number }>();
  return linkJSON({ passkey_enabled: row?.enabled === 1 });
}

async function dashboardPasskeySummary(request: Request, env: Env, url: URL): Promise<Response> {
  const authorization = await dashboardSessionAuthorization(request, env);
  if (!authorization) return linkJSON({ error: "unauthorized" }, 401);
  const generation = await dashboardAccessKeyGeneration(env);
  const row = await env.DB.prepare(
    `SELECT COUNT(*) AS count FROM dashboard_passkeys
     WHERE rp_id = ? AND access_key_generation = ?`
  ).bind(url.hostname, generation).first<{ count: number }>();
  return linkJSON({
    count: Math.max(0, Number(row?.count ?? 0)),
    can_manage: dashboardPasskeyManagementAllowed(authorization),
  });
}

async function reverifyDashboardAccessKey(request: Request, env: Env): Promise<Response> {
  const authorization = await dashboardSessionAuthorization(request, env);
  if (!authorization) return linkJSON({ error: "unauthorized" }, 401);
  if (!(await registrationAccessAllowed(request, env))) {
    return linkJSON({ error: "unauthorized" }, 401);
  }
  const now = Math.floor(Date.now() / 1_000);
  await env.DB.prepare(
    `UPDATE dashboard_session_authorizations SET key_verified_until = ?
     WHERE token_hash = ?`
  ).bind(now + DASHBOARD_KEY_GRANT_TTL_SECONDS, authorization.token_hash).run();
  console.log(JSON.stringify({ event: "dashboard_access_key_reverified" }));
  return new Response(null, { status: 204, headers: linkSecurityHeaders() });
}

async function createPasskeyRegistrationOptions(
  request: Request,
  env: Env,
  url: URL,
): Promise<Response> {
  if (!(await hasEmptyJSONBody(request))) return linkJSON({ error: "invalid_request" }, 400);
  const authorization = await dashboardSessionAuthorization(request, env);
  if (!authorization) return linkJSON({ error: "unauthorized" }, 401);
  if (!dashboardPasskeyManagementAllowed(authorization)) {
    return linkJSON({ error: "access_key_verification_required" }, 403);
  }
  const identity = await dashboardWebAuthnIdentity(env, url.hostname);
  const generation = await dashboardAccessKeyGeneration(env);
  await env.DB.prepare(
    `DELETE FROM dashboard_passkeys
     WHERE rp_id = ? AND access_key_generation <> ?`
  ).bind(url.hostname, generation).run();
  const options = await generateRegistrationOptions({
    rpName: "When Reset",
    rpID: url.hostname,
    userID: new Uint8Array(base64URLBytes(identity.user_handle)),
    userName: "When Reset operator",
    userDisplayName: "When Reset operator",
    timeout: WEBAUTHN_CHALLENGE_TTL_SECONDS * 1_000,
    attestationType: "none",
    supportedAlgorithmIDs: [-7],
    authenticatorSelection: {
      residentKey: "required",
      requireResidentKey: true,
      userVerification: "required",
    },
  });
  const transactionID = await storeWebAuthnChallenge(env, {
    purpose: "registration",
    challenge: options.challenge,
    origin: url.origin,
    rpID: url.hostname,
    sessionTokenHash: authorization.token_hash,
  });
  if (!transactionID) return linkJSON({ error: "too_many_requests" }, 429);
  return linkJSON({ transaction_id: transactionID, options });
}

async function verifyPasskeyRegistration(
  request: Request,
  env: Env,
  url: URL,
): Promise<Response> {
  const body = await parsePasskeyVerificationBody(request, "registration");
  if (!body) return linkJSON({ error: "invalid_request" }, 400);
  const authorization = await dashboardSessionAuthorization(request, env);
  if (!authorization) return linkJSON({ error: "unauthorized" }, 401);
  if (!dashboardPasskeyManagementAllowed(authorization)) {
    return linkJSON({ error: "access_key_verification_required" }, 403);
  }
  const transaction = await consumeWebAuthnChallenge(
    env, body.transaction_id, "registration", url, authorization.token_hash,
  );
  if (!transaction) return passkeyVerificationFailed();
  try {
    if (!webAuthnClientDataIsTopLevel(body.credential.response.clientDataJSON)) {
      return passkeyVerificationFailed();
    }
    const verification = await verifyRegistrationResponse({
      response: body.credential,
      expectedChallenge: transaction.challenge,
      expectedOrigin: transaction.origin,
      expectedRPID: transaction.rp_id,
      requireUserPresence: true,
      requireUserVerification: true,
      supportedAlgorithmIDs: [-7],
    });
    if (!verification.verified || !verification.registrationInfo.userVerified) {
      return passkeyVerificationFailed();
    }
    const identity = await dashboardWebAuthnIdentity(env, url.hostname);
    const credential = verification.registrationInfo.credential;
    const publicKey = new Uint8Array(credential.publicKey).buffer;
    const now = Math.floor(Date.now() / 1_000);
    await env.DB.prepare(
      `INSERT INTO dashboard_passkeys (
         credential_id, user_handle, rp_id, public_key, counter, transports_json,
         access_key_generation, created_at, last_used_at
       ) VALUES (?, ?, ?, ?, ?, '[]', ?, ?, NULL)`
    ).bind(
      credential.id,
      identity.user_handle,
      url.hostname,
      publicKey,
      credential.counter,
      await dashboardAccessKeyGeneration(env),
      now,
    ).run();
    console.log(JSON.stringify({ event: "dashboard_passkey_registered" }));
    return new Response(null, { status: 204, headers: linkSecurityHeaders() });
  } catch (error) {
    console.warn(JSON.stringify({
      event: "dashboard_passkey_registration_rejected",
      error: safeError(error),
    }));
    return passkeyVerificationFailed();
  }
}

async function createPasskeyAuthenticationOptions(
  request: Request,
  env: Env,
  url: URL,
): Promise<Response> {
  if (!(await hasEmptyJSONBody(request))) return linkJSON({ error: "invalid_request" }, 400);
  const generation = await dashboardAccessKeyGeneration(env);
  const existing = await env.DB.prepare(
    `SELECT 1 AS enabled FROM dashboard_passkeys
     WHERE rp_id = ? AND access_key_generation = ? LIMIT 1`
  ).bind(url.hostname, generation).first<{ enabled: number }>();
  if (!existing) return linkJSON({ error: "passkey_unavailable" }, 404);
  const options = await generateAuthenticationOptions({
    rpID: url.hostname,
    timeout: WEBAUTHN_CHALLENGE_TTL_SECONDS * 1_000,
    userVerification: "required",
  });
  delete options.allowCredentials;
  const transactionID = await storeWebAuthnChallenge(env, {
    purpose: "authentication",
    challenge: options.challenge,
    origin: url.origin,
    rpID: url.hostname,
    sessionTokenHash: null,
  });
  if (!transactionID) return linkJSON({ error: "too_many_requests" }, 429);
  return linkJSON({ transaction_id: transactionID, options });
}

async function verifyPasskeyAuthentication(
  request: Request,
  env: Env,
  url: URL,
): Promise<Response> {
  const body = await parsePasskeyVerificationBody(request, "authentication");
  if (!body) return linkJSON({ error: "invalid_request" }, 400);
  const transaction = await consumeWebAuthnChallenge(
    env, body.transaction_id, "authentication", url, null,
  );
  if (!transaction) return passkeyVerificationFailed();
  try {
    if (!webAuthnClientDataIsTopLevel(body.credential.response.clientDataJSON)) {
      return passkeyVerificationFailed();
    }
    const generation = await dashboardAccessKeyGeneration(env);
    const passkey = await env.DB.prepare(
      `SELECT credential_id, user_handle, public_key, counter, transports_json
       FROM dashboard_passkeys
       WHERE credential_id = ? AND rp_id = ? AND access_key_generation = ?`
    ).bind(body.credential.id, url.hostname, generation).first<DashboardPasskeyRow>();
    if (!passkey || body.credential.response.userHandle !== passkey.user_handle) {
      return passkeyVerificationFailed();
    }
    const verification = await verifyAuthenticationResponse({
      response: body.credential,
      expectedChallenge: transaction.challenge,
      expectedOrigin: transaction.origin,
      expectedRPID: transaction.rp_id,
      credential: {
        id: passkey.credential_id,
        publicKey: new Uint8Array(passkey.public_key),
        counter: passkey.counter,
      },
      requireUserVerification: true,
    });
    if (!verification.verified || !verification.authenticationInfo.userVerified) {
      return passkeyVerificationFailed();
    }
    const newCounter = verification.authenticationInfo.newCounter;
    const now = Math.floor(Date.now() / 1_000);
    const counterUpdate = await env.DB.prepare(
      `UPDATE dashboard_passkeys SET counter = ?, last_used_at = ?
       WHERE credential_id = ? AND access_key_generation = ? AND counter = ?`
    ).bind(newCounter, now, passkey.credential_id, generation, passkey.counter).run();
    if ((counterUpdate.meta.changes ?? 0) !== 1) return passkeyVerificationFailed();
    const token = randomBase64URL(32);
    const tokenHash = await dashboardSessionHash(env, token);
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO dashboard_sessions (token_hash, created_at, expires_at) VALUES (?, ?, ?)`
      ).bind(tokenHash, now, now + DASHBOARD_SESSION_TTL_SECONDS),
      env.DB.prepare(
        `INSERT INTO dashboard_session_authorizations (
           token_hash, auth_method, key_verified_until, passkey_rp_id
         ) VALUES (?, 'passkey', NULL, ?)`
      ).bind(tokenHash, url.hostname),
    ]);
    console.log(JSON.stringify({ event: "dashboard_passkey_authenticated" }));
    return new Response(null, {
      status: 204,
      headers: linkSecurityHeaders({
        "set-cookie": dashboardSessionCookie(token, DASHBOARD_SESSION_TTL_SECONDS),
      }),
    });
  } catch {
    return passkeyVerificationFailed();
  }
}

async function deleteDashboardPasskeys(request: Request, env: Env, url: URL): Promise<Response> {
  const authorization = await dashboardSessionAuthorization(request, env);
  if (!authorization) return linkJSON({ error: "unauthorized" }, 401);
  if (!dashboardPasskeyManagementAllowed(authorization)) {
    return linkJSON({ error: "access_key_verification_required" }, 403);
  }
  await env.DB.batch([
    env.DB.prepare(
      `DELETE FROM dashboard_sessions WHERE token_hash IN (
         SELECT token_hash FROM dashboard_session_authorizations
         WHERE auth_method = 'passkey' AND passkey_rp_id = ?
       ) OR token_hash = ?`
    ).bind(url.hostname, authorization.token_hash),
    env.DB.prepare(
      `DELETE FROM dashboard_session_authorizations
       WHERE auth_method = 'passkey' AND passkey_rp_id = ?`
    ).bind(url.hostname),
    env.DB.prepare("DELETE FROM dashboard_passkeys WHERE rp_id = ?").bind(url.hostname),
    env.DB.prepare("DELETE FROM dashboard_webauthn_challenges WHERE rp_id = ?")
      .bind(url.hostname),
  ]);
  console.log(JSON.stringify({ event: "dashboard_passkeys_deleted" }));
  return new Response(null, {
    status: 204,
    headers: linkSecurityHeaders({ "set-cookie": dashboardSessionCookie("", 0) }),
  });
}

async function dashboardWebAuthnIdentity(
  env: Env,
  rpID: string,
): Promise<{ user_handle: string }> {
  await env.DB.prepare(
    `INSERT OR IGNORE INTO dashboard_webauthn_identities (rp_id, user_handle, created_at)
     VALUES (?, ?, ?)`
  ).bind(rpID, randomBase64URL(32), Math.floor(Date.now() / 1_000)).run();
  const identity = await env.DB.prepare(
    "SELECT user_handle FROM dashboard_webauthn_identities WHERE rp_id = ?"
  ).bind(rpID).first<{ user_handle: string }>();
  if (!identity) throw new Error("Could not create WebAuthn identity");
  return identity;
}

async function storeWebAuthnChallenge(
  env: Env,
  value: {
    purpose: "authentication" | "registration";
    challenge: string;
    origin: string;
    rpID: string;
    sessionTokenHash: string | null;
  },
): Promise<string | null> {
  const now = Math.floor(Date.now() / 1_000);
  await pruneWebAuthnChallenges(env, now);
  const transactionID = randomBase64URL(32);
  const result = await env.DB.prepare(
    `INSERT INTO dashboard_webauthn_challenges (
       transaction_id, purpose, challenge, origin, rp_id, session_token_hash,
       created_at, expires_at, consumed_at
     ) SELECT ?, ?, ?, ?, ?, ?, ?, ?, NULL
       WHERE (SELECT COUNT(*) FROM dashboard_webauthn_challenges
              WHERE consumed_at IS NULL AND expires_at > ?) < ?`
  ).bind(
    transactionID,
    value.purpose,
    value.challenge,
    value.origin,
    value.rpID,
    value.sessionTokenHash,
    now,
    now + WEBAUTHN_CHALLENGE_TTL_SECONDS,
    now,
    MAX_ACTIVE_WEBAUTHN_CHALLENGES,
  ).run();
  return (result.meta.changes ?? 0) === 1 ? transactionID : null;
}

async function consumeWebAuthnChallenge(
  env: Env,
  transactionID: string,
  purpose: "authentication" | "registration",
  url: URL,
  sessionTokenHash: string | null,
): Promise<DashboardWebAuthnChallengeRow | null> {
  const now = Math.floor(Date.now() / 1_000);
  const row = await env.DB.prepare(
    `SELECT transaction_id, purpose, challenge, origin, rp_id, session_token_hash, expires_at
     FROM dashboard_webauthn_challenges WHERE transaction_id = ?`
  ).bind(transactionID).first<DashboardWebAuthnChallengeRow>();
  if (!row) return null;
  const result = await env.DB.prepare(
    `UPDATE dashboard_webauthn_challenges SET consumed_at = ?
     WHERE transaction_id = ? AND purpose = ? AND origin = ? AND rp_id = ?
       AND session_token_hash IS ? AND consumed_at IS NULL AND expires_at > ?`
  ).bind(
    now,
    transactionID,
    purpose,
    url.origin,
    url.hostname,
    sessionTokenHash,
    now,
  ).run();
  return (result.meta.changes ?? 0) === 1 ? row : null;
}

async function pruneWebAuthnChallenges(env: Env, now: number): Promise<void> {
  await env.DB.prepare(
    "DELETE FROM dashboard_webauthn_challenges WHERE expires_at <= ? OR consumed_at IS NOT NULL"
  ).bind(now).run();
}

function passkeyVerificationFailed(): Response {
  return linkJSON({ error: "passkey_verification_failed" }, 401);
}

async function dashboardOverview(env: Env): Promise<Response> {
  const now = Math.floor(Date.now() / 1_000);
  const [groups, deviceSummary, runSummary, resetSummary] = await Promise.all([
    loadDashboardAccountGroups(env),
    env.DB.prepare(
      `SELECT COUNT(*) AS total,
              SUM(CASE WHEN last_seen_at >= ? THEN 1 ELSE 0 END) AS active,
              SUM(CASE WHEN push_disabled_at IS NOT NULL THEN 1 ELSE 0 END) AS push_disabled,
              SUM(CASE WHEN apns_environment = 'production' THEN 1 ELSE 0 END) AS production,
              SUM(CASE WHEN apns_environment = 'development' THEN 1 ELSE 0 END) AS development
       FROM devices`
    ).bind(now - ACTIVE_DEVICE_DAYS * 86_400).first<{
      total: number;
      active: number | null;
      push_disabled: number | null;
      production: number | null;
      development: number | null;
    }>(),
    env.DB.prepare(
      `SELECT SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END) AS pending,
              SUM(CASE WHEN status IN ('running', 'fetched') THEN 1 ELSE 0 END) AS running,
              SUM(CASE WHEN status = 'failed' AND created_at >= ? THEN 1 ELSE 0 END) AS failed_24h,
              SUM(CASE WHEN status = 'succeeded' AND created_at >= ? THEN 1 ELSE 0 END) AS succeeded_24h,
              MAX(completed_at) AS last_completed_at
       FROM monitor_runs`
    ).bind(now - 86_400, now - 86_400).first<{
      pending: number | null;
      running: number | null;
      failed_24h: number | null;
      succeeded_24h: number | null;
      last_completed_at: number | null;
    }>(),
    env.DB.prepare(
      `SELECT MIN(reset_at) AS nearest_reset_at
       FROM (
         SELECT CAST(json_extract(quota.value, '$.resets_at') AS INTEGER) AS reset_at
         FROM monitored_accounts
         INNER JOIN account_monitoring_consent
           ON account_monitoring_consent.device_id = monitored_accounts.device_id
          AND account_monitoring_consent.account_id = monitored_accounts.account_id
          AND account_monitoring_consent.enabled = 1
         INNER JOIN json_each(
           CASE
             WHEN json_valid(monitored_accounts.latest_snapshot)
              AND json_extract(monitored_accounts.latest_snapshot, '$.provider_id')
                  = monitored_accounts.provider_id
             THEN COALESCE(json_extract(monitored_accounts.latest_snapshot, '$.windows'), '[]')
             ELSE '[]'
           END
         ) AS quota
         UNION ALL
         SELECT CAST(json_extract(quota.value, '$.resets_at') AS INTEGER) AS reset_at
         FROM device_snapshot_sources
         INNER JOIN device_snapshot_consent
           ON device_snapshot_consent.device_id = device_snapshot_sources.device_id
          AND device_snapshot_consent.account_id = device_snapshot_sources.account_id
          AND device_snapshot_consent.enabled = 1
         INNER JOIN json_each(
           CASE
             WHEN json_valid(device_snapshot_sources.latest_snapshot)
              AND json_extract(device_snapshot_sources.latest_snapshot, '$.provider_id')
                  = device_snapshot_sources.provider_id
             THEN COALESCE(
               json_extract(device_snapshot_sources.latest_snapshot, '$.windows'), '[]'
             )
             ELSE '[]'
           END
         ) AS quota
       )
       WHERE reset_at > ?`
    ).bind(now).first<{ nearest_reset_at: number | null }>(),
  ]);

  let healthy = 0;
  let attention = 0;
  let unchecked = 0;
  let lastSuccessAt: number | null = null;
  for (const group of groups.groups) {
    const row = group.representative;
    const session = dashboardAccountSession(row, now);
    if (session.status === "active") healthy += 1;
    else if (session.status === "unchecked") unchecked += 1;
    else attention += 1;
    if (row.last_success_at !== null) {
      lastSuccessAt = lastSuccessAt === null
        ? row.last_success_at : Math.max(lastSuccessAt, row.last_success_at);
    }
  }

  const displayedGroups = groups.groups.slice(0, DASHBOARD_ACCOUNT_LIMIT);
  const snapshots = await loadDashboardSnapshots(env, displayedGroups);
  const accounts = displayedGroups.map((group) => {
    const selected = snapshots.get(group.id) ?? null;
    const row = selected?.row ?? group.representative;
    const session = dashboardAccountSession(row, now);
    return {
      id: group.id,
      provider_id: row.provider_id,
      provider_name: providerDisplayName(row.provider_id),
      display_name: safeDashboardText(row.display_name, 128)
        ?? providerDisplayName(row.provider_id),
      plan: safeDashboardText(row.plan, 200),
      plan_expires_at: safeDashboardTimestamp(row.plan_expires_at),
      trial_expires_at: safeDashboardTimestamp(row.trial_expires_at),
      status: session.status,
      last_checked_at: session.checkedAt,
      last_success_at: safeDashboardTimestamp(row.last_success_at),
      next_refresh_at: safeDashboardTimestamp(row.next_refresh_at),
      refresh_interval_seconds: row.source_kind === "device"
          && row.refresh_interval_seconds === 0 ? 0 : boundedDashboardInteger(
        row.refresh_interval_seconds, MIN_MONITOR_INTERVAL_SECONDS, MAX_MONITOR_INTERVAL_SECONDS
      ),
      history_retention_days: boundedDashboardInteger(
        row.history_retention_days, MIN_HISTORY_RETENTION_DAYS, MAX_HISTORY_RETENTION_DAYS
      ),
      source: selected?.source ?? row.source_kind,
      source_count: new Set(
        group.rows.map((source) => `${source.device_id}\u0000${source.account_id}`)
      ).size,
      snapshot: selected?.snapshot ?? null,
    };
  });

  return dashboardJSON({
    version: 1,
    generated_at: now,
    summary: {
      accounts: groups.groups.length,
      shown_accounts: accounts.length,
      healthy,
      attention,
      unchecked,
      last_success_at: lastSuccessAt,
      nearest_reset_at: safeDashboardTimestamp(resetSummary?.nearest_reset_at),
      truncated: groups.incomplete || groups.groups.length > accounts.length,
    },
    devices: {
      total: deviceSummary?.total ?? 0,
      active: deviceSummary?.active ?? 0,
      push_disabled: deviceSummary?.push_disabled ?? 0,
      production: deviceSummary?.production ?? 0,
      development: deviceSummary?.development ?? 0,
    },
    runs: {
      pending: runSummary?.pending ?? 0,
      running: runSummary?.running ?? 0,
      failed_24h: runSummary?.failed_24h ?? 0,
      succeeded_24h: runSummary?.succeeded_24h ?? 0,
      last_completed_at: runSummary?.last_completed_at ?? null,
    },
    accounts,
  }, "overview");
}

type DashboardAccountDeleteMode = "preserve" | "purge";

async function deleteDashboardAccount(
  request: Request,
  env: Env,
  dashboardID: string,
  url: URL,
): Promise<Response> {
  const authorization = await dashboardSessionAuthorization(request, env);
  if (!authorization) return linkJSON({ error: "unauthorized" }, 401);
  if (!dashboardManagementAllowed(authorization)) {
    return linkJSON({ error: "access_key_verification_required" }, 403);
  }
  const modeValue = url.searchParams.get("mode") ?? "preserve";
  if (modeValue !== "preserve" && modeValue !== "purge") {
    return linkJSON({ error: "invalid_delete_mode" }, 400);
  }
  const mode = modeValue as DashboardAccountDeleteMode;
  const loaded = await loadDashboardAccountGroups(env);
  if (loaded.incomplete) {
    return linkJSON({ error: "account_index_incomplete" }, 503);
  }
  const group = loaded.groups.find((candidate) => candidate.id === dashboardID);
  if (!group) return linkJSON({ error: "account_not_found" }, 404);

  const now = Math.floor(Date.now() / 1_000);
  const statements: D1PreparedStatement[] = [];
  const seen = new Set<string>();
  for (const source of group.rows) {
    const sourceKey = `${source.source_kind}\u0000${source.device_id}\u0000${source.account_id}`;
    if (seen.has(sourceKey)) continue;
    seen.add(sourceKey);
    if (source.source_kind === "worker") {
      if (mode === "preserve") {
        statements.push(
          env.DB.prepare(
            `INSERT INTO dashboard_account_archives (
               device_id, account_id, provider_id, workspace_id, display_name, plan,
               plan_expires_at, trial_expires_at, missing_quotas, latest_snapshot,
               last_refresh_at, last_success_at, refresh_interval_seconds,
               history_retention_days, archived_at
             )
             SELECT device_id, account_id, provider_id, workspace_id, display_name, plan,
                    plan_expires_at, trial_expires_at, missing_quotas, latest_snapshot,
                    last_refresh_at, last_success_at, refresh_interval_seconds,
                    history_retention_days, ?
             FROM monitored_accounts
             WHERE device_id = ? AND account_id = ?
               AND EXISTS (
                 SELECT 1 FROM account_monitoring_consent
                 WHERE device_id = ? AND account_id = ? AND enabled = 1
               )
             ON CONFLICT(device_id, account_id) DO UPDATE SET
               provider_id = excluded.provider_id,
               workspace_id = excluded.workspace_id,
               display_name = excluded.display_name,
               plan = excluded.plan,
               plan_expires_at = excluded.plan_expires_at,
               trial_expires_at = excluded.trial_expires_at,
               missing_quotas = excluded.missing_quotas,
               latest_snapshot = excluded.latest_snapshot,
               last_refresh_at = excluded.last_refresh_at,
               last_success_at = excluded.last_success_at,
               refresh_interval_seconds = excluded.refresh_interval_seconds,
               history_retention_days = excluded.history_retention_days,
               archived_at = excluded.archived_at`
          ).bind(
            now, source.device_id, source.account_id, source.device_id, source.account_id,
          ),
          env.DB.prepare(
            `INSERT OR IGNORE INTO dashboard_account_archive_history (
               device_id, account_id, provider_id, metric_id, metric_title, kind,
               window_minutes, remaining_percent, recorded_at, resets_at,
               seconds_until_reset, plan
             )
             SELECT device_id, account_id, provider_id, metric_id, metric_title, kind,
                    window_minutes, remaining_percent, recorded_at, resets_at,
                    seconds_until_reset, plan
             FROM usage_history
             WHERE device_id = ? AND account_id = ?`
          ).bind(source.device_id, source.account_id),
        );
      } else {
        statements.push(
          env.DB.prepare(
            `DELETE FROM dashboard_account_archives
             WHERE device_id = ? AND account_id = ?`
          ).bind(source.device_id, source.account_id),
          env.DB.prepare(
            `DELETE FROM dashboard_account_archive_history
             WHERE device_id = ? AND account_id = ?`
          ).bind(source.device_id, source.account_id),
        );
      }
      statements.push(
        env.DB.prepare(
          `DELETE FROM usage_history WHERE device_id = ? AND account_id = ?`
        ).bind(source.device_id, source.account_id),
        env.DB.prepare(
          `DELETE FROM monitored_accounts WHERE device_id = ? AND account_id = ?`
        ).bind(source.device_id, source.account_id),
        env.DB.prepare(
          `DELETE FROM account_monitoring_consent WHERE device_id = ? AND account_id = ?`
        ).bind(source.device_id, source.account_id),
      );
    } else if (mode === "purge") {
      statements.push(
        env.DB.prepare(
          `DELETE FROM device_snapshot_history WHERE device_id = ? AND account_id = ?`
        ).bind(source.device_id, source.account_id),
        env.DB.prepare(
          `DELETE FROM device_snapshot_sources WHERE device_id = ? AND account_id = ?`
        ).bind(source.device_id, source.account_id),
        env.DB.prepare(
          `DELETE FROM device_snapshot_consent WHERE device_id = ? AND account_id = ?`
        ).bind(source.device_id, source.account_id),
      );
    } else {
      statements.push(
        env.DB.prepare(
          `UPDATE device_snapshot_consent SET enabled = 0, updated_at = ?
           WHERE device_id = ? AND account_id = ?`
        ).bind(now, source.device_id, source.account_id),
      );
    }
  }
  if (statements.length === 0) return linkJSON({ error: "account_not_found" }, 404);
  // A single group can contain several physical copies. Keep the operation bounded
  // to the already bounded dashboard group and let D1 execute the changes atomically.
  await env.DB.batch(statements);
  console.log(JSON.stringify({
    event: mode === "preserve" ? "dashboard_account_detached" : "dashboard_account_deleted",
    sources: seen.size,
  }));
  return linkJSON({
    ok: true,
    mode,
    retained_data: mode === "preserve",
  }, 200, { "cache-control": "no-store" });
}

type DashboardDeviceRow = {
  device_id: string;
  secret_hash: string;
  apns_environment: string;
  created_at: number;
  last_seen_at: number;
  last_push_at: number | null;
  push_disabled_at: number | null;
  monitored_accounts: number | null;
  published_accounts: number | null;
  subscriptions: number | null;
};

// Device rows are addressed by an HMAC handle so the dashboard never receives, renders, or
// echoes a real device identifier. The same key already anonymizes account rows.
async function dashboardDeviceID(key: CryptoKey, deviceID: string): Promise<string> {
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`when-reset:dashboard-device:v1:${deviceID}`),
  );
  return base64URL(new Uint8Array(signature));
}

// A short, stable, unambiguous nickname so a person can tell two linked devices apart without
// the Worker ever exposing the device identifier itself.
function dashboardDeviceLabel(handle: string): string {
  const alphabet = "23456789ABCDEFGHJKMNPQRSTVWXYZ";
  let label = "";
  for (let index = 0; index < 4; index += 1) {
    const code = handle.charCodeAt(index) + index * 7;
    label += alphabet[code % alphabet.length];
  }
  return label;
}

async function loadDashboardDeviceRows(env: Env): Promise<DashboardDeviceRow[]> {
  const result = await env.DB.prepare(
    `SELECT devices.device_id, devices.secret_hash, devices.apns_environment,
            devices.created_at, devices.last_seen_at, devices.last_push_at,
            devices.push_disabled_at,
            (SELECT COUNT(*) FROM monitored_accounts
              INNER JOIN account_monitoring_consent
                ON account_monitoring_consent.device_id = monitored_accounts.device_id
               AND account_monitoring_consent.account_id = monitored_accounts.account_id
               AND account_monitoring_consent.enabled = 1
              WHERE monitored_accounts.device_id = devices.device_id) AS monitored_accounts,
            (SELECT COUNT(*) FROM device_snapshot_sources
              INNER JOIN device_snapshot_consent
                ON device_snapshot_consent.device_id = device_snapshot_sources.device_id
               AND device_snapshot_consent.account_id = device_snapshot_sources.account_id
               AND device_snapshot_consent.enabled = 1
              WHERE device_snapshot_sources.device_id = devices.device_id) AS published_accounts,
            (SELECT COUNT(*) FROM remote_account_subscriptions
              WHERE remote_account_subscriptions.subscriber_device_id = devices.device_id)
              AS subscriptions
     FROM devices
     ORDER BY devices.last_seen_at DESC, devices.device_id
     LIMIT ?`
  ).bind(DASHBOARD_DEVICE_LIMIT + 1).all<DashboardDeviceRow>();
  return result.results;
}

async function dashboardDevices(env: Env, authorization: DashboardSessionAuthorizationRow):
  Promise<Response> {
  const now = Math.floor(Date.now() / 1_000);
  const rows = await loadDashboardDeviceRows(env);
  const truncated = rows.length > DASHBOARD_DEVICE_LIMIT;
  const shown = rows.slice(0, DASHBOARD_DEVICE_LIMIT);
  const key = await credentialFingerprintKey(env);
  const activeSince = now - ACTIVE_DEVICE_DAYS * 86_400;
  const devices = await Promise.all(shown.map(async (row) => {
    const handle = await dashboardDeviceID(key, row.device_id);
    return {
      id: handle,
      label: dashboardDeviceLabel(handle),
      environment: row.apns_environment === "development" ? "development" : "production",
      created_at: safeDashboardTimestamp(row.created_at),
      last_seen_at: safeDashboardTimestamp(row.last_seen_at),
      last_push_at: safeDashboardTimestamp(row.last_push_at),
      push_disabled_at: safeDashboardTimestamp(row.push_disabled_at),
      push_enabled: row.push_disabled_at === null,
      active: row.last_seen_at >= activeSince,
      retired: row.push_disabled_at !== null && row.last_seen_at < activeSince,
      monitored_accounts: Math.max(0, Number(row.monitored_accounts ?? 0)),
      published_accounts: Math.max(0, Number(row.published_accounts ?? 0)),
      subscriptions: Math.max(0, Number(row.subscriptions ?? 0)),
    };
  }));
  return dashboardJSON({
    version: 1,
    generated_at: now,
    can_manage: dashboardManagementAllowed(authorization, now),
    truncated,
    devices,
  }, "devices");
}

async function resolveDashboardDevice(
  env: Env,
  handle: string,
): Promise<DashboardDeviceRow | null> {
  const key = await credentialFingerprintKey(env);
  for (const row of await loadDashboardDeviceRows(env)) {
    if (timingSafeEqualStrings(await dashboardDeviceID(key, row.device_id), handle)) return row;
  }
  return null;
}

async function updateDashboardDevice(
  request: Request,
  env: Env,
  handle: string,
): Promise<Response> {
  const authorization = await dashboardSessionAuthorization(request, env);
  if (!authorization) return linkJSON({ error: "unauthorized" }, 401);
  if (!dashboardManagementAllowed(authorization)) {
    return linkJSON({ error: "access_key_verification_required" }, 403);
  }
  const body = await boundedRequestJSON(request, MAX_DEVICE_TOKEN_BODY_BYTES);
  if (!isRecord(body) || typeof body.push_enabled !== "boolean"
      || Object.keys(body).length !== 1) {
    return linkJSON({ error: "invalid_device_update" }, 400);
  }
  const device = await resolveDashboardDevice(env, handle);
  if (!device) return linkJSON({ error: "device_not_found" }, 404);
  const now = Math.floor(Date.now() / 1_000);
  // Re-pinning the row to its secret hash keeps a concurrent re-registration from being
  // silently overwritten by a stale dashboard view.
  const result = await env.DB.prepare(
    `UPDATE devices SET push_disabled_at = ?
     WHERE device_id = ? AND secret_hash = ?`
  ).bind(body.push_enabled ? null : now, device.device_id, device.secret_hash).run();
  if ((result.meta.changes ?? 0) !== 1) {
    return linkJSON({ error: "device_not_found" }, 404);
  }
  console.log(JSON.stringify({
    event: body.push_enabled ? "dashboard_device_push_enabled" : "dashboard_device_push_disabled",
  }));
  return linkJSON({ ok: true, push_enabled: body.push_enabled });
}

async function deleteDashboardDevice(
  request: Request,
  env: Env,
  handle: string,
): Promise<Response> {
  const authorization = await dashboardSessionAuthorization(request, env);
  if (!authorization) return linkJSON({ error: "unauthorized" }, 401);
  if (!dashboardManagementAllowed(authorization)) {
    return linkJSON({ error: "access_key_verification_required" }, 403);
  }
  const device = await resolveDashboardDevice(env, handle);
  if (!device) return linkJSON({ error: "device_not_found" }, 404);
  const now = Math.floor(Date.now() / 1_000);
  // The batch reports the number of rows the delete touched, which grows with the device's
  // cascaded child rows. Confirm the registration is actually gone instead of trusting the count.
  for (let attempt = 0; attempt < 2; attempt += 1) {
    await tombstoneAndDeleteDeviceBySecretHash(
      env, device.device_id, device.secret_hash, now
    );
    const live = await env.DB.prepare(
      "SELECT 1 AS live FROM devices WHERE device_id = ? AND secret_hash = ?"
    ).bind(device.device_id, device.secret_hash).first<{ live: number }>();
    if (!live) {
      console.log(JSON.stringify({ event: "dashboard_device_unlinked" }));
      return linkJSON({ ok: true });
    }
  }
  return linkJSON({ error: "device_unlink_failed" }, 503);
}

async function dashboardAccountHistory(
  env: Env,
  dashboardID: string,
  url: URL,
): Promise<Response> {
  const rangeValues = url.searchParams.getAll("range");
  if (rangeValues.length > 1) return linkJSON({ error: "invalid_range" }, 400);
  const range = rangeValues[0] ?? "7d";
  const rangeSeconds = range === "24h" ? 86_400
    : range === "7d" ? 7 * 86_400
    : range === "30d" ? 30 * 86_400
    : null;
  if (rangeSeconds === null) return linkJSON({ error: "invalid_range" }, 400);

  const loaded = await loadDashboardAccountGroups(env);
  if (loaded.incomplete) {
    return linkJSON({ error: "account_index_incomplete" }, 503);
  }
  const group = loaded.groups.find((candidate) => candidate.id === dashboardID);
  if (!group) return linkJSON({ error: "account_not_found" }, 404);
  const now = Math.floor(Date.now() / 1_000);
  const since = now - rangeSeconds;
  const sources = JSON.stringify(group.rows.map((source) => [
    source.source_kind, source.device_id, source.account_id,
  ]));
  const historyResult = await env.DB.prepare(
    `WITH requested_sources AS (
       SELECT json_extract(value, '$[0]') AS source_kind,
              json_extract(value, '$[1]') AS device_id,
              json_extract(value, '$[2]') AS account_id
       FROM json_each(?)
     ), source_history AS (
       SELECT usage_history.device_id, usage_history.account_id,
              usage_history.metric_id, usage_history.metric_title,
              usage_history.kind, usage_history.window_minutes,
              usage_history.remaining_percent, usage_history.recorded_at,
              usage_history.resets_at, usage_history.plan
       FROM usage_history
       INNER JOIN requested_sources
         ON requested_sources.source_kind = 'worker'
        AND requested_sources.device_id = usage_history.device_id
        AND requested_sources.account_id = usage_history.account_id
       UNION ALL
       SELECT device_snapshot_history.device_id, device_snapshot_history.account_id,
              device_snapshot_history.metric_id, device_snapshot_history.metric_title,
              device_snapshot_history.kind, device_snapshot_history.window_minutes,
              device_snapshot_history.remaining_percent,
              device_snapshot_history.recorded_at,
              device_snapshot_history.resets_at, device_snapshot_history.plan
       FROM device_snapshot_history
       INNER JOIN requested_sources
         ON requested_sources.source_kind = 'device'
        AND requested_sources.device_id = device_snapshot_history.device_id
        AND requested_sources.account_id = device_snapshot_history.account_id
     ), ranked_history AS (
       SELECT source_history.metric_id, source_history.metric_title,
              source_history.kind, source_history.window_minutes,
              source_history.remaining_percent, source_history.recorded_at,
              source_history.resets_at, source_history.plan,
              ROW_NUMBER() OVER (
                PARTITION BY source_history.metric_id, source_history.recorded_at
                ORDER BY source_history.device_id, source_history.account_id
              ) AS duplicate_rank
       FROM source_history
       WHERE source_history.recorded_at >= ?
     )
     SELECT metric_id, metric_title, kind, window_minutes, remaining_percent,
            recorded_at, resets_at, plan
     FROM ranked_history
     WHERE duplicate_rank = 1
     ORDER BY recorded_at DESC, metric_id LIMIT ?`
  ).bind(sources, since, DASHBOARD_HISTORY_LIMIT + 1).all<DashboardHistoryRow>();

  const rawRows = historyResult.results;
  const truncated = rawRows.length > DASHBOARD_HISTORY_LIMIT;
  const deduplicated = new Map<string, DashboardHistoryRow>();
  for (const row of rawRows.slice(0, DASHBOARD_HISTORY_LIMIT)) {
    if (!Number.isFinite(row.recorded_at) || !Number.isFinite(row.remaining_percent)
        || !Number.isFinite(row.resets_at)) continue;
    const metricID = safeDashboardText(row.metric_id, 512);
    if (!metricID) continue;
    const key = `${metricID}\u0000${Math.floor(row.recorded_at)}`;
    if (!deduplicated.has(key)) deduplicated.set(key, row);
  }

  const seriesByMetric = new Map<string, {
    id: string;
    title: string;
    kind: string | null;
    window_minutes: number | null;
    points: Array<{
      recorded_at: number;
      remaining_percent: number;
      resets_at: number;
      plan: string | null;
    }>;
  }>();
  for (const row of deduplicated.values()) {
    const metricID = row.metric_id;
    let series = seriesByMetric.get(metricID);
    if (!series) {
      series = {
        id: await dashboardSeriesID(env, dashboardID, metricID),
        title: safeDashboardText(row.metric_title, 256) ?? "Quota",
        kind: dashboardWindowKind(row.kind),
        window_minutes: dashboardWindowMinutes(row.window_minutes),
        points: [],
      };
      seriesByMetric.set(metricID, series);
    }
    series.points.push({
      recorded_at: Math.floor(row.recorded_at),
      remaining_percent: clampDashboardPercent(row.remaining_percent),
      resets_at: Math.floor(row.resets_at),
      plan: safeDashboardText(row.plan, 200),
    });
  }
  const series = [...seriesByMetric.values()]
    .map((item) => ({ ...item, points: item.points.sort((a, b) => a.recorded_at - b.recorded_at) }))
    .sort((a, b) => a.title.localeCompare(b.title));
  const row = group.representative;
  return dashboardJSON({
    account: {
      id: dashboardID,
      provider_id: row.provider_id,
      provider_name: providerDisplayName(row.provider_id),
      display_name: safeDashboardText(row.display_name, 128)
        ?? providerDisplayName(row.provider_id),
      plan: safeDashboardText(row.plan, 200),
    },
    range,
    from: since,
    to: now,
    series,
    truncated,
  }, "history");
}

async function loadDashboardAccountGroups(env: Env): Promise<{
  groups: DashboardAccountGroup[];
  incomplete: boolean;
}> {
  const grouped = new Map<string, DashboardAccountGroup>();
  const dashboardKey = await credentialFingerprintKey(env);
  const [workerResult, deviceResult] = await Promise.all([
    env.DB.prepare(
      `SELECT 'worker' AS source_kind,
              monitored_accounts.device_id, monitored_accounts.account_id,
              monitored_accounts.provider_id, monitored_accounts.workspace_id,
              monitored_accounts.display_name, monitored_accounts.plan,
              monitored_accounts.plan_expires_at, monitored_accounts.trial_expires_at,
              monitored_accounts.refresh_interval_seconds,
              monitored_accounts.history_retention_days, monitored_accounts.next_refresh_at,
              monitored_accounts.last_refresh_at, monitored_accounts.last_success_at,
              monitored_accounts.last_error,
              CASE WHEN json_valid(monitored_accounts.latest_snapshot)
                  AND json_extract(monitored_accounts.latest_snapshot,
                    '$.account_reference_verified') = 1
                  AND json_extract(monitored_accounts.latest_snapshot,
                    '$.account_reference_scope') = 'provider_account_v2'
                THEN json_extract(monitored_accounts.latest_snapshot, '$.account_reference')
                ELSE NULL
              END AS dashboard_account_reference
       FROM monitored_accounts
       INNER JOIN account_monitoring_consent
         ON account_monitoring_consent.device_id = monitored_accounts.device_id
        AND account_monitoring_consent.account_id = monitored_accounts.account_id
        AND account_monitoring_consent.enabled = 1
       ORDER BY monitored_accounts.device_id, monitored_accounts.account_id
       LIMIT ?`
    ).bind(MAX_DASHBOARD_ACCOUNT_SOURCE_ROWS + 1).all<DashboardAccountRow>(),
    env.DB.prepare(
      `SELECT 'device' AS source_kind,
              device_snapshot_sources.device_id, device_snapshot_sources.account_id,
              device_snapshot_sources.provider_id, '' AS workspace_id,
              device_snapshot_sources.display_name, device_snapshot_sources.plan,
              NULL AS plan_expires_at, NULL AS trial_expires_at,
              device_snapshot_sources.refresh_interval_seconds,
              device_snapshot_sources.history_retention_days,
              CASE WHEN device_snapshot_sources.refresh_interval_seconds = 0
                THEN NULL
                ELSE MIN(device_snapshot_sources.last_observed_at,
                         device_snapshot_sources.last_upload_at)
                  + device_snapshot_sources.refresh_interval_seconds
              END AS next_refresh_at,
              MIN(device_snapshot_sources.last_observed_at,
                  device_snapshot_sources.last_upload_at) AS last_refresh_at,
              MIN(device_snapshot_sources.last_observed_at,
                  device_snapshot_sources.last_upload_at) AS last_success_at,
              NULL AS last_error,
              CASE WHEN json_valid(monitored_accounts_for_identity.latest_snapshot)
                  AND json_extract(monitored_accounts_for_identity.latest_snapshot,
                    '$.account_reference_verified') = 1
                  AND json_extract(monitored_accounts_for_identity.latest_snapshot,
                    '$.account_reference_scope') = 'provider_account_v2'
                THEN json_extract(monitored_accounts_for_identity.latest_snapshot,
                  '$.account_reference')
                ELSE NULL
              END AS dashboard_account_reference
       FROM device_snapshot_sources
       INNER JOIN device_snapshot_consent
         ON device_snapshot_consent.device_id = device_snapshot_sources.device_id
        AND device_snapshot_consent.account_id = device_snapshot_sources.account_id
        AND device_snapshot_consent.enabled = 1
       LEFT JOIN monitored_accounts AS monitored_accounts_for_identity
         ON monitored_accounts_for_identity.device_id = device_snapshot_sources.device_id
        AND monitored_accounts_for_identity.account_id = device_snapshot_sources.account_id
        AND monitored_accounts_for_identity.provider_id = device_snapshot_sources.provider_id
       ORDER BY device_snapshot_sources.device_id, device_snapshot_sources.account_id
       LIMIT ?`
    ).bind(MAX_DASHBOARD_ACCOUNT_SOURCE_ROWS + 1).all<DashboardAccountRow>(),
  ]);
  const combined = [...workerResult.results, ...deviceResult.results].sort((left, right) =>
    left.device_id.localeCompare(right.device_id)
      || left.account_id.localeCompare(right.account_id)
      || left.source_kind.localeCompare(right.source_kind)
  );
  const incomplete = combined.length > MAX_DASHBOARD_ACCOUNT_SOURCE_ROWS;
  const rows = combined.slice(0, MAX_DASHBOARD_ACCOUNT_SOURCE_ROWS);
  for (let offset = 0; offset < rows.length; offset += 50) {
    const identified = await Promise.all(rows.slice(offset, offset + 50).map(async (row) => ({
      row,
      id: isProviderID(row.provider_id) ? await dashboardAccountID(dashboardKey, row) : null,
    })));
    for (const { row, id } of identified) {
      if (!id) continue;
      const source = row;
      const existing = grouped.get(id);
      if (!existing) {
        grouped.set(id, { id, representative: row, rows: [source] });
        continue;
      }
      existing.rows.push(source);
      const rowFreshness = dashboardAccountFreshness(row);
      const existingFreshness = dashboardAccountFreshness(existing.representative);
      if (rowFreshness > existingFreshness
          || (rowFreshness === existingFreshness && row.source_kind === "device")) {
        existing.representative = row;
      }
    }
  }
  const groups = [...grouped.values()].sort((a, b) => {
    const freshness = dashboardAccountFreshness(b.representative)
      - dashboardAccountFreshness(a.representative);
    if (freshness !== 0) return freshness;
    return providerDisplayName(a.representative.provider_id)
      .localeCompare(providerDisplayName(b.representative.provider_id));
  });
  return { groups, incomplete };
}

async function loadDashboardSnapshots(
  env: Env,
  groups: DashboardAccountGroup[],
): Promise<Map<string, DashboardSnapshotSelection | null>> {
  const snapshots = new Map<string, DashboardSnapshotSelection | null>();
  for (let offset = 0; offset < groups.length; offset += DASHBOARD_SNAPSHOT_LOAD_BATCH_SIZE) {
    const batch = groups.slice(offset, offset + DASHBOARD_SNAPSHOT_LOAD_BATCH_SIZE);
    const requested = batch.flatMap((group, groupPosition) => {
      const preferred = group.representative;
      const fallbacks = group.rows.filter((source) =>
        source.source_kind !== preferred.source_kind
          || source.device_id !== preferred.device_id
          || source.account_id !== preferred.account_id
      );
      return [preferred, ...fallbacks].map((source) => [
        groupPosition,
        source.source_kind,
        source.device_id,
        source.account_id,
      ]);
    });
    const sources = JSON.stringify(requested);
    const result = await env.DB.prepare(
      `WITH requested_sources AS (
       SELECT CAST(key AS INTEGER) AS source_position,
                CAST(json_extract(value, '$[0]') AS INTEGER) AS group_position,
                json_extract(value, '$[1]') AS source_kind,
                json_extract(value, '$[2]') AS device_id,
                json_extract(value, '$[3]') AS account_id
         FROM json_each(?)
       )
       SELECT requested_sources.source_position, requested_sources.group_position,
              requested_sources.source_kind,
              COALESCE(monitored_accounts.provider_id,
                       device_snapshot_sources.provider_id) AS provider_id,
              CASE WHEN requested_sources.source_kind = 'worker'
                  AND length(CAST(monitored_accounts.latest_snapshot AS BLOB)) <= ?
                THEN monitored_accounts.latest_snapshot
                WHEN requested_sources.source_kind = 'device'
                  AND length(CAST(device_snapshot_sources.latest_snapshot AS BLOB)) <= ?
                THEN device_snapshot_sources.latest_snapshot
                ELSE NULL
              END AS latest_snapshot
       FROM requested_sources
       LEFT JOIN monitored_accounts
         ON requested_sources.source_kind = 'worker'
        AND monitored_accounts.device_id = requested_sources.device_id
        AND monitored_accounts.account_id = requested_sources.account_id
       LEFT JOIN device_snapshot_sources
         ON requested_sources.source_kind = 'device'
        AND device_snapshot_sources.device_id = requested_sources.device_id
        AND device_snapshot_sources.account_id = requested_sources.account_id`
    ).bind(
      sources, MAX_DASHBOARD_SNAPSHOT_BYTES, MAX_DASHBOARD_SNAPSHOT_BYTES
    ).all<{
      source_position: number;
      group_position: number;
      source_kind: "worker" | "device";
      provider_id: string;
      latest_snapshot: string | null;
    }>();
    const candidates = result.results.sort((left, right) =>
      Number(left.group_position) - Number(right.group_position)
        || Number(left.source_position) - Number(right.source_position)
    );
    for (const row of candidates) {
      const position = Number(row.group_position);
      const group = Number.isSafeInteger(position) ? batch[position] : undefined;
      if (!group || !isProviderID(row.provider_id)
          || row.provider_id !== group.representative.provider_id) continue;
      const snapshot = sanitizeDashboardSnapshot(row.latest_snapshot, row.provider_id);
      if (snapshot && !snapshots.get(group.id)) {
        const selectedRow = group.rows.find((source) =>
          source.source_kind === row.source_kind
            && source.device_id === requested[Number(row.source_position)]?.[2]
            && source.account_id === requested[Number(row.source_position)]?.[3]
        ) ?? group.representative;
        snapshots.set(group.id, { source: row.source_kind, snapshot, row: selectedRow });
      }
      else if (!snapshots.has(group.id)) snapshots.set(group.id, null);
    }
  }
  return snapshots;
}

function dashboardAccountFreshness(row: DashboardAccountRow): number {
  return row.last_success_at ?? row.last_refresh_at ?? 0;
}

async function dashboardAccountID(key: CryptoKey, row: DashboardAccountRow): Promise<string> {
  let accountReference = typeof row.dashboard_account_reference === "string"
    && /^[A-Za-z0-9_-]{43}$/.test(row.dashboard_account_reference)
    ? row.dashboard_account_reference : null;
  if (!accountReference) {
    accountReference = await sourceAccountReferenceWithKey(
      key,
      row.provider_id,
      row.device_id,
      row.account_id,
    );
  }
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`when-reset:dashboard-account:v1:${accountReference}`),
  );
  return base64URL(new Uint8Array(signature));
}

async function dashboardSeriesID(
  env: Env,
  dashboardID: string,
  metricID: string,
): Promise<string> {
  const signature = await crypto.subtle.sign(
    "HMAC",
    await credentialFingerprintKey(env),
    new TextEncoder().encode(`when-reset:dashboard-series:v1:${dashboardID}:${metricID}`),
  );
  return base64URL(new Uint8Array(signature));
}

function dashboardAccountSession(
  row: DashboardAccountRow,
  now: number,
): { status: DashboardAccountStatus; checkedAt: number | null } {
  const session = workerSession(row);
  if (row.source_kind === "device") {
    if (row.last_success_at === null) return { status: "unchecked", checkedAt: null };
    if (row.refresh_interval_seconds === 0) {
      return { status: "active", checkedAt: row.last_success_at };
    }
    const staleAfter = Math.max(30 * 60, row.refresh_interval_seconds * 3);
    return now - row.last_success_at > staleAfter
      ? { status: "stale", checkedAt: row.last_success_at }
      : { status: "active", checkedAt: row.last_success_at };
  }
  if (session.status !== "active" || row.last_success_at === null) return session;
  const staleAfter = Math.max(30 * 60, row.refresh_interval_seconds * 3);
  return now - row.last_success_at > staleAfter
    ? { status: "stale", checkedAt: session.checkedAt }
    : session;
}

function sanitizeDashboardSnapshot(
  snapshotJSON: string | null,
  providerID: ProviderID,
): DashboardSnapshot | null {
  if (!snapshotJSON) return null;
  let value: unknown;
  try { value = JSON.parse(snapshotJSON) as unknown; }
  catch { return null; }
  if (!isRecord(value) || value.provider_id !== providerID) return null;
  const fetchedAt = safeDashboardTimestamp(value.fetched_at);
  if (fetchedAt === null || !Array.isArray(value.windows)) return null;
  const windows: DashboardWindow[] = [];
  for (const raw of value.windows.slice(0, 50)) {
    if (!isRecord(raw)) continue;
    const title = safeDashboardText(raw.title, 200);
    const remaining = typeof raw.remaining_percent === "number" ? raw.remaining_percent : null;
    const resetsAt = safeDashboardTimestamp(raw.resets_at);
    if (!title || remaining === null || !Number.isFinite(remaining) || resetsAt === null) continue;
    windows.push({
      title,
      kind: dashboardWindowKind(raw.kind),
      window_minutes: dashboardWindowMinutes(raw.window_minutes),
      remaining_percent: clampDashboardPercent(remaining),
      resets_at: resetsAt,
    });
  }
  const availableResetCount = typeof value.available_reset_count === "number"
    && Number.isSafeInteger(value.available_reset_count)
    ? Math.max(0, Math.min(1_000, value.available_reset_count)) : 0;
  const resetCredits: DashboardResetCredit[] = [];
  if (Array.isArray(value.reset_credits)) {
    for (const raw of value.reset_credits.slice(0, 50)) {
      if (!isRecord(raw)) continue;
      resetCredits.push({
        status: safeDashboardText(raw.status, 64),
        granted_at: safeDashboardTimestamp(raw.granted_at),
        expires_at: safeDashboardTimestamp(raw.expires_at),
      });
    }
  }
  const result: DashboardSnapshot = {
    fetched_at: fetchedAt,
    windows,
    available_reset_count: availableResetCount,
    reset_credits: resetCredits,
    reset_credits_authoritative: value.reset_credits_authoritative !== false,
  };
  const balance = sanitizeDashboardBalance(value.api_balance);
  if (balance) result.api_balance = balance;
  return result;
}

function sanitizeDashboardBalance(value: unknown): DashboardBalance | null {
  if (!isRecord(value)) return null;
  const title = safeDashboardText(value.title, 200);
  const currencyCode = safeDashboardText(value.currency_code, 8);
  const spent = dashboardFiniteNumber(value.spent);
  if (!title || !currencyCode || spent === null) return null;
  return {
    title,
    currency_code: currencyCode.toUpperCase(),
    spent,
    limit: dashboardNullableNumber(value.limit),
    remaining: dashboardNullableNumber(value.remaining),
    period_start: safeDashboardTimestamp(value.period_start),
    period_end: safeDashboardTimestamp(value.period_end),
    access_expires_at: safeDashboardTimestamp(value.access_expires_at),
    is_unlimited: value.is_unlimited === true,
    kind: value.kind === "wallet" ? "wallet" : "budget",
    unit_label: safeDashboardText(value.unit_label, 64),
  };
}

function safeDashboardText(value: unknown, maximum: number): string | null {
  if (typeof value !== "string" || value.length > maximum) return null;
  return value.trim() || null;
}

function safeDashboardTimestamp(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) && value >= 0
    ? Math.floor(value) : null;
}

function dashboardFiniteNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function dashboardNullableNumber(value: unknown): number | null {
  return value === null || value === undefined ? null : dashboardFiniteNumber(value);
}

function boundedDashboardInteger(value: number, minimum: number, maximum: number): number {
  return Number.isSafeInteger(value) ? Math.max(minimum, Math.min(maximum, value)) : minimum;
}

function clampDashboardPercent(value: number): number {
  return Math.max(0, Math.min(100, value));
}

function dashboardWindowKind(value: unknown): string | null {
  return value === "fiveHour" || value === "weekly" || value === "additional"
    ? value : null;
}

function dashboardWindowMinutes(value: unknown): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0
    && value <= 525_600 ? value : null;
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

function strictSameOriginRequest(request: Request, origin: string): boolean {
  return request.headers.get("origin") === origin;
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
            monitored_accounts.last_error, account_monitoring_consent.consent_revision
     FROM remote_account_subscriptions
     INNER JOIN monitored_accounts
       ON monitored_accounts.device_id = remote_account_subscriptions.source_device_id
      AND monitored_accounts.account_id = remote_account_subscriptions.source_account_id
     INNER JOIN account_monitoring_consent
       ON account_monitoring_consent.device_id = monitored_accounts.device_id
      AND account_monitoring_consent.account_id = monitored_accounts.account_id
      AND account_monitoring_consent.enabled = 1
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
      account: remoteAccountImportPayload(existing, imported.local_account_id, 1),
    }, 200, { "cache-control": "no-store" });
  }
  const candidates = await loadRemoteAccountCandidates(env, subscriberDeviceID);
  const source = candidates.find(
    (candidate) => candidate.remote_account_id === imported.remote_account_id
  );
  if (!source) return json({ error: "remote_account_not_found" }, 404);
  const sourceSubscription = await env.DB.prepare(
    `SELECT local_account_id FROM remote_account_subscriptions
     WHERE subscriber_device_id = ? AND source_device_id = ? AND source_account_id = ?`
  ).bind(subscriberDeviceID, source.device_id, source.account_id).first<{
    local_account_id: string;
  }>();
  const direct = await env.DB.prepare(
    "SELECT account_id FROM monitored_accounts WHERE device_id = ? AND account_id = ?"
  ).bind(subscriberDeviceID, imported.local_account_id).first<{ account_id: string }>();
  if (direct) {
    if (source.device_id === subscriberDeviceID
        && source.account_id === imported.local_account_id) {
      return json({
        account: remoteAccountImportPayload(
          source, imported.local_account_id, source.consent_revision
        ),
      }, 200, { "cache-control": "no-store" });
    }
    return json({ error: "local_account_conflict" }, 409);
  }
  const now = Math.floor(Date.now() / 1_000);
  const rebound = sourceSubscription ? await env.DB.prepare(
    `UPDATE remote_account_subscriptions
     SET local_account_id = ?, created_at = ?
     WHERE subscriber_device_id = ?
       AND source_device_id = ? AND source_account_id = ?
       AND local_account_id = ?
       AND local_account_id <> ?
       AND NOT EXISTS (
         SELECT 1 FROM monitored_accounts
         WHERE monitored_accounts.device_id = ?
           AND monitored_accounts.account_id = ?
       )
       AND NOT EXISTS (
         SELECT 1 FROM remote_account_subscriptions AS local_subscription
         WHERE local_subscription.subscriber_device_id = ?
           AND local_subscription.local_account_id = ?
       )
       AND EXISTS (
         SELECT 1 FROM monitored_accounts
         INNER JOIN account_monitoring_consent
           ON account_monitoring_consent.device_id = monitored_accounts.device_id
          AND account_monitoring_consent.account_id = monitored_accounts.account_id
          AND account_monitoring_consent.enabled = 1
         WHERE monitored_accounts.device_id = ?
           AND monitored_accounts.account_id = ?
           AND monitored_accounts.credential_fingerprint IS NOT NULL
       )`
  ).bind(
    imported.local_account_id, now, subscriberDeviceID,
    source.device_id, source.account_id, sourceSubscription.local_account_id,
    imported.local_account_id,
    subscriberDeviceID, imported.local_account_id,
    subscriberDeviceID, imported.local_account_id,
    source.device_id, source.account_id,
  ).run() : null;
  if ((rebound?.meta.changes ?? 0) === 1) {
    console.log(JSON.stringify({
      event: "remote_account_rebound",
      provider: source.provider_id,
    }));
    return json({
      account: remoteAccountImportPayload(source, imported.local_account_id, 1),
    }, 200, { "cache-control": "no-store" });
  }
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
         AND monitored_accounts.credential_fingerprint IS NOT NULL
     )
       AND NOT EXISTS (
         SELECT 1 FROM monitored_accounts AS local_account
         WHERE local_account.device_id = ? AND local_account.account_id = ?
     )
     ON CONFLICT DO NOTHING`
  ).bind(
    subscriberDeviceID, imported.local_account_id, source.device_id, source.account_id, now,
    source.device_id, source.account_id,
    subscriberDeviceID, imported.local_account_id,
  ).run();
  if ((result.meta.changes ?? 0) !== 1) {
    const directConflict = await env.DB.prepare(
      "SELECT account_id FROM monitored_accounts WHERE device_id = ? AND account_id = ?"
    ).bind(subscriberDeviceID, imported.local_account_id).first<{ account_id: string }>();
    if (directConflict) return json({ error: "local_account_conflict" }, 409);
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
      account: remoteAccountImportPayload(source, imported.local_account_id, 1),
    }, 200, { "cache-control": "no-store" });
  }
  console.log(JSON.stringify({ event: "remote_account_imported", provider: source.provider_id }));
  return json({
    account: remoteAccountImportPayload(source, imported.local_account_id, 1),
  }, 201, { "cache-control": "no-store" });
}

async function loadRemoteAccountCandidates(
  env: Env,
  subscriberDeviceID: string,
): Promise<RemoteAccountCandidate[]> {
  const result = await env.DB.prepare(
    `SELECT monitored_accounts.device_id, monitored_accounts.account_id,
            monitored_accounts.provider_id, monitored_accounts.workspace_id,
            monitored_accounts.display_name, monitored_accounts.profile_name,
            monitored_accounts.email, monitored_accounts.plan,
            monitored_accounts.plan_expires_at, monitored_accounts.trial_expires_at,
            monitored_accounts.credential_fingerprint, monitored_accounts.latest_snapshot,
            monitored_accounts.last_refresh_at, monitored_accounts.last_success_at,
            monitored_accounts.last_error, account_monitoring_consent.consent_revision
     FROM monitored_accounts
     INNER JOIN account_monitoring_consent
       ON account_monitoring_consent.device_id = monitored_accounts.device_id
      AND account_monitoring_consent.account_id = monitored_accounts.account_id
      AND account_monitoring_consent.enabled = 1
     LEFT JOIN remote_account_subscriptions AS existing_subscription
       ON existing_subscription.subscriber_device_id = ?
      AND existing_subscription.source_device_id = monitored_accounts.device_id
      AND existing_subscription.source_account_id = monitored_accounts.account_id
     WHERE monitored_accounts.credential_fingerprint IS NOT NULL
     ORDER BY (existing_subscription.local_account_id IS NULL),
              (monitored_accounts.device_id <> ?),
              (monitored_accounts.last_error IS NOT NULL),
              monitored_accounts.last_success_at DESC,
              monitored_accounts.device_id, monitored_accounts.account_id
     LIMIT ?`
  ).bind(subscriberDeviceID, subscriberDeviceID, MAX_REMOTE_ACCOUNT_IMPORTS * 8)
    .all<RemoteAccountCandidateRow>();
  const seen = new Set<string>();
  const candidates: RemoteAccountCandidate[] = [];
  for (const row of result.results) {
    const accountReference = await accountReferenceForRow(env, row);
    if (seen.has(accountReference)) continue;
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

function remoteAccountImportPayload(
  candidate: RemoteAccountCandidate,
  localAccountID: string,
  consentRevision: number,
): Record<string, unknown> {
  return {
    ...remoteAccountPayload(candidate),
    local_account_id: localAccountID,
    consent_revision: consentRevision,
  };
}

async function syncedAccountReference(accountID: string): Promise<string> {
  return hashSecret(`when-reset:synced-account:v1:${accountID.toLowerCase()}`);
}

async function accountReferenceForRow(
  env: Env,
  row: {
    provider_id: ProviderID;
    latest_snapshot: string | null;
    device_id?: string;
    account_id?: string;
    source_device_id?: string;
    source_account_id?: string;
  },
): Promise<string> {
  const verifiedReference = verifiedSnapshotAccountReference(row.latest_snapshot);
  if (verifiedReference) return verifiedReference;
  const sourceDeviceID = row.source_device_id ?? row.device_id;
  const sourceAccountID = row.source_account_id ?? row.account_id;
  if (!sourceDeviceID || !sourceAccountID) {
    throw new Error("Missing source identity for account reference");
  }
  return sourceAccountReferenceWithKey(
    await credentialFingerprintKey(env),
    row.provider_id,
    sourceDeviceID,
    sourceAccountID,
  );
}

async function sourceAccountReferenceWithKey(
  key: CryptoKey,
  providerID: ProviderID,
  deviceID: string,
  accountID: string,
): Promise<string> {
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(
      `when-reset:provider-account-source:v1:${providerID}:${deviceID}:${accountID}`
    ),
  );
  return base64URL(new Uint8Array(signature));
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
    if (normalized === "provider_session_expired") {
      return { status: "expired", checkedAt };
    }
    if (normalized === "provider_request_forbidden") {
      return { status: "error", checkedAt };
    }
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

async function parseDeviceSnapshotSourceUpload(
  request: Request,
): Promise<DeviceSnapshotSourceUpload | null> {
  const value = await boundedRequestJSON(request, MAX_DEVICE_SNAPSHOT_BODY_BYTES);
  if (!isExactObject(value, [
    "provider_id", "display_name", "refresh_interval_seconds",
    "history_retention_days", "consent_revision",
  ]) || !isProviderID(value.provider_id)) return null;
  const displayName = optionalBoundedString(value.display_name, 128);
  const interval = value.refresh_interval_seconds;
  const retention = value.history_retention_days;
  const consentRevision = parseUploadConsentRevision(value.consent_revision);
  if (displayName === undefined
      || typeof interval !== "number" || !Number.isSafeInteger(interval)
      || (interval !== 0
        && (interval < MIN_MONITOR_INTERVAL_SECONDS || interval > MAX_MONITOR_INTERVAL_SECONDS))
      || typeof retention !== "number" || !Number.isSafeInteger(retention)
      || retention < MIN_HISTORY_RETENTION_DAYS || retention > MAX_HISTORY_RETENTION_DAYS
      || consentRevision === null) return null;
  return {
    provider_id: value.provider_id,
    display_name: displayName,
    refresh_interval_seconds: interval,
    history_retention_days: retention,
    consent_revision: consentRevision,
  };
}

async function parseDeviceSnapshotUpload(
  request: Request,
  providerID: ProviderID,
): Promise<DeviceSnapshotUpload | null> {
  const value = await boundedRequestJSON(request, MAX_DEVICE_SNAPSHOT_BODY_BYTES);
  if (!isExactObject(value, ["consent_revision", "sequence", "observed_at", "snapshot"])
      || typeof value.sequence !== "number" || !Number.isSafeInteger(value.sequence)
      || value.sequence <= 0 || value.sequence >= Number.MAX_SAFE_INTEGER) return null;
  const consentRevision = parseUploadConsentRevision(value.consent_revision);
  const observedAt = safeDeviceTimestamp(value.observed_at);
  if (consentRevision === null || observedAt === null) return null;
  const snapshot = parseDeviceSnapshotProjection(
    value.snapshot,
    providerID,
    observedAt,
    value.sequence,
  );
  return snapshot ? {
    consent_revision: consentRevision,
    sequence: value.sequence,
    observed_at: observedAt,
    snapshot,
  } : null;
}

function parseDeviceSnapshotProjection(
  value: unknown,
  providerID: ProviderID,
  observedAt: number,
  sequence: number,
): ProviderSnapshot | null {
  if (!isExactObject(value, [
    "provider_id", "plan", "windows", "available_reset_count", "reset_credits",
    "reset_credits_authoritative", "api_balance",
  ], ["api_balance"]) || value.provider_id !== providerID
      || !Array.isArray(value.windows)
      || value.windows.length > MAX_DEVICE_SNAPSHOT_WINDOWS
      || !Array.isArray(value.reset_credits)
      || value.reset_credits.length > MAX_DEVICE_SNAPSHOT_RESET_CREDITS
      || typeof value.reset_credits_authoritative !== "boolean") return null;
  const plan = optionalBoundedString(value.plan, 200);
  const resetCount = value.available_reset_count;
  if (plan === undefined || typeof resetCount !== "number"
      || !Number.isSafeInteger(resetCount) || resetCount < 0 || resetCount > 1_000) return null;

  const windows: ProviderSnapshot["windows"] = [];
  const positions = new Set<number>();
  const metricIDs = new Set<string>();
  for (const raw of value.windows) {
    if (!isExactObject(raw, [
      "position", "metric_id", "title", "kind", "window_minutes",
      "remaining_percent", "resets_at",
    ], ["kind", "window_minutes"])) return null;
    const position = raw.position;
    const metricID = requiredBoundedString(raw.metric_id, 512, false);
    const title = requiredBoundedString(raw.title, 256, false);
    const kind = raw.kind ?? null;
    const windowMinutes = raw.window_minutes ?? null;
    const remaining = raw.remaining_percent;
    const resetsAt = safeDeviceTimestamp(raw.resets_at);
    if (typeof position !== "number" || !Number.isSafeInteger(position)
        || position < 0 || position >= MAX_DEVICE_SNAPSHOT_WINDOWS
        || positions.has(position) || metricID === null || metricIDs.has(metricID)
        || title === null
        || (kind !== null && kind !== "fiveHour" && kind !== "weekly"
          && kind !== "additional")
        || (windowMinutes !== null && (typeof windowMinutes !== "number"
          || !Number.isSafeInteger(windowMinutes) || windowMinutes <= 0
          || windowMinutes > 10 * 365 * 24 * 60))
        || typeof remaining !== "number" || !Number.isFinite(remaining)
        || remaining < 0 || remaining > 100 || resetsAt === null
        || resetsAt < observedAt - MAX_DEVICE_SNAPSHOT_CLOCK_SKEW_SECONDS
        || resetsAt > observedAt + 10 * 365 * 86_400) return null;
    positions.add(position);
    metricIDs.add(metricID);
    windows.push({
      position,
      metric_id: metricID,
      title,
      kind,
      window_minutes: windowMinutes,
      remaining_percent: remaining,
      resets_at: resetsAt,
    });
  }

  const resetCredits: ProviderSnapshot["reset_credits"] = [];
  for (const [index, raw] of value.reset_credits.entries()) {
    if (!isExactObject(
      raw,
      ["expires_at", "status", "granted_at"],
      ["expires_at", "status", "granted_at"],
    )) return null;
    const expiresAt = nullableDeviceTimestamp(raw.expires_at);
    const grantedAt = nullableDeviceTimestamp(raw.granted_at);
    const status = optionalBoundedString(raw.status, 64);
    if (expiresAt === undefined || grantedAt === undefined || status === undefined
        || (expiresAt !== null && expiresAt > observedAt + 10 * 365 * 86_400)
        || (grantedAt !== null && grantedAt > observedAt + MAX_DEVICE_SNAPSHOT_CLOCK_SKEW_SECONDS)
        || (grantedAt !== null && expiresAt !== null && grantedAt > expiresAt)) return null;
    resetCredits.push({
      // Provider identifiers are intentionally not accepted. The server creates a harmless,
      // source-local identifier solely so existing snapshot consumers can key the row.
      id: `device:${sequence}:${index}`,
      expires_at: expiresAt,
      status,
      granted_at: grantedAt,
    });
  }

  const apiBalance = value.api_balance === undefined
    ? undefined : parseDeviceAPIBalance(value.api_balance, observedAt);
  if (value.api_balance !== undefined && apiBalance === null) return null;
  return {
    provider_id: providerID,
    plan,
    fetched_at: observedAt,
    windows,
    available_reset_count: resetCount,
    reset_credits: resetCredits,
    reset_credits_authoritative: value.reset_credits_authoritative,
    ...(apiBalance ? { api_balance: apiBalance } : {}),
  };
}

function parseDeviceAPIBalance(
  value: unknown,
  observedAt: number,
): NonNullable<ProviderSnapshot["api_balance"]> | null {
  if (!isExactObject(value, [
    "title", "currency_code", "spent", "limit", "remaining", "period_start", "period_end",
    "access_expires_at", "is_unlimited", "kind", "unit_label",
  ], [
    "limit", "remaining", "period_start", "period_end", "access_expires_at", "kind",
    "unit_label",
  ])) return null;
  const title = requiredBoundedString(value.title, 200, false);
  const currencyCode = requiredBoundedString(value.currency_code, 8, false);
  const spent = boundedDeviceNumber(value.spent);
  const limit = nullableDeviceNumber(value.limit);
  const remaining = nullableDeviceNumber(value.remaining);
  const periodStart = nullableDeviceTimestamp(value.period_start);
  const periodEnd = nullableDeviceTimestamp(value.period_end);
  const accessExpiresAt = nullableDeviceTimestamp(value.access_expires_at);
  const kind = value.kind === undefined || value.kind === null ? undefined
    : value.kind === "budget" || value.kind === "wallet" ? value.kind : null;
  const unitLabel = optionalBoundedString(value.unit_label, 64);
  if (title === null || currencyCode === null || !/^[A-Za-z0-9]{3,8}$/.test(currencyCode)
      || spent === null || limit === undefined || remaining === undefined
      || periodStart === undefined || periodEnd === undefined || accessExpiresAt === undefined
      || typeof value.is_unlimited !== "boolean" || kind === null || unitLabel === undefined) {
    return null;
  }
  const maximumFuture = observedAt + 10 * 365 * 86_400;
  if ((periodStart !== null && periodStart > maximumFuture)
      || (periodEnd !== null && periodEnd > maximumFuture)
      || (accessExpiresAt !== null && accessExpiresAt > maximumFuture)
      || (periodStart !== null && periodEnd !== null && periodStart > periodEnd)) return null;
  return {
    title,
    currency_code: currencyCode.toUpperCase(),
    spent,
    limit,
    remaining,
    period_start: periodStart,
    period_end: periodEnd,
    access_expires_at: accessExpiresAt,
    is_unlimited: value.is_unlimited,
    ...(kind === undefined ? {} : { kind }),
    ...(unitLabel === null ? {} : { unit_label: unitLabel }),
  };
}

function safeDeviceTimestamp(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  const timestamp = Math.floor(value);
  return Number.isSafeInteger(timestamp) && timestamp >= 0 && timestamp <= 10_000_000_000
    ? timestamp : null;
}

function nullableDeviceTimestamp(value: unknown): number | null | undefined {
  if (value === null || value === undefined) return null;
  return safeDeviceTimestamp(value) ?? undefined;
}

function boundedDeviceNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) && Math.abs(value) <= 1e15
    ? value : null;
}

function nullableDeviceNumber(value: unknown): number | null | undefined {
  if (value === null || value === undefined) return null;
  return boundedDeviceNumber(value) ?? undefined;
}

async function enableDeviceSnapshotSource(
  request: Request,
  env: Env,
  deviceID: string,
  accountID: string,
): Promise<Response> {
  const upload = await parseDeviceSnapshotSourceUpload(request);
  if (!upload) {
    return json({ error: "invalid_snapshot_source" }, 400, { "cache-control": "no-store" });
  }
  const [existing, occupied] = await Promise.all([
    env.DB.prepare(
      `SELECT device_snapshot_sources.provider_id, device_snapshot_sources.next_sequence
       FROM device_snapshot_sources
       WHERE device_id = ? AND account_id = ?`
    ).bind(deviceID, accountID).first<{ provider_id: ProviderID; next_sequence: number }>(),
    env.DB.prepare(
      `SELECT 1 AS occupied
       FROM remote_account_subscriptions
       WHERE subscriber_device_id = ? AND local_account_id = ?`
    ).bind(deviceID, accountID).first<{ occupied: number }>(),
  ]);
  if (occupied) {
    return json({ error: "local_account_conflict" }, 409, { "cache-control": "no-store" });
  }
  if (existing && existing.provider_id !== upload.provider_id) {
    return json({ error: "provider_account_mismatch" }, 409, {
      "cache-control": "no-store",
    });
  }
  const now = Math.floor(Date.now() / 1_000);
  const results = await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO device_snapshot_consent (
         device_id, account_id, consent_revision, enabled, updated_at
       ) VALUES (?, ?, ?, 1, ?)
       ON CONFLICT(device_id, account_id) DO UPDATE SET
         consent_revision = excluded.consent_revision,
         enabled = 1,
         updated_at = excluded.updated_at
       WHERE excluded.consent_revision > device_snapshot_consent.consent_revision
          OR (excluded.consent_revision = device_snapshot_consent.consent_revision
              AND device_snapshot_consent.enabled = 1)`
    ).bind(deviceID, accountID, upload.consent_revision, now),
    env.DB.prepare(
      `INSERT INTO device_snapshot_sources (
         device_id, account_id, provider_id, display_name,
         refresh_interval_seconds, history_retention_days,
         next_sequence, created_at, updated_at
       )
       SELECT ?, ?, ?, ?, ?, ?, 1, ?, ?
       WHERE EXISTS (
         SELECT 1 FROM device_snapshot_consent
         WHERE device_id = ? AND account_id = ?
           AND consent_revision = ? AND enabled = 1
       )
         AND NOT EXISTS (
           SELECT 1 FROM remote_account_subscriptions
           WHERE subscriber_device_id = ? AND local_account_id = ?
         )
       ON CONFLICT(device_id, account_id) DO UPDATE SET
         display_name = excluded.display_name,
         refresh_interval_seconds = excluded.refresh_interval_seconds,
         history_retention_days = excluded.history_retention_days,
         updated_at = excluded.updated_at
       WHERE device_snapshot_sources.provider_id = excluded.provider_id`
    ).bind(
      deviceID, accountID, upload.provider_id, upload.display_name,
      upload.refresh_interval_seconds, upload.history_retention_days, now, now,
      deviceID, accountID, upload.consent_revision,
      deviceID, accountID,
    ),
  ]);
  const consentChanges = results[0]?.meta.changes ?? 0;
  const sourceChanges = results[1]?.meta.changes ?? 0;
  if (consentChanges === 0) {
    return json({ error: "consent_revision_conflict" }, 409, {
      "cache-control": "no-store",
    });
  }
  if (sourceChanges !== 1) {
    const conflict = await env.DB.prepare(
      `SELECT 1 AS occupied
       FROM remote_account_subscriptions
       WHERE subscriber_device_id = ? AND local_account_id = ?`
    ).bind(deviceID, accountID).first<{ occupied: number }>();
    if (conflict) {
      return json({ error: "local_account_conflict" }, 409, {
        "cache-control": "no-store",
      });
    }
    throw new Error("Could not atomically enable device snapshot source");
  }
  const source = await loadDeviceSnapshotSource(env, deviceID, accountID);
  if (!source) throw new Error("Could not load device snapshot source");
  console.log(JSON.stringify({
    event: existing ? "device_snapshot_source_updated" : "device_snapshot_source_enabled",
    provider: source.provider_id,
  }));
  return json({
    ok: true,
    consent_revision: source.consent_revision,
    next_sequence: source.next_sequence,
  }, existing ? 200 : 201, { "cache-control": "no-store" });
}

async function uploadDeviceSnapshot(
  request: Request,
  env: Env,
  deviceID: string,
  accountID: string,
): Promise<Response> {
  const source = await loadDeviceSnapshotSource(env, deviceID, accountID);
  if (!source) {
    return json({ error: "account_not_found" }, 404, { "cache-control": "no-store" });
  }
  const upload = await parseDeviceSnapshotUpload(request, source.provider_id);
  if (!upload) {
    return json({ error: "invalid_device_snapshot" }, 400, {
      "cache-control": "no-store",
    });
  }
  if (upload.consent_revision !== source.consent_revision) {
    return json({ error: "consent_revision_conflict" }, 409, {
      "cache-control": "no-store",
    });
  }
  const now = Math.floor(Date.now() / 1_000);
  const cutoff = now - source.history_retention_days * 86_400;
  if (upload.observed_at < cutoff
      || upload.observed_at > now + MAX_DEVICE_SNAPSHOT_CLOCK_SKEW_SECONDS) {
    return json({ error: "snapshot_outside_time_window" }, 400, {
      "cache-control": "no-store",
    });
  }
  const payloadHash = await hashSecret(JSON.stringify({
    consent_revision: upload.consent_revision,
    sequence: upload.sequence,
    observed_at: upload.observed_at,
    snapshot: upload.snapshot,
  }));
  if (upload.sequence === source.next_sequence - 1
      && payloadHash === source.last_payload_hash) {
    return json({ accepted: true, sequence: upload.sequence }, 200, {
      "cache-control": "no-store",
    });
  }
  if (upload.sequence !== source.next_sequence) {
    return json({ error: "snapshot_replay" }, 409, { "cache-control": "no-store" });
  }
  if (source.last_observed_at !== null && upload.observed_at < source.last_observed_at) {
    return json({ error: "snapshot_stale" }, 409, { "cache-control": "no-store" });
  }

  const guard = `EXISTS (
    SELECT 1 FROM device_snapshot_sources
    INNER JOIN device_snapshot_consent
      ON device_snapshot_consent.device_id = device_snapshot_sources.device_id
     AND device_snapshot_consent.account_id = device_snapshot_sources.account_id
    WHERE device_snapshot_sources.device_id = ?
      AND device_snapshot_sources.account_id = ?
      AND device_snapshot_sources.provider_id = ?
      AND device_snapshot_sources.next_sequence = ?
      AND device_snapshot_consent.consent_revision = ?
      AND device_snapshot_consent.enabled = 1
  )`;
  const statements: D1PreparedStatement[] = upload.snapshot.windows.map((window) =>
    env.DB.prepare(
      `INSERT INTO device_snapshot_history (
         device_id, account_id, row_tag, provider_id, metric_id, metric_title,
         kind, window_minutes, remaining_percent, recorded_at, resets_at,
         seconds_until_reset, plan
       ) SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
       WHERE ${guard}
       ON CONFLICT(device_id, account_id, metric_id, recorded_at) DO UPDATE SET
         row_tag = excluded.row_tag,
         metric_title = excluded.metric_title,
         kind = excluded.kind,
         window_minutes = excluded.window_minutes,
         remaining_percent = excluded.remaining_percent,
         resets_at = excluded.resets_at,
         seconds_until_reset = excluded.seconds_until_reset,
         plan = excluded.plan`
    ).bind(
      deviceID, accountID, historyRowTag(accountID, window.metric_id, upload.observed_at),
      source.provider_id, window.metric_id, window.title, window.kind,
      window.window_minutes, window.remaining_percent, upload.observed_at, window.resets_at,
      Math.max(0, window.resets_at - upload.observed_at), upload.snapshot.plan,
      deviceID, accountID, source.provider_id, upload.sequence, upload.consent_revision,
    )
  );
  statements.push(
    env.DB.prepare(
      `DELETE FROM device_snapshot_history
       WHERE device_id = ? AND account_id = ? AND recorded_at < ?
         AND ${guard}`
    ).bind(
      deviceID, accountID, cutoff,
      deviceID, accountID, source.provider_id, upload.sequence, upload.consent_revision,
    ),
  );
  const updateIndex = statements.length;
  statements.push(
    env.DB.prepare(
      `UPDATE device_snapshot_sources SET
         plan = ?, next_sequence = ?, last_payload_hash = ?, latest_snapshot = ?,
         last_observed_at = ?, last_upload_at = ?, updated_at = ?
       WHERE device_id = ? AND account_id = ? AND provider_id = ? AND next_sequence = ?
         AND EXISTS (
           SELECT 1 FROM device_snapshot_consent
           WHERE device_id = ? AND account_id = ?
             AND consent_revision = ? AND enabled = 1
         )`
    ).bind(
      upload.snapshot.plan, upload.sequence + 1, payloadHash,
      JSON.stringify(upload.snapshot), upload.observed_at, now, now,
      deviceID, accountID, source.provider_id, upload.sequence,
      deviceID, accountID, upload.consent_revision,
    ),
  );
  const results = await env.DB.batch(statements);
  if ((results[updateIndex]?.meta.changes ?? 0) !== 1) {
    const current = await loadDeviceSnapshotSource(env, deviceID, accountID);
    if (!current || current.consent_revision !== upload.consent_revision) {
      return json({ error: "consent_revision_conflict" }, 409, {
        "cache-control": "no-store",
      });
    }
    if (current.next_sequence === upload.sequence + 1
        && current.last_payload_hash === payloadHash) {
      return json({ accepted: true, sequence: upload.sequence }, 200, {
        "cache-control": "no-store",
      });
    }
    return json({ error: "snapshot_replay" }, 409, { "cache-control": "no-store" });
  }
  console.log(JSON.stringify({
    event: "device_snapshot_uploaded",
    provider: source.provider_id,
    windows: upload.snapshot.windows.length,
  }));
  return json({ accepted: true, sequence: upload.sequence }, 200, {
    "cache-control": "no-store",
  });
}

async function disableDeviceSnapshotSource(
  env: Env,
  deviceID: string,
  accountID: string,
  consentRevision: number,
): Promise<Response> {
  const now = Math.floor(Date.now() / 1_000);
  const results = await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO device_snapshot_consent (
         device_id, account_id, consent_revision, enabled, updated_at
       ) VALUES (?, ?, ?, 0, ?)
       ON CONFLICT(device_id, account_id) DO UPDATE SET
         consent_revision = excluded.consent_revision,
         enabled = 0,
         updated_at = excluded.updated_at
       WHERE excluded.consent_revision > device_snapshot_consent.consent_revision
          OR (excluded.consent_revision = device_snapshot_consent.consent_revision
              AND device_snapshot_consent.enabled = 0)`
    ).bind(deviceID, accountID, consentRevision, now),
    env.DB.prepare(
      `DELETE FROM device_snapshot_sources
       WHERE device_id = ? AND account_id = ?
         AND EXISTS (
           SELECT 1 FROM device_snapshot_consent
           WHERE device_id = ? AND account_id = ?
             AND consent_revision = ? AND enabled = 0
         )`
    ).bind(deviceID, accountID, deviceID, accountID, consentRevision),
  ]);
  if ((results[0]?.meta.changes ?? 0) !== 1) {
    return json({ error: "consent_revision_conflict" }, 409, {
      "cache-control": "no-store",
    });
  }
  console.log(JSON.stringify({ event: "device_snapshot_source_disabled" }));
  return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
}

async function loadDeviceSnapshotSource(
  env: Env,
  deviceID: string,
  accountID: string,
): Promise<DeviceSnapshotSourceRow | null> {
  return env.DB.prepare(
    `SELECT device_snapshot_sources.device_id, device_snapshot_sources.account_id,
            device_snapshot_sources.provider_id, device_snapshot_sources.display_name,
            device_snapshot_sources.plan, device_snapshot_sources.refresh_interval_seconds,
            device_snapshot_sources.history_retention_days,
            device_snapshot_sources.next_sequence,
            device_snapshot_sources.last_payload_hash,
            device_snapshot_sources.latest_snapshot,
            device_snapshot_sources.last_observed_at,
            device_snapshot_sources.last_upload_at,
            device_snapshot_consent.consent_revision
     FROM device_snapshot_sources
     INNER JOIN device_snapshot_consent
       ON device_snapshot_consent.device_id = device_snapshot_sources.device_id
      AND device_snapshot_consent.account_id = device_snapshot_sources.account_id
      AND device_snapshot_consent.enabled = 1
     WHERE device_snapshot_sources.device_id = ?
       AND device_snapshot_sources.account_id = ?`
  ).bind(deviceID, accountID).first<DeviceSnapshotSourceRow>();
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
            monitored_accounts.credential_fingerprint,
            monitored_accounts.credential_revision, monitored_accounts.latest_snapshot,
            monitored_accounts.history_retention_days,
            account_monitoring_consent.consent_revision
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
  const archived = await env.DB.prepare(
    `SELECT provider_id, workspace_id, latest_snapshot, last_refresh_at, last_success_at
     FROM dashboard_account_archives
     WHERE device_id = ? AND account_id = ?`
  ).bind(deviceID, accountID).first<{
    provider_id: ProviderID;
    workspace_id: string;
    latest_snapshot: string | null;
    last_refresh_at: number | null;
    last_success_at: number | null;
  }>();
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
         AND NOT EXISTS (
           SELECT 1 FROM remote_account_subscriptions
           WHERE subscriber_device_id = ? AND local_account_id = ?
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
      deviceID, accountID,
    ),
  ]);
  const consentChanges = results[0]?.meta.changes ?? 0;
  const accountChanges = results[1]?.meta.changes ?? 0;
  if (consentChanges === 0 && accountChanges === 0) {
    return json({ error: "consent_revision_conflict" }, 409, { "cache-control": "no-store" });
  }
  if (consentChanges === 1 && accountChanges === 0) {
    return json({ error: "remote_account_is_read_only" }, 409, {
      "cache-control": "no-store",
    });
  }
  if (consentChanges !== 1 || accountChanges !== 1) {
    throw new Error("Could not atomically save monitored account consent");
  }
  if (archived) {
    if (archived.provider_id === upload.provider_id
        && archived.workspace_id === upload.workspace_id) {
      await env.DB.batch([
        env.DB.prepare(
          `INSERT OR IGNORE INTO usage_history (
             device_id, account_id, provider_id, metric_id, metric_title, kind,
             window_minutes, remaining_percent, recorded_at, resets_at,
             seconds_until_reset, plan
           )
           SELECT device_id, account_id, provider_id, metric_id, metric_title, kind,
                  window_minutes, remaining_percent, recorded_at, resets_at,
                  seconds_until_reset, plan
           FROM dashboard_account_archive_history
           WHERE device_id = ? AND account_id = ?`
        ).bind(deviceID, accountID),
        env.DB.prepare(
          `UPDATE monitored_accounts SET
             latest_snapshot = COALESCE(latest_snapshot, (SELECT latest_snapshot
               FROM dashboard_account_archives WHERE device_id = ? AND account_id = ?)),
             last_refresh_at = COALESCE(last_refresh_at, (SELECT last_refresh_at
               FROM dashboard_account_archives WHERE device_id = ? AND account_id = ?)),
             last_success_at = COALESCE(last_success_at, (SELECT last_success_at
               FROM dashboard_account_archives WHERE device_id = ? AND account_id = ?))
           WHERE device_id = ? AND account_id = ?`
        ).bind(
          deviceID, accountID, deviceID, accountID, deviceID, accountID, deviceID, accountID,
        ),
        env.DB.prepare(
          `DELETE FROM dashboard_account_archives WHERE device_id = ? AND account_id = ?`
        ).bind(deviceID, accountID),
      ]);
    } else {
      // A local UUID reused for another provider/workspace must never inherit
      // the previous account's retained history.
      await env.DB.batch([
        env.DB.prepare(
          `DELETE FROM dashboard_account_archive_history
           WHERE device_id = ? AND account_id = ?`
        ).bind(deviceID, accountID),
        env.DB.prepare(
          `DELETE FROM dashboard_account_archives WHERE device_id = ? AND account_id = ?`
        ).bind(deviceID, accountID),
      ]);
    }
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
  const remoteAuthorization: RemoteCredentialReplacementAuthorization | null =
    requiresWorkspaceMatch ? null : { subscriberDeviceID, localAccountID };
  const expectedUploadRevision = remoteAuthorization ? 1 : source.consent_revision;
  if (upload.consent_revision !== expectedUploadRevision) {
    return json({ error: "consent_revision_conflict" }, 409, {
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
    (result.snapshot as StoredProviderSnapshot).account_reference_verified =
      result.account_identity !== undefined;
    if (result.account_identity !== undefined) {
      (result.snapshot as StoredProviderSnapshot).account_reference_scope =
        "provider_account_v2";
    }
  } catch (error) {
    console.warn(JSON.stringify({
      event: "remote_account_credential_check_failed",
      provider: source.provider_id,
      error: safeError(error),
    }));
    return providerCredentialErrorResponse(error, source.provider_id);
  }
  // Legacy rows used a workspace-derived opaque reference before providers returned a verified
  // identity. That fallback must be allowed to migrate once; only an identity previously
  // verified by the provider is authoritative enough to reject a replacement credential.
  const previousReference = verifiedSnapshotAccountReference(source.latest_snapshot);
  if (previousReference && previousReference !== result.snapshot.account_reference) {
    return json({ error: "provider_account_mismatch" }, 409, {
      "cache-control": "no-store",
    });
  }
  const applied = await applyVerifiedCredentialResult(
    env, source, result, upload, remoteAuthorization
  );
  if (!applied) {
    return json({ error: "consent_revision_conflict" }, 409, {
      "cache-control": "no-store",
    });
  }
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

type ProviderCredentialFailureCode =
  "provider_session_expired" | "provider_request_forbidden" | "provider_check_failed";

function providerCredentialFailureCode(
  error: unknown,
  providerID: ProviderID,
): ProviderCredentialFailureCode {
  if (!(error instanceof ProviderFetchError)) return "provider_check_failed";
  if (error.status === 401) return "provider_session_expired";
  if (error.status === 403) {
    return providerID === "chatgpt"
      ? "provider_request_forbidden"
      : "provider_session_expired";
  }
  return "provider_check_failed";
}

function providerCredentialErrorResponse(error: unknown, providerID: ProviderID): Response {
  const code = providerCredentialFailureCode(error, providerID);
  const status = code === "provider_session_expired"
    ? 401
    : code === "provider_request_forbidden" ? 403 : 502;
  return json({ error: code }, status, {
    "cache-control": "no-store",
  });
}

function verifiedSnapshotAccountReference(snapshotJSON: string | null): string | null {
  if (!snapshotJSON) return null;
  try {
    const snapshot = JSON.parse(snapshotJSON) as StoredProviderSnapshot;
    return snapshot.account_reference_verified === true
        && snapshot.account_reference_scope === "provider_account_v2"
        && typeof snapshot.account_reference === "string"
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
            monitored_accounts.credential_fingerprint,
            monitored_accounts.credential_revision, monitored_accounts.latest_snapshot,
            monitored_accounts.history_retention_days,
            account_monitoring_consent.consent_revision
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
  accountReference: string,
  excludedDeviceID: string,
  excludedAccountID: string,
): Promise<CredentialTargetRow[]> {
  const result = await env.DB.prepare(
    `SELECT monitored_accounts.device_id, monitored_accounts.account_id,
            monitored_accounts.provider_id, monitored_accounts.workspace_id,
            monitored_accounts.plan, monitored_accounts.refresh_interval_seconds,
            monitored_accounts.credential_fingerprint,
            monitored_accounts.credential_revision, monitored_accounts.latest_snapshot,
            monitored_accounts.history_retention_days,
            account_monitoring_consent.consent_revision
     FROM monitored_accounts
     INNER JOIN account_monitoring_consent
       ON account_monitoring_consent.device_id = monitored_accounts.device_id
      AND account_monitoring_consent.account_id = monitored_accounts.account_id
      AND account_monitoring_consent.enabled = 1
     WHERE monitored_accounts.provider_id = ?
       AND json_extract(monitored_accounts.latest_snapshot, '$.account_reference') = ?
       AND json_extract(monitored_accounts.latest_snapshot, '$.account_reference_verified') = 1
       AND json_extract(monitored_accounts.latest_snapshot, '$.account_reference_scope') =
         'provider_account_v2'
       AND NOT (monitored_accounts.device_id = ? AND monitored_accounts.account_id = ?)
     ORDER BY monitored_accounts.device_id, monitored_accounts.account_id
     LIMIT ?`
  ).bind(
    providerID, accountReference, excludedDeviceID, excludedAccountID, MAX_REMOTE_ACCOUNT_IMPORTS
  ).all<CredentialTargetRow>();
  return result.results;
}

async function applyVerifiedCredentialResult(
  env: Env,
  target: CredentialTargetRow,
  result: ProviderFetchResult,
  replacementUpload: AccountUpload | null = null,
  remoteAuthorization: RemoteCredentialReplacementAuthorization | null = null,
): Promise<boolean> {
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
  const incomingReference = verifiedSnapshotAccountReference(JSON.stringify(snapshot));
  const remoteAuthorizationSQL = remoteAuthorization ? `
         AND EXISTS (
           SELECT 1 FROM remote_account_subscriptions
           WHERE subscriber_device_id = ? AND local_account_id = ?
             AND source_device_id = monitored_accounts.device_id
             AND source_account_id = monitored_accounts.account_id
         )` : "";
  const targetGuardBindings: Array<string | number | null> = [
    target.provider_id,
    target.workspace_id,
    target.credential_revision,
    target.credential_fingerprint,
    incomingReference,
    target.consent_revision,
    ...(remoteAuthorization
      ? [remoteAuthorization.subscriberDeviceID, remoteAuthorization.localAccountID]
      : []),
  ];
  const capturedTargetSQL = `
         monitored_accounts.provider_id = ?
         AND monitored_accounts.workspace_id = ?
         AND monitored_accounts.credential_revision = ?
         AND monitored_accounts.credential_fingerprint IS ?
         AND (
           COALESCE(json_extract(
             monitored_accounts.latest_snapshot, '$.account_reference_verified'
           ), 0) <> 1
           OR COALESCE(json_extract(
             monitored_accounts.latest_snapshot, '$.account_reference_scope'
           ), '') <> 'provider_account_v2'
           OR json_extract(
             monitored_accounts.latest_snapshot, '$.account_reference'
           ) IS NULL
           OR json_extract(
             monitored_accounts.latest_snapshot, '$.account_reference'
           ) = ?
         )
         AND
         EXISTS (
           SELECT 1 FROM account_monitoring_consent
           WHERE device_id = monitored_accounts.device_id
             AND account_id = monitored_accounts.account_id
             AND consent_revision = ? AND enabled = 1
         )${remoteAuthorizationSQL}`;
  const statements: D1PreparedStatement[] = [];
  if (replacementUpload) {
    statements.push(env.DB.prepare(
      `UPDATE monitored_accounts SET display_name = ?, profile_name = ?, email = ?,
         plan_expires_at = ?, trial_expires_at = ?, missing_quotas = ?,
         refresh_interval_seconds = ?, history_retention_days = ?, updated_at = ?
       WHERE device_id = ? AND account_id = ? AND ${capturedTargetSQL}`
    ).bind(
      replacementUpload.display_name, replacementUpload.profile_name, replacementUpload.email,
      replacementUpload.plan_expires_at, replacementUpload.trial_expires_at,
      JSON.stringify(replacementUpload.missing_quotas),
      replacementUpload.refresh_interval_seconds, replacementUpload.history_retention_days,
      appliedAt, target.device_id, target.account_id, ...targetGuardBindings,
    ));
  }
  statements.push(
    env.DB.prepare(
      `DELETE FROM monitor_run_targets
       WHERE device_id = ? AND account_id = ? AND applied_at IS NULL
         AND EXISTS (
           SELECT 1 FROM monitored_accounts
           WHERE monitored_accounts.device_id = monitor_run_targets.device_id
             AND monitored_accounts.account_id = monitor_run_targets.account_id
             AND ${capturedTargetSQL}
         )`
    ).bind(target.device_id, target.account_id, ...targetGuardBindings),
  );
  statements.push(...snapshot.windows.map((window) => env.DB.prepare(
      `INSERT INTO usage_history (
         device_id, account_id, row_tag, history_source,
         provider_id, metric_id, metric_title, kind, window_minutes,
         remaining_percent, recorded_at, resets_at, seconds_until_reset, plan
       ) SELECT ?, ?, ?, 'worker', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
       WHERE EXISTS (
         SELECT 1 FROM monitored_accounts
         WHERE monitored_accounts.device_id = ? AND monitored_accounts.account_id = ?
           AND ${capturedTargetSQL}
       )
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
      target.device_id, target.account_id, ...targetGuardBindings,
    )),
  );
  // Keep the credential mutation last. Every earlier statement uses the same captured-row
  // guard; D1 batches execute transactionally and without interleaving, so changing the
  // fingerprint here cannot invalidate the history statements that belong to this winner.
  const credentialUpdateIndex = statements.length;
  statements.push(
    env.DB.prepare(
      `UPDATE monitored_accounts SET plan = ?, encrypted_credentials = ?,
         credential_fingerprint = ?, latest_snapshot = ?, scheduled_monitor_at = NULL,
         last_refresh_at = ?, last_success_at = ?, last_error = NULL,
         consecutive_failures = 0, next_refresh_at = ?, updated_at = ?
       WHERE device_id = ? AND account_id = ? AND ${capturedTargetSQL}`
    ).bind(
      effectivePlan, encrypted, fingerprint, JSON.stringify(snapshot),
      appliedAt, appliedAt, appliedAt + target.refresh_interval_seconds, appliedAt,
      target.device_id, target.account_id, ...targetGuardBindings,
    ),
  );
  const results = await env.DB.batch(statements);
  const applied = (results[credentialUpdateIndex]?.meta.changes ?? 0) === 1;
  if (applied) {
    if (remoteAuthorization) {
      await enqueueAccountRefreshHints(env, target.device_id, target.account_id);
    } else {
      await enqueueRemoteAccountRefreshHints(env, target.device_id, target.account_id);
    }
  }
  return applied;
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

  const sourceReference = verifiedSnapshotAccountReference(source.latest_snapshot);
  const duplicates = sourceReference
    ? (await loadSameAccountCredentialTargets(
      env,
      source.provider_id,
      sourceReference,
      source.device_id,
      source.account_id,
      )).filter((target) => {
        if (target.account_id !== source.account_id) return false;
        return verifiedSnapshotAccountReference(target.latest_snapshot) === sourceReference;
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
         ) SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
         WHERE EXISTS (
           SELECT 1 FROM account_monitoring_consent
           WHERE device_id = ? AND account_id = ?
             AND consent_revision = ? AND enabled = 1
         )
         ON CONFLICT DO NOTHING`
      ).bind(
        target.device_id, target.account_id, point.row_tag, point.history_source ?? "device",
        point.provider_id, point.metric_id, point.metric_title, point.kind,
        point.window_minutes, point.remaining_percent, point.recorded_at,
        point.resets_at, point.seconds_until_reset, point.plan,
        target.device_id, target.account_id, target.consent_revision,
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
  const verifiedReference = verifiedSnapshotAccountReference(row.latest_snapshot);
  const cursorSQL = cursor
    ? `AND (usage_history.recorded_at > ?
            OR (usage_history.recorded_at = ? AND usage_history.metric_id > ?))`
    : "";
  const query = verifiedReference
    ? `WITH identity_sources AS (
         SELECT monitored_accounts.device_id, monitored_accounts.account_id
         FROM monitored_accounts
         INNER JOIN account_monitoring_consent
           ON account_monitoring_consent.device_id = monitored_accounts.device_id
          AND account_monitoring_consent.account_id = monitored_accounts.account_id
          AND account_monitoring_consent.enabled = 1
         WHERE monitored_accounts.provider_id = ?
           AND json_extract(monitored_accounts.latest_snapshot, '$.account_reference') = ?
           AND json_extract(monitored_accounts.latest_snapshot,
             '$.account_reference_verified') = 1
           AND json_extract(monitored_accounts.latest_snapshot,
             '$.account_reference_scope') = 'provider_account_v2'
       ), ranked_history AS (
         SELECT usage_history.*,
                ROW_NUMBER() OVER (
                  PARTITION BY usage_history.metric_id, usage_history.recorded_at
                  ORDER BY CASE WHEN usage_history.device_id = ?
                                  AND usage_history.account_id = ? THEN 0 ELSE 1 END,
                           usage_history.device_id, usage_history.account_id
                ) AS identity_position
         FROM usage_history
         INNER JOIN identity_sources
           ON identity_sources.device_id = usage_history.device_id
          AND identity_sources.account_id = usage_history.account_id
         WHERE usage_history.recorded_at >= ? ${cursorSQL}
       )
       SELECT row_tag, history_source, provider_id, metric_id, metric_title,
              kind, window_minutes, remaining_percent,
              recorded_at, resets_at, seconds_until_reset, plan
       FROM ranked_history WHERE identity_position = 1
       ORDER BY recorded_at, metric_id LIMIT ?`
    : `SELECT row_tag, history_source, provider_id, metric_id, metric_title,
              kind, window_minutes, remaining_percent,
              recorded_at, resets_at, seconds_until_reset, plan
       FROM usage_history
       WHERE device_id = ? AND account_id = ? AND recorded_at >= ?
         ${cursor ? "AND (recorded_at > ? OR (recorded_at = ? AND metric_id > ?))" : ""}
       ORDER BY recorded_at, metric_id LIMIT ?`;
  const leadingBindings: unknown[] = verifiedReference
    ? [
        row.provider_id, verifiedReference,
        row.source_device_id, row.source_account_id, effectiveSince,
      ]
    : [row.source_device_id, row.source_account_id, effectiveSince];
  const cursorBindings: unknown[] = cursor
    ? [cursor.recordedAt, cursor.recordedAt, cursor.metricID] : [];
  const statement = env.DB.prepare(query).bind(
    ...leadingBindings,
    ...cursorBindings,
    HISTORY_PAGE_SIZE + 1,
  );
  const result = await statement.all<HistoryRow>();
  const rows = result.results;
  const hasMore = rows.length > HISTORY_PAGE_SIZE;
  const history = rows.slice(0, HISTORY_PAGE_SIZE).map((point) => ({
    ...point,
    // Stored tags are scoped to their owning Worker row. Re-key them to the authenticated
    // client's local account so a subscription or verified-identity union never exposes a
    // source device's raw account UUID.
    row_tag: historyRowTag(accountID, point.metric_id, point.recorded_at),
  }));
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
    try {
      snapshot = sanitizePublicProviderSnapshot(
        JSON.parse(row.latest_snapshot) as unknown,
        row.provider_id,
      );
    }
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

function sanitizePublicProviderSnapshot(
  value: unknown,
  providerID: ProviderID,
): ProviderSnapshot | null {
  if (!isRecord(value) || value.provider_id !== providerID) return null;
  const plan = optionalBoundedString(value.plan, 200);
  const fetchedAt = safeDashboardTimestamp(value.fetched_at);
  if (plan === undefined || fetchedAt === null || !Array.isArray(value.windows)
      || !Array.isArray(value.reset_credits)) return null;
  const windows: ProviderSnapshot["windows"] = [];
  for (const raw of value.windows.slice(0, 50)) {
    if (!isRecord(raw)) continue;
    const position = typeof raw.position === "number" && Number.isSafeInteger(raw.position)
      && raw.position >= 0 && raw.position <= 1_000 ? raw.position : null;
    const metricID = requiredBoundedString(raw.metric_id, 512, false);
    const title = requiredBoundedString(raw.title, 256, false);
    const kind = dashboardWindowKind(raw.kind);
    const windowMinutes = dashboardWindowMinutes(raw.window_minutes);
    const remaining = dashboardFiniteNumber(raw.remaining_percent);
    const resetsAt = safeDashboardTimestamp(raw.resets_at);
    if (position === null || metricID === null || title === null || remaining === null
        || resetsAt === null) continue;
    windows.push({
      position,
      metric_id: metricID,
      title,
      kind: kind as ProviderSnapshot["windows"][number]["kind"],
      window_minutes: windowMinutes,
      remaining_percent: clampDashboardPercent(remaining),
      resets_at: resetsAt,
    });
  }
  const resetCredits: ProviderSnapshot["reset_credits"] = [];
  for (const raw of value.reset_credits.slice(0, 50)) {
    if (!isRecord(raw)) continue;
    const id = requiredBoundedString(raw.id, 512, false);
    const status = optionalBoundedString(raw.status, 64);
    const expiresAt = publicNullableTimestamp(raw.expires_at);
    const grantedAt = publicNullableTimestamp(raw.granted_at);
    if (id === null || status === undefined || expiresAt === undefined
        || grantedAt === undefined) continue;
    resetCredits.push({ id, status, expires_at: expiresAt, granted_at: grantedAt });
  }
  const rawCount = value.available_reset_count;
  const availableResetCount = typeof rawCount === "number" && Number.isSafeInteger(rawCount)
    ? Math.max(0, Math.min(1_000, rawCount)) : 0;
  const result: ProviderSnapshot = {
    provider_id: providerID,
    plan,
    fetched_at: fetchedAt,
    windows,
    available_reset_count: availableResetCount,
    reset_credits: resetCredits,
  };
  if (typeof value.reset_credits_authoritative === "boolean") {
    result.reset_credits_authoritative = value.reset_credits_authoritative;
  }
  const accountReference = typeof value.account_reference === "string"
    && /^[A-Za-z0-9_-]{43}$/.test(value.account_reference)
    ? value.account_reference : null;
  if (accountReference) result.account_reference = accountReference;
  const balance = sanitizePublicAPIBalance(value.api_balance);
  if (balance) result.api_balance = balance;
  return result;
}

function sanitizePublicAPIBalance(value: unknown): ProviderSnapshot["api_balance"] | null {
  if (!isRecord(value)) return null;
  const title = requiredBoundedString(value.title, 200, false);
  const currencyCode = requiredBoundedString(value.currency_code, 8, false);
  const spent = dashboardFiniteNumber(value.spent);
  const limit = publicNullableNumber(value.limit);
  const remaining = publicNullableNumber(value.remaining);
  const periodStart = publicNullableTimestamp(value.period_start);
  const periodEnd = publicNullableTimestamp(value.period_end);
  const accessExpiresAt = publicNullableTimestamp(value.access_expires_at);
  const unitLabel = optionalBoundedString(value.unit_label, 64);
  const kind = value.kind === undefined ? undefined
    : value.kind === "budget" || value.kind === "wallet" ? value.kind : null;
  if (title === null || currencyCode === null || spent === null || limit === undefined
      || remaining === undefined || periodStart === undefined || periodEnd === undefined
      || accessExpiresAt === undefined || unitLabel === undefined || kind === null) return null;
  return {
    title,
    currency_code: currencyCode,
    spent,
    limit,
    remaining,
    period_start: periodStart,
    period_end: periodEnd,
    access_expires_at: accessExpiresAt,
    is_unlimited: value.is_unlimited === true,
    ...(kind ? { kind } : {}),
    ...(value.unit_label === undefined ? {} : { unit_label: unitLabel }),
  };
}

function publicNullableNumber(value: unknown): number | null | undefined {
  if (value === null || value === undefined) return null;
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function publicNullableTimestamp(value: unknown): number | null | undefined {
  if (value === null || value === undefined) return null;
  return typeof value === "number" && Number.isFinite(value) && value >= 0
    ? Math.floor(value) : undefined;
}

async function loadAccountSyncRow(
  env: Env,
  deviceID: string,
  accountID: string,
): Promise<AccountSyncRow | null> {
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
    pruneDeviceSnapshotHistory(env, now),
    pruneDashboardSessions(env, now),
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
    (result.snapshot as StoredProviderSnapshot).account_reference_verified =
      result.account_identity !== undefined;
    if (result.account_identity !== undefined) {
      (result.snapshot as StoredProviderSnapshot).account_reference_scope =
        "provider_account_v2";
    }
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
    const errorText = monitorError(error, source.provider_id);
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
    await enqueueAccountRefreshHints(env, row.device_id, row.account_id);
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
  if (!result.account_identity || !reference) return 0;
  const targets = await loadSameAccountCredentialTargets(
    env,
    source.provider_id,
    reference,
    source.device_id,
    source.account_id,
  );
  let updated = 0;
  const updatedDeviceIDs = new Set<string>();
  for (const target of targets) {
    if (verifiedSnapshotAccountReference(target.latest_snapshot) !== reference) continue;
    const applied = await applyVerifiedCredentialResult(env, target, result);
    if (!applied) continue;
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

async function enqueueDeviceRefreshHints(env: Env, deviceIDs: Set<string>): Promise<number> {
  if (deviceIDs.size === 0) return 0;
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
  return targets.length;
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

async function enqueueAccountRefreshHints(
  env: Env,
  sourceDeviceID: string,
  sourceAccountID: string,
): Promise<void> {
  const deviceIDs = await remoteAccountSubscriberDeviceIDs(
    env, sourceDeviceID, sourceAccountID
  );
  deviceIDs.add(sourceDeviceID);
  const enqueued = await enqueueDeviceRefreshHints(env, deviceIDs);
  if (enqueued > 0) {
    console.log(JSON.stringify({
      event: "account_refresh_hints_enqueued",
      devices: enqueued,
    }));
  }
}

async function enqueueRemoteAccountRefreshHints(
  env: Env,
  sourceDeviceID: string,
  sourceAccountID: string,
): Promise<void> {
  const deviceIDs = await remoteAccountSubscriberDeviceIDs(
    env, sourceDeviceID, sourceAccountID
  );
  const enqueued = await enqueueDeviceRefreshHints(env, deviceIDs);
  if (enqueued > 0) {
    console.log(JSON.stringify({
      event: "remote_account_refresh_hints_enqueued",
      devices: enqueued,
    }));
  }
}

async function remoteAccountSubscriberDeviceIDs(
  env: Env,
  sourceDeviceID: string,
  sourceAccountID: string,
): Promise<Set<string>> {
  const result = await env.DB.prepare(
    `SELECT DISTINCT subscriber_device_id AS device_id
     FROM remote_account_subscriptions
     WHERE source_device_id = ? AND source_account_id = ?`
  ).bind(sourceDeviceID, sourceAccountID).all<{ device_id: string }>();
  return new Set(result.results.map((row) => row.device_id));
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
      const results = await env.DB.batch([
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
      if ((results[0]?.meta.changes ?? 0) === 1) {
        await enqueueAccountRefreshHints(env, row.device_id, row.account_id);
      }
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

async function pruneDeviceSnapshotHistory(env: Env, now: number): Promise<void> {
  await env.DB.prepare(
    `DELETE FROM device_snapshot_history
     WHERE EXISTS (
       SELECT 1 FROM device_snapshot_sources
       WHERE device_snapshot_sources.device_id = device_snapshot_history.device_id
         AND device_snapshot_sources.account_id = device_snapshot_history.account_id
         AND device_snapshot_history.recorded_at
           < ? - device_snapshot_sources.history_retention_days * 86400
     )`
  ).bind(now).run();
}

async function pruneLinkSessions(env: Env, now: number): Promise<void> {
  await env.DB.prepare("DELETE FROM link_sessions WHERE expires_at <= ?").bind(now).run();
}

async function pruneDashboardSessions(env: Env, now: number): Promise<void> {
  await env.DB.prepare("DELETE FROM dashboard_sessions WHERE expires_at <= ?").bind(now).run();
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

async function hasEmptyJSONBody(request: Request): Promise<boolean> {
  // Fetch clients commonly send an explicit Content-Length: 0 with POST requests. A zero-byte
  // body is the same empty JSON envelope accepted by the browser UI; do not try to JSON-decode the
  // empty stream and turn a valid passkey-options request into `invalid_request`.
  if (request.headers.get("content-length")?.trim() === "0") return true;
  if (!request.body) return true;
  const value = await boundedRequestJSON(request, 256);
  return isRecord(value) && Object.keys(value).length === 0;
}

type PasskeyRegistrationVerificationBody = {
  transaction_id: string;
  credential: RegistrationResponseJSON;
};

type PasskeyAuthenticationVerificationBody = {
  transaction_id: string;
  credential: AuthenticationResponseJSON;
};

async function parsePasskeyVerificationBody(
  request: Request,
  purpose: "registration",
): Promise<PasskeyRegistrationVerificationBody | null>;
async function parsePasskeyVerificationBody(
  request: Request,
  purpose: "authentication",
): Promise<PasskeyAuthenticationVerificationBody | null>;
async function parsePasskeyVerificationBody(
  request: Request,
  purpose: "registration" | "authentication",
): Promise<PasskeyRegistrationVerificationBody | PasskeyAuthenticationVerificationBody | null> {
  const value = await boundedRequestJSON(request, MAX_WEBAUTHN_BODY_BYTES);
  if (!isExactObject(value, ["transaction_id", "credential"])) return null;
  if (typeof value.transaction_id !== "string"
      || !/^[A-Za-z0-9_-]{43}$/.test(value.transaction_id)) return null;
  const credential = purpose === "registration"
    ? parseRegistrationCredential(value.credential)
    : parseAuthenticationCredential(value.credential);
  if (!credential) return null;
  if (purpose === "registration") {
    return {
      transaction_id: value.transaction_id,
      credential: credential as RegistrationResponseJSON,
    };
  }
  return {
    transaction_id: value.transaction_id,
    credential: credential as AuthenticationResponseJSON,
  };
}

function parseRegistrationCredential(value: unknown): RegistrationResponseJSON | null {
  if (!isCredentialEnvelope(value)) return null;
  if (!isExactObject(value.response, [
    "clientDataJSON", "attestationObject", "authenticatorData", "transports",
    "publicKeyAlgorithm", "publicKey",
  ], ["authenticatorData", "transports", "publicKeyAlgorithm", "publicKey"])) return null;
  if (!boundedBase64URL(value.response.clientDataJSON, 8_192)
      || !boundedBase64URL(value.response.attestationObject, 24_576)) return null;
  return {
    id: value.id,
    rawId: value.rawId,
    type: "public-key",
    clientExtensionResults: {},
    response: {
      clientDataJSON: value.response.clientDataJSON,
      attestationObject: value.response.attestationObject,
    },
    ...(value.authenticatorAttachment === undefined || value.authenticatorAttachment === null
      ? {}
      : { authenticatorAttachment: value.authenticatorAttachment }),
  };
}

function parseAuthenticationCredential(value: unknown): AuthenticationResponseJSON | null {
  if (!isCredentialEnvelope(value)) return null;
  if (!isExactObject(value.response, [
    "clientDataJSON", "authenticatorData", "signature", "userHandle",
  ], ["userHandle"])) return null;
  if (!boundedBase64URL(value.response.clientDataJSON, 8_192)
      || !boundedBase64URL(value.response.authenticatorData, 8_192)
      || !boundedBase64URL(value.response.signature, 8_192)
      || !boundedBase64URL(value.response.userHandle, 1_024)) return null;
  return {
    id: value.id,
    rawId: value.rawId,
    type: "public-key",
    clientExtensionResults: {},
    response: {
      clientDataJSON: value.response.clientDataJSON,
      authenticatorData: value.response.authenticatorData,
      signature: value.response.signature,
      userHandle: value.response.userHandle,
    },
    ...(value.authenticatorAttachment === undefined || value.authenticatorAttachment === null
      ? {}
      : { authenticatorAttachment: value.authenticatorAttachment }),
  };
}

function isCredentialEnvelope(value: unknown): value is {
  id: string;
  rawId: string;
  type: "public-key";
  response: Record<string, unknown>;
  authenticatorAttachment?: "platform" | "cross-platform" | null;
} {
  if (!isExactObject(value, [
    "id", "rawId", "type", "response", "clientExtensionResults", "authenticatorAttachment",
  ], ["authenticatorAttachment"])) return false;
  return boundedBase64URL(value.id, 2_048)
    && value.rawId === value.id
    && value.type === "public-key"
    && isRecord(value.response)
    && isRecord(value.clientExtensionResults)
    && (value.authenticatorAttachment === undefined
      || value.authenticatorAttachment === null
      || value.authenticatorAttachment === "platform"
      || value.authenticatorAttachment === "cross-platform");
}

function isExactObject(
  value: unknown,
  keys: readonly string[],
  optionalKeys: readonly string[] = [],
): value is Record<string, unknown> {
  if (!isRecord(value)) return false;
  const allowed = new Set(keys);
  const optional = new Set(optionalKeys);
  for (const key of Object.keys(value)) if (!allowed.has(key)) return false;
  for (const key of keys) if (!optional.has(key) && !(key in value)) return false;
  return true;
}

function boundedBase64URL(value: unknown, maximumLength: number): value is string {
  return typeof value === "string"
    && value.length > 0
    && value.length <= maximumLength
    && /^[A-Za-z0-9_-]+$/.test(value);
}

function base64URLBytes(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/")
    + "=".repeat((4 - value.length % 4) % 4);
  const binary = atob(padded);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function webAuthnClientDataIsTopLevel(encoded: string): boolean {
  try {
    const value = JSON.parse(new TextDecoder().decode(base64URLBytes(encoded))) as unknown;
    return isRecord(value)
      && value.crossOrigin !== true
      && !("topOrigin" in value);
  } catch {
    return false;
  }
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

function monitorError(error: unknown, providerID: ProviderID): string {
  const credentialFailure = providerCredentialFailureCode(error, providerID);
  if (credentialFailure !== "provider_check_failed") return credentialFailure;
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
  const configured = registrationAccessKey(env);
  const candidate = request.headers.get("x-when-reset-server-key") ?? "";
  return secretsMatch(candidate, await hashSecret(configured));
}

function registrationAccessKey(env: Pick<Env, "REGISTRATION_ACCESS_KEY">): string {
  const configured = env.REGISTRATION_ACCESS_KEY;
  if (typeof configured !== "string" || configured.length < 32) {
    throw new Error("Registration access key is not configured");
  }
  return configured;
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

function timingSafeEqualStrings(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  const encoder = new TextEncoder();
  return crypto.subtle.timingSafeEqual(encoder.encode(left), encoder.encode(right));
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
  if (error instanceof ProviderFetchError) return `ProviderFetchError:${error.status}`;
  if (error instanceof Error) return error.name.slice(0, 80) || "Error";
  return "unknown_error";
}

function json(body: unknown, status = 200, headers: HeadersInit = {}): Response {
  return Response.json(body, { status, headers });
}

function linkJSON(body: unknown, status = 200, headers: HeadersInit = {}): Response {
  return Response.json(body, { status, headers: linkSecurityHeaders(headers) });
}

type DashboardResponseKind = "overview" | "history" | "devices";

function dashboardJSON(body: unknown, kind: DashboardResponseKind, status = 200): Response {
  assertDashboardResponseSafe(body, kind);
  return linkJSON(body, status);
}

function assertDashboardResponseSafe(value: unknown, kind: DashboardResponseKind): void {
  if (kind === "devices") {
    const deviceRoot = dashboardAllowedObject(
      value,
      ["version", "generated_at", "can_manage", "truncated", "devices"],
      ["devices"],
    );
    for (const deviceValue of dashboardAllowedArray(deviceRoot.devices)) {
      dashboardAllowedObject(deviceValue, [
        "id", "label", "environment", "created_at", "last_seen_at", "last_push_at",
        "push_disabled_at", "push_enabled", "active", "retired", "monitored_accounts",
        "published_accounts", "subscriptions",
      ]);
    }
    return;
  }

  const root = dashboardAllowedObject(
    value,
    kind === "overview"
      ? ["version", "generated_at", "summary", "devices", "runs", "accounts"]
      : ["account", "range", "from", "to", "series", "truncated"],
    kind === "overview" ? ["summary", "devices", "runs", "accounts"] : ["account", "series"],
  );
  if (kind === "overview") {
    dashboardAllowedObject(root.summary, [
      "accounts", "shown_accounts", "healthy", "attention", "unchecked",
      "last_success_at", "nearest_reset_at", "truncated",
    ]);
    dashboardAllowedObject(root.devices, [
      "total", "active", "push_disabled", "production", "development",
    ]);
    dashboardAllowedObject(root.runs, [
      "pending", "running", "failed_24h", "succeeded_24h", "last_completed_at",
    ]);
    for (const accountValue of dashboardAllowedArray(root.accounts)) {
      const account = dashboardAllowedObject(accountValue, [
        "id", "provider_id", "provider_name", "display_name", "plan",
        "plan_expires_at", "trial_expires_at", "status", "last_checked_at",
        "last_success_at", "next_refresh_at", "refresh_interval_seconds",
        "history_retention_days", "source", "source_count", "snapshot",
      ], ["snapshot"]);
      if (account.snapshot === null) continue;
      const snapshot = dashboardAllowedObject(account.snapshot, [
        "fetched_at", "windows", "available_reset_count", "reset_credits",
        "reset_credits_authoritative", "api_balance",
      ], ["windows", "reset_credits", "api_balance"]);
      for (const window of dashboardAllowedArray(snapshot.windows)) {
        dashboardAllowedObject(window, [
          "title", "kind", "window_minutes", "remaining_percent", "resets_at",
        ]);
      }
      for (const credit of dashboardAllowedArray(snapshot.reset_credits)) {
        dashboardAllowedObject(credit, ["status", "granted_at", "expires_at"]);
      }
      if (snapshot.api_balance !== undefined) {
        dashboardAllowedObject(snapshot.api_balance, [
          "title", "currency_code", "spent", "limit", "remaining", "period_start",
          "period_end", "access_expires_at", "is_unlimited", "kind", "unit_label",
        ]);
      }
    }
    return;
  }

  dashboardAllowedObject(root.account, [
    "id", "provider_id", "provider_name", "display_name", "plan",
  ]);
  for (const seriesValue of dashboardAllowedArray(root.series)) {
    const series = dashboardAllowedObject(seriesValue, [
      "id", "title", "kind", "window_minutes", "points",
    ], ["points"]);
    for (const point of dashboardAllowedArray(series.points)) {
      dashboardAllowedObject(point, [
        "recorded_at", "remaining_percent", "resets_at", "plan",
      ]);
    }
  }
}

function dashboardAllowedObject(
  value: unknown,
  allowedKeys: readonly string[],
  nestedKeys: readonly string[] = [],
): Record<string, unknown> {
  if (!isRecord(value)) throw new Error("Unsafe dashboard response shape");
  const allowed = new Set(allowedKeys);
  const nested = new Set(nestedKeys);
  for (const [key, item] of Object.entries(value)) {
    if (!allowed.has(key)) throw new Error("Unsafe dashboard response field");
    if (!nested.has(key) && item !== null && typeof item === "object") {
      throw new Error("Unsafe dashboard response shape");
    }
  }
  return value;
}

function dashboardAllowedArray(value: unknown): unknown[] {
  if (!Array.isArray(value)) throw new Error("Unsafe dashboard response shape");
  return value;
}

function linkSecurityHeaders(additional: HeadersInit = {}): Headers {
  const headers = new Headers(additional);
  headers.set("cache-control", "no-store");
  headers.set("cross-origin-opener-policy", "same-origin");
  headers.set("cross-origin-resource-policy", "same-origin");
  headers.set("permissions-policy", "camera=(), microphone=(), geolocation=(), payment=()");
  headers.set("referrer-policy", "no-referrer");
  headers.set("x-robots-tag", "noindex, nofollow, noarchive");
  headers.set("x-content-type-options", "nosniff");
  headers.set("x-frame-options", "DENY");
  return headers;
}

export const testing = {
  applyVerifiedCredentialResult,
  assertDashboardResponseSafe,
  dashboardAccessKeyGeneration,
  dashboardSessionHash,
  credentialFingerprint,
  createAPNSAuthorization,
  decryptCredentials,
  encryptCredentials,
  handleAPNSResult,
  hashSecret,
  isUUID,
  loadCredentialTarget,
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
