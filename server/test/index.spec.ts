import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { testing } from "../src/index";

const deviceID = "019f724a-3414-4d52-ae37-0c7024a1ab97";
const deviceSecret = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
const apnsToken = "a".repeat(64);

beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare("DROP TABLE IF EXISTS devices"),
    env.DB.prepare(`CREATE TABLE devices (
      device_id TEXT PRIMARY KEY NOT NULL,
      secret_hash TEXT NOT NULL,
      apns_token TEXT NOT NULL UNIQUE,
      created_at INTEGER NOT NULL,
      last_seen_at INTEGER NOT NULL,
      last_push_at INTEGER
    )`),
  ]);
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
