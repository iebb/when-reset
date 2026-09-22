import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { connect, createServer as createHTTP2Server } from "node:http2";
import { request as httpRequest } from "node:http";
import { spawnSync } from "node:child_process";
import type { AddressInfo } from "node:net";
import { afterEach, describe, expect, it, vi } from "vitest";
import worker, { processQueue, runScheduledRefresh, type QueueTarget } from "../../src/index";
import type { RuntimeEnv } from "../../src/runtime";
import { createAPNSFetch } from "../apns";
import { readConfig } from "../config";
import { SQLiteDatabase } from "../database";
import { createHTTPServer } from "../http";
import { SQLiteQueue } from "../queue";
import { Scheduler } from "../scheduler";

const schema = readFileSync("schema.sql", "utf8");
const migrations = readdirSync("migrations").map((name) => ({ name, sql: readFileSync(`migrations/${name}`, "utf8") }));
const directories: string[] = [];
const databases: SQLiteDatabase[] = [];
const httpFetch = globalThis.fetch;

function database(filename = ":memory:") {
  const db = new SQLiteDatabase(filename);
  databases.push(db);
  db.initialize(schema, migrations);
  return db;
}

function diskPath() {
  const directory = mkdtempSync(join(tmpdir(), "when-reset-linux-test-"));
  directories.push(directory);
  return join(directory, "test.sqlite");
}

afterEach(() => {
  vi.unstubAllGlobals();
  for (const db of databases.splice(0)) if (db.sqlite.isOpen) db.close();
  for (const directory of directories.splice(0)) rmSync(directory, { recursive: true, force: true });
});

describe("SQLite storage", () => {
  it("baselines fresh installs, preserves data on restart and applies later migrations exactly once", async () => {
    const path = diskPath();
    const first = database(path);
    first.sqlite.exec("CREATE TABLE marker (value TEXT); INSERT INTO marker VALUES ('kept')");
    first.close();
    const reopened = database(path);
    const updated = [...migrations, { name: "9999_test.sql", sql: "ALTER TABLE marker ADD COLUMN updated INTEGER NOT NULL DEFAULT 1" }];
    reopened.initialize(schema, updated);
    reopened.initialize(schema, updated);
    expect(await reopened.prepare("SELECT * FROM marker").first()).toEqual({ value: "kept", updated: 1 });
    expect(() => reopened.initialize(schema, [...updated, {
      name: "99999_broken.sql", sql: "UPDATE marker SET updated = 2; SELECT * FROM missing_table;",
    }])).toThrow();
    expect(await reopened.prepare("SELECT updated FROM marker").first("updated")).toBe(1);
  });

  it("rolls back failed batches, reports guarded changes and preserves binary values", async () => {
    const db = database();
    db.sqlite.exec("CREATE TABLE sample (id INTEGER PRIMARY KEY, value BLOB)");
    const result = await db.prepare("INSERT INTO sample VALUES (?, ?)").bind(1, new Uint8Array([1, 2, 255])).run();
    expect(result.meta.changes).toBe(1);
    expect(new Uint8Array((await db.prepare("SELECT value FROM sample").first<ArrayBuffer>("value"))!)).toEqual(new Uint8Array([1, 2, 255]));
    await expect(db.batch([
      db.prepare("INSERT INTO sample VALUES (2, NULL)"),
      db.prepare("INSERT INTO sample VALUES (1, NULL)"),
    ])).rejects.toThrow();
    expect(await db.prepare("SELECT count(*) AS n FROM sample").first("n")).toBe(1);
    expect((await db.prepare("UPDATE sample SET value = NULL WHERE id = 99").run()).meta.changes).toBe(0);
  });
});

describe("persistent jobs and scheduling", () => {
  it("preserves delayed/retried jobs across restart and honors explicit acknowledgements", async () => {
    const path = diskPath();
    let now = 1_000;
    let db = database(path);
    let queue = new SQLiteQueue(db, () => now);
    await queue.send({ kind: "test" }, { delaySeconds: 10 });
    expect(await queue.consume(async () => { throw new Error("not due"); })).toBe(false);
    db.close();
    db = database(path);
    queue = new SQLiteQueue(db, () => now);
    now = 11_000;
    await queue.consume(async (batch) => {
      expect(batch.messages[0].attempts).toBe(1);
      expect(batch.messages[0].body).toEqual({ kind: "test" });
      batch.messages[0].retry({ delaySeconds: 5 });
    });
    expect(await queue.consume(async () => {})).toBe(false);
    now += 5_000;
    await queue.consume(async (batch) => {
      expect(batch.messages[0].attempts).toBe(2);
      batch.ackAll();
      throw new Error("acknowledgement must win");
    });
    expect(await queue.consume(async () => {})).toBe(false);
  });

  it("limits retries and enqueues batches atomically", async () => {
    let now = 0;
    const db = database();
    const queue = new SQLiteQueue(db, () => now);
    await expect(queue.sendBatch([{ body: "valid" }, { body: undefined }])).rejects.toThrow();
    expect(await queue.consume(async () => {})).toBe(false);
    await queue.send({ kind: "test" });
    for (let attempt = 1; attempt <= 4; attempt++) {
      await queue.consume(async (batch) => { expect(batch.messages[0].attempts).toBe(attempt); batch.retryAll(); });
      now += 60_000;
    }
    expect(await queue.consume(async () => {})).toBe(false);
  });

  it("recovers a job after a process dies with a persisted lease", async () => {
    const db = database();
    const queue = new SQLiteQueue(db, () => 1_000_000);
    await queue.send({ kind: "test" });
    db.sqlite.exec("UPDATE _server_queue SET attempts = 1, available_at = 999999");
    await queue.consume(async (batch) => { expect(batch.messages[0].attempts).toBe(2); });
    expect(await queue.consume(async () => {})).toBe(false);
  });

  it("keeps UTC five-minute/hour boundaries and does not repeat completed intervals on restart", async () => {
    const path = diskPath();
    let db = database(path);
    const run = vi.fn(async (_time: number) => {});
    const hour = Date.UTC(2026, 8, 22, 10);
    const scheduler = new Scheduler(db, run);
    await Promise.all([scheduler.tick(hour + 20_000), scheduler.tick(hour + 21_000)]);
    expect(run.mock.calls).toEqual([[hour]]);
    db.close();
    db = database(path);
    const restarted = new Scheduler(db, run);
    await restarted.tick(hour + 60_000);
    await restarted.tick(hour + 300_000);
    expect(run.mock.calls).toEqual([[hour], [hour + 300_000]]);
  });

  it("retries failed scheduling without recording completion", async () => {
    const db = database();
    const run = vi.fn().mockRejectedValueOnce(new Error("temporary")).mockResolvedValue(undefined);
    const scheduler = new Scheduler(db, run);
    await scheduler.tick(300_000);
    await scheduler.tick(301_000);
    expect(run).toHaveBeenCalledTimes(1);
    await scheduler.tick(360_000);
    expect(run).toHaveBeenCalledTimes(2);
    expect(await db.prepare("SELECT completed_at FROM _server_schedule").first("completed_at")).toBe(300_000);
  });
});

describe("Linux network transports", () => {
  it("refuses to print access keys to redirected output", () => {
    const result = spawnSync(process.execPath, ["scripts/show-access-key.mjs"], {
      encoding: "utf8", env: {
        ...process.env, REGISTRATION_ACCESS_KEY: "dashboard-canary".repeat(4),
        CREDENTIAL_ENCRYPTION_KEY: "encryption-canary".repeat(4),
      },
    });
    expect(result.status).toBe(1);
    expect(result.stdout).toBe("");
    expect(result.stderr).toContain("Redirected output is refused");
    expect(result.stderr).not.toContain("canary");
  });

  it("serves the app protocol, protects the public origin and records a scheduled provider sample", async () => {
    const db = database();
    const queue = new SQLiteQueue<QueueTarget>(db);
    const apns = vi.fn(async () => new Response(null, { status: 200 }));
    const env: RuntimeEnv = {
      DB: db, PUSH_QUEUE: queue, REGISTRATION_ACCESS_KEY: "a".repeat(43),
      CREDENTIAL_ENCRYPTION_KEY: "b".repeat(43), APNS_FETCH: apns,
    };
    const server = createHTTPServer("https://reset.example", (request) => worker.fetch(request, env));
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
    const request = (path: string, init?: RequestInit) => httpFetch(origin + path, init);
    try {
      expect((await request("/healthz")).status).toBe(200);
      for (const path of ["/.env", "/server.env", "/data/when-reset.sqlite", "/schema.sql",
        "/apns/WhenResetSharedAPNs.p8", "/%2e%2e/%2e%2e/etc/when-reset/server.env"]) {
        const response = await request(path);
        expect(response.status).toBe(404);
        expect(response.headers.get("cache-control")).toBe("no-store");
        const text = await response.text();
        expect(text).not.toContain(env.REGISTRATION_ACCESS_KEY);
        expect(text).not.toContain(env.CREDENTIAL_ENCRYPTION_KEY);
      }
      expect((await request("/v1/dashboard")).status).toBe(401);
      const loginHeaders = { origin: "https://reset.example", "x-when-reset-server-key": env.REGISTRATION_ACCESS_KEY };
      expect((await request("/v1/dashboard/session", {
        method: "POST", headers: { ...loginHeaders, origin: "https://evil.example", "x-forwarded-host": "evil.example" },
      })).status).toBe(403);
      const login = await request("/v1/dashboard/session", { method: "POST", headers: loginHeaders });
      expect(login.status).toBe(204);
      expect(login.headers.get("set-cookie")).toContain("Secure");
      const cookie = login.headers.get("set-cookie")!.split(";")[0];
      const link = await request("/v1/link-sessions", { method: "POST", headers: loginHeaders });
      const linkBody = await link.json() as { link_uri: string };
      expect(new URL(linkBody.link_uri).searchParams.get("server")).toBe("https://reset.example");
      const deviceID = "019f724a-3414-4d52-ae37-0c7024a1ab97";
      const accountID = "019f724a-3414-4d52-ae37-0c7024a1ab98";
      const secret = "c".repeat(43);
      const registered = await request("/v1/devices", {
        method: "POST", headers: loginHeaders,
        body: JSON.stringify({ device_id: deviceID, device_secret: secret, apns_token: "d".repeat(64) }),
      });
      expect(registered.status).toBe(201);
      const credentials = "provider-secret-canary";
      const upload = await request(`/v1/devices/${deviceID}/accounts/${accountID}`, {
        method: "PUT", headers: { authorization: `Bearer ${secret}` },
        body: JSON.stringify({
          provider_id: "synthetic", workspace_id: "own-network", display_name: "Linux account", plan: "Pro",
          refresh_interval_seconds: 300, history_retention_days: 35, consent_revision: 1,
          credentials: { access_token: credentials, refresh_token: "", id_token: "", expires_at: null }, missing_quotas: [],
        }),
      });
      expect(upload.status).toBe(201);
      expect(await db.prepare("SELECT encrypted_credentials FROM monitored_accounts").first("encrypted_credentials")).not.toContain(credentials);
      const now = Math.floor(Date.now() / 1_000);
      const provider = vi.fn(async (url: string) => {
        expect(url).toBe("https://api.synthetic.new/v2/quotas");
        return Response.json({ rollingFiveHourLimit: { max: 100, remaining: 75, nextTickAt: now + 3600 } });
      });
      vi.stubGlobal("fetch", provider);
      await runScheduledRefresh(env, Date.now());
      // Drain both the monitoring job and its resulting push hint.
      for (let index = 0; index < 5 && await queue.consume((batch) => processQueue(batch, env)); index++) {}
      expect(provider).toHaveBeenCalledTimes(1);
      expect(apns).toHaveBeenCalled();
      expect(await db.prepare("SELECT remaining_percent FROM usage_history").first("remaining_percent")).toBe(75);
      const dashboard = await request("/v1/dashboard", { headers: { cookie } });
      expect(dashboard.status).toBe(200);
      expect(await dashboard.text()).not.toContain(credentials);
      const sync = await request(`/v1/devices/${deviceID}/accounts/${accountID}/sync`, { headers: { authorization: `Bearer ${secret}` } });
      expect(sync.status).toBe(200);
      expect(sync.headers.get("cache-control")).toBe("no-store");
      expect(await sync.text()).not.toContain(credentials);
      // Send the declared size before the body so an early 413 does not race the
      // client's large upload and turn into an OS-dependent broken-pipe error.
      const oversizedStatus = await new Promise<number | undefined>((resolve, reject) => {
        const oversized = httpRequest(`${origin}/v1/devices`, {
          method: "POST", headers: { "content-length": String(512 * 1024 + 1) },
        }, (response) => { response.resume(); resolve(response.statusCode); });
        oversized.on("error", reject);
        oversized.end();
      });
      expect(oversizedStatus).toBe(413);
    } finally {
      await new Promise<void>((resolve) => { server.close(() => resolve()); server.closeAllConnections(); });
    }
  });

  it("delivers APNs over HTTP/2 with the required headers and handles Apple errors", async () => {
    const server = createHTTP2Server();
    const received: string[] = [];
    server.on("stream", (stream, headers) => {
      expect(headers[":method"]).toBe("POST");
      expect(headers["apns-topic"]).toBe("ad.neko.when");
      stream.on("data", (chunk) => received.push(String(chunk)));
      stream.on("end", () => { stream.respond({ ":status": 410 }); stream.end('{"reason":"Unregistered"}'); });
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const transport = createAPNSFetch(() => connect(`http://127.0.0.1:${(server.address() as AddressInfo).port}`));
    try {
      const response = await transport(`https://api.push.apple.com/3/device/${"a".repeat(64)}`, {
        method: "POST", headers: { "apns-topic": "ad.neko.when" }, body: '{"aps":{"content-available":1}}',
      });
      expect(response.status).toBe(410);
      expect(await response.json()).toEqual({ reason: "Unregistered" });
      expect(received.join("")).toContain("content-available");
      await expect(transport("https://evil.example/3/device/aa", { method: "POST", body: "{}" })).rejects.toThrow();
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });

  it("rejects insecure origins and invalid secrets before starting", () => {
    const values = { PUBLIC_ORIGIN: "https://reset.example", REGISTRATION_ACCESS_KEY: "a".repeat(43), CREDENTIAL_ENCRYPTION_KEY: "b".repeat(43) };
    expect(readConfig(values)).toMatchObject({ host: "127.0.0.1", port: 8787 });
    for (const origin of ["http://reset.example", "https://reset.example/path", "https://user:pass@reset.example", "https://reset.example?x=1"]) {
      expect(() => readConfig({ ...values, PUBLIC_ORIGIN: origin })).toThrow();
    }
    expect(() => readConfig({ ...values, CREDENTIAL_ENCRYPTION_KEY: values.REGISTRATION_ACCESS_KEY })).toThrow();
    expect(() => readConfig({ ...values, PORT: "0" })).toThrow();
  });
});
