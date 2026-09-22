import { chmodSync, mkdirSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { setTimeout as pause } from "node:timers/promises";
import worker, { processQueue, runScheduledRefresh, type QueueTarget } from "../src/index";
import type { RuntimeEnv } from "../src/runtime";
import { createAPNSFetch } from "./apns";
import { readConfig } from "./config";
import { SQLiteDatabase } from "./database";
import { createHTTPServer } from "./http";
import { SQLiteQueue } from "./queue";
import { Scheduler } from "./scheduler";

async function main(): Promise<void> {
  process.umask(0o077);
  const config = readConfig(process.env);
  if (process.argv.includes("--check-config")) return;
  mkdirSync(config.dataDirectory, { recursive: true, mode: 0o700 });
  chmodSync(config.dataDirectory, 0o700);
  const databasePath = join(config.dataDirectory, "when-reset.sqlite");
  const database = new SQLiteDatabase(databasePath);
  try {
    const migrationsURL = new URL("./migrations/", import.meta.url);
    database.initialize(readFileSync(new URL("./schema.sql", import.meta.url), "utf8"),
      readdirSync(migrationsURL).filter((name) => /^\d+_.*\.sql$/.test(name)).map((name) => ({
        name, sql: readFileSync(new URL(name, migrationsURL), "utf8"),
      })));
    chmodSync(databasePath, 0o600);
    if (process.argv.includes("--migrate-only")) return;
    const queue = new SQLiteQueue<QueueTarget>(database);
    const env: RuntimeEnv = {
      DB: database,
      PUSH_QUEUE: queue,
      REGISTRATION_ACCESS_KEY: config.registrationKey,
      CREDENTIAL_ENCRYPTION_KEY: config.encryptionKey,
      APNS_FETCH: createAPNSFetch(),
    };
    const scheduler = new Scheduler(database, (time) => runScheduledRefresh(env, time));
    const server = createHTTPServer(config.origin, (request) => worker.fetch(request, env));
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(config.port, config.host, resolve);
    });
    let stopping = false;
    let closed: Promise<void> | undefined;
    const stop = () => {
      if (stopping) return;
      stopping = true;
      closed = new Promise<void>((resolve) => server.close(() => resolve()));
      server.closeIdleConnections();
    };
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);
    console.log(JSON.stringify({ event: "linux_server_ready", origin: config.origin, port: config.port }));
    try {
      while (!stopping) {
        try {
          await scheduler.tick();
          if (!stopping) await queue.consume((batch) => processQueue(batch, env));
        } catch {
          console.error(JSON.stringify({ event: "local_background_failed" }));
        }
        if (!stopping) await pause(1_000);
      }
      await closed;
    } finally {
      process.removeListener("SIGINT", stop);
      process.removeListener("SIGTERM", stop);
    }
  } finally {
    database.close();
  }
}

main().catch(() => {
  // Error objects can include SQL bindings, tokens or environment values.
  console.error(JSON.stringify({ event: "linux_server_start_failed", message: "Check configuration, database permissions and the configured listen address." }));
  process.exitCode = 1;
});
