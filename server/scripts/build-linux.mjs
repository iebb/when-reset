import { build } from "esbuild";
import { cp, mkdir, rm } from "node:fs/promises";

await rm("dist", { recursive: true, force: true });
await mkdir("dist");
await build({
  entryPoints: ["linux/main.ts"],
  outfile: "dist/server.mjs",
  platform: "node",
  format: "esm",
  target: "node24",
  bundle: true,
  loader: { ".p8": "text" },
  // CommonJS dependencies may require Node built-ins from the ESM bundle.
  banner: { js: 'import { createRequire } from "node:module"; const require = createRequire(import.meta.url);' },
});
await cp("schema.sql", "dist/schema.sql");
await cp("scripts/show-access-key.mjs", "dist/show-access-key.mjs");
await cp("migrations", "dist/migrations", { recursive: true });
