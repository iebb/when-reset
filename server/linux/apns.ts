import { connect, type ClientHttp2Session } from "node:http2";
import type { RuntimeEnv } from "../src/runtime";

// Node's built-in fetch uses HTTP/1.1; Apple's provider API requires HTTP/2.
// Keep this transport scoped to APNs so provider polling uses ordinary direct fetch.
export function createAPNSFetch(
  openSession: (origin: string) => ClientHttp2Session = connect,
): NonNullable<RuntimeEnv["APNS_FETCH"]> {
  return async (input, init) => {
    const url = new URL(input);
    if (!["https://api.push.apple.com", "https://api.sandbox.push.apple.com"].includes(url.origin)
        || !/^\/3\/device\/[a-f0-9]+$/i.test(url.pathname)
        || init.method !== "POST" || typeof init.body !== "string") {
      throw new Error("Invalid APNs request");
    }
    return new Promise<Response>((resolve, reject) => {
      const session = openSession(url.origin);
      const request = session.request({
        ...Object.fromEntries(new Headers(init.headers)),
        ":method": "POST",
        ":path": url.pathname,
      });
      let settled = false;
      let status = 0;
      let size = 0;
      const chunks: Buffer[] = [];
      const finish = (response?: Response) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        request.close();
        session.destroy();
        if (response) resolve(response);
        else reject(new Error("APNs transport failed"));
      };
      const timeout = setTimeout(() => finish(), 30_000);
      session.on("error", () => finish());
      request.on("error", () => finish());
      request.on("aborted", () => finish());
      request.on("response", (headers) => { status = Number(headers[":status"]); });
      request.on("data", (chunk: Buffer) => {
        size += chunk.length;
        if (size > 64 * 1_024) finish();
        else chunks.push(chunk);
      });
      request.on("end", () => {
        if (status < 200 || status > 599) return finish();
        const body = [204, 205, 304].includes(status) ? null : Buffer.concat(chunks).toString("utf8");
        finish(new Response(body, { status }));
      });
      request.on("close", () => { if (!settled) finish(); });
      request.end(init.body);
    });
  };
}
