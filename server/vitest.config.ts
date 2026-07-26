import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

const testServerAccessKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
const testCredentialEncryptionKey = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";
process.env.REGISTRATION_ACCESS_KEY ??= testServerAccessKey;
process.env.CREDENTIAL_ENCRYPTION_KEY ??= testCredentialEncryptionKey;

export default defineConfig({
  plugins: [cloudflareTest({
    wrangler: { configPath: "./wrangler.jsonc" },
    miniflare: {
      bindings: {
        REGISTRATION_ACCESS_KEY: testServerAccessKey,
        CREDENTIAL_ENCRYPTION_KEY: testCredentialEncryptionKey,
      },
    },
  })],
});
