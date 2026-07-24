import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

const testServerAccessKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
process.env.REGISTRATION_ACCESS_KEY ??= testServerAccessKey;

export default defineConfig({
  plugins: [cloudflareTest({
    wrangler: { configPath: "./wrangler.jsonc" },
    miniflare: {
      bindings: {
        REGISTRATION_ACCESS_KEY: testServerAccessKey,
      },
    },
  })],
});
