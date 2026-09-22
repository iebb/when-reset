import { resolve } from "node:path";

export function readConfig(values: Record<string, string | undefined>) {
  const originValue = values.PUBLIC_ORIGIN;
  if (!originValue) throw new Error("PUBLIC_ORIGIN must be your external HTTPS origin");
  let url: URL;
  try { url = new URL(originValue); } catch { throw new Error("Invalid PUBLIC_ORIGIN"); }
  if (url.protocol !== "https:" || url.username || url.password || url.pathname !== "/" || url.search || url.hash) {
    throw new Error("PUBLIC_ORIGIN must be an HTTPS origin without a path, credentials, query or fragment");
  }
  const registrationKey = values.REGISTRATION_ACCESS_KEY;
  const encryptionKey = values.CREDENTIAL_ENCRYPTION_KEY;
  if (!registrationKey || registrationKey.length < 32) throw new Error("REGISTRATION_ACCESS_KEY must have at least 32 characters");
  if (!encryptionKey || encryptionKey.length < 32) throw new Error("CREDENTIAL_ENCRYPTION_KEY must have at least 32 characters");
  if (encryptionKey === registrationKey) throw new Error("Use different registration and encryption keys");
  const port = Number(values.PORT ?? "8787");
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("PORT must be between 1 and 65535");
  return {
    origin: url.origin,
    host: values.HOST || "127.0.0.1",
    port,
    dataDirectory: resolve(values.DATA_DIR || "./data"),
    registrationKey,
    encryptionKey,
  };
}
