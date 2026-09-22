// Run the existing API/provider regression suite against the real SQLite adapter too.
import { readFileSync, readdirSync } from "node:fs";
import { afterAll } from "vitest";
import worker from "../../src/index";
import type { RuntimeEnv } from "../../src/runtime";
import { SQLiteDatabase } from "../database";
import { SQLiteQueue } from "../queue";

const database = new SQLiteDatabase(":memory:");
database.initialize(readFileSync("schema.sql", "utf8"), readdirSync("migrations").map((name) => ({
  name, sql: readFileSync(`migrations/${name}`, "utf8"),
})));
export const env: RuntimeEnv = {
  DB: database,
  PUSH_QUEUE: new SQLiteQueue(database),
  REGISTRATION_ACCESS_KEY: "A".repeat(43),
  CREDENTIAL_ENCRYPTION_KEY: "B".repeat(43),
};
export const SELF = {
  fetch(input: string | Request, init?: RequestInit) {
    return worker.fetch(new Request(input, init), env);
  },
};
afterAll(() => database.close());
