import { afterEach, describe, expect, it, vi } from "vitest";
import { fetchProviderUsage, ProviderFetchError, providerTesting } from "../src/providers";

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe("server-side provider adapters", () => {
  it("uses manual redirects because the Workers runtime rejects redirect error mode", async () => {
    const fetchMock = vi.fn().mockResolvedValue(Response.json({ ok: true }));
    vi.stubGlobal("fetch", fetchMock);

    await expect(providerTesting.requestJSON("https://provider.example/usage", {}))
      .resolves.toEqual({ ok: true });
    expect(fetchMock).toHaveBeenCalledWith(
      "https://provider.example/usage",
      expect.objectContaining({ redirect: "manual" }),
    );
  });

  it("rejects manual redirects without forwarding authorization", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(null, {
      status: 302,
      headers: { location: "https://unexpected.example/" },
    })));

    await expect(providerTesting.requestJSON("https://provider.example/usage", {
      headers: { authorization: "Bearer test-only" },
    })).rejects.toMatchObject({
      message: "Provider redirected unexpectedly.",
      status: 302,
      retryable: false,
    });
  });

  it("captures Retry-After and applies a conservative 429 backoff", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(null, {
      status: 429,
      headers: { "retry-after": "120" },
    })));

    await expect(providerTesting.requestJSON("https://provider.example/usage", {}))
      .rejects.toMatchObject({
        message: "Provider rate limit reached; retrying later.",
        status: 429,
        retryable: true,
        retryAfterSeconds: 120,
      });
    expect(providerTesting.providerRetryDelaySeconds(
      new ProviderFetchError("limited", 429, true, 120)
    )).toBe(30 * 60);
    expect(providerTesting.providerRetryDelaySeconds(
      new ProviderFetchError("limited", 429, true, 2 * 60 * 60)
    )).toBe(2 * 60 * 60);
    expect(providerTesting.providerRetryDelaySeconds(
      new ProviderFetchError("expired", 400, false)
    )).toBe(6 * 60 * 60);
  });

  it("keeps ChatGPT usage when only banked-reset details are rate-limited", async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(Response.json({
        plan_type: "pro",
        rate_limit: {
          primary_window: {
            used_percent: 25,
            limit_window_seconds: 18_000,
            reset_at: 2_000_003_600,
          },
        },
        rate_limit_reset_credits: { available_count: 2 },
      }))
      .mockResolvedValueOnce(new Response(null, { status: 429 }));
    vi.stubGlobal("fetch", fetchMock);

    const result = await fetchProviderUsage({
      provider_id: "chatgpt",
      workspace_id: "workspace-test",
      plan: null,
    }, {
      access_token: "test-access",
      refresh_token: "test-refresh",
      id_token: "",
      expires_at: 2_100_000_000,
    }, 2_000_000_000);

    expect(result.snapshot.windows).toHaveLength(1);
    expect(result.snapshot.available_reset_count).toBe(2);
    expect(result.snapshot.reset_credits).toEqual([]);
    expect(result.snapshot.reset_credits_authoritative).toBe(false);
  });

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
