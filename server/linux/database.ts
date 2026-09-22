import { DatabaseSync, type SQLInputValue, type SQLOutputValue } from "node:sqlite";
import type { RuntimeEnv } from "../src/runtime";

export type Migration = { name: string; sql: string };
type DatabaseBinding = RuntimeEnv["DB"];

export class SQLiteDatabase implements DatabaseBinding {
  readonly sqlite: DatabaseSync;

  constructor(filename: string) {
    this.sqlite = new DatabaseSync(filename, { timeout: 5_000 });
    this.sqlite.exec("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;");
  }

  initialize(schema: string, migrations: Migration[]): void {
    this.transaction(() => {
      const initialized = this.sqlite.prepare(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '_server_migrations'"
      ).get();
      if (!initialized) {
        const existing = this.sqlite.prepare(
          "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' LIMIT 1"
        ).get();
        if (existing) throw new Error("Use a new database for the Linux server; direct D1 imports are not supported.");
        this.sqlite.exec("CREATE TABLE _server_migrations (name TEXT PRIMARY KEY NOT NULL)");
      }
      // Like db:initialize on Workers, also create newly introduced baseline objects
      // on upgrades. Every baseline DDL statement is idempotent.
      this.sqlite.exec(schema);
      for (const migration of [...migrations].sort((a, b) => a.name.localeCompare(b.name))) {
        if (this.sqlite.prepare("SELECT 1 FROM _server_migrations WHERE name = ?").get(migration.name)) continue;
        // Match the Workers deployment: schema.sql is the baseline, and historical
        // ALTERs still need to run on a fresh install. The ledger makes restarts safe.
        this.sqlite.exec(migration.sql);
        this.sqlite.prepare("INSERT INTO _server_migrations (name) VALUES (?)").run(migration.name);
      }
      this.sqlite.exec(`
        CREATE TABLE IF NOT EXISTS _server_queue (
          id TEXT PRIMARY KEY NOT NULL,
          body TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          available_at INTEGER NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS _server_queue_due ON _server_queue(available_at, created_at);
        CREATE TABLE IF NOT EXISTS _server_schedule (
          id INTEGER PRIMARY KEY CHECK(id = 1),
          completed_at INTEGER NOT NULL
        );
      `);
    });
  }

  prepare(query: string): SQLiteStatement {
    return new SQLiteStatement(this, query);
  }

  async batch<T = unknown>(statements: D1PreparedStatement[]): Promise<D1Result<T>[]> {
    // Do not await between statements: D1 batches are atomic and cannot interleave
    // with requests. Consent and credential revision guards depend on this guarantee.
    return this.transaction(() => statements.map((statement) => {
      if (!(statement instanceof SQLiteStatement) || statement.database !== this) {
        throw new Error("Statement belongs to a different database");
      }
      return statement.execute<T>();
    }));
  }

  transaction<T>(action: () => T): T {
    this.sqlite.exec("BEGIN IMMEDIATE");
    try {
      const result = action();
      this.sqlite.exec("COMMIT");
      return result;
    } catch (error) {
      this.sqlite.exec("ROLLBACK");
      throw error;
    }
  }

  close(): void {
    this.sqlite.close();
  }
}

function inputValue(value: unknown): SQLInputValue {
  if (value === null || typeof value === "string" || typeof value === "number") return value;
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  if (Array.isArray(value) && value.every((byte) => Number.isInteger(byte) && byte >= 0 && byte <= 255)) {
    return Uint8Array.from(value);
  }
  throw new TypeError("Unsupported SQLite binding");
}

function outputRow(row: Record<string, SQLOutputValue>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(row).map(([key, value]) => [
    key, value instanceof Uint8Array ? Uint8Array.from(value).buffer : value,
  ]));
}

class SQLiteStatement {
  constructor(
    readonly database: SQLiteDatabase,
    readonly sql: string,
    readonly values: SQLInputValue[] = [],
  ) {}

  bind(...values: unknown[]): SQLiteStatement {
    return new SQLiteStatement(this.database, this.sql, values.map(inputValue));
  }

  async first<T = Record<string, unknown>>(column?: string): Promise<T | null> {
    const row = this.database.sqlite.prepare(this.sql).get(...this.values);
    if (!row) return null;
    const result = outputRow(row);
    if (column !== undefined && !(column in result)) throw new Error("Unknown result column");
    return (column === undefined ? result : result[column]) as T;
  }

  async run<T = Record<string, unknown>>(): Promise<D1Result<T>> {
    return this.execute<T>();
  }

  async all<T = Record<string, unknown>>(): Promise<D1Result<T>> {
    return this.execute<T>();
  }

  async raw<T = unknown[]>(options: { columnNames: true }): Promise<[string[], ...T[]]>;
  async raw<T = unknown[]>(options?: { columnNames?: false }): Promise<T[]>;
  async raw<T = unknown[]>(options?: { columnNames?: boolean }): Promise<T[] | [string[], ...T[]]> {
    const statement = this.database.sqlite.prepare(this.sql);
    const rows = statement.all(...this.values).map((row) => Object.values(outputRow(row)) as T);
    return options?.columnNames ? [statement.columns().map((column) => column.name), ...rows] : rows;
  }

  execute<T>(): D1Result<T> {
    const db = this.database.sqlite;
    const started = performance.now();
    const before = Number(db.prepare("SELECT total_changes() AS n").get()!.n);
    const statement = db.prepare(this.sql);
    const results = statement.columns().length > 0
      ? statement.all(...this.values).map(outputRow) : (statement.run(...this.values), []);
    const after = db.prepare("SELECT total_changes() AS n, last_insert_rowid() AS id").get()!;
    const changes = Number(after.n) - before;
    return {
      success: true,
      results: results as T[],
      meta: {
        changes,
        duration: performance.now() - started,
        last_row_id: Number(after.id),
        changed_db: changes > 0,
        // D1's page/row scan telemetry has no equivalent in node:sqlite.
        size_after: 0,
        rows_read: results.length,
        rows_written: changes,
      },
    };
  }
}
