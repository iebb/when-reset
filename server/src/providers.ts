const MAX_PROVIDER_RESPONSE_BYTES = 1_048_576;
const USER_AGENT = "WhenReset-Worker/1.0";

export type ProviderID = "chatgpt" | "claude" | "kimi" | "github_copilot" | "zai" | "minimax";
export type WindowKind = "fiveHour" | "weekly" | "additional";

export type ProviderCredentials = {
  access_token: string;
  refresh_token: string;
  id_token: string;
  expires_at: number | null;
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
};

export type ProviderFetchResult = {
  credentials: ProviderCredentials;
  snapshot: ProviderSnapshot;
};

export class ProviderFetchError extends Error {
  readonly retryable: boolean;
  readonly status: number;

  constructor(message: string, status = 0, retryable = false) {
    super(message);
    this.name = "ProviderFetchError";
    this.status = status;
    this.retryable = retryable;
  }
}

export async function fetchProviderUsage(
  account: ProviderAccount,
  originalCredentials: ProviderCredentials,
  now = Math.floor(Date.now() / 1_000),
): Promise<ProviderFetchResult> {
  switch (account.provider_id) {
    case "chatgpt": return fetchChatGPT(account, originalCredentials, now);
    case "claude": return fetchClaude(account, originalCredentials, now);
    case "kimi": return fetchKimi(account, originalCredentials, now);
    case "github_copilot": return fetchCopilot(account, originalCredentials, now);
    case "zai": return fetchZAI(account, originalCredentials, now);
    case "minimax": return fetchMiniMax(account, originalCredentials, now);
  }
}

async function fetchChatGPT(
  account: ProviderAccount,
  credentials: ProviderCredentials,
  now: number,
): Promise<ProviderFetchResult> {
  const refreshed = await refreshChatGPT(credentials, now);
  const headers = {
    authorization: `Bearer ${refreshed.access_token}`,
    "chatgpt-account-id": account.workspace_id,
    "user-agent": USER_AGENT,
  };
  const [usage, credits] = await Promise.all([
    getJSON("https://chatgpt.com/backend-api/wham/usage", headers),
    getJSON("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits", headers),
  ]);
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
    snapshot: snapshot(account.provider_id, plan, now, windows, resetCount, resetCredits),
  };
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
  const value = await requestJSON("https://auth.openai.com/oauth/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  });
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

function snapshot(
  providerID: ProviderID,
  plan: string | null,
  fetchedAt: number,
  windows: ProviderUsageWindow[],
  resetCount: number,
  credits: ProviderResetCredit[],
): ProviderSnapshot {
  return {
    provider_id: providerID,
    plan,
    fetched_at: fetchedAt,
    windows,
    available_reset_count: Math.max(0, resetCount),
    reset_credits: credits,
  };
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
    response = await fetch(url, { ...init, redirect: "error" });
  } catch {
    throw new ProviderFetchError("Provider request failed.", 0, true);
  }
  const value = await boundedJSON(response);
  if (!response.ok) {
    throw new ProviderFetchError(`Provider request failed (HTTP ${response.status}).`, response.status,
      response.status === 408 || response.status === 429 || response.status >= 500);
  }
  return value;
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
  const parts = token.split(".");
  if (parts.length < 2) return null;
  try {
    const value = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = value + "=".repeat((4 - value.length % 4) % 4);
    return number(asRecord(JSON.parse(atob(padded)) as unknown)?.exp);
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
  chatGPTWindow,
  fallbackResetCreditID,
  jwtExpiration,
  quotaFromUnknown,
  miniMaxWindow,
  zaiWindow,
};
