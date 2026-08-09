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

  it("parses Synthetic rolling and weekly quotas", () => {
    const windows = providerTesting.syntheticWindows({
      rollingFiveHourLimit: {
        max: 100,
        remaining: 75,
        nextTickAt: 2_000_003_600,
      },
      weeklyTokenLimit: {
        maxCredits: "$100.00",
        remainingCredits: "$40.00",
        nextRegenAt: 2_000_086_400,
      },
    }, 2_000_000_000);

    expect(windows).toMatchObject([
      { metric_id: "synthetic:five_hour", remaining_percent: 75 },
      { metric_id: "synthetic:weekly", remaining_percent: 40 },
    ]);
  });

  it("parses Warp request-credit quota", () => {
    expect(providerTesting.warpWindow({
      data: {
        user: {
          __typename: "UserOutput",
          user: {
            requestLimitInfo: {
              isUnlimited: false,
              nextRefreshTime: 2_000_086_400,
              requestLimit: 1_000,
              requestsUsedSinceLastRefresh: 250,
            },
          },
        },
      },
    }, 0, 2_000_000_000)).toMatchObject({
      metric_id: "warp:monthly_credits",
      remaining_percent: 75,
    });
  });
});
