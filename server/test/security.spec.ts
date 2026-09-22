import { env } from "cloudflare:test";
import { describe, expect, it, vi } from "vitest";
import worker, { testing } from "../src/index";
import type { RuntimeEnv } from "../src/runtime";

const deviceID = "a19f724a-3414-4d52-ae37-0c7024a1ab97";
const deviceSecret = "C".repeat(43);
const deviceToken = "c".repeat(64);
const canary = "do-not-disclose-credential-canary";

describe("secret disclosure boundaries", () => {
  // Isolate these tests from the production schema and the larger API suite.
  async function pushEnvironment(apns: RuntimeEnv["APNS_FETCH"]): Promise<RuntimeEnv> {
    const row = {
      device_id: deviceID, secret_hash: await testing.hashSecret(deviceSecret),
      apns_token: deviceToken, apns_environment: "production", push_disabled_at: null,
    };
    const statement = {
      bind() { return this; },
      first: async () => row,
      run: async () => ({ meta: { changes: 1 } }),
    };
    return { ...env, APNS_FETCH: apns, DB: { prepare: (sql: string) => sql.includes("apns_provider_tokens")
      ? { ...statement, first: async () => ({ token: canary, issued_at: Math.floor(Date.now() / 1_000) }) }
      : statement } } as unknown as RuntimeEnv;
  }

  it.each([canary, { token: canary }, "BadDeviceToken"])(
    "allows only recognized APNs rejection codes: %j", async (reason) => {
      const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
      try {
        const testEnv = await pushEnvironment(async (_url, init) => {
          expect(init.redirect).toBe("manual");
          return Response.json({ reason, token: canary }, { status: 400 });
        });
        const response = await worker.fetch(new Request(`https://reset.example/v1/devices/${deviceID}/refresh`, {
          method: "POST", headers: { authorization: `Bearer ${deviceSecret}` },
        }), testEnv);
        expect(response.status).toBe(502);
        expect(response.headers.get("cache-control")).toBe("no-store");
        expect(await response.json()).toEqual(reason === "BadDeviceToken"
          ? { error: "apns_rejected", reason: "BadDeviceToken" }
          : { error: "apns_rejected" });
        const logs = JSON.stringify(warning.mock.calls);
        for (const secret of [canary, deviceSecret, deviceToken]) expect(logs).not.toContain(secret);
      } finally { warning.mockRestore(); }
    },
  );

  it("cancels oversized APNs error bodies instead of buffering or echoing them", async () => {
    const cancel = vi.fn();
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      const testEnv = await pushEnvironment(async () => new Response(new ReadableStream({
        start(controller) { controller.enqueue(new Uint8Array(1_025)); }, cancel,
      }), { status: 400 }));
      const response = await worker.fetch(new Request(`https://reset.example/v1/devices/${deviceID}/refresh`, {
        method: "POST", headers: { authorization: `Bearer ${deviceSecret}` },
      }), testEnv);
      expect(await response.json()).toEqual({ error: "apns_rejected" });
      expect(cancel).toHaveBeenCalledOnce();
    } finally { warning.mockRestore(); }
  });

  it("never logs exception names, messages, causes, request bodies or credentials", async () => {
    const failure = new Error(canary, { cause: canary });
    failure.name = canary;
    const errorLog = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      const testEnv = { ...env, DB: { prepare() { throw failure; } } } as unknown as RuntimeEnv;
      const response = await worker.fetch(new Request("https://reset.example/v1/devices", {
        method: "POST", headers: { "x-when-reset-server-key": env.REGISTRATION_ACCESS_KEY },
        body: JSON.stringify({ device_id: deviceID, device_secret: deviceSecret, apns_token: deviceToken }),
      }), testEnv);
      expect(response.status).toBe(500);
      expect(await response.json()).toEqual({ error: "internal_error" });
      expect(errorLog).toHaveBeenCalledWith(JSON.stringify({ event: "request_failed", error: "Error" }));
      const logs = JSON.stringify(errorLog.mock.calls);
      for (const secret of [canary, deviceSecret, deviceToken, env.REGISTRATION_ACCESS_KEY,
        env.CREDENTIAL_ENCRYPTION_KEY]) expect(logs).not.toContain(secret);
    } finally { errorLog.mockRestore(); }
  });
});
