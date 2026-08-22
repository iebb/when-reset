import { afterEach, describe, expect, it, vi } from "vitest";
import { fetchProviderUsage, ProviderFetchError, providerTesting } from "../src/providers";

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

function unsignedJWT(payload: Record<string, unknown>): string {
  const encoded = btoa(JSON.stringify(payload))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
  return `e30.${encoded}.test-only`;
}

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
      .mockResolvedValueOnce(Response.json({ id: "user-stable-123" }))
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
    }, 1_700_000_000);

    expect(result.snapshot.windows).toHaveLength(1);
    expect(result.snapshot.available_reset_count).toBe(2);
    expect(result.snapshot.reset_credits).toEqual([]);
    expect(result.snapshot.reset_credits_authoritative).toBe(false);
    expect(result.account_identity)
      .toBe("user:user-stable-123|account:workspace-test");
    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://chatgpt.com/backend-api/me");
  });

  it("keeps collecting ChatGPT quota without merging when profile verification is unavailable", async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(null, { status: 503 }))
      .mockResolvedValueOnce(Response.json({
        rate_limit: {
          primary_window: {
            used_percent: 10,
            limit_window_seconds: 604_800,
            reset_at: 2_000_604_800,
          },
        },
      }))
      .mockResolvedValueOnce(Response.json({ credits: [], available_count: 0 }));
    vi.stubGlobal("fetch", fetchMock);

    const result = await fetchProviderUsage({
      provider_id: "chatgpt",
      workspace_id: "workspace-test",
      plan: null,
    }, {
      access_token: "test-access",
      refresh_token: "test-refresh",
      id_token: unsignedJWT({ sub: "stable-token-user" }),
      expires_at: 2_100_000_000,
    }, 1_700_000_000);

    expect(result.account_identity).toBeUndefined();
    expect(result.snapshot.windows).toHaveLength(1);
    expect(fetchMock.mock.calls.map((call) => call[0])).toEqual([
      "https://chatgpt.com/backend-api/me",
      "https://chatgpt.com/backend-api/wham/usage",
      "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits",
    ]);
  });

  it("keeps collecting ChatGPT quota when a Codex-scoped token cannot read the profile", async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(null, { status: 403 }))
      .mockResolvedValueOnce(Response.json({
        rate_limit: {
          primary_window: {
            used_percent: 10,
            limit_window_seconds: 604_800,
            reset_at: 2_000_604_800,
          },
        },
      }))
      .mockResolvedValueOnce(Response.json({ credits: [], available_count: 0 }));
    vi.stubGlobal("fetch", fetchMock);

    const result = await fetchProviderUsage({
      provider_id: "chatgpt",
      workspace_id: "workspace-test",
      plan: null,
    }, {
      access_token: "codex-scoped-access",
      refresh_token: "test-refresh",
      id_token: unsignedJWT({ sub: "stable-token-user" }),
      expires_at: 2_100_000_000,
    }, 1_700_000_000);

    expect(result.account_identity).toBeUndefined();
    expect(result.snapshot.windows).toHaveLength(1);
    expect(fetchMock.mock.calls.map((call) => call[0])).toEqual([
      "https://chatgpt.com/backend-api/me",
      "https://chatgpt.com/backend-api/wham/usage",
      "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits",
    ]);
  });

  it("does not hide a ChatGPT profile authentication failure behind token claims", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(null, { status: 401 })));

    await expect(fetchProviderUsage({
      provider_id: "chatgpt",
      workspace_id: "workspace-test",
      plan: null,
    }, {
      access_token: "test-access",
      refresh_token: "test-refresh",
      id_token: unsignedJWT({ sub: "stable-token-user" }),
      expires_at: 2_100_000_000,
    }, 1_700_000_000)).rejects.toMatchObject({ status: 401 });
  });

  it("classifies a rejected ChatGPT refresh grant as an expired session", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(null, { status: 400 })));

    await expect(fetchProviderUsage({
      provider_id: "chatgpt",
      workspace_id: "workspace-test",
      plan: null,
    }, {
      access_token: "expired-access",
      refresh_token: "rejected-refresh",
      id_token: unsignedJWT({ sub: "stable-token-user" }),
      expires_at: 1_600_000_000,
    }, 1_700_000_000)).rejects.toMatchObject({
      status: 401,
      message: "ChatGPT authorization expired.",
    });
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

  it("parses Grok Build weekly credit usage and reset", () => {
    const parsed = providerTesting.grokBilling({
      subscriptionTier: "supergrok_heavy",
      config: {
        creditUsagePercent: 42.5,
        currentPeriod: {
          type: "USAGE_PERIOD_TYPE_WEEKLY",
          start: "2030-01-01T00:00:00Z",
          end: "2030-01-08T00:00:00Z",
        },
      },
    }, 1_700_000_000);

    expect(parsed.plan).toBe("SuperGrok Heavy");
    expect(parsed.window).toMatchObject({
      metric_id: "grok:weekly",
      kind: "weekly",
      window_minutes: 10_080,
      remaining_percent: 57.5,
    });
  });

  it("parses the legacy Grok monthly billing shape", () => {
    const parsed = providerTesting.grokBilling({
      config: {
        monthlyLimit: { val: 2_000 },
        used: { val: 500 },
        billingPeriodStart: "2030-02-01T00:00:00Z",
        billingPeriodEnd: "2030-03-01T00:00:00Z",
      },
    }, 1_700_000_000);

    expect(parsed.window).toMatchObject({
      metric_id: "grok:monthly",
      kind: "additional",
      remaining_percent: 75,
    });
  });

  it("refreshes Grok OAuth and sends the official billing headers", async () => {
    const payload = btoa(JSON.stringify({ sub: "user-123", tier: 5 }))
      .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
    const accessToken = `header.${payload}.signature`;
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(Response.json({
        access_token: accessToken,
        refresh_token: "rotated-refresh",
        expires_in: 3_600,
      }))
      .mockResolvedValueOnce(Response.json({
        config: {
          creditUsagePercent: 20,
          currentPeriod: {
            type: "USAGE_PERIOD_TYPE_WEEKLY",
            start: "2030-01-01T00:00:00Z",
            end: "2030-01-08T00:00:00Z",
          },
        },
      }));
    vi.stubGlobal("fetch", fetchMock);

    const result = await fetchProviderUsage({
      provider_id: "grok",
      workspace_id: "user-123",
      plan: null,
    }, {
      access_token: "expired-token",
      refresh_token: "refresh-token",
      id_token: "id-token",
      expires_at: 1_699_999_000,
    }, 1_700_000_000);

    expect(result.credentials.refresh_token).toBe("rotated-refresh");
    expect(result.snapshot.plan).toBe("SuperGrok Heavy");
    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://auth.x.ai/oauth2/token");
    expect(fetchMock.mock.calls[1]?.[0]).toBe(
      "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
    );
    expect(fetchMock.mock.calls[1]?.[1]).toMatchObject({
      headers: expect.objectContaining({
        authorization: `Bearer ${accessToken}`,
        "x-xai-token-auth": "xai-grok-cli",
        "x-userid": "user-123",
        "x-grok-client-mode": "headless",
      }),
      redirect: "manual",
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

  it("parses OpenAI organization costs into a monthly budget balance", () => {
    expect(providerTesting.openAIAPIBalance({
      data: [
        { results: [{ amount: { value: 1.25, currency: "usd" } }] },
        { results: [{ amount: { value: 0.75, currency: "usd" } }] },
      ],
    }, 10, { start: 2_000_000_000, end: 2_002_678_400 })).toMatchObject({
      currency_code: "USD",
      spent: 2,
      limit: 10,
      remaining: 8,
    });
  });

  it("parses Anthropic cost-report cents into dollars", () => {
    expect(providerTesting.anthropicAPIBalance({
      data: [{ results: [
        { amount: "123", currency: "USD" },
        { amount: { value: "77", currency: "USD" } },
      ] }],
    }, null, { start: 2_000_000_000, end: 2_002_678_400 })).toMatchObject({
      currency_code: "USD",
      spent: 2,
      limit: null,
      remaining: null,
    });
  });

  it("fetches an OpenRouter key limit with its documented UTC reset period and stable creator", async () => {
    const now = Date.UTC(2030, 0, 2, 12) / 1_000;
    const fetchMock = vi.fn().mockResolvedValue(Response.json({
      data: {
        creator_user_id: "user-stable",
        is_free_tier: true,
        limit: 100,
        limit_remaining: 74.5,
        limit_reset: "monthly",
        usage: 25.5,
        usage_monthly: 25.5,
        expires_at: "2031-01-01T00:00:00Z",
      },
    }));
    vi.stubGlobal("fetch", fetchMock);

    const result = await fetchProviderUsage({
      provider_id: "openrouter",
      workspace_id: "local-openrouter-account",
      plan: "Developer",
    }, {
      access_token: "openrouter-test-key",
      refresh_token: "",
      id_token: "",
      expires_at: null,
    }, now);

    expect(result.account_identity)
      .toBe("creator:user-stable|key:openrouter-test-key");
    expect(result.snapshot.plan).toBe("Free tier");
    expect(result.snapshot.windows).toEqual([]);
    expect(result.snapshot.api_balance).toMatchObject({
      title: "Monthly API key limit",
      currency_code: "USD",
      spent: 25.5,
      limit: 100,
      remaining: 74.5,
      period_start: Date.UTC(2030, 0, 1) / 1_000,
      period_end: Date.UTC(2030, 1, 1) / 1_000,
      access_expires_at: Date.UTC(2031, 0, 1) / 1_000,
      is_unlimited: false,
    });
    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://openrouter.ai/api/v1/key");
    expect(fetchMock.mock.calls[0]?.[1]).toMatchObject({
      headers: expect.objectContaining({ authorization: "Bearer openrouter-test-key" }),
      redirect: "manual",
    });
  });

  it("clamps OpenRouter remaining spend to the declared key limit", () => {
    const parsed = providerTesting.openRouterAPIBalance({
      data: {
        limit: 100,
        limit_remaining: 150,
        limit_reset: "monthly",
        usage_monthly: 0,
      },
    }, Date.UTC(2030, 0, 2) / 1_000);
    expect(parsed.balance).toMatchObject({
      spent: 0,
      limit: 100,
      remaining: 100,
      is_unlimited: false,
    });
  });

  it("scopes OpenRouter identity to the exact key as well as its creator", () => {
    const first = providerTesting.openRouterAccountIdentity("creator-1", "key-a");
    expect(providerTesting.openRouterAccountIdentity("creator-1", "key-a")).toBe(first);
    expect(providerTesting.openRouterAccountIdentity("creator-1", "key-b")).not.toBe(first);
    expect(providerTesting.openRouterAccountIdentity("creator-2", "key-a")).not.toBe(first);
  });

  it.each(["accounts/team-one", "team-one"])(
    "fetches the Fireworks monthly spending quota for account reference %s",
    async (workspaceID) => {
      const fetchMock = vi.fn().mockResolvedValue(Response.json({
        quotas: [{
          name: "accounts/team-one/quotas/monthly-spend-usd",
          value: "50",
          maxValue: "500",
          usage: 12.5,
          updateTime: "2030-01-02T00:00:00Z",
        }],
      }));
      vi.stubGlobal("fetch", fetchMock);

      const result = await fetchProviderUsage({
        provider_id: "fireworks",
        workspace_id: workspaceID,
        plan: null,
      }, {
        access_token: "fireworks-test-key",
        refresh_token: "",
        id_token: "",
        expires_at: null,
      }, Date.UTC(2030, 0, 2) / 1_000);

      expect(result.account_identity).toBe("account:team-one");
      expect(result.snapshot.api_balance).toMatchObject({
        title: "Monthly API budget",
        currency_code: "USD",
        spent: 12.5,
        limit: 50,
        remaining: 37.5,
        is_unlimited: false,
      });
      expect(fetchMock.mock.calls[0]?.[0]).toBe(
        "https://api.fireworks.ai/v1/accounts/team-one/quotas?pageSize=200"
      );
      expect(fetchMock.mock.calls[0]?.[1]).toMatchObject({
        headers: expect.objectContaining({ authorization: "Bearer fireworks-test-key" }),
        redirect: "manual",
      });
    },
  );

  it("uses the Fireworks quota maximum when no configured value is returned", () => {
    expect(providerTesting.fireworksAPIBalance({
      quotas: [{
        name: "monthly-spend-usd",
        maxValue: "500",
        usage: "125.50",
      }],
    }, null, Date.UTC(2030, 0, 2) / 1_000)).toMatchObject({
      title: "Monthly API budget",
      spent: 125.5,
      limit: 500,
      remaining: 374.5,
    });
  });

  it("rejects an invalid Fireworks account path before making a provider request", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    await expect(fetchProviderUsage({
      provider_id: "fireworks",
      workspace_id: "fireworks-accounts/team-one",
      plan: null,
    }, {
      access_token: "fireworks-test-key",
      refresh_token: "",
      id_token: "",
      expires_at: null,
    }, 2_000_000_000)).rejects.toMatchObject({ status: 400, retryable: false });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("keeps DeepSeek wallet balance separate from reset-window quota", async () => {
    const fetchMock = vi.fn().mockResolvedValue(Response.json({
      is_available: true,
      balance_infos: [
        { currency: "CNY", total_balance: "110.00" },
        { currency: "USD", total_balance: "15.25" },
      ],
    }));
    vi.stubGlobal("fetch", fetchMock);

    const result = await fetchProviderUsage({
      provider_id: "deepseek",
      workspace_id: "local-deepseek-account",
      plan: null,
    }, {
      access_token: "deepseek-test-key",
      refresh_token: "",
      id_token: "",
      expires_at: null,
    }, 2_000_000_000);

    expect(result.account_identity).toBeUndefined();
    expect(result.snapshot.windows).toEqual([]);
    expect(result.snapshot.api_balance).toEqual({
      title: "API wallet balance",
      currency_code: "USD",
      spent: 0,
      limit: null,
      remaining: 15.25,
      period_start: null,
      period_end: null,
      access_expires_at: null,
      is_unlimited: false,
      kind: "wallet",
    });
    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://api.deepseek.com/user/balance");
    expect(fetchMock.mock.calls[0]?.[1]).toMatchObject({
      headers: expect.objectContaining({ authorization: "Bearer deepseek-test-key" }),
      redirect: "manual",
    });
  });

  it("keeps Poe points as a non-renewal balance", async () => {
    const fetchMock = vi.fn().mockResolvedValue(Response.json({
      current_point_balance: 295_932_027,
    }));
    vi.stubGlobal("fetch", fetchMock);

    const result = await fetchProviderUsage({
      provider_id: "poe",
      workspace_id: "local-poe-account",
      plan: null,
    }, {
      access_token: "poe-test-key",
      refresh_token: "",
      id_token: "",
      expires_at: null,
    }, 2_000_000_000);

    expect(result.account_identity).toBeUndefined();
    expect(result.snapshot.windows).toEqual([]);
    expect(result.snapshot.api_balance).toEqual({
      title: "API point balance",
      currency_code: "POINTS",
      spent: 0,
      limit: null,
      remaining: 295_932_027,
      period_start: null,
      period_end: null,
      access_expires_at: null,
      is_unlimited: false,
      kind: "wallet",
      unit_label: "points",
    });
    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://api.poe.com/usage/current_balance");
    expect(fetchMock.mock.calls[0]?.[1]).toMatchObject({
      headers: expect.objectContaining({ authorization: "Bearer poe-test-key" }),
      redirect: "manual",
    });
  });
});
