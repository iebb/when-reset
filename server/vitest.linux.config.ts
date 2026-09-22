import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: { alias: { "cloudflare:test": fileURLToPath(new URL("./linux/test/worker-shim.ts", import.meta.url)) } },
  plugins: [{
    name: "bundled-apns-key",
    load(id) {
      if (id.endsWith(".p8")) return `export default ${JSON.stringify(readFileSync(id, "utf8"))}`;
    },
  }],
  test: { include: ["linux/test/**/*.test.ts", "test/**/*.spec.ts"], environment: "node" },
});
