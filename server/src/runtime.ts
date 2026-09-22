// Derive the shared application contract from Wrangler's generated bindings. The Linux
// adapter only needs the database and queue operations actually used by the application.
export type RuntimeEnv = Omit<Cloudflare.Env, "DB" | "PUSH_QUEUE"> & {
  DB: Pick<Cloudflare.Env["DB"], "prepare" | "batch">;
  PUSH_QUEUE: Pick<Cloudflare.Env["PUSH_QUEUE"], "send" | "sendBatch">;
  APNS_FETCH?: (url: string, init: RequestInit) => Promise<Response>;
};
