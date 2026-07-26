import { describe, expect, it } from "vitest";
import { providerTesting } from "../src/providers";

describe("server-side provider adapters", () => {
  it("parses ChatGPT windows into remaining percentage and duration", () => {
    expect(providerTesting.chatGPTWindow({
      used_percent: 25,
      limit_window_seconds: 18_000,
      reset_at: 2_000_003_600,
    }, 0, "Usage limit")).toMatchObject({
      kind: "fiveHour",
      window_minutes: 300,
      remaining_percent: 75,
    });
  });

  it("parses additional Z.AI duration quotas with bounded percentages", () => {
    expect(providerTesting.zaiWindow({
      type: "TOKENS_LIMIT",
      unit: 3,
      number: 5,
      usage: 1_000,
      remaining: 250,
      currentValue: 750,
      nextResetTime: 2_000_003_600,
    }, 0, 2_000_000_000)).toMatchObject({
      kind: "fiveHour",
      window_minutes: 300,
      remaining_percent: 25,
    });
  });

  it("matches the app's deterministic reset-credit fallback IDs", () => {
    expect(providerTesting.fallbackResetCreditID(
      2_000_086_400,
      2_000_000_000,
      "AVAILABLE",
      0,
    )).toBe("generated:2000000000000:2000086400000:available:0");
  });
});
