import { randomUUID } from "node:crypto";
import { SQLiteDatabase } from "./database";

type QueueRow = { id: string; body: string; created_at: number; attempts: number };

export class SQLiteQueue<Body = unknown> {
  constructor(readonly database: SQLiteDatabase, readonly clock = Date.now) {}

  async send(body: Body, options?: QueueSendOptions): Promise<QueueSendResponse> {
    return this.sendBatch([{ body, ...options }]);
  }

  async sendBatch(
    messages: Iterable<MessageSendRequest<Body>>, options?: QueueSendBatchOptions,
  ): Promise<QueueSendBatchResponse> {
    this.database.transaction(() => {
      const insert = this.database.sqlite.prepare(
        "INSERT INTO _server_queue (id, body, created_at, available_at) VALUES (?, ?, ?, ?)"
      );
      for (const message of messages) {
        if (message.contentType && message.contentType !== "json") throw new Error("Only JSON jobs are supported");
        const body = JSON.stringify(message.body);
        if (body === undefined) throw new Error("Job must have a JSON body");
        insert.run(randomUUID(), body, this.clock(), this.clock() + delay(message.delaySeconds ?? options?.delaySeconds, 0));
      }
    });
    const metrics = this.database.sqlite.prepare(
      "SELECT COUNT(*) AS count, COALESCE(SUM(length(body)), 0) AS bytes FROM _server_queue"
    ).get()!;
    return { metadata: { metrics: { backlogCount: Number(metrics.count), backlogBytes: Number(metrics.bytes) } } };
  }

  async consume(handler: (batch: MessageBatch<Body>) => Promise<void>): Promise<boolean> {
    // A single job per invocation bounds shutdown latency and avoids bursts to providers.
    // A lease survives process crashes; systemd must run only one consumer per database.
    const row = this.database.transaction(() => {
      const next = this.database.sqlite.prepare(
        "SELECT id, body, created_at, attempts FROM _server_queue WHERE available_at <= ? ORDER BY available_at, created_at LIMIT 1"
      ).get(this.clock()) as QueueRow | undefined;
      if (!next) return undefined;
      this.database.sqlite.prepare(
        "UPDATE _server_queue SET attempts = attempts + 1, available_at = ? WHERE id = ?"
      ).run(this.clock() + 5 * 60_000, next.id);
      return { ...next, attempts: next.attempts + 1 };
    });
    if (!row) return false;
    let disposition: "ack" | "retry" | undefined;
    let retryDelay = 60_000;
    const message: Message<Body> = {
      id: row.id,
      timestamp: new Date(row.created_at),
      attempts: row.attempts,
      body: JSON.parse(row.body),
      ack() { disposition ??= "ack"; },
      retry(options) {
        if (disposition) return;
        disposition = "retry";
        retryDelay = delay(options?.delaySeconds, 60);
      },
    };
    try {
      await handler({
        queue: "when-reset-local",
        messages: [message],
        ackAll() { message.ack(); },
        retryAll(options) { message.retry(options); },
        metadata: { metrics: { backlogCount: 1, backlogBytes: row.body.length } },
      });
      disposition ??= "ack";
    } catch {
      disposition ??= "retry";
      console.error(JSON.stringify({ event: "local_queue_handler_failed" }));
    }
    if (disposition === "ack" || row.attempts >= 4) {
      this.database.sqlite.prepare("DELETE FROM _server_queue WHERE id = ?").run(row.id);
      if (disposition !== "ack") console.error(JSON.stringify({ event: "local_queue_retries_exhausted" }));
    } else {
      this.database.sqlite.prepare("UPDATE _server_queue SET available_at = ? WHERE id = ?")
        .run(this.clock() + retryDelay, row.id);
    }
    return true;
  }
}

function delay(seconds: number | undefined, fallback: number): number {
  const value = seconds ?? fallback;
  if (!Number.isFinite(value) || value < 0 || value > 86_400) throw new Error("Invalid queue delay");
  return Math.ceil(value * 1_000);
}
