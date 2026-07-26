import { renderSVG } from "uqr";

const PAGE_SCRIPT = String.raw`
const form = document.querySelector("#link-form");
const keyInput = document.querySelector("#access-key");
const submitButton = document.querySelector("#create-link");
const status = document.querySelector("#status");
const result = document.querySelector("#link-result");
const qr = document.querySelector("#qr-code");
const expiry = document.querySelector("#expiry");
const openLink = document.querySelector("#open-link");

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const accessKey = keyInput.value.trim();
  keyInput.value = "";
  submitButton.disabled = true;
  result.hidden = true;
  status.textContent = "Creating a private link…";
  try {
    const response = await fetch("/v1/link-sessions", {
      method: "POST",
      headers: { "X-When-Reset-Server-Key": accessKey },
      cache: "no-store",
      credentials: "omit",
      redirect: "error",
    });
    if (!response.ok) throw new Error("link_failed");
    const payload = await response.json();
    if (typeof payload.qr_svg !== "string" || typeof payload.link_uri !== "string"
        || typeof payload.expires_at !== "number") throw new Error("invalid_response");
    const linkURL = new URL(payload.link_uri);
    if (linkURL.protocol !== "whenreset:" || linkURL.host !== "link-worker") {
      throw new Error("invalid_link");
    }
    qr.innerHTML = payload.qr_svg;
    openLink.href = payload.link_uri;
    expiry.textContent = "Expires " + new Date(payload.expires_at * 1000).toLocaleTimeString();
    result.hidden = false;
    status.textContent = "Scan with Camera or open on this device.";
  } catch (_) {
    status.textContent = "Couldn’t create a link. Check the access key and try again.";
  } finally {
    submitButton.disabled = false;
  }
});
`;

export function renderLinkPage(origin: string, displayName: string, nonce: string): string {
  const safeOrigin = escapeHTML(origin);
  const safeDisplayName = escapeHTML(displayName);
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Link When Reset</title>
  <style nonce="${nonce}">
    :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: Canvas; color: CanvasText; }
    main { width: min(34rem, calc(100% - 2rem)); padding: 2rem; box-sizing: border-box; }
    .card { border: 1px solid color-mix(in srgb, CanvasText 15%, transparent); border-radius: 1.25rem; padding: 1.5rem; background: color-mix(in srgb, Canvas 94%, CanvasText 6%); }
    h1 { margin: 0 0 .35rem; font-size: 1.8rem; }
    p { line-height: 1.45; }
    .host { color: GrayText; overflow-wrap: anywhere; }
    label { display: block; font-weight: 600; margin: 1.25rem 0 .45rem; }
    input, button, a.button { width: 100%; min-height: 3rem; border-radius: .8rem; box-sizing: border-box; font: inherit; }
    input { border: 1px solid color-mix(in srgb, CanvasText 25%, transparent); padding: .7rem .85rem; background: Canvas; color: CanvasText; }
    button, a.button { margin-top: .8rem; border: 0; padding: .75rem 1rem; background: #0a84ff; color: white; font-weight: 650; cursor: pointer; }
    button:disabled { opacity: .55; cursor: wait; }
    a.button { display: flex; align-items: center; justify-content: center; text-decoration: none; }
    #status { min-height: 1.5rem; color: GrayText; }
    #link-result { margin-top: 1.2rem; text-align: center; }
    #qr-code { display: grid; place-items: center; padding: 1rem; border-radius: 1rem; background: white; }
    #qr-code svg { display: block; width: min(100%, 22rem); height: auto; }
    #expiry { margin-bottom: .2rem; font-variant-numeric: tabular-nums; }
    .notice { font-size: .9rem; color: GrayText; }
  </style>
</head>
<body>
  <main>
    <section class="card">
      <h1>Link When Reset</h1>
      <p class="host">${safeDisplayName}<br>${safeOrigin}</p>
      <p>Create a five-minute, one-use link for the When Reset app.</p>
      <form id="link-form" method="post" action="/v1/link-sessions">
        <label for="access-key">Server access key</label>
        <input id="access-key" name="access-key" type="password" minlength="32" autocomplete="off" required>
        <button id="create-link" type="submit">Create QR code</button>
      </form>
      <p id="status" role="status" aria-live="polite"></p>
      <section id="link-result" hidden>
        <div id="qr-code" aria-label="When Reset worker link QR code"></div>
        <p id="expiry"></p>
        <a id="open-link" class="button" href="#">Open When Reset</a>
        <p class="notice">Scanning does not upload anything. When Reset shows the server and affected accounts for confirmation before linking or uploading provider credentials.</p>
      </section>
    </section>
  </main>
  <script nonce="${nonce}">${PAGE_SCRIPT}</script>
</body>
</html>`;
}

export function renderLinkQRCode(linkURI: string): string {
  return renderSVG(linkURI, { ecc: "M", border: 4 });
}

function escapeHTML(value: string): string {
  return value.replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "\"": "&quot;",
    "'": "&#39;",
  })[character] ?? character);
}
