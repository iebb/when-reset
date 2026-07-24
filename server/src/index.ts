import APNSPrivateKey from "../apns/WhenResetSharedAPNs.p8";

const MAX_BODY_BYTES = 2_048;
const ACTIVE_DEVICE_DAYS = 45;
const DATABASE_BATCH_SIZE = 500;
const QUEUE_BATCH_SIZE = 100;
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

type PushTarget = {
  device_id: string;
  apns_token: string;
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
      return json({ error: "internal_error" }, 500);
    }
  },

  async scheduled(_controller, env, context): Promise<void> {
    context.waitUntil(enqueueActiveDevices(env));
  },

  async queue(batch, env): Promise<void> {
    await deliverQueuedPushes(batch as MessageBatch<PushTarget>, env);
  },
} satisfies ExportedHandler<Env>;

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (request.method === "GET" && url.pathname === "/healthz") {
    return json({ ok: true, mode: "self_hosted", topic: APNS_TOPIC });
  }

  if (request.method === "POST" && url.pathname === "/v1/devices") {
    if (!(await registrationAccessAllowed(request, env))) {
      return json({ error: "unauthorized" }, 401);
    }
    const registration = await parseRegistration(request);
    if (!registration) return json({ error: "invalid_registration" }, 400);
    return registerDevice(env, registration);
  }

  const match = /^\/v1\/devices\/([0-9a-f-]{36})(?:\/(refresh))?$/.exec(url.pathname);
  if (!match) return json({ error: "not_found" }, 404);

  const deviceID = match[1];
  if (!isUUID(deviceID)) return json({ error: "invalid_device_id" }, 400);
  const secret = bearerToken(request);
  if (!secret) return json({ error: "unauthorized" }, 401);

  const row = await env.DB.prepare(
    "SELECT device_id, secret_hash, apns_token FROM devices WHERE device_id = ?"
  ).bind(deviceID).first<DeviceRow>();
  if (!row || !(await secretsMatch(secret, row.secret_hash))) {
    return json({ error: "unauthorized" }, 401);
  }

  if (request.method === "DELETE" && !match[2]) {
    await env.DB.prepare("DELETE FROM devices WHERE device_id = ?").bind(deviceID).run();
    return new Response(null, { status: 204 });
  }

  if (request.method === "POST" && match[2] === "refresh") {
    const authorization = await currentAPNSAuthorization(env);
    const result = await sendSilentPush(env, row.apns_token, authorization);
    await handleAPNSResult(env, row, result);
    if (!result.ok) return json({ error: "apns_rejected", reason: result.reason }, 502);
    return json({ ok: true });
  }

  return json({ error: "method_not_allowed" }, 405, { Allow: match[2] ? "POST" : "DELETE" });
}

async function registerDevice(env: Env, registration: DeviceRegistration): Promise<Response> {
  const existing = await env.DB.prepare(
    "SELECT device_id, secret_hash, apns_token FROM devices WHERE device_id = ?"
  ).bind(registration.device_id).first<DeviceRow>();

  if (existing && !(await secretsMatch(registration.device_secret, existing.secret_hash))) {
    return json({ error: "unauthorized" }, 401);
  }

  const now = Math.floor(Date.now() / 1_000);
  const secretHash = existing?.secret_hash ?? await hashSecret(registration.device_secret);
  await env.DB.prepare(
    `INSERT INTO devices (device_id, secret_hash, apns_token, created_at, last_seen_at)
     VALUES (?, ?, ?, ?, ?)
     ON CONFLICT(device_id) DO UPDATE SET
       apns_token = excluded.apns_token,
       last_seen_at = excluded.last_seen_at`
  ).bind(registration.device_id, secretHash, registration.apns_token, now, now).run();

  console.log(JSON.stringify({ event: existing ? "device_updated" : "device_registered" }));
  return json({ ok: true }, existing ? 200 : 201);
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
    ).bind(activeSince, cursor, DATABASE_BATCH_SIZE).all<PushTarget>();
    const rows = result.results;
    for (let offset = 0; offset < rows.length; offset += QUEUE_BATCH_SIZE) {
      await env.PUSH_QUEUE.sendBatch(
        rows.slice(offset, offset + QUEUE_BATCH_SIZE).map((body) => ({ body }))
      );
    }
    enqueued += rows.length;
    if (rows.length < DATABASE_BATCH_SIZE) break;
    cursor = rows.at(-1)?.device_id ?? cursor;
  }

  console.log(JSON.stringify({ event: "scheduled_push_enqueued", enqueued }));
}

async function deliverQueuedPushes(batch: MessageBatch<PushTarget>, env: Env): Promise<void> {
  validateAPNSConfiguration();
  const authorization = await currentAPNSAuthorization(env);
  let delivered = 0;
  let rejected = 0;
  await Promise.all(batch.messages.map(async (message) => {
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
    attempted: batch.messages.length,
    delivered,
    rejected,
  }));
}

async function handleAPNSResult(env: Env, row: PushTarget, result: APNSResult): Promise<void> {
  if (result.ok) {
    await env.DB.prepare(
      "UPDATE devices SET last_push_at = ? WHERE device_id = ? AND apns_token = ?"
    ).bind(Math.floor(Date.now() / 1_000), row.device_id, row.apns_token).run();
  } else if (isPermanentAPNSRejection(result)) {
    await env.DB.prepare("DELETE FROM devices WHERE device_id = ? AND apns_token = ?")
      .bind(row.device_id, row.apns_token).run();
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
  if (length > MAX_BODY_BYTES) return null;
  const text = await request.text();
  if (text.length > MAX_BODY_BYTES) return null;
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

export const testing = { createAPNSAuthorization, hashSecret, isUUID, parseRegistration };
