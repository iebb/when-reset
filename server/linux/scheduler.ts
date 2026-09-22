import { SQLiteDatabase } from "./database";

export class Scheduler {
  private running = false;
  private retryAt = 0;

  constructor(readonly database: SQLiteDatabase, readonly run: (time: number) => Promise<void>) {}

  async tick(now = Date.now()): Promise<void> {
    if (this.running || now < this.retryAt) return;
    const occurrence = Math.floor(now / 300_000) * 300_000;
    const last = this.database.sqlite.prepare("SELECT completed_at FROM _server_schedule WHERE id = 1").get();
    if (last && Number(last.completed_at) >= occurrence) return;
    this.running = true;
    try {
      // Use UTC five-minute boundaries, including minute zero for hourly APNs hints.
      // On restart, process the current interval instead of replaying missed history.
      await this.run(occurrence);
      this.database.sqlite.prepare(
        "INSERT INTO _server_schedule (id, completed_at) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET completed_at = excluded.completed_at"
      ).run(occurrence);
    } catch {
      this.retryAt = now + 60_000;
      console.error(JSON.stringify({ event: "local_schedule_failed" }));
    } finally {
      this.running = false;
    }
  }
}
