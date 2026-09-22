import { createServer, type IncomingMessage } from "node:http";

const MAX_BODY_BYTES = 512 * 1_024;

export function createHTTPServer(origin: string, handle: (request: Request) => Promise<Response>) {
  const server = createServer({ maxHeaderSize: 16 * 1_024 }, async (incoming, outgoing) => {
    try {
      // Never derive URLs from Host or forwarded headers. This is the public HTTPS
      // origin used for CSRF checks, one-use links, Secure cookies and WebAuthn.
      const path = incoming.url ?? "/";
      const url = new URL(path, origin);
      if (!path.startsWith("/") || path.startsWith("//") || url.origin !== origin) {
        outgoing.writeHead(400).end();
        return;
      }
      const headers = new Headers();
      for (const [name, values] of Object.entries(incoming.headers)) {
        if (Array.isArray(values)) values.forEach((value) => headers.append(name, value));
        else if (values !== undefined) headers.set(name, values);
      }
      const method = incoming.method ?? "GET";
      const bytes = await readBody(incoming);
      if (["GET", "HEAD"].includes(method) && bytes.byteLength > 0) {
        outgoing.writeHead(400).end();
        return;
      }
      const response = await handle(new Request(url, {
        method,
        headers,
        body: bytes.byteLength ? bytes.buffer : undefined,
      }));
      outgoing.statusCode = response.status;
      response.headers.forEach((value, name) => {
        if (name !== "set-cookie") outgoing.setHeader(name, value);
      });
      const cookies = response.headers.getSetCookie();
      if (cookies.length) outgoing.setHeader("set-cookie", cookies);
      // Application responses are bounded JSON or the static dashboard page.
      outgoing.end(method === "HEAD" ? undefined : Buffer.from(await response.arrayBuffer()));
    } catch (error) {
      if (outgoing.headersSent) { outgoing.destroy(); return; }
      const oversized = error instanceof BodyTooLarge;
      outgoing.writeHead(oversized ? 413 : 400, {
        "content-type": "application/json",
        "cache-control": "no-store",
        "connection": "close",
      }).end(JSON.stringify({ error: oversized ? "body_too_large" : "invalid_request" }));
    }
  });
  server.requestTimeout = 30_000;
  server.headersTimeout = 15_000;
  server.keepAliveTimeout = 5_000;
  server.setTimeout(60_000, (socket) => socket.destroy());
  return server;
}

class BodyTooLarge extends Error {}

function readBody(request: IncomingMessage): Promise<Uint8Array<ArrayBuffer>> {
  if (Number(request.headers["content-length"]) > MAX_BODY_BYTES) {
    request.resume();
    return Promise.reject(new BodyTooLarge());
  }
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks: Buffer[] = [];
    const onData = (chunk: Buffer) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        request.removeListener("data", onData);
        chunks.length = 0;
        reject(new BodyTooLarge());
      } else chunks.push(chunk);
    };
    request.on("data", onData);
    request.on("error", () => reject(new Error("Request failed")));
    request.on("aborted", () => reject(new Error("Request aborted")));
    request.on("end", () => resolve(Uint8Array.from(Buffer.concat(chunks))));
  });
}
