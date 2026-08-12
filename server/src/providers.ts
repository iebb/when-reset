const MAX_PROVIDER_RESPONSE_BYTES = 1_048_576;
const PROVIDER_REQUEST_TIMEOUT_MILLISECONDS = 20_000;
const USER_AGENT = "WhenReset-Worker/1.0";
const TRANSIENT_RETRY_FLOOR_SECONDS = 15 * 60;
const RATE_LIMIT_RETRY_FLOOR_SECONDS = 30 * 60;
const CREDENTIAL_ERROR_RETRY_FLOOR_SECONDS = 6 * 60 * 60;
const MAX_PROVIDER_RETRY_SECONDS = 8 * 60 * 60;

export type ProviderID = "chatgpt" | "claude" | "grok" | "kimi" | "github_copilot" | "zai" | "minimax"
  | "synthetic" | "warp" | "openai_api" | "anthropic_api" | "openrouter" | "fireworks"
  | "deepseek" | "poe";
export type WindowKind = "fiveHour" | "weekly" | "additional";

export type ProviderCredentials = {
  access_token: string;
  refresh_token: string;
  id_token: string;
  expires_at: number | null;
  monthly_budget?: number | null;
  currency_code?: string | null;
};

export type ProviderAccount = {
  provider_id: ProviderID;
  workspace_id: string;
  plan: string | null;
};

export type ProviderUsageWindow = {
  position: number;
  metric_id: string;
  title: string;
  kind: WindowKind | null;
  window_minutes: number | null;
  remaining_percent: number;
  resets_at: number;
};

export type ProviderResetCredit = {
  id: string;
  expires_at: number | null;
  status: string | null;
  granted_at: number | null;
};

export type ProviderSnapshot = {
  provider_id: ProviderID;
  plan: string | null;
  fetched_at: number;
  windows: ProviderUsageWindow[];
  available_reset_count: number;
  reset_credits: ProviderResetCredit[];
  reset_credits_authoritative?: boolean;
  api_balance?: ProviderAPIBalance;
  // An opaque HMAC added by the Worker after provider-side identity verification.
  // Raw provider user IDs never leave the refresh call or enter D1.
  account_reference?: string;
};

export type ProviderAPIBalance = {
  title: string;
  currency_code: string;
  spent: number;
  limit: number | null;
  remaining: number | null;
  period_start: number | null;
  period_end: number | null;
  access_expires_at: number | null;
  is_unlimited: boolean;
  kind?: "budget" | "wallet";
  unit_label?: string | null;
};

export type ProviderFetchResult = {
  credentials: ProviderCredentials;
  snapshot: ProviderSnapshot;
  account_identity?: string;
};

export class ProviderFetchError extends Error {
  readonly retryable: boolean;
  readonly status: number;
  readonly retryAfterSeconds: number | null;

  constructor(message: string, status = 0, retryable = false, retryAfterSeconds: number | null = null) {
    super(message);
    this.name = "ProviderFetchError";
    this.status = status;
    this.retryable = retryable;
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

export function providerRetryDelaySeconds(error: ProviderFetchError): number | null {
  if (!error.retryable) {
    return error.status >= 400 && error.status < 500
      ? CREDENTIAL_ERROR_RETRY_FLOOR_SECONDS
      : null;
  }
  const floor = error.status === 429
    ? RATE_LIMIT_RETRY_FLOOR_SECONDS
    : TRANSIENT_RETRY_FLOOR_SECONDS;
  return Math.min(MAX_PROVIDER_RETRY_SECONDS, Math.max(floor, error.retryAfterSeconds ?? 0));
}

export async function fetchProviderUsage(
  account: ProviderAccount,
  originalCredentials: ProviderCredentials,
  now = Math.floor(Date.now() / 1_000),
): Promise<ProviderFetchResult> {
  switch (account.provider_id) {
    case "chatgpt": return fetchChatGPT(account, originalCredentials, now);
    case "claude": return fetchClaude(account, originalCredentials, now);
    case "grok": return fetchGrok(account, originalCredentials, now);
    case "kimi": return fetchKimi(account, originalCredentials, now);
    case "github_copilot": return fetchCopilot(account, originalCredentials, now);
    case "zai": return fetchZAI(account, originalCredentials, now);
    case "minimax": return fetchMiniMax(account, originalCredentials, now);
    case "synthetic": return fetchSynthetic(account, originalCredentials, now);
    case "warp": return fetchWarp(account, originalCredentials, now);
    case "openai_api": return fetchOpenAIAPI(account, originalCredentials, now);
    case "anthropic_api": return fetchAnthropicAPI(account, originalCredentials, now);
    case "openrouter": return fetchOpenRouter(account, originalCredentials, now);
    case "fireworks": return fetchFireworks(account, originalCredentials, now);
    case "deepseek": return fetchDeepSeek(account, originalCredentials, now);
    case "poe": return fetchPoe(account, originalCredentials, now);
  }
}

async function fetchGrok(
  account: ProviderAccount,
  credentials: ProviderCredentials,
  now: number,
): Promise<ProviderFetchResult> {
  const refreshed = await refreshGrok(credentials, now);
  const value = await getJSON(
    "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
    {
      authorization: `Bearer ${refreshed.access_token}`,
      "x-xai-token-auth": "xai-grok-cli",
      "x-userid": account.workspace_id,
      "x-grok-client-version": "1.0.0",
      "x-grok-client-mode": "headless",
      accept: "application/json",
      "user-agent": USER_AGENT,
    },
  );
  const parsed = grokBilling(value, now);
  return {
    credentials: refreshed,
    snapshot: snapshot(
      account.provider_id,
      parsed.plan ?? grokTierPlan(refreshed.access_token) ?? account.plan,
      now,
      [parsed.window],
      0,
      [],
    ),
  };
}

async function refreshGrok(
  credentials: ProviderCredentials,
  now: number,
): Promise<ProviderCredentials> {
  const expiration = credentials.expires_at ?? jwtExpiration(credentials.access_token);
  if (expiration !== null && expiration - now >= 5 * 60) return credentials;
  if (!credentials.refresh_token) {
    throw new ProviderFetchError("Grok refresh token is missing.", 401);
  }
  const body = new URLSearchParams({
    grant_type: "refresh_token",
    refresh_token: credentials.refresh_token,
    client_id: "b1a00492-073a-47ea-816f-4c329264a828",
  });
  const accessClaims = jwtClaims(credentials.access_token);
  const principalType = text(accessClaims?.principal_type);
  const principalID = text(accessClaims?.principal_id);
  if (principalType) body.set("principal_type", principalType);
  if (principalID) body.set("principal_id", principalID);

  const value = await requestJSON("https://auth.x.ai/oauth2/token", {
    method: "POST",
    headers: {
      accept: "application/json",
      "content-type": "application/x-www-form-urlencoded",
      "x-grok-client-version": "1.0.0",
      "user-agent": USER_AGENT,
    },
    body: body.toString(),
  });
  const root = requiredRecord(value, "Grok returned an unreadable token response.");
  const accessToken = requiredText(root.access_token, "Grok did not return an access token.");
  const expiresIn = number(root.expires_in);
  return {
    ...credentials,
    access_token: accessToken,
    refresh_token: text(root.refresh_token) ?? credentials.refresh_token,
    id_token: text(root.id_token) ?? credentials.id_token,
    expires_at: expiresIn !== null ? now + expiresIn : jwtExpiration(accessToken),
  };
}

function grokBilling(value: unknown, now: number): {
  window: ProviderUsageWindow;
  plan: string | null;
} {
  const root = requiredRecord(value, "Grok returned unreadable billing data.");
  const config = asRecord(root.config);
  if (!config) throw new ProviderFetchError("Grok returned no resettable quota.");
  const limit = centValue(config.monthlyLimit ?? config.monthly_limit);
  const used = centValue(config.used);
  const usedPercent = number(config.creditUsagePercent ?? config.credit_usage_percent)
    ?? (limit !== null && limit > 0 && used !== null ? used / limit * 100 : null);
  if (usedPercent === null) throw new ProviderFetchError("Grok returned unreadable billing data.");

  const period = asRecord(config.currentPeriod ?? config.current_period);
  const start = timestamp(period?.start ?? config.billingPeriodStart ?? config.billing_period_start);
  const end = timestamp(period?.end ?? config.billingPeriodEnd ?? config.billing_period_end);
  if (end === null || end <= now) throw new ProviderFetchError("Grok returned no resettable quota.");
  const duration = start !== null ? Math.max(1, Math.round((end - start) / 60)) : null;
  const periodType = text(period?.type)?.toUpperCase();
  const periodCode = integer(period?.type);
  const weekly = periodType?.includes("WEEKLY") === true || periodCode === 1
    || (duration !== null && duration >= 9_000 && duration <= 11_000);
  const monthly = periodType?.includes("MONTHLY") === true || periodCode === 2
    || (duration !== null && duration >= 38_000 && duration <= 46_000);
  const title = weekly ? "Weekly limit" : monthly ? "Monthly limit" : "Coding limit";
  const id = weekly ? "grok:weekly" : monthly ? "grok:monthly" : "grok:coding";
  const plan = firstText(root, ["subscriptionTier", "subscription_tier", "plan"]);
  return {
    window: window(
      0,
      id,
      title,
      weekly ? "weekly" : "additional",
      weekly ? 10_080 : duration,
      100 - clamp(usedPercent),
      end,
    ),
    plan: plan ? displayGrokPlan(plan) : null,
  };
}

function centValue(value: unknown): number | null {
  const root = asRecord(value);
  return root ? number(root.val) : number(value);
}

function grokTierPlan(token: string): string | null {
  const claims = jwtClaims(token);
  const named = text(claims?.subscription_tier ?? claims?.subscriptionTier ?? claims?.plan);
  if (named) return displayGrokPlan(named);
  switch (integer(claims?.tier)) {
    case 0: return "Free";
    case 1: return "SuperGrok";
    case 2: return "X Basic";
    case 3: return "X Premium";
    case 4: return "X Premium+";
    case 5: return "SuperGrok Heavy";
    case 6: return "SuperGrok Lite";
    case 7: return "SuperGrok+";
    default: return null;
  }
}

function displayGrokPlan(value: string): string {
  const words = value.trim().replace(/[_-]+/g, " ").split(/\s+/);
  return words.map((word) => {
    switch (word.toLowerCase()) {
      case "supergrok": return "SuperGrok";
      case "supergrokpro": return "SuperGrok Heavy";
      case "supergroklite": return "SuperGrok Lite";
      case "supergrokplus": return "SuperGrok+";
      default: return word.charAt(0).toUpperCase() + word.slice(1).toLowerCase();
    }
  }).join(" ");
}

async function fetchOpenAIAPI(
  account: ProviderAccount,
  credentials: ProviderCredentials,
  now: number,
): Promise<ProviderFetchResult> {
  const period = utcMonthPeriod(now);
  const parameters = new URLSearchParams({
    start_time: String(period.start),
    end_time: String(now + 1),
    bucket_width: "1d",
    limit: "31",
  });
  const value = await getJSON(
    `https://api.openai.com/v1/organization/costs?${parameters.toString()}`,
    {
      authorization: `Bearer ${credentials.access_token}`,
      "user-agent": USER_AGENT,
    },
  );
  const balance = openAIAPIBalance(value, credentials.monthly_budget ?? null, period);
  const result = snapshot(account.provider_id, account.plan, now, [], 0, []);
  result.api_balance = balance;
  return { credentials, snapshot: result };
}

async function fetchAnthropicAPI(
  account: ProviderAccount,
  credentials: ProviderCredentials,
  now: number,
): Promise<ProviderFetchResult> {
  const period = utcMonthPeriod(now);
  const parameters = new URLSearchParams({
    starting_at: new Date(period.start * 1_000).toISOString(),
    ending_at: new Date(now * 1_000).toISOString(),
    bucket_width: "1d",
    limit: "31",
  });
  const value = await getJSON(
    `https://api.anthropic.com/v1/organizations/cost_report?${parameters.toString()}`,
    {
      "x-api-key": credentials.access_token,
      "anthropic-version": "2023-06-01",
      "user-agent": USER_AGENT,
    },
  );
  const balance = anthropicAPIBalance(value, credentials.monthly_budget ?? null, period);
  const result = snapshot(account.provider_id, account.plan, now, [], 0, []);
  result.api_balance = balance;
  return { credentials, snapshot: result };
}

async function fetchOpenRouter(
  account: ProviderAccount,
  credentials: ProviderCredentials,
  now: number,
): Promise<ProviderFetchResult> {
  const value = await getJSON("https://openrouter.ai/api/v1/key", {
    authorization: `Bearer ${credentials.access_token}`,
    accept: "application/json",
    "user-agent": USER_AGENT,
  });
  const parsed = openRouterAPIBalance(value, now);
  const result = snapshot(
    account.provider_id,
    parsed.freeTier ? "Free tier" : account.plan,
    now,
    [],
    0,
    [],
  );
  result.api_balance = parsed.balance;
  return {
    credentials,
    snapshot: result,
    account_identity: parsed.creatorUserID ? `creator:${parsed.creatorUserID}` : undefined,
  };
}

function openRouterAPIBalance(value: unknown, now: number): {
  balance: ProviderAPIBalance;
  creatorUserID: string | null;
  freeTier: boolean;
} {
  const root = requiredRecord(value, "OpenRouter returned unreadable API key data.");
  const data = asRecord(root.data);
  if (!data) throw new ProviderFetchError("OpenRouter returned unreadable API key data.");
  const rawLimit = number(data.limit);
  const limit = rawLimit !== null && rawLimit >= 0 ? rawLimit : null;
  const rawRemaining = number(data.limit_remaining);
  const reset = text(data.limit_reset)?.toLowerCase() ?? null;
  const period = apiKeyResetPeriod(reset, now);
  const periodUsage = reset === "daily" ? number(data.usage_daily)
    : reset === "weekly" ? number(data.usage_weekly)
    : reset === "monthly" ? number(data.usage_monthly)
    : number(data.usage);
  const spent = limit !== null && rawRemaining !== null
    ? Math.max(0, limit - rawRemaining)
    : Math.max(0, periodUsage ?? 0);
  if (limit === null && periodUsage === null && rawRemaining === null) {
    throw new ProviderFetchError("OpenRouter returned unreadable API key usage.");
  }
  const remaining = limit === null ? null
    : Math.min(limit, Math.max(0, rawRemaining ?? limit - spent));
  const resetTitle = reset === "daily" ? "Daily" : reset === "weekly" ? "Weekly"
    : reset === "monthly" ? "Monthly" : null;
  return {
    balance: {
      title: limit === null ? "API key usage"
        : resetTitle ? `${resetTitle} API key limit` : "API key spending limit",
      currency_code: "USD",
      spent,
      limit,
      remaining,
      period_start: period?.start ?? null,
      period_end: period?.end ?? null,
      access_expires_at: timestamp(data.expires_at),
      is_unlimited: limit === null,
      kind: "budget",
    },
    creatorUserID: text(data.creator_user_id),
    freeTier: data.is_free_tier === true,
  };
}

async function fetchFireworks(
  account: ProviderAccount,
  credentials: ProviderCredentials,
  now: number,
): Promise<ProviderFetchResult> {
  const accountID = fireworksAccountID(account.workspace_id);
  if (!accountID) {
    throw new ProviderFetchError("Fireworks account ID is missing or invalid.", 400);
  }
  const value = await getJSON(
    `https://api.fireworks.ai/v1/accounts/${encodeURIComponent(accountID)}/quotas?pageSize=200`,
    {
      authorization: `Bearer ${credentials.access_token}`,
      accept: "application/json",
      "user-agent": USER_AGENT,
    },
  );
  const result = snapshot(account.provider_id, account.plan, now, [], 0, []);
  result.api_balance = fireworksAPIBalance(value, credentials.monthly_budget ?? null, now);
  return {
    credentials,
    snapshot: result,
    // A successful authenticated request verifies that this key can access the official
    // Fireworks account resource used as the quota scope.
    account_identity: `account:${accountID}`,
  };
}

function fireworksAccountID(value: string): string | null {
  return normalizeFireworksAccountResource(value)?.slice("accounts/".length) ?? null;
}

export function normalizeFireworksAccountResource(value: string): string | null {
  const trimmed = value.trim();
  const identifier = trimmed.startsWith("accounts/") ? trimmed.slice("accounts/".length) : trimmed;
  return /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(identifier)
    ? `accounts/${identifier}`
    : null;
}

function fireworksAPIBalance(
  value: unknown,
  fallbackBudget: number | null,
  now: number,
): ProviderAPIBalance {
  const root = requiredRecord(value, "Fireworks returned unreadable quota data.");
  const quotas = asRecords(root.quotas);
  if (!quotas) throw new ProviderFetchError("Fireworks returned unreadable quota data.");
  const quota = quotas.find((candidate) => {
    const name = text(candidate.name)?.toLowerCase().replaceAll("_", "-") ?? "";
    const leaf = name.split("/").at(-1) ?? name;
    return leaf === "monthly-spend-usd"
      || (leaf.includes("monthly") && leaf.includes("spend") && leaf.includes("usd"));
  });
  if (!quota) throw new ProviderFetchError("Fireworks returned no monthly spending quota.");
  const rawSpent = currencyNumber(quota.usage);
  if (rawSpent === null || rawSpent < 0) {
    throw new ProviderFetchError("Fireworks returned unreadable monthly spending usage.");
  }
  const configured = currencyNumber(quota.value) ?? currencyNumber(quota.maxValue);
  const limit = configured !== null && configured >= 0 ? configured
    : fallbackBudget !== null && fallbackBudget > 0 ? fallbackBudget : null;
  const period = utcMonthPeriod(now);
  return {
    title: limit === null ? "API spend this month" : "Monthly API budget",
    currency_code: "USD",
    spent: rawSpent,
    limit,
    remaining: limit === null ? null : Math.max(0, limit - rawSpent),
    period_start: period.start,
    period_end: period.end,
    access_expires_at: null,
    is_unlimited: limit === null,
    kind: "budget",
  };
}

async function fetchDeepSeek(
  account: ProviderAccount,
  credentials: ProviderCredentials,
  now: number,
): Promise<ProviderFetchResult> {
  const value = await getJSON("https://api.deepseek.com/user/balance", {
    authorization: `Bearer ${credentials.access_token}`,
    accept: "application/json",
    "user-agent": USER_AGENT,
  });
  const result = snapshot(account.provider_id, account.plan, now, [], 0, []);
  result.api_balance = deepSeekAPIBalance(value);
  return { credentials, snapshot: result };
}

function deepSeekAPIBalance(value: unknown): ProviderAPIBalance {
  const root = requiredRecord(value, "DeepSeek returned unreadable balance data.");
  const balances = asRecords(root.balance_infos);
  if (!balances?.length) throw new ProviderFetchError("DeepSeek returned no API balance.");
  const selected = balances.find((item) => text(item.currency)?.toUpperCase() === "USD")
    ?? balances.find((item) => text(item.currency)?.toUpperCase() === "CNY")
    ?? balances[0];
  const remaining = currencyNumber(selected.total_balance);
  const currency = text(selected.currency)?.toUpperCase();
  if (remaining === null || remaining < 0 || !currency || !/^[A-Z]{3}$/.test(currency)) {
    throw new ProviderFetchError("DeepSeek returned unreadable balance data.");
  }
  return {
    title: "API wallet balance",
    currency_code: currency,
    spent: 0,
    limit: null,
    remaining,
    period_start: null,
    period_end: null,
    access_expires_at: null,
    is_unlimited: false,
    kind: "wallet",
  };
}

async function fetchPoe(
  account: ProviderAccount,
  credentials: ProviderCredentials,
  now: number,
): Promise<ProviderFetchResult> {
  const value = await getJSON("https://api.poe.com/usage/current_balance", {
    authorization: `Bearer ${credentials.access_token}`,
    accept: "application/json",
    "user-agent": USER_AGENT,
  });
  const result = snapshot(account.provider_id, account.plan, now, [], 0, []);
  result.api_balance = poeAPIBalance(value);
  return { credentials, snapshot: result };
}

function poeAPIBalance(value: unknown): ProviderAPIBalance {
  const root = requiredRecord(value, "Poe returned unreadable point balance data.");
  const remaining = number(root.current_point_balance);
  if (remaining === null || remaining < 0) {
    throw new ProviderFetchError("Poe returned unreadable point balance data.");
  }
  return {
    title: "API point balance",
    currency_code: "POINTS",
    spent: 0,
    limit: null,
    remaining,
    period_start: null,
    period_end: null,
    access_expires_at: null,
    is_unlimited: false,
    kind: "wallet",
    unit_label: "points",
  };
}

type BillingPeriod = { start: number; end: number };

function utcMonthPeriod(now: number): BillingPeriod {
  const date = new Date(now * 1_000);
  const start = Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), 1) / 1_000;
  const end = Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 1) / 1_000;
  return { start, end };
}

function apiKeyResetPeriod(reset: string | null, now: number): BillingPeriod | null {
  const date = new Date(now * 1_000);
  if (reset === "daily") {
    const start = Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()) / 1_000;
    return { start, end: start + 86_400 };
  }
  if (reset === "weekly") {
    const daysSinceMonday = (date.getUTCDay() + 6) % 7;
    const start = Date.UTC(
      date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate() - daysSinceMonday,
    ) / 1_000;
    return { start, end: start + 7 * 86_400 };
  }
  return reset === "monthly" ? utcMonthPeriod(now) : null;
}

function openAIAPIBalance(
  value: unknown,
  rawBudget: number | null,
  period: BillingPeriod,
): ProviderAPIBalance {
  const root = requiredRecord(value, "OpenAI API returned unreadable billing data.");
  const buckets = asRecords(root.data);
  if (!buckets) throw new ProviderFetchError("OpenAI API returned unreadable billing data.");
  let spent = 0;
  let currency = "USD";
  for (const bucket of buckets) {
    const results = asRecords(bucket.results);
    if (!results) continue;
    for (const result of results) {
      const amount = asRecord(result.amount);
      const amountValue = number(amount?.value);
      if (amountValue !== null) spent += amountValue;
      currency = text(amount?.currency)?.toUpperCase() ?? currency;
    }
  }
  return apiBalance(spent, rawBudget, currency, period);
}

function anthropicAPIBalance(
  value: unknown,
  rawBudget: number | null,
  period: BillingPeriod,
): ProviderAPIBalance {
  const root = requiredRecord(value, "Anthropic API returned unreadable billing data.");
  const buckets = asRecords(root.data);
  if (!buckets) throw new ProviderFetchError("Anthropic API returned unreadable billing data.");
  let cents = 0;
  let currency = "USD";
  for (const bucket of buckets) {
    const results = asRecords(bucket.results);
    if (!results) continue;
    for (const result of results) {
      const amount = asRecord(result.amount);
      const amountValue = number(amount?.value ?? result.amount);
      if (amountValue !== null) cents += amountValue;
      currency = text(amount?.currency ?? result.currency)?.toUpperCase() ?? currency;
    }
  }
  return apiBalance(cents / 100, rawBudget, currency, period);
}

function apiBalance(
  spent: number,
  rawBudget: number | null,
  currency: string,
  period: BillingPeriod,
): ProviderAPIBalance {
  const limit = rawBudget !== null && Number.isFinite(rawBudget) && rawBudget > 0
    ? rawBudget : null;
  return {
    title: limit === null ? "API spend this month" : "Monthly API budget",
    currency_code: currency,
    spent: Math.max(0, spent),
    limit,
    remaining: limit === null ? null : Math.max(0, limit - spent),
    period_start: period.start,
    period_end: period.end,
    access_expires_at: null,
    is_unlimited: false,
    kind: "budget",
  };
}

async function fetchChatGPT(
  account: ProviderAccount,
  credentials: ProviderCredentials,
  now: number,
): Promise<ProviderFetchResult> {
  const verified = await verifyChatGPTIdentity(account, credentials, now);
  const refreshed = verified.credentials;
  const headers = {
    authorization: `Bearer ${refreshed.access_token}`,
    "chatgpt-account-id": account.workspace_id,
    "user-agent": USER_AGENT,
  };
  const usage = await getJSON("https://chatgpt.com/backend-api/wham/usage", headers);
  let credits: unknown = {};
  let resetCreditsAuthoritative = true;
  try {
    credits = await getJSON(
      "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits",
      headers,
    );
  } catch {
    // The banked-reset endpoint has its own rate limit. Quota windows from /usage remain valid,
    // so retain the previous credit detail during fan-out instead of failing the whole refresh.
    resetCreditsAuthoritative = false;
  }
  const root = asRecord(usage) ?? {};
  const limit = asRecord(root.rate_limit) ?? root;
  const windows: ProviderUsageWindow[] = [];
  const primary = chatGPTWindow(limit.primary_window ?? limit.primary, 0, "Usage limit");
  const secondary = chatGPTWindow(limit.secondary_window ?? limit.secondary, 1, "Usage limit");
  if (primary) windows.push(primary);
  if (secondary) windows.push(secondary);
  const additional = asRecords(root.additional_rate_limits) ?? [];
  for (const item of additional) {
    const rateLimit = asRecord(item.rate_limit) ?? {};
    const title = text(item.limit_name) ?? "Additional limit";
    const feature = text(item.metered_feature) ?? title;
    const first = chatGPTWindow(
      rateLimit.primary_window ?? rateLimit.primary,
      windows.length,
      title,
      "additional",
      `additional:${feature}:primary`,
    );
    if (first) windows.push(first);
    const second = chatGPTWindow(
      rateLimit.secondary_window ?? rateLimit.secondary,
      windows.length,
      title,
      "additional",
      `additional:${feature}:secondary`,
    );
    if (second) windows.push(second);
  }
  if (windows.length === 0) throw new ProviderFetchError("ChatGPT returned no resettable quota.");

  const creditRoot = asRecord(credits) ?? {};
  const fallbackOrdinals = new Map<string, number>();
  const resetCredits = (asRecords(creditRoot.credits) ?? []).map((item) => {
    const expiresAt = timestamp(item.expires_at ?? item.expiresAt);
    const grantedAt = timestamp(item.granted_at ?? item.grantedAt);
    const status = text(item.status);
    const base = fallbackResetCreditID(expiresAt, grantedAt, status, 0);
    const ordinal = fallbackOrdinals.get(base) ?? 0;
    fallbackOrdinals.set(base, ordinal + 1);
    const id = text(item.id) ?? fallbackResetCreditID(expiresAt, grantedAt, status, ordinal);
    return { id, expires_at: expiresAt, status: status ?? null, granted_at: grantedAt };
  }).filter((credit) => credit.status === null || credit.status.toLowerCase() === "available")
    .sort((a, b) => (a.expires_at ?? Number.MAX_SAFE_INTEGER) - (b.expires_at ?? Number.MAX_SAFE_INTEGER));
  const usageCredit = asRecord(root.rate_limit_reset_credits);
  const resetCount = integer(creditRoot.available_count)
    ?? integer(usageCredit?.available_count)
    ?? resetCredits.length;
  const reportedPlan = text(root.plan_type);
  const plan = preferredPlan(reportedPlan, account.plan);
  return {
    credentials: refreshed,
    account_identity: verified.identity,
    snapshot: snapshot(
      account.provider_id,
      plan,
      now,
      windows,
      resetCount,
      resetCredits,
      resetCreditsAuthoritative,
    ),
  };
}

async function verifyChatGPTIdentity(
  account: ProviderAccount,
  credentials: ProviderCredentials,
  now: number,
): Promise<{ credentials: ProviderCredentials; identity: string }> {
  const refreshed = await refreshChatGPT(credentials, now);
  const headers = {
    authorization: `Bearer ${refreshed.access_token}`,
    "chatgpt-account-id": account.workspace_id,
    "user-agent": USER_AGENT,
  };
  const tokenIdentity = chatGPTTokenIdentity(refreshed.id_token)
    ?? chatGPTTokenIdentity(refreshed.access_token);
  let profileIdentity: string | null = null;
  try {
    profileIdentity = chatGPTProfileIdentity(
      await getJSON("https://chatgpt.com/backend-api/me", headers)
    );
  } catch (error) {
    // Authentication failures are authoritative session checks. A temporary or unsupported
    // profile endpoint must not interrupt quota history when the signed token still supplies
    // the same stable user identity.
    if (error instanceof ProviderFetchError && (error.status === 401 || error.status === 403)) {
      throw error;
    }
    if (!tokenIdentity) throw error;
  }
  const identity = profileIdentity ?? tokenIdentity;
  if (!identity) {
    throw new ProviderFetchError("ChatGPT returned no stable account identity.");
  }
  return { credentials: refreshed, identity };
}

function chatGPTProfileIdentity(value: unknown): string | null {
  const root = asRecord(value);
  if (!root) return null;
  const user = asRecord(root.user);
  const account = asRecord(root.account);
  const id = text(root.id)
    ?? text(root.user_id)
    ?? text(user?.id)
    ?? text(user?.user_id)
    ?? text(account?.user_id);
  return id ? `user:${id}` : null;
}

function chatGPTTokenIdentity(token: string): string | null {
  const claims = jwtClaims(token);
  const auth = asRecord(claims?.["https://api.openai.com/auth"]);
  const id = text(auth?.chatgpt_user_id)
    ?? text(auth?.user_id)
    ?? text(claims?.sub);
  return id ? `user:${id}` : null;
}

async function refreshChatGPT(credentials: ProviderCredentials, now: number): Promise<ProviderCredentials> {
  const expiration = credentials.expires_at ?? jwtExpiration(credentials.access_token);
  if (expiration !== null && expiration - now >= 5 * 60) return credentials;
  if (!credentials.refresh_token) throw new ProviderFetchError("ChatGPT refresh token is missing.", 401);
  const body = new URLSearchParams({
    client_id: "app_EMoamEEZ73f0CkXaXp7hrann",
    grant_type: "refresh_token",
    refresh_token: credentials.refresh_token,
  });
  let value: unknown;
  try {
    value = await requestJSON("https://auth.openai.com/oauth/token", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: body.toString(),
    });
  } catch (error) {
    if (error instanceof ProviderFetchError && [400, 401, 403].includes(error.status)) {
      throw new ProviderFetchError("ChatGPT authorization expired.", 401);
    }
    throw error;
  }
  const root = requiredRecord(value, "ChatGPT returned an unreadable token response.");
  const accessToken = requiredText(root.access_token, "ChatGPT did not return an access token.");
  const idToken = text(root.id_token) ?? credentials.id_token;
  return {
    access_token: accessToken,
    refresh_token: text(root.refresh_token) ?? credentials.refresh_token,
    id_token: idToken,
    expires_at: jwtExpiration(accessToken) ?? jwtExpiration(idToken),
  };
}

function chatGPTWindow(
  value: unknown,
  position: number,
  fallbackTitle: string,
  suppliedKind: WindowKind | null = null,
  identifier: string | null = null,
): ProviderUsageWindow | null {
  const root = asRecord(value);
  if (!root) return null;
  const used = number(root.used_percent ?? root.usedPercent);
  const reset = timestamp(root.reset_at ?? root.resets_at ?? root.resetsAt)
    ?? secondsFromNow(root.reset_after_seconds);
  if (used === null || reset === null) return null;
  const seconds = integer(root.limit_window_seconds);
  const minutes = seconds !== null ? Math.trunc(seconds / 60)
    : integer(root.window_minutes ?? root.windowDurationMins);
  const kind = suppliedKind ?? (minutes === 300 ? "fiveHour" : minutes === 10_080 ? "weekly" : null);
  return window(
    position,
    identifier ?? (kind === "fiveHour" ? "five_hour" : kind === "weekly" ? "weekly" : `limit:${fallbackTitle}`),
    text(root.limit_name) ?? fallbackTitle,
    kind,
    minutes,
    100 - used,
    reset,
  );
}

async function fetchClaude(
  account: ProviderAccount,
  credentials: ProviderCredentials,
  now: number,
): Promise<ProviderFetchResult> {
  const refreshed = await refreshClaude(credentials, now);
  const value = await getJSON("https://api.anthropic.com/api/oauth/usage", {
    authorization: `Bearer ${refreshed.access_token}`,
    "anthropic-beta": "oauth-2025-04-20",
    accept: "application/json",
    "content-type": "application/json",
    "user-agent": "claude-code/2.1.0",
  });
  const root = requiredRecord(value, "Claude returned unreadable usage data.");
  const windows: ProviderUsageWindow[] = [];
  const fiveHour = claudeWindow(root.five_hour, 0, "5h limit", 300, "five_hour", "fiveHour");
  const weekly = claudeWindow(root.seven_day, 1, "Weekly limit", 10_080, "weekly", "weekly");
  if (fiveHour) windows.push(fiveHour);
  if (weekly) windows.push(weekly);
  if (windows.length === 0) throw new ProviderFetchError("Claude returned no resettable quota.");
  return {
    credentials: refreshed,
    snapshot: snapshot(account.provider_id, account.plan, now, windows, 0, []),
  };
}

async function refreshClaude(credentials: ProviderCredentials, now: number): Promise<ProviderCredentials> {
  if (credentials.expires_at !== null && credentials.expires_at - now >= 5 * 60) return credentials;
  if (!credentials.refresh_token) throw new ProviderFetchError("Claude refresh token is missing.", 401);
  const value = await requestJSON("https://platform.claude.com/v1/oauth/token", {
    method: "POST",
    headers: {
      accept: "application/json",
      "content-type": "application/json",
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      grant_type: "refresh_token",
      refresh_token: credentials.refresh_token,
      client_id: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
    }),
  });
  const root = requiredRecord(value, "Claude returned an unreadable token response.");
  const accessToken = requiredText(root.access_token, "Claude did not return an access token.");
  const expiresAt = timestamp(root.expires_at)
    ?? number(root.expires_in)?.valueOf()
    ?? 8 * 60 * 60;
  const absoluteExpiry = timestamp(root.expires_at) ?? now + expiresAt;
  return {
    access_token: accessToken,
    refresh_token: text(root.refresh_token) ?? credentials.refresh_token,
    id_token: credentials.id_token,
    expires_at: absoluteExpiry,
  };
}

function claudeWindow(
  value: unknown,
  position: number,
  title: string,
  minutes: number,
  id: string,
  kind: WindowKind,
): ProviderUsageWindow | null {
  const root = asRecord(value);
  const used = number(root?.utilization);
  const reset = timestamp(root?.resets_at);
  return used === null || reset === null ? null
    : window(position, id, title, kind, minutes, 100 - used, reset);
}

async function fetchKimi(
  account: ProviderAccount,
  credentials: ProviderCredentials,
  now: number,
): Promise<ProviderFetchResult> {
  const refreshed = await refreshKimi(credentials, now);
  const value = await getJSON("https://api.kimi.com/coding/v1/usages", {
    authorization: `Bearer ${refreshed.access_token}`,
    accept: "application/json",
    "cache-control": "no-store",
    "user-agent": USER_AGENT,
  });
  const root = requiredRecord(value, "Kimi returned unreadable usage data.");
  let fiveHour: ProviderUsageWindow | null = null;
  let weekly = kimiWindow(asRecord(root.usage), 1, "Weekly limit", 10_080, "weekly", "weekly", now);
  const extras: ProviderUsageWindow[] = [];
  const limits = asRecords(root.limits) ?? [];
  for (const [index, item] of limits.entries()) {
    const detail = asRecord(item.detail) ?? item;
    const duration = asRecord(item.window) ?? {};
    const minutes = durationMinutes(duration, item, detail);
    const title = windowTitle(item, detail, minutes, index);
    if (minutes === 300 && !fiveHour) {
      fiveHour = kimiWindow(detail, 0, "5h limit", 300, "fiveHour", "five_hour", now);
    } else if (minutes === 10_080 && !weekly) {
      weekly = kimiWindow(detail, 1, "Weekly limit", 10_080, "weekly", "weekly", now);
    } else {
      const extra = kimiWindow(
        detail,
        extras.length + 2,
        title,
        minutes,
        "additional",
        `kimi:${identifier(title)}:${minutes ?? 0}`,
        now,
      );
      if (extra) extras.push(extra);
    }
  }
  const windows = [fiveHour, weekly, ...extras].filter((item): item is ProviderUsageWindow => item !== null)
    .map((item, position) => ({ ...item, position }));
  if (windows.length === 0) throw new ProviderFetchError("Kimi returned no resettable quota.");
  return {
    credentials: refreshed,
    snapshot: snapshot(
      account.provider_id,
      text(root.plan ?? root.subscription_type ?? root.tier) ?? account.plan,
      now,
      windows,
      0,
      [],
    ),
  };
}

async function refreshKimi(credentials: ProviderCredentials, now: number): Promise<ProviderCredentials> {
  const expiration = credentials.expires_at
    ?? jwtExpiration(credentials.id_token || credentials.access_token);
  if (expiration !== null && expiration - now >= 5 * 60) return credentials;
  if (!credentials.refresh_token) throw new ProviderFetchError("Kimi refresh token is missing.", 401);
  const body = new URLSearchParams({
    client_id: "17e5f671-d194-4dfb-9706-5516cb48c098",
    grant_type: "refresh_token",
    refresh_token: credentials.refresh_token,
  });
  const value = await requestJSON("https://auth.kimi.com/api/oauth/token", {
    method: "POST",
    headers: {
      accept: "application/json",
      "content-type": "application/x-www-form-urlencoded",
      "cache-control": "no-store",
      "user-agent": USER_AGENT,
    },
    body: body.toString(),
  });
  const root = requiredRecord(value, "Kimi returned an unreadable token response.");
  const expiresIn = number(root.expires_in);
  return {
    access_token: requiredText(root.access_token, "Kimi did not return an access token."),
    refresh_token: requiredText(root.refresh_token, "Kimi did not return a refresh token."),
    id_token: text(root.id_token) ?? credentials.id_token,
    expires_at: expiresIn !== null ? now + expiresIn : null,
  };
}

function kimiWindow(
  detail: Record<string, unknown> | null,
  position: number,
  title: string,
  minutes: number | null,
  kind: WindowKind,
  id: string,
  now: number,
): ProviderUsageWindow | null {
  if (!detail) return null;
  const limit = number(detail.limit);
  const used = number(detail.used) ?? (limit !== null && number(detail.remaining) !== null
    ? limit - number(detail.remaining)! : null);
  const reset = timestamp(detail.resetTime ?? detail.resetAt ?? detail.reset_time ?? detail.reset_at)
    ?? relativeTimestamp(detail, now);
  if (limit === null || limit <= 0 || used === null || reset === null) return null;
  return window(position, id, title, kind, minutes, 100 - used / limit * 100, reset);
}

async function fetchCopilot(
  account: ProviderAccount,
  credentials: ProviderCredentials,
  now: number,
): Promise<ProviderFetchResult> {
  if (credentials.expires_at !== null && credentials.expires_at - now < 5 * 60) {
    throw new ProviderFetchError("GitHub authorization expired; relink this account.", 401);
  }
  const value = await getJSON("https://api.github.com/copilot_internal/user", {
    authorization: `token ${credentials.access_token}`,
    accept: "application/json",
    "editor-version": "vscode/1.96.2",
    "editor-plugin-version": "copilot-chat/0.26.7",
    "user-agent": "GitHubCopilotChat/0.26.7",
    "x-github-api-version": "2025-04-01",
  });
  const root = requiredRecord(value, "GitHub returned unreadable Copilot usage data.");
  const reset = timestamp(root.quota_reset_date);
  const direct = asRecord(root.quota_snapshots);
  const fallback = copilotFallback(root);
  const dynamic = dynamicCopilotQuotas(direct);
  const premium = preferredQuota(
    (direct ? quotaFromUnknown(direct.premium_interactions) : null) ?? dynamic.premium,
    fallback.premium,
  );
  const chat = preferredQuota(
    (direct ? quotaFromUnknown(direct.chat) : null) ?? dynamic.chat,
    fallback.chat,
  );
  const windows: ProviderUsageWindow[] = [];
  if (reset !== null && premium && premium.remainingPercent !== null && !premium.unlimited) {
    windows.push(window(0, "copilot:premium", "Premium requests", null, null,
      premium.remainingPercent, reset));
  }
  if (reset !== null && chat && chat.remainingPercent !== null && !chat.unlimited) {
    windows.push(window(1, "copilot:chat", "Chat", null, null, chat.remainingPercent, reset));
  }
  if (windows.length === 0 && premium?.unlimited !== true && chat?.unlimited !== true
      && root.token_based_billing !== true) {
    throw new ProviderFetchError("GitHub returned no resettable Copilot quota.");
  }
  return {
    credentials,
    snapshot: snapshot(account.provider_id, displayPlan(text(root.copilot_plan)) ?? account.plan,
      now, windows, 0, []),
  };
}

type CopilotQuota = { remainingPercent: number | null; unlimited: boolean };

function quotaFromUnknown(value: unknown): CopilotQuota | null {
  const root = asRecord(value);
  if (!root) return null;
  const unlimited = root.unlimited === true;
  const explicit = number(root.percent_remaining);
  const entitlement = number(root.entitlement);
  const remaining = number(root.remaining);
  const remainingPercent = unlimited ? 100 : explicit
    ?? (entitlement !== null && entitlement > 0 && remaining !== null ? remaining / entitlement * 100 : null);
  return { remainingPercent: remainingPercent === null ? null : clamp(remainingPercent), unlimited };
}

function copilotFallback(root: Record<string, unknown>): { premium: CopilotQuota | null; chat: CopilotQuota | null } {
  const monthly = asRecord(root.monthly_quotas);
  const limited = asRecord(root.limited_user_quotas);
  const build = (key: string): CopilotQuota | null => {
    const entitlement = number(monthly?.[key]);
    const remaining = number(limited?.[key]);
    return entitlement !== null && entitlement > 0 && remaining !== null
      ? { remainingPercent: clamp(remaining / entitlement * 100), unlimited: false }
      : null;
  };
  return { premium: build("completions"), chat: build("chat") };
}

function preferredQuota(direct: CopilotQuota | null, fallback: CopilotQuota | null): CopilotQuota | null {
  if (direct?.unlimited && fallback?.remainingPercent != null) return fallback;
  return direct && (direct.remainingPercent !== null || direct.unlimited) ? direct : fallback;
}

function dynamicCopilotQuotas(root: Record<string, unknown> | null): {
  premium: CopilotQuota | null;
  chat: CopilotQuota | null;
} {
  if (!root) return { premium: null, chat: null };
  let premium: CopilotQuota | null = null;
  let chat: CopilotQuota | null = null;
  let first: CopilotQuota | null = null;
  for (const [key, value] of Object.entries(root)) {
    const quota = quotaFromUnknown(value);
    if (!quota || (quota.remainingPercent === null && !quota.unlimited)) continue;
    first ??= quota;
    const name = key.toLowerCase();
    if (!chat && name.includes("chat")) chat = quota;
    if (!premium && ["premium", "completion", "code"].some((term) => name.includes(term))) {
      premium = quota;
    }
  }
  if (!premium && !chat) chat = first;
  return { premium, chat };
}

async function fetchZAI(
  account: ProviderAccount,
  credentials: ProviderCredentials,
  now: number,
): Promise<ProviderFetchResult> {
  const value = await getJSON("https://api.z.ai/api/monitor/usage/quota/limit", {
    authorization: `Bearer ${credentials.access_token}`,
    accept: "application/json",
    "user-agent": USER_AGENT,
  });
  const root = requiredRecord(value, "Z.AI returned unreadable quota data.");
  const payload = asRecord(root.data);
  const limits = asRecords(payload?.limits);
  if (integer(root.code) !== 200 || root.success === false || !payload || !limits) {
    throw new ProviderFetchError("Z.AI returned unreadable quota data.");
  }
  const candidates = limits.map((item) => zaiWindow(item, 0, now))
    .filter((item): item is ProviderUsageWindow => item !== null);
  const fiveHour = candidates.find((item) => item.window_minutes === 300);
  const weekly = candidates.find((item) => item.window_minutes === 10_080);
  const selected = [fiveHour, weekly, ...candidates.filter((item) => item !== fiveHour && item !== weekly)]
    .filter((item): item is ProviderUsageWindow => item !== undefined)
    .map((item, position) => ({ ...item, position }));
  if (selected.length === 0) throw new ProviderFetchError("Z.AI returned no resettable quota.");
  const plan = text(payload.planName ?? payload.plan ?? payload.plan_type ?? payload.packageName) ?? account.plan;
  return { credentials, snapshot: snapshot(account.provider_id, plan, now, selected, 0, []) };
}

function zaiWindow(raw: Record<string, unknown>, position: number, now: number): ProviderUsageWindow | null {
  const type = text(raw.type)?.toUpperCase();
  const reset = timestamp(raw.nextResetTime ?? raw.next_reset_time);
  if ((type !== "TOKENS_LIMIT" && type !== "TIME_LIMIT") || reset === null || reset <= now) return null;
  const unit = integer(raw.unit);
  const count = integer(raw.number) ?? 0;
  const minutes = unit === 1 ? count * 24 * 60 : unit === 3 ? count * 60
    : unit === 5 ? count : unit === 6 ? count * 7 * 24 * 60 : null;
  const allowance = number(raw.usage);
  const remaining = number(raw.remaining);
  const current = number(raw.currentValue ?? raw.current_value);
  const usedPercent = allowance !== null && allowance > 0
    ? Math.max(remaining !== null ? allowance - remaining : 0, current ?? 0) / allowance * 100
    : number(raw.percentage) ?? 0;
  if (type === "TIME_LIMIT") {
    return window(position, `zai:mcp:${unit ?? -1}:${count}`, "Monthly MCP limit", "additional",
      minutes, 100 - usedPercent, reset);
  }
  const kind: WindowKind = minutes === 300 ? "fiveHour" : minutes === 10_080 ? "weekly" : "additional";
  const title = minutes === 300 ? "5h limit" : minutes === 10_080 ? "Weekly limit"
    : durationTitle(unit, count) ?? "Coding limit";
  const id = minutes === 300 ? "zai:five_hour" : minutes === 10_080 ? "zai:weekly"
    : `zai:coding:${unit ?? -1}:${count}`;
  return window(position, id, title, kind, minutes, 100 - usedPercent, reset);
}

async function fetchMiniMax(
  account: ProviderAccount,
  credentials: ProviderCredentials,
  now: number,
): Promise<ProviderFetchResult> {
  const urls = [
    "https://www.minimax.io/v1/token_plan/remains",
    "https://www.minimaxi.com/v1/token_plan/remains",
  ];
  let lastError: unknown;
  for (const url of urls) {
    try {
      const value = await getJSON(url, {
        authorization: `Bearer ${credentials.access_token}`,
        accept: "application/json",
        "user-agent": USER_AGENT,
      });
      const root = requiredRecord(value, "MiniMax returned unreadable quota data.");
      const payload = asRecord(root.data) ?? root;
      const models = asRecords(payload.model_remains ?? payload.modelRemains);
      if (!models?.length) throw new ProviderFetchError("MiniMax returned unreadable quota data.");
      const candidates = models.filter(isCodingModel).sort((a, b) => modelPriority(a) - modelPriority(b));
      const primary = candidates.map((model) => miniMaxWindow(model, false, 0, now)).find(Boolean) ?? null;
      const secondary = candidates.map((model) => miniMaxWindow(model, true, 1, now)).find(Boolean) ?? null;
      const windows = [primary, secondary].filter((item): item is ProviderUsageWindow => item !== null)
        .map((item, position) => ({ ...item, position }));
      if (windows.length === 0) throw new ProviderFetchError("MiniMax returned no resettable quota.");
      const plan = firstText(payload, ["current_subscribe_title", "plan_name", "combo_title", "current_plan_title"])
        ?? account.plan ?? "Token Plan";
      return { credentials, snapshot: snapshot(account.provider_id, plan, now, windows, 0, []) };
    } catch (error) {
      lastError = error;
      if (error instanceof ProviderFetchError && ![401, 403, 404, 405].includes(error.status)) throw error;
    }
  }
  throw lastError instanceof Error ? lastError : new ProviderFetchError("MiniMax quota request failed.");
}

function miniMaxWindow(
  model: Record<string, unknown>,
  weekly: boolean,
  position: number,
  now: number,
): ProviderUsageWindow | null {
  const prefix = weekly ? "current_weekly" : "current_interval";
  const total = number(model[`${prefix}_total_count`]);
  const remaining = number(model[`${prefix}_usage_count`]);
  const remainingPercent = number(model[`${prefix}_remaining_percent`]);
  const status = integer(model[`${prefix}_status`]);
  if (status === 3 && (total ?? 0) === 0 && (remaining ?? 0) === 0 && (remainingPercent ?? 100) >= 100) {
    return null;
  }
  const percent = remainingPercent
    ?? (total !== null && total > 0 && remaining !== null ? remaining / total * 100 : null);
  if (percent === null) return null;
  const expected = weekly ? 7 * 86_400 : 5 * 3_600;
  let reset = timestamp(model[weekly ? "weekly_end_time" : "end_time"]);
  if (reset === null || reset <= now) {
    const rawRemaining = number(model[weekly ? "weekly_remains_time" : "remains_time"]);
    if (rawRemaining === null || rawRemaining <= 0) return null;
    reset = now + (rawRemaining > expected * 10 ? rawRemaining / 1_000 : rawRemaining);
  }
  return window(position, weekly ? "minimax:weekly" : "minimax:five_hour",
    weekly ? "Weekly limit" : "5h limit", weekly ? "weekly" : "fiveHour",
    weekly ? 10_080 : 300, percent, reset);
}

async function fetchSynthetic(
  account: ProviderAccount,
  credentials: ProviderCredentials,
  now: number,
): Promise<ProviderFetchResult> {
  const value = await getJSON("https://api.synthetic.new/v2/quotas", {
    authorization: `Bearer ${credentials.access_token}`,
    accept: "application/json",
    "user-agent": USER_AGENT,
  });
  const root = requiredRecord(value, "Synthetic returned unreadable quota data.");
  const windows = syntheticWindows(root, now);
  if (windows.length === 0) throw new ProviderFetchError("Synthetic returned no resettable quota.");
  const payload = asRecord(root.data) ?? root;
  const plan = firstText(payload, ["plan", "planName", "plan_name", "subscription", "tier"])
    ?? account.plan;
  return { credentials, snapshot: snapshot(account.provider_id, plan, now, windows, 0, []) };
}

function syntheticWindows(root: Record<string, unknown>, now: number): ProviderUsageWindow[] {
  const payload = asRecord(root.data) ?? root;
  const candidates: Array<{
    value: unknown;
    title: string;
    minutes: number;
    kind: WindowKind;
    id: string;
  }> = [
    { value: payload.rollingFiveHourLimit, title: "5h limit", minutes: 300,
      kind: "fiveHour", id: "synthetic:five_hour" },
    { value: payload.weeklyTokenLimit, title: "Weekly limit", minutes: 10_080,
      kind: "weekly", id: "synthetic:weekly" },
  ];
  return candidates.map((candidate, position) => {
    const quota = asRecord(candidate.value);
    if (!quota) return null;
    const remainingPercent = syntheticRemainingPercent(quota);
    const reset = timestamp(quota.resetAt ?? quota.reset_at ?? quota.resetsAt ?? quota.resets_at
      ?? quota.nextTickAt ?? quota.next_tick_at ?? quota.nextRegenAt ?? quota.next_regen_at
      ?? quota.periodEnd ?? quota.period_end);
    if (remainingPercent === null || reset === null || reset <= now) return null;
    return window(position, candidate.id, candidate.title, candidate.kind, candidate.minutes,
      remainingPercent, reset);
  }).filter((item): item is ProviderUsageWindow => item !== null);
}

function syntheticRemainingPercent(root: Record<string, unknown>): number | null {
  const explicit = number(root.percentRemaining ?? root.remainingPercent
    ?? root.remaining_percent ?? root.percent_remaining);
  if (explicit !== null) return clamp(explicit);
  const usedPercent = number(root.percentUsed ?? root.usedPercent ?? root.used_percent
    ?? root.percent_used ?? root.percentage);
  if (usedPercent !== null) return clamp(100 - usedPercent);
  const limit = currencyNumber(root.limit ?? root.max ?? root.total ?? root.maxCredits);
  const remaining = currencyNumber(root.remaining ?? root.left ?? root.remainingCredits);
  const used = currencyNumber(root.used ?? root.usage ?? root.usedCredits);
  if (limit === null || limit <= 0) return null;
  if (remaining !== null) return clamp(remaining / limit * 100);
  if (used !== null) return clamp(100 - used / limit * 100);
  return null;
}

const WARP_QUERY = `
query GetRequestLimitInfo($requestContext: RequestContext!) {
  user(requestContext: $requestContext) {
    __typename
    ... on UserOutput {
      user { requestLimitInfo { isUnlimited nextRefreshTime requestLimit requestsUsedSinceLastRefresh } }
    }
  }
}`;

async function fetchWarp(
  account: ProviderAccount,
  credentials: ProviderCredentials,
  now: number,
): Promise<ProviderFetchResult> {
  const value = await requestJSON("https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo", {
    method: "POST",
    headers: {
      authorization: `Bearer ${credentials.access_token}`,
      accept: "application/json",
      "content-type": "application/json",
      "user-agent": "Warp/1.0",
      "x-warp-client-id": "warp-app",
      "x-warp-os-category": "macOS",
      "x-warp-os-name": "macOS",
      "x-warp-os-version": "14.0.0",
    },
    body: JSON.stringify({
      query: WARP_QUERY,
      operationName: "GetRequestLimitInfo",
      variables: {
        requestContext: {
          clientContext: {},
          osContext: { category: "macOS", name: "macOS", version: "14.0.0" },
        },
      },
    }),
  });
  const root = requiredRecord(value, "Warp returned unreadable quota data.");
  const quota = warpWindow(root, 0, now);
  if (!quota) throw new ProviderFetchError("Warp returned no resettable quota.");
  return {
    credentials,
    snapshot: snapshot(account.provider_id, account.plan ?? "Warp", now, [quota], 0, []),
  };
}

function warpWindow(root: Record<string, unknown>, position: number, now: number): ProviderUsageWindow | null {
  const errors = Array.isArray(root.errors) ? root.errors : [];
  if (errors.length > 0) return null;
  const data = asRecord(root.data);
  const output = asRecord(data?.user);
  const user = asRecord(output?.user);
  const quota = asRecord(user?.requestLimitInfo);
  if (!quota || quota.isUnlimited === true) return null;
  const limit = number(quota.requestLimit);
  const used = number(quota.requestsUsedSinceLastRefresh);
  const reset = timestamp(quota.nextRefreshTime);
  if (limit === null || limit <= 0 || used === null || reset === null || reset <= now) return null;
  return window(position, "warp:monthly_credits", "Monthly credits", "additional", null,
    100 - used / limit * 100, reset);
}

function snapshot(
  providerID: ProviderID,
  plan: string | null,
  fetchedAt: number,
  windows: ProviderUsageWindow[],
  resetCount: number,
  credits: ProviderResetCredit[],
  resetCreditsAuthoritative = true,
): ProviderSnapshot {
  const result: ProviderSnapshot = {
    provider_id: providerID,
    plan,
    fetched_at: fetchedAt,
    windows,
    available_reset_count: Math.max(0, resetCount),
    reset_credits: credits,
  };
  if (!resetCreditsAuthoritative) result.reset_credits_authoritative = false;
  return result;
}

function fallbackResetCreditID(
  expiresAt: number | null,
  grantedAt: number | null,
  status: string | null,
  ordinal: number,
): string {
  const milliseconds = (value: number | null) => value === null
    ? "unknown" : String(Math.round(value * 1_000));
  return `generated:${milliseconds(grantedAt)}:${milliseconds(expiresAt)}:${status?.trim().toLowerCase() ?? "available"}:${ordinal}`;
}

function window(
  position: number,
  id: string,
  title: string,
  kind: WindowKind | null,
  minutes: number | null,
  remainingPercent: number,
  resetsAt: number,
): ProviderUsageWindow {
  return {
    position,
    metric_id: id,
    title,
    kind,
    window_minutes: minutes,
    remaining_percent: clamp(remainingPercent),
    resets_at: resetsAt,
  };
}

async function getJSON(url: string, headers: HeadersInit): Promise<unknown> {
  return requestJSON(url, { headers });
}

async function requestJSON(url: string, init: RequestInit): Promise<unknown> {
  let response: Response;
  try {
    // The Workers runtime supports manual redirect handling, but intentionally rejects
    // `redirect: "error"` before issuing the request. Never follow redirects here because an
    // Authorization header must not be forwarded to an unexpected origin.
    const timeout = AbortSignal.timeout(PROVIDER_REQUEST_TIMEOUT_MILLISECONDS);
    const signal = init.signal ? AbortSignal.any([init.signal, timeout]) : timeout;
    response = await fetch(url, { ...init, signal, redirect: "manual" });
  } catch {
    throw new ProviderFetchError("Provider request failed.", 0, true);
  }
  if (response.status >= 300 && response.status < 400) {
    await discardResponseBody(response);
    throw new ProviderFetchError("Provider redirected unexpectedly.", response.status);
  }
  if (!response.ok) {
    const retryAfter = parseRetryAfterSeconds(response.headers.get("retry-after"));
    await discardResponseBody(response);
    const retryable = response.status === 408 || response.status === 429 || response.status >= 500;
    const message = response.status === 429
      ? "Provider rate limit reached; retrying later."
      : `Provider request failed (HTTP ${response.status}).`;
    throw new ProviderFetchError(message, response.status, retryable, retryAfter);
  }
  return boundedJSON(response);
}

async function discardResponseBody(response: Response): Promise<void> {
  try { await response.body?.cancel(); } catch { /* The response is already unusable. */ }
}

function parseRetryAfterSeconds(value: string | null, now = Date.now()): number | null {
  if (!value) return null;
  const trimmed = value.trim();
  if (/^\d+$/.test(trimmed)) return Number(trimmed);
  const date = Date.parse(trimmed);
  if (!Number.isFinite(date)) return null;
  return Math.max(0, Math.ceil((date - now) / 1_000));
}

async function boundedJSON(response: Response): Promise<unknown> {
  const declared = number(response.headers.get("content-length"));
  if (declared !== null && declared > MAX_PROVIDER_RESPONSE_BYTES) {
    await response.body?.cancel();
    throw new ProviderFetchError("Provider response exceeded the size limit.");
  }
  if (!response.body) return null;
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const result = await reader.read();
    if (result.done) break;
    total += result.value.byteLength;
    if (total > MAX_PROVIDER_RESPONSE_BYTES) {
      await reader.cancel();
      throw new ProviderFetchError("Provider response exceeded the size limit.");
    }
    chunks.push(result.value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  const raw = new TextDecoder().decode(bytes);
  if (!raw) return null;
  try { return JSON.parse(raw) as unknown; }
  catch { throw new ProviderFetchError("Provider returned invalid JSON."); }
}

function requiredRecord(value: unknown, message: string): Record<string, unknown> {
  const result = asRecord(value);
  if (!result) throw new ProviderFetchError(message);
  return result;
}

function requiredText(value: unknown, message: string): string {
  const result = text(value);
  if (!result) throw new ProviderFetchError(message);
  return result;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown> : null;
}

function asRecords(value: unknown): Record<string, unknown>[] | null {
  if (!Array.isArray(value)) return null;
  const result = value.map(asRecord);
  return result.every((item): item is Record<string, unknown> => item !== null) ? result : null;
}

function text(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

function number(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function currencyNumber(value: unknown): number | null {
  if (typeof value === "string") return number(value.replace(/[$,%]/g, ""));
  return number(value);
}

function integer(value: unknown): number | null {
  const parsed = number(value);
  return parsed === null ? null : Math.trunc(parsed);
}

function timestamp(value: unknown): number | null {
  const numeric = number(value);
  if (numeric !== null) return numeric > 10_000_000_000 ? numeric / 1_000 : numeric;
  const raw = text(value);
  if (!raw) return null;
  const parsed = Date.parse(raw);
  return Number.isFinite(parsed) ? parsed / 1_000 : null;
}

function secondsFromNow(value: unknown): number | null {
  const seconds = number(value);
  return seconds !== null && seconds > 0 ? Date.now() / 1_000 + seconds : null;
}

function jwtExpiration(token: string): number | null {
  return number(jwtClaims(token)?.exp);
}

function jwtClaims(token: string): Record<string, unknown> | null {
  const parts = token.split(".");
  if (parts.length < 2) return null;
  try {
    const value = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = value + "=".repeat((4 - value.length % 4) % 4);
    return asRecord(JSON.parse(atob(padded)) as unknown);
  } catch {
    return null;
  }
}

function relativeTimestamp(detail: Record<string, unknown>, now: number): number | null {
  for (const key of ["reset_in", "resetIn", "ttl"]) {
    const seconds = number(detail[key]);
    if (seconds !== null && seconds > 0) return now + seconds;
  }
  return null;
}

function durationMinutes(...records: Record<string, unknown>[]): number | null {
  const value = records.map((item) => number(item.duration)).find((item) => item !== null) ?? null;
  if (value === null || value <= 0) return null;
  const unit = records.map((item) => text(item.timeUnit)).find((item) => item !== null)?.toUpperCase() ?? "";
  if (unit.includes("MINUTE")) return Math.trunc(value);
  if (unit.includes("HOUR")) return Math.trunc(value * 60);
  if (unit.includes("DAY")) return Math.trunc(value * 24 * 60);
  if (unit.includes("SECOND")) return Math.max(1, Math.round(value / 60));
  return null;
}

function windowTitle(item: Record<string, unknown>, detail: Record<string, unknown>,
  minutes: number | null, index: number): string {
  for (const key of ["name", "title", "scope"]) {
    const value = text(item[key] ?? detail[key]);
    if (value) return value;
  }
  if (minutes !== null) {
    if (minutes % 1_440 === 0) return `${minutes / 1_440}d limit`;
    if (minutes % 60 === 0) return `${minutes / 60}h limit`;
    return `${minutes}m limit`;
  }
  return `Limit ${index + 1}`;
}

function durationTitle(unit: number | null, count: number): string | null {
  if (count <= 0) return null;
  if (unit === 1) return `${count}-day limit`;
  if (unit === 3) return `${count}h limit`;
  if (unit === 5) return `${count}-minute limit`;
  if (unit === 6) return count === 1 ? "Weekly limit" : `${count}-week limit`;
  return null;
}

function identifier(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "");
}

function preferredPlan(reported: string | null, linked: string | null): string | null {
  if (!reported) return linked;
  if (!linked) return reported;
  const generic = reported.toLowerCase();
  const specific = linked.toLowerCase();
  return ["_", "-", " "].some((separator) => specific.startsWith(generic + separator))
    && /\d/.test(specific) ? linked : reported;
}

function displayPlan(value: string | null): string | null {
  if (!value || value.toLowerCase() === "unknown") return null;
  return value.replace(/[_-]+/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function isCodingModel(model: Record<string, unknown>): boolean {
  const name = text(model.model_name ?? model.modelName)?.toLowerCase();
  return !name || !["video", "image", "speech", "audio", "music"].some((term) => name.includes(term));
}

function modelPriority(model: Record<string, unknown>): number {
  const name = text(model.model_name ?? model.modelName)?.toLowerCase() ?? "";
  if (name === "general" || name.includes("text generation")) return 0;
  if (name.includes("minimax") || name.includes("abab")) return 1;
  return 2;
}

function firstText(root: Record<string, unknown>, keys: string[]): string | null {
  return keys.map((key) => text(root[key])).find((value) => value !== null) ?? null;
}

function clamp(value: number): number {
  return Math.max(0, Math.min(100, value));
}

export const providerTesting = {
  anthropicAPIBalance,
  chatGPTWindow,
  fallbackResetCreditID,
  fireworksAPIBalance,
  grokBilling,
  grokTierPlan,
  jwtExpiration,
  parseRetryAfterSeconds,
  providerRetryDelaySeconds,
  quotaFromUnknown,
  requestJSON,
  miniMaxWindow,
  openRouterAPIBalance,
  openAIAPIBalance,
  deepSeekAPIBalance,
  poeAPIBalance,
  syntheticWindows,
  warpWindow,
  zaiWindow,
};
