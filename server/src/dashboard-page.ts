const DASHBOARD_SCRIPT = String.raw`
(() => {
  "use strict";

  const AUTO_REFRESH_MS = 60_000;
  const els = {
    html: document.documentElement,
    locked: document.querySelector("#locked-view"),
    dashboard: document.querySelector("#dashboard-view"),
    unlockForm: document.querySelector("#unlock-form"),
    keyInput: document.querySelector("#server-key"),
    unlockButton: document.querySelector("#unlock-button"),
    passkeyButton: document.querySelector("#passkey-button"),
    passkeyDivider: document.querySelector("#passkey-divider"),
    unlockStatus: document.querySelector("#unlock-status"),
    sessionControls: document.querySelector("#session-controls"),
    logoutButton: document.querySelector("#logout-button"),
    refreshButton: document.querySelector("#refresh-button"),
    autoButton: document.querySelector("#auto-button"),
    autoStatus: document.querySelector("#auto-status"),
    connectionStatus: document.querySelector("#connection-status"),
    generatedAt: document.querySelector("#generated-at"),
    globalNotice: document.querySelector("#global-notice"),
    overviewAccounts: document.querySelector("#overview-accounts"),
    overviewHealthy: document.querySelector("#overview-healthy"),
    overviewAttention: document.querySelector("#overview-attention"),
    overviewDevices: document.querySelector("#overview-devices"),
    nearestReset: document.querySelector("#nearest-reset"),
    lastSuccess: document.querySelector("#last-success"),
    accountsHeadingCount: document.querySelector("#accounts-heading-count"),
    accountsGrid: document.querySelector("#accounts-grid"),
    accountsEmpty: document.querySelector("#accounts-empty"),
    devicesSummary: document.querySelector("#devices-summary"),
    devicesPanel: document.querySelector("#devices-panel"),
    devicesHeadingCount: document.querySelector("#devices-heading-count"),
    devicesStatus: document.querySelector("#devices-status"),
    devicesEmpty: document.querySelector("#devices-empty"),
    devicesList: document.querySelector("#devices-list"),
    overviewDevicesDetail: document.querySelector("#overview-devices-detail"),
    runsSummary: document.querySelector("#runs-summary"),
    historyPanel: document.querySelector("#history-panel"),
    historyTitle: document.querySelector("#history-title"),
    historyMeta: document.querySelector("#history-meta"),
    historyStatus: document.querySelector("#history-status"),
    historyCanvas: document.querySelector("#history-canvas"),
    historyLegend: document.querySelector("#history-legend"),
    historySummary: document.querySelector("#history-summary"),
    historyClose: document.querySelector("#history-close"),
    rangeButtons: Array.from(document.querySelectorAll("[data-history-range]")),
    linkButton: document.querySelector("#link-button"),
    linkStatus: document.querySelector("#link-status"),
    linkResult: document.querySelector("#link-result"),
    qrCode: document.querySelector("#qr-code"),
    linkExpiry: document.querySelector("#link-expiry"),
    openLink: document.querySelector("#open-link"),
    passkeySettings: document.querySelector("#passkey-settings"),
    passkeyCount: document.querySelector("#passkey-count"),
    passkeySummary: document.querySelector("#passkey-summary"),
    passkeyStatus: document.querySelector("#passkey-status"),
    addPasskeyButton: document.querySelector("#add-passkey-button"),
    removePasskeysButton: document.querySelector("#remove-passkeys-button"),
    verifyPanel: document.querySelector("#verify-panel"),
    verifyForm: document.querySelector("#verify-form"),
    verifyInput: document.querySelector("#verify-key"),
    verifyButton: document.querySelector("#verify-button"),
    verifyReason: document.querySelector("#verify-reason"),
    verifyStatus: document.querySelector("#verify-status"),
    themeButton: document.querySelector("#theme-button"),
    toast: document.querySelector("#toast"),
  };

  const state = {
    authenticated: false,
    dashboardLoading: false,
    autoRefresh: true,
    nextRefreshAt: 0,
    refreshTimer: 0,
    countdowns: [],
    dashboardPayload: null,
    dashboardController: null,
    accountDeleteController: null,
    devicesController: null,
    deviceActionController: null,
    devicesPayload: null,
    devicesLoaded: false,
    canManage: false,
    verifyReturnFocus: null,
    viewEpoch: 0,
    selectedAccount: null,
    historyReturnFocus: null,
    selectedRange: "24h",
    historyPayload: null,
    historyController: null,
    linkController: null,
    linkExpiresAt: null,
    authMethodsController: null,
    passkeySettingsController: null,
    passkeyOperationController: null,
    passkeyEnabled: false,
    passkeyCount: 0,
    passkeyCanManage: false,
    passkeySettingsLoaded: false,
    theme: "auto",
    toastTimer: 0,
  };

  function isObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
  }

  function stringValue(value, fallback) {
    return typeof value === "string" && value.trim() ? value.trim() : fallback;
  }

  function numberValue(value) {
    return typeof value === "number" && Number.isFinite(value) ? value : null;
  }

  function integerValue(value) {
    const number = numberValue(value);
    return number === null ? null : Math.max(0, Math.trunc(number));
  }

  function arrayValue(value) {
    return Array.isArray(value) ? value : [];
  }

  function clampPercent(value) {
    const number = numberValue(value);
    return number === null ? null : Math.max(0, Math.min(100, number));
  }

  function setText(element, value) {
    if (element) element.textContent = value;
  }

  function setConnection(label, tone) {
    setText(els.connectionStatus, label);
    els.connectionStatus.classList.toggle("is-live", tone === "live");
    els.connectionStatus.classList.toggle("is-busy", tone === "busy");
    els.connectionStatus.classList.toggle("is-bad", tone === "bad");
  }

  function clear(element) {
    if (element) element.replaceChildren();
  }

  function formatInteger(value) {
    const number = integerValue(value);
    return number === null ? "—" : new Intl.NumberFormat().format(number);
  }

  function timestampMilliseconds(value) {
    const number = numberValue(value);
    if (number === null || number <= 0) return null;
    return number > 10_000_000_000 ? number : number * 1000;
  }

  function formatDateTime(value) {
    const milliseconds = timestampMilliseconds(value);
    if (milliseconds === null) return "Not reported";
    try {
      return new Intl.DateTimeFormat(undefined, {
        dateStyle: "medium",
        timeStyle: "short",
      }).format(new Date(milliseconds));
    } catch (_) {
      return "Not reported";
    }
  }

  function formatRelative(value) {
    const milliseconds = timestampMilliseconds(value);
    if (milliseconds === null) return "Not yet";
    const seconds = Math.round((milliseconds - Date.now()) / 1000);
    const absolute = Math.abs(seconds);
    let amount;
    let unit;
    if (absolute < 60) {
      amount = seconds;
      unit = "second";
    } else if (absolute < 3600) {
      amount = Math.round(seconds / 60);
      unit = "minute";
    } else if (absolute < 86_400) {
      amount = Math.round(seconds / 3600);
      unit = "hour";
    } else {
      amount = Math.round(seconds / 86_400);
      unit = "day";
    }
    try {
      return new Intl.RelativeTimeFormat(undefined, { numeric: "auto" }).format(amount, unit);
    } catch (_) {
      return formatDateTime(value);
    }
  }

  function formatDuration(secondsValue) {
    const seconds = integerValue(secondsValue);
    if (seconds === null) return "Not reported";
    if (seconds < 3600) return Math.max(1, Math.round(seconds / 60)) + " min";
    if (seconds < 86_400) return Math.max(1, Math.round(seconds / 3600)) + " hr";
    return Math.max(1, Math.round(seconds / 86_400)) + " days";
  }

  function countdownText(value) {
    const milliseconds = timestampMilliseconds(value);
    if (milliseconds === null) return "Reset not reported";
    const seconds = Math.max(0, Math.floor((milliseconds - Date.now()) / 1000));
    if (seconds === 0) return "Reset due now";
    const days = Math.floor(seconds / 86_400);
    const hours = Math.floor((seconds % 86_400) / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    if (days > 0) return "Resets in " + days + "d " + hours + "h";
    if (hours > 0) return "Resets in " + hours + "h " + minutes + "m";
    return "Resets in " + Math.max(1, minutes) + "m";
  }

  function addCountdown(element, value, prefix) {
    const milliseconds = timestampMilliseconds(value);
    if (milliseconds === null) {
      setText(element, prefix || "Reset not reported");
      return;
    }
    state.countdowns.push({ element: element, timestamp: milliseconds, prefix: prefix || "" });
    updateCountdown({ element: element, timestamp: milliseconds, prefix: prefix || "" });
  }

  function updateCountdown(item) {
    const base = countdownText(item.timestamp);
    setText(item.element, item.prefix ? item.prefix + base.toLowerCase() : base);
  }

  function updateAllCountdowns() {
    state.countdowns = state.countdowns.filter((item) => item.element.isConnected);
    state.countdowns.forEach(updateCountdown);
    if (state.authenticated && state.autoRefresh && state.nextRefreshAt > 0) {
      const seconds = Math.max(0, Math.ceil((state.nextRefreshAt - Date.now()) / 1000));
      setText(els.autoStatus, seconds === 0 ? "Refreshing…" : "Next refresh in " + seconds + "s");
      if (seconds === 0 && !state.dashboardLoading && document.visibilityState === "visible") {
        void loadDashboard(false);
      }
    } else if (state.authenticated) {
      setText(els.autoStatus, state.autoRefresh ? "Refreshes when this tab is active" : "Auto-refresh paused");
    }
    if (state.linkExpiresAt !== null) updateLinkExpiry();
  }

  function formatPercent(value) {
    const number = clampPercent(value);
    if (number === null) return "Not reported";
    return new Intl.NumberFormat(undefined, { maximumFractionDigits: 1 }).format(number) + "%";
  }

  function formatAmount(value, balance) {
    const number = numberValue(value);
    if (number === null) return "Not reported";
    const currency = stringValue(balance.currency_code, "");
    if (currency) {
      try {
        return new Intl.NumberFormat(undefined, {
          style: "currency",
          currency: currency.toUpperCase(),
          maximumFractionDigits: 2,
        }).format(number);
      } catch (_) {
        return new Intl.NumberFormat(undefined, { maximumFractionDigits: 2 }).format(number) + " " + currency;
      }
    }
    const unit = stringValue(balance.unit_label, "");
    return new Intl.NumberFormat(undefined, { maximumFractionDigits: 2 }).format(number) + (unit ? " " + unit : "");
  }

  function element(tag, className, textValue) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (textValue !== undefined) node.textContent = textValue;
    return node;
  }

  function labelledValue(label, value) {
    const wrapper = element("div", "labelled-value");
    wrapper.append(element("span", "labelled-value__label", label));
    wrapper.append(element("span", "labelled-value__value", value));
    return wrapper;
  }

  function statusLabel(status) {
    const labels = {
      active: "Active",
      stale: "Stale",
      expired: "Sign-in expired",
      error: "Provider error",
      unchecked: "Not checked",
    };
    return labels[status] || labels.unchecked;
  }

  function accountStatusLabel(status, source) {
    if (source === "device") {
      if (status === "active") return "Current";
      if (status === "stale") return "Stale upload";
      if (status === "unchecked") return "Waiting for upload";
    }
    return statusLabel(status);
  }

  function normalizeStatus(value) {
    return ["active", "stale", "expired", "error", "unchecked"].includes(value)
      ? value
      : "unchecked";
  }

  function showToast(message) {
    window.clearTimeout(state.toastTimer);
    setText(els.toast, message);
    els.toast.hidden = false;
    state.toastTimer = window.setTimeout(() => {
      els.toast.hidden = true;
    }, 4500);
  }

  async function readJSON(response) {
    const contentType = response.headers.get("content-type") || "";
    if (!contentType.toLowerCase().includes("application/json")) throw new Error("invalid_response");
    return response.json();
  }

  function supportsWebAuthn() {
    return window.isSecureContext
      && typeof window.PublicKeyCredential === "function"
      && navigator.credentials
      && typeof navigator.credentials.get === "function"
      && typeof navigator.credentials.create === "function";
  }

  function base64URLToBuffer(value) {
    if (typeof value !== "string" || !value || !/^[A-Za-z0-9_-]+$/.test(value)) {
      throw new Error("invalid_base64url");
    }
    const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
    const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
    const binary = window.atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
    return bytes.buffer;
  }

  function bufferToBase64URL(value) {
    let bytes;
    if (value instanceof ArrayBuffer) {
      bytes = new Uint8Array(value);
    } else if (ArrayBuffer.isView(value)) {
      bytes = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    } else {
      throw new Error("invalid_buffer");
    }
    let binary = "";
    for (let offset = 0; offset < bytes.length; offset += 0x8000) {
      binary += String.fromCharCode.apply(null, bytes.subarray(offset, offset + 0x8000));
    }
    return window.btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
  }

  function jsonSafeWebAuthnValue(value) {
    if (value instanceof ArrayBuffer || ArrayBuffer.isView(value)) return bufferToBase64URL(value);
    if (Array.isArray(value)) return value.map(jsonSafeWebAuthnValue);
    if (isObject(value)) {
      const safe = {};
      Object.keys(value).forEach((key) => {
        const item = jsonSafeWebAuthnValue(value[key]);
        if (item !== undefined) safe[key] = item;
      });
      return safe;
    }
    if (value === null || ["string", "number", "boolean"].includes(typeof value)) return value;
    return undefined;
  }

  function parseAuthenticationOptions(options) {
    if (!isObject(options)) throw new Error("invalid_options");
    if (typeof PublicKeyCredential.parseRequestOptionsFromJSON === "function") {
      return PublicKeyCredential.parseRequestOptionsFromJSON(options);
    }
    const publicKey = { ...options, challenge: base64URLToBuffer(options.challenge) };
    if (options.allowCredentials !== undefined) {
      if (!Array.isArray(options.allowCredentials)) throw new Error("invalid_options");
      publicKey.allowCredentials = options.allowCredentials.map((credential) => {
        if (!isObject(credential)) throw new Error("invalid_options");
        return { ...credential, id: base64URLToBuffer(credential.id) };
      });
    }
    return publicKey;
  }

  function parseRegistrationOptions(options) {
    if (!isObject(options) || !isObject(options.user)) throw new Error("invalid_options");
    if (typeof PublicKeyCredential.parseCreationOptionsFromJSON === "function") {
      return PublicKeyCredential.parseCreationOptionsFromJSON(options);
    }
    const publicKey = {
      ...options,
      challenge: base64URLToBuffer(options.challenge),
      user: { ...options.user, id: base64URLToBuffer(options.user.id) },
    };
    if (options.excludeCredentials !== undefined) {
      if (!Array.isArray(options.excludeCredentials)) throw new Error("invalid_options");
      publicKey.excludeCredentials = options.excludeCredentials.map((credential) => {
        if (!isObject(credential)) throw new Error("invalid_options");
        return { ...credential, id: base64URLToBuffer(credential.id) };
      });
    }
    return publicKey;
  }

  function serializePublicKeyCredential(credential, operation) {
    if (!credential || typeof credential !== "object" || !credential.response) {
      throw new Error("invalid_credential");
    }
    if (typeof credential.toJSON === "function") {
      const serialized = credential.toJSON();
      if (isObject(serialized)) {
        const normalized = jsonSafeWebAuthnValue(serialized);
        if (isObject(normalized)) {
          if (!["platform", "cross-platform"].includes(normalized.authenticatorAttachment)) {
            delete normalized.authenticatorAttachment;
          }
          return normalized;
        }
      }
    }
    const response = {
      clientDataJSON: bufferToBase64URL(credential.response.clientDataJSON),
    };
    if (operation === "authentication") {
      response.authenticatorData = bufferToBase64URL(credential.response.authenticatorData);
      response.signature = bufferToBase64URL(credential.response.signature);
      response.userHandle = credential.response.userHandle === null
        ? null
        : bufferToBase64URL(credential.response.userHandle);
    } else {
      response.attestationObject = bufferToBase64URL(credential.response.attestationObject);
      response.transports = typeof credential.response.getTransports === "function"
        ? credential.response.getTransports()
        : [];
      if (typeof credential.response.getAuthenticatorData === "function") {
        const authenticatorData = credential.response.getAuthenticatorData();
        if (authenticatorData) response.authenticatorData = bufferToBase64URL(authenticatorData);
      }
      if (typeof credential.response.getPublicKey === "function") {
        const publicKey = credential.response.getPublicKey();
        if (publicKey) response.publicKey = bufferToBase64URL(publicKey);
      }
      if (typeof credential.response.getPublicKeyAlgorithm === "function") {
        response.publicKeyAlgorithm = credential.response.getPublicKeyAlgorithm();
      }
    }
    const serialized = {
      id: stringValue(credential.id, ""),
      rawId: bufferToBase64URL(credential.rawId),
      response: response,
      type: stringValue(credential.type, "public-key"),
      clientExtensionResults: jsonSafeWebAuthnValue(
        typeof credential.getClientExtensionResults === "function"
          ? credential.getClientExtensionResults()
          : {}
      ),
    };
    if (["platform", "cross-platform"].includes(credential.authenticatorAttachment)) {
      serialized.authenticatorAttachment = credential.authenticatorAttachment;
    }
    return serialized;
  }

  function webAuthnErrorMessage(error, action) {
    if (error instanceof DOMException && error.name === "NotAllowedError") {
      return action === "registration"
        ? "Passkey setup was cancelled or timed out. No passkey was added."
        : "Passkey sign-in was cancelled or timed out. Try again when you’re ready.";
    }
    if (error instanceof DOMException && error.name === "InvalidStateError") {
      return "That passkey is already registered for this dashboard.";
    }
    return action === "registration"
      ? "Couldn’t add a passkey. Nothing was saved; try again."
      : "That passkey could not open this dashboard. Use another passkey or the recovery access key.";
  }

  function clearSensitiveView() {
    clear(els.accountsGrid);
    clear(els.devicesSummary);
    clear(els.devicesList);
    clear(els.runsSummary);
    clear(els.historyLegend);
    clear(els.qrCode);
    clearCanvas();
    setText(els.historyTitle, "Account history");
    setText(els.historyMeta, "Provider · Plan");
    setText(els.historyStatus, "Choose a range.");
    setText(els.historySummary, "");
    setText(els.overviewAccounts, "—");
    setText(els.overviewHealthy, "—");
    setText(els.overviewAttention, "—");
    setText(els.overviewDevices, "—");
    setText(els.lastSuccess, "Not reported");
    setText(els.nearestReset, "Reset not reported");
    setText(els.accountsHeadingCount, "0");
    setText(els.devicesHeadingCount, "0");
    setText(els.devicesStatus, "Loading linked devices…");
    setText(els.overviewDevicesDetail, "Managed below by short label");
    els.devicesEmpty.hidden = true;
    els.accountsEmpty.hidden = true;
    els.globalNotice.hidden = true;
    els.historyPanel.hidden = true;
    els.linkResult.hidden = true;
    els.openLink.removeAttribute("href");
    state.passkeySettingsLoaded = false;
    state.passkeyCount = 0;
    state.passkeyCanManage = false;
    state.devicesPayload = null;
    state.devicesLoaded = false;
    state.canManage = false;
    hideVerifyPanel();
    setText(els.passkeyCount, "—");
    setText(els.passkeySummary, "Passkey settings are available after the dashboard loads.");
    setText(els.passkeyStatus, "");
    els.addPasskeyButton.disabled = true;
    els.removePasskeysButton.disabled = true;
  }

  function showLocked(message, focusInput) {
    state.viewEpoch += 1;
    if (state.dashboardController) state.dashboardController.abort();
    state.dashboardController = null;
    state.dashboardLoading = false;
    els.refreshButton.disabled = false;
    state.authenticated = false;
    state.nextRefreshAt = 0;
    state.countdowns = [];
    state.dashboardPayload = null;
    state.selectedAccount = null;
    state.historyReturnFocus = null;
    state.historyPayload = null;
    state.linkExpiresAt = null;
    if (state.historyController) state.historyController.abort();
    state.historyController = null;
    if (state.linkController) state.linkController.abort();
    state.linkController = null;
    if (state.passkeySettingsController) state.passkeySettingsController.abort();
    state.passkeySettingsController = null;
    if (state.passkeyOperationController) state.passkeyOperationController.abort();
    state.passkeyOperationController = null;
    if (state.accountDeleteController) state.accountDeleteController.abort();
    state.accountDeleteController = null;
    if (state.devicesController) state.devicesController.abort();
    state.devicesController = null;
    if (state.deviceActionController) state.deviceActionController.abort();
    state.deviceActionController = null;
    els.linkButton.disabled = false;
    els.unlockButton.disabled = false;
    els.passkeyButton.disabled = false;
    els.verifyButton.disabled = false;
    clearSensitiveView();
    els.dashboard.hidden = true;
    els.sessionControls.hidden = true;
    els.logoutButton.hidden = true;
    els.locked.hidden = false;
    els.keyInput.value = "";
    setConnection("Locked", "idle");
    setText(els.unlockStatus, message || "Use a passkey or enter the recovery access key to continue.");
    if (focusInput) els.keyInput.focus();
  }

  function showDashboard() {
    state.authenticated = true;
    els.locked.hidden = true;
    els.dashboard.hidden = false;
    els.sessionControls.hidden = false;
    els.logoutButton.hidden = false;
    setConnection("Private session", "busy");
  }

  function handleUnauthorized(message) {
    showLocked(message || "Your private session ended. Use a passkey or the recovery access key again.", true);
  }

  async function loadAuthMethods() {
    const epoch = state.viewEpoch;
    const controller = new AbortController();
    if (state.authMethodsController) state.authMethodsController.abort();
    state.authMethodsController = controller;
    try {
      const response = await fetch("/v1/dashboard/auth-methods", {
        method: "GET",
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error",
        headers: { Accept: "application/json" },
        signal: controller.signal,
      });
      if (!response.ok) throw new Error("auth_methods_failed");
      const payload = await readJSON(response);
      if (controller.signal.aborted || epoch !== state.viewEpoch || !isObject(payload)) return;
      state.passkeyEnabled = payload.passkey_enabled === true;
    } catch (_) {
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      state.passkeyEnabled = false;
    } finally {
      if (state.authMethodsController === controller) state.authMethodsController = null;
      const available = state.passkeyEnabled && supportsWebAuthn();
      els.passkeyButton.hidden = !available;
      els.passkeyDivider.hidden = !available;
      if (state.passkeyEnabled && !supportsWebAuthn()) {
        setText(els.unlockStatus, window.isSecureContext
          ? "Passkeys are not available in this browser. You can still use the recovery access key."
          : "Passkeys require a secure HTTPS connection. You can still use the recovery access key.");
      }
    }
  }

  async function authenticateWithPasskey() {
    if (!supportsWebAuthn() || !state.passkeyEnabled) return;
    const epoch = state.viewEpoch;
    const controller = new AbortController();
    if (state.passkeyOperationController) state.passkeyOperationController.abort();
    state.passkeyOperationController = controller;
    els.passkeyButton.disabled = true;
    els.unlockButton.disabled = true;
    setText(els.unlockStatus, "Waiting for your passkey…");
    try {
      const optionsResponse = await fetch("/v1/dashboard/passkeys/authentication/options", {
        method: "POST",
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error",
        headers: { Accept: "application/json" },
        signal: controller.signal,
      });
      if (!optionsResponse.ok) throw new Error("options_failed");
      const envelope = await readJSON(optionsResponse);
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      const transactionID = isObject(envelope) ? stringValue(envelope.transaction_id, "") : "";
      if (!transactionID || !isObject(envelope.options)) throw new Error("invalid_options");
      const credential = await navigator.credentials.get({
        publicKey: parseAuthenticationOptions(envelope.options),
        signal: controller.signal,
      });
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      const verifyResponse = await fetch("/v1/dashboard/passkeys/authentication/verify", {
        method: "POST",
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          transaction_id: transactionID,
          credential: serializePublicKeyCredential(credential, "authentication"),
        }),
        signal: controller.signal,
      });
      if (verifyResponse.status !== 204) throw new Error("verify_failed");
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      state.viewEpoch += 1;
      state.authenticated = true;
      await loadDashboard(true);
      if (state.dashboardPayload) els.refreshButton.focus();
    } catch (error) {
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      setText(els.unlockStatus, webAuthnErrorMessage(error, "authentication"));
      els.passkeyButton.focus();
    } finally {
      if (state.passkeyOperationController === controller) {
        state.passkeyOperationController = null;
        els.passkeyButton.disabled = false;
        els.unlockButton.disabled = false;
      }
    }
  }

  async function authenticate(event) {
    event.preventDefault();
    let key = els.keyInput.value;
    els.keyInput.value = "";
    if (!key || key.length < 32) {
      key = "";
      setText(els.unlockStatus, "That access key could not be verified.");
      els.keyInput.focus();
      return;
    }
    const epoch = state.viewEpoch;
    const controller = new AbortController();
    if (state.passkeyOperationController) state.passkeyOperationController.abort();
    state.passkeyOperationController = controller;
    els.unlockButton.disabled = true;
    els.passkeyButton.disabled = true;
    setText(els.unlockStatus, "Opening a private session…");
    try {
      const loginRequest = new Request("/v1/dashboard/session", {
        method: "POST",
        headers: { "X-When-Reset-Server-Key": key },
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error",
        signal: controller.signal,
      });
      key = "";
      const response = await fetch(loginRequest);
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      if (!response.ok) throw new Error("unauthorized");
      state.viewEpoch += 1;
      if (state.dashboardController) state.dashboardController.abort();
      state.dashboardController = null;
      state.dashboardLoading = false;
      state.authenticated = true;
      await loadDashboard(true);
      if (state.dashboardPayload) els.refreshButton.focus();
    } catch (_) {
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      showLocked("That access key could not be verified. Check it and try again.", true);
    } finally {
      key = "";
      els.keyInput.value = "";
      if (state.passkeyOperationController === controller) {
        state.passkeyOperationController = null;
        els.unlockButton.disabled = false;
        els.passkeyButton.disabled = false;
      }
    }
  }

  async function logout() {
    if (state.passkeyOperationController) state.passkeyOperationController.abort();
    state.passkeyOperationController = null;
    if (state.accountDeleteController) state.accountDeleteController.abort();
    state.accountDeleteController = null;
    if (state.passkeySettingsLoaded) renderPasskeySettings();
    els.logoutButton.disabled = true;
    try {
      const response = await fetch("/v1/dashboard/session", {
        method: "DELETE",
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error",
      });
      if (response.status !== 204) throw new Error("logout_failed");
      showLocked("Signed out. No account data remains on this page.", true);
    } catch (_) {
      showToast("Couldn’t sign out. Your private session is still active; check the connection and try again.");
      setConnection("Sign-out failed", "bad");
    } finally {
      els.logoutButton.disabled = false;
    }
  }

  async function loadDashboard(announce) {
    if (state.dashboardLoading) return;
    const epoch = state.viewEpoch;
    const controller = new AbortController();
    state.dashboardController = controller;
    state.dashboardLoading = true;
    els.refreshButton.disabled = true;
    setConnection(state.dashboardPayload ? "Refreshing…" : "Loading…", "busy");
    try {
      const response = await fetch("/v1/dashboard", {
        method: "GET",
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error",
        headers: { Accept: "application/json" },
        signal: controller.signal,
      });
      if (epoch !== state.viewEpoch) return;
      if (response.status === 401) {
        handleUnauthorized(
          state.authenticated || state.dashboardPayload
            ? "Your private session ended. Use a passkey or the recovery access key again."
            : "Use a passkey or the recovery access key to continue."
        );
        return;
      }
      if (!response.ok) throw new Error("dashboard_failed");
      const payload = await readJSON(response);
      if (epoch !== state.viewEpoch) return;
      if (!isObject(payload) || payload.version !== 1 || !Array.isArray(payload.accounts)) {
        throw new Error("invalid_dashboard");
      }
      state.dashboardPayload = payload;
      showDashboard();
      renderDashboard(payload);
      if (!state.passkeySettingsLoaded) void loadPasskeySettings();
      void loadDevices();
      state.nextRefreshAt = Date.now() + AUTO_REFRESH_MS;
      setConnection("Live", "live");
      if (announce) showToast("Dashboard is up to date.");
    } catch (_) {
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      if (state.dashboardPayload) {
        setConnection("Refresh failed", "bad");
        state.nextRefreshAt = Date.now() + AUTO_REFRESH_MS;
        showToast("Couldn’t refresh monitoring data. The last successful view is still shown.");
      } else if (state.authenticated) {
        showDashboard();
        els.globalNotice.hidden = false;
        setText(els.globalNotice, "Your private session is active, but monitoring data could not be loaded. Select Refresh to try again.");
        setConnection("Load failed", "bad");
        state.nextRefreshAt = Date.now() + AUTO_REFRESH_MS;
        els.refreshButton.focus();
      } else {
        showLocked("Couldn’t reach the private dashboard. Try again.", false);
      }
    } finally {
      if (state.dashboardController === controller) {
        state.dashboardController = null;
        state.dashboardLoading = false;
        els.refreshButton.disabled = false;
      }
    }
  }

  function renderDashboard(payload) {
    state.countdowns = state.countdowns.filter((item) => item.element.closest("#link-result"));
    const summary = isObject(payload.summary) ? payload.summary : {};
    const devices = isObject(payload.devices) ? payload.devices : {};
    const runs = isObject(payload.runs) ? payload.runs : {};
    const accounts = arrayValue(payload.accounts).filter(isObject);

    setText(els.generatedAt, "Updated " + formatRelative(payload.generated_at));
    setText(els.overviewAccounts, formatInteger(summary.accounts));
    setText(els.overviewHealthy, formatInteger(summary.healthy));
    setText(els.overviewAttention, formatInteger(summary.attention));
    setText(els.overviewDevices, formatInteger(devices.total));
    setText(els.lastSuccess, formatDateTime(summary.last_success_at));
    addCountdown(els.nearestReset, summary.nearest_reset_at, "Nearest quota ");
    setText(els.accountsHeadingCount, formatInteger(accounts.length));

    if (summary.truncated === true) {
      els.globalNotice.hidden = false;
      const total = integerValue(summary.accounts);
      const shown = integerValue(summary.shown_accounts);
      setText(
        els.globalNotice,
        total !== null && shown !== null
          ? "Monitoring data is bounded for safety. Showing " + formatInteger(shown) + " account cards from " + formatInteger(total) + " grouped accounts in this response."
          : "Monitoring data is bounded for safety; this response may be partial."
      );
    } else {
      els.globalNotice.hidden = true;
      setText(els.globalNotice, "");
    }

    renderDevices(devices);
    renderRuns(runs);
    renderAccounts(accounts, devices);
  }

  function renderPasskeySettings() {
    setText(els.passkeyCount, formatInteger(state.passkeyCount));
    setText(
      els.passkeySummary,
      state.passkeyCount === 1
        ? "One passkey can open this dashboard."
        : state.passkeyCount > 1
          ? state.passkeyCount + " passkeys can open this dashboard."
          : "No passkeys are registered. Add one from this authenticated dashboard session."
    );
    // A live dashboard session is sufficient for passkey management. The recovery key remains
    // the fallback login method, not a second prompt before enrolling another device.
    els.addPasskeyButton.disabled = !supportsWebAuthn();
    els.removePasskeysButton.disabled = state.passkeyCount < 1;
    if (!supportsWebAuthn() && !els.passkeyStatus.textContent) {
      setText(els.passkeyStatus, window.isSecureContext
        ? "This browser cannot create passkeys. The recovery access key remains available."
        : "Passkeys require a secure HTTPS connection. The recovery access key remains available.");
    } else if (!els.passkeyStatus.textContent) {
      setText(els.passkeyStatus, "This authenticated session can manage passkeys.");
    }
  }

  async function loadPasskeySettings() {
    const epoch = state.viewEpoch;
    const controller = new AbortController();
    if (state.passkeySettingsController) state.passkeySettingsController.abort();
    state.passkeySettingsController = controller;
    try {
      const response = await fetch("/v1/dashboard/passkeys", {
        method: "GET",
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error",
        headers: { Accept: "application/json" },
        signal: controller.signal,
      });
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      if (response.status === 401) {
        handleUnauthorized("Your private session ended. Use a passkey or the recovery access key again.");
        return;
      }
      if (!response.ok) throw new Error("passkey_settings_failed");
      const payload = await readJSON(response);
      if (controller.signal.aborted || epoch !== state.viewEpoch || !isObject(payload)) return;
      state.passkeyCount = integerValue(payload.count) ?? 0;
      state.passkeyCanManage = payload.can_manage === true;
      state.passkeySettingsLoaded = true;
      renderPasskeySettings();
    } catch (_) {
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      setText(els.passkeySummary, "Passkey settings could not be loaded.");
      setText(els.passkeyStatus, "Refresh the dashboard and try again.");
    } finally {
      if (state.passkeySettingsController === controller) state.passkeySettingsController = null;
    }
  }

  function showVerifyPanel(reason, focus) {
    setText(els.verifyReason, reason || "This action needs the recovery access key for this Worker. The key is exchanged for a short grant and is never stored by this page.");
    els.verifyPanel.hidden = false;
    if (focus !== false) {
      els.verifyPanel.scrollIntoView({
        behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth",
        block: "center",
      });
      els.verifyInput.focus({ preventScroll: true });
    }
  }

  function hideVerifyPanel() {
    els.verifyPanel.hidden = true;
    els.verifyInput.value = "";
    setText(els.verifyStatus, "");
  }

  // Every destructive dashboard action funnels through the same step-up so the recovery key
  // prompt appears in one predictable place instead of inside an unrelated settings card.
  function requireAccessKeyVerification(reason) {
    state.canManage = false;
    if (state.devicesLoaded) renderDeviceList();
    showVerifyPanel(reason, true);
  }

  async function verifyAccessKey(event) {
    event.preventDefault();
    let key = els.verifyInput.value;
    els.verifyInput.value = "";
    if (!key || key.length < 32) {
      key = "";
      setText(els.verifyStatus, "That recovery access key could not be verified.");
      els.verifyInput.focus();
      return;
    }
    const epoch = state.viewEpoch;
    const controller = new AbortController();
    if (state.passkeyOperationController) state.passkeyOperationController.abort();
    state.passkeyOperationController = controller;
    els.verifyButton.disabled = true;
    setText(els.verifyStatus, "Verifying the recovery access key…");
    try {
      const request = new Request("/v1/dashboard/passkeys/reverify", {
        method: "POST",
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error",
        headers: { "X-When-Reset-Server-Key": key },
        signal: controller.signal,
      });
      key = "";
      const response = await fetch(request);
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      if (response.status === 401) {
        handleUnauthorized("Your private session ended. Use a passkey or the recovery access key again.");
        return;
      }
      if (response.status !== 204) throw new Error("reverify_failed");
      state.passkeyCanManage = true;
      state.canManage = true;
      const returnFocus = state.verifyReturnFocus;
      state.verifyReturnFocus = null;
      hideVerifyPanel();
      showToast("Recovery access confirmed.");
      if (state.devicesLoaded) renderDeviceList();
      if (returnFocus && returnFocus.isConnected) returnFocus.focus();
    } catch (_) {
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      setText(els.verifyStatus, "That recovery access key could not be verified.");
      els.verifyInput.focus();
    } finally {
      key = "";
      els.verifyInput.value = "";
      if (state.passkeyOperationController === controller) state.passkeyOperationController = null;
      els.verifyButton.disabled = false;
    }
  }

  async function addPasskey() {
    if (!supportsWebAuthn()) {
      setText(els.passkeyStatus, "Passkeys are not available in this browser or connection.");
      return;
    }
    const epoch = state.viewEpoch;
    const controller = new AbortController();
    if (state.passkeyOperationController) state.passkeyOperationController.abort();
    state.passkeyOperationController = controller;
    els.addPasskeyButton.disabled = true;
    els.removePasskeysButton.disabled = true;
    setText(els.passkeyStatus, "Waiting for your device to create a passkey…");
    try {
      const optionsResponse = await fetch("/v1/dashboard/passkeys/registration/options", {
        method: "POST",
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error",
        headers: { Accept: "application/json" },
        signal: controller.signal,
      });
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      if (optionsResponse.status === 403) {
        throw new Error("management_denied");
      }
      if (!optionsResponse.ok) throw new Error("options_failed");
      const envelope = await readJSON(optionsResponse);
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      const transactionID = isObject(envelope) ? stringValue(envelope.transaction_id, "") : "";
      if (!transactionID || !isObject(envelope.options)) throw new Error("invalid_options");
      const credential = await navigator.credentials.create({
        publicKey: parseRegistrationOptions(envelope.options),
        signal: controller.signal,
      });
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      const verifyResponse = await fetch("/v1/dashboard/passkeys/registration/verify", {
        method: "POST",
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          transaction_id: transactionID,
          credential: serializePublicKeyCredential(credential, "registration"),
        }),
        signal: controller.signal,
      });
      if (verifyResponse.status !== 204) throw new Error("verify_failed");
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      state.passkeyCount += 1;
      state.passkeyEnabled = true;
      els.passkeyButton.hidden = !supportsWebAuthn();
      els.passkeyDivider.hidden = !supportsWebAuthn();
      setText(els.passkeyStatus, "Passkey added. Its private key never left your device or passkey provider.");
      renderPasskeySettings();
      showToast("Passkey added.");
      els.addPasskeyButton.focus();
    } catch (error) {
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      setText(els.passkeyStatus, error instanceof Error && error.message === "management_denied"
        ? "This dashboard session can no longer manage passkeys. Sign in again and retry."
        : webAuthnErrorMessage(error, "registration"));
    } finally {
      if (state.passkeyOperationController === controller) {
        state.passkeyOperationController = null;
        renderPasskeySettings();
      }
    }
  }

  async function removeAllPasskeys() {
    if (state.passkeyCount < 1) return;
    if (!window.confirm("Remove every passkey from this dashboard? This blocks dashboard sign-in but does not delete saved copies from iCloud Keychain or another password manager. You will be signed out and need the recovery access key to return.")) return;
    const epoch = state.viewEpoch;
    const controller = new AbortController();
    if (state.passkeyOperationController) state.passkeyOperationController.abort();
    state.passkeyOperationController = controller;
    els.addPasskeyButton.disabled = true;
    els.removePasskeysButton.disabled = true;
    setText(els.passkeyStatus, "Removing passkeys from this dashboard…");
    try {
      const response = await fetch("/v1/dashboard/passkeys", {
        method: "DELETE",
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error",
        signal: controller.signal,
      });
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      if (response.status === 403) {
        throw new Error("management_denied");
      }
      if (response.status !== 204) throw new Error("delete_failed");
      state.passkeyCount = 0;
      state.passkeyEnabled = false;
      els.passkeyButton.hidden = true;
      els.passkeyDivider.hidden = true;
      try {
        await fetch("/v1/dashboard/session", {
          method: "DELETE",
          credentials: "same-origin",
          cache: "no-store",
          redirect: "error",
          signal: controller.signal,
        });
      } catch (_) {
        // The passkey deletion may already have revoked this session.
      }
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      showLocked("All passkeys were removed from this dashboard. You were signed out; use the recovery access key to return.", true);
      showToast("All dashboard passkeys removed.");
    } catch (error) {
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      setText(els.passkeyStatus, error instanceof Error && error.message === "management_denied"
        ? "This dashboard session can no longer manage passkeys. Sign in again and retry."
        : "Passkeys could not be removed. Nothing changed; try again.");
      renderPasskeySettings();
    } finally {
      if (state.passkeyOperationController === controller) {
        state.passkeyOperationController = null;
        renderPasskeySettings();
      }
    }
  }

  function renderDevices(devices) {
    clear(els.devicesSummary);
    const values = [
      ["Linked", formatInteger(devices.total)],
      ["Active", formatInteger(devices.active)],
      ["Push disabled", formatInteger(devices.push_disabled)],
      ["Production", formatInteger(devices.production)],
      ["Development", formatInteger(devices.development)],
    ];
    values.forEach((entry) => els.devicesSummary.append(labelledValue(entry[0], entry[1])));
    const pushDisabled = integerValue(devices.push_disabled) || 0;
    setText(
      els.overviewDevicesDetail,
      pushDisabled > 0
        ? formatInteger(pushDisabled) + " with push delivery off"
        : "Managed below by short label"
    );
  }

  async function loadDevices() {
    const epoch = state.viewEpoch;
    const controller = new AbortController();
    if (state.devicesController) state.devicesController.abort();
    state.devicesController = controller;
    if (!state.devicesLoaded) setText(els.devicesStatus, "Loading linked devices…");
    try {
      const response = await fetch("/v1/dashboard/devices", {
        method: "GET",
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error",
        headers: { Accept: "application/json" },
        signal: controller.signal,
      });
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      if (response.status === 401) {
        handleUnauthorized("Your private session ended. Use a passkey or the recovery access key again.");
        return;
      }
      if (!response.ok) throw new Error("devices_failed");
      const payload = await readJSON(response);
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      if (!isObject(payload) || !Array.isArray(payload.devices)) throw new Error("invalid_devices");
      state.devicesPayload = payload;
      state.devicesLoaded = true;
      state.canManage = payload.can_manage === true;
      renderDeviceList();
    } catch (_) {
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      if (!state.devicesLoaded) {
        clear(els.devicesList);
        els.devicesEmpty.hidden = true;
      }
      setText(els.devicesStatus, "Linked devices could not be loaded. Select Refresh to try again.");
    } finally {
      if (state.devicesController === controller) state.devicesController = null;
    }
  }

  function deviceStateLabel(device) {
    if (device.push_enabled !== true) return { label: "Push off", tone: "warn" };
    if (device.active !== true) return { label: "Idle", tone: "unchecked" };
    return { label: "Active", tone: "active" };
  }

  function renderDeviceList() {
    const payload = isObject(state.devicesPayload) ? state.devicesPayload : null;
    const devices = payload ? arrayValue(payload.devices).filter(isObject) : [];
    clear(els.devicesList);
    setText(els.devicesHeadingCount, formatInteger(devices.length));
    els.devicesEmpty.hidden = devices.length !== 0;
    if (devices.length === 0) {
      setText(els.devicesStatus, payload ? "No devices are linked to this Worker yet." : "Loading linked devices…");
      return;
    }
    const truncated = payload && payload.truncated === true
      ? " Only the most recently seen devices are listed."
      : "";
    setText(
      els.devicesStatus,
      (state.canManage
        ? "Changes apply immediately."
        : "Verify the recovery access key to disable push or unlink a device.") + truncated
    );
    devices.forEach((device) => els.devicesList.append(renderDeviceRow(device)));
  }

  function renderDeviceRow(device) {
    const row = element("li", "device-row");
    const label = stringValue(device.label, "Device");
    const status = deviceStateLabel(device);
    if (device.retired === true) row.classList.add("is-retired");

    const identity = element("div", "device-identity");
    identity.append(element("span", "device-avatar", label.slice(0, 2)));
    const identityText = element("div", "device-identity__text");
    const name = element("span", "device-name");
    name.append(document.createTextNode("Device " + label));
    const badge = element("span", "status-badge", status.label);
    badge.classList.add("status-badge--" + status.tone);
    name.append(badge);
    identityText.append(name);
    const meta = element("span", "device-meta");
    setText(meta, "Linked " + formatDateTime(device.created_at));
    identityText.append(meta);
    identity.append(identityText);
    row.append(identity);

    const stateColumn = element("div", "device-state");
    stateColumn.append(labelledValue("Last seen", formatRelative(device.last_seen_at)));
    stateColumn.append(labelledValue(
      "Push",
      device.push_enabled === true
        ? (numberValue(device.last_push_at) === null
            ? "On · none sent yet" : "On · last " + formatRelative(device.last_push_at))
        : (numberValue(device.push_disabled_at) === null
            ? "Off" : "Off since " + formatRelative(device.push_disabled_at))
    ));
    row.append(stateColumn);

    const usage = element("div", "device-usage");
    const counts = [
      ["monitored", integerValue(device.monitored_accounts) || 0,
        "account this device asked the Worker to poll"],
      ["published", integerValue(device.published_accounts) || 0,
        "account this device uploads usage for"],
      ["followed", integerValue(device.subscriptions) || 0,
        "account this device follows from another device"],
    ];
    counts.forEach((entry) => {
      const tag = element("span", "device-tag");
      if (entry[1] === 0) tag.classList.add("device-tag--idle");
      setText(tag, formatInteger(entry[1]) + " " + entry[0]);
      tag.title = formatInteger(entry[1]) + " " + entry[2] + (entry[1] === 1 ? "" : "s");
      usage.append(tag);
    });
    const environment = element("span", "device-tag");
    setText(environment, device.environment === "development" ? "Sandbox push" : "Production push");
    usage.append(environment);
    row.append(usage);

    const actions = element("div", "device-actions");
    const pushEnabled = device.push_enabled === true;
    const pushButton = element(
      "button", "button button--quiet button--small", pushEnabled ? "Disable push" : "Enable push"
    );
    pushButton.type = "button";
    pushButton.disabled = !state.canManage;
    pushButton.setAttribute(
      "aria-label",
      (pushEnabled ? "Disable push for device " : "Enable push for device ") + label
    );
    pushButton.addEventListener("click", () => {
      void setDevicePush(device, !pushEnabled, pushButton);
    });
    const unlinkButton = element(
      "button", "button button--quiet button--danger button--small", "Unlink"
    );
    unlinkButton.type = "button";
    unlinkButton.disabled = !state.canManage;
    unlinkButton.setAttribute("aria-label", "Unlink device " + label);
    unlinkButton.addEventListener("click", () => void unlinkDevice(device, unlinkButton));
    actions.append(pushButton, unlinkButton);
    if (!state.canManage) {
      const verifyButton = element("button", "button button--ghost button--small", "Verify to manage");
      verifyButton.type = "button";
      verifyButton.addEventListener("click", () => {
        state.verifyReturnFocus = verifyButton;
        showVerifyPanel(
          "Disabling push or unlinking a device needs the recovery access key for this Worker.",
          true
        );
      });
      actions.append(verifyButton);
    }
    row.append(actions);
    return row;
  }

  function deviceActionFailed(error, fallback) {
    const message = error instanceof Error ? error.message : "";
    if (message === "management_expired") {
      return "Verify the recovery access key, then try again.";
    }
    if (message === "device_not_found") {
      return "That device is no longer linked. The list has been refreshed.";
    }
    return fallback;
  }

  async function runDeviceAction(request, trigger) {
    if (state.deviceActionController) state.deviceActionController.abort();
    const controller = new AbortController();
    state.deviceActionController = controller;
    if (trigger) trigger.disabled = true;
    try {
      const response = await fetch(request.url, {
        method: request.method,
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error",
        headers: request.body === undefined
          ? { Accept: "application/json" }
          : { Accept: "application/json", "Content-Type": "application/json" },
        body: request.body === undefined ? undefined : JSON.stringify(request.body),
        signal: controller.signal,
      });
      if (response.status === 401) {
        handleUnauthorized("Your private session ended. Use a passkey or the recovery access key again.");
        throw new Error("unauthorized");
      }
      if (!response.ok) {
        let body = null;
        try { body = await readJSON(response); } catch (_) { body = null; }
        if (response.status === 403 && isObject(body)
            && body.error === "access_key_verification_required") {
          state.verifyReturnFocus = trigger || null;
          requireAccessKeyVerification(request.verifyReason);
          throw new Error("management_expired");
        }
        throw new Error(isObject(body) && typeof body.error === "string" ? body.error : "device_action_failed");
      }
      return true;
    } finally {
      if (state.deviceActionController === controller) {
        state.deviceActionController = null;
        if (trigger && trigger.isConnected) trigger.disabled = false;
      }
    }
  }

  async function setDevicePush(device, enabled, trigger) {
    const deviceID = stringValue(device.id, "");
    if (!deviceID) return;
    const label = stringValue(device.label, "this device");
    if (!enabled && !window.confirm("Stop sending push notifications to device " + label + "? It stays linked and keeps syncing when the app is open, and you can re-enable delivery here at any time.")) return;
    const epoch = state.viewEpoch;
    setText(els.devicesStatus, enabled ? "Enabling push delivery…" : "Disabling push delivery…");
    try {
      await runDeviceAction({
        url: "/v1/dashboard/devices/" + encodeURIComponent(deviceID),
        method: "PATCH",
        body: { push_enabled: enabled },
        verifyReason: "Changing push delivery for a linked device needs the recovery access key for this Worker.",
      }, trigger);
      if (epoch !== state.viewEpoch) return;
      showToast(enabled ? "Push delivery enabled for device " + label + "." : "Push delivery disabled for device " + label + ".");
      await loadDevices();
      await loadDashboard(false);
    } catch (error) {
      if (epoch !== state.viewEpoch) return;
      setText(els.devicesStatus, deviceActionFailed(
        error, "Push delivery could not be changed. Nothing was modified; try again."
      ));
      if (error instanceof Error && error.message === "device_not_found") await loadDevices();
    }
  }

  async function unlinkDevice(device, trigger) {
    const deviceID = stringValue(device.id, "");
    if (!deviceID) return;
    const label = stringValue(device.label, "this device");
    const monitored = integerValue(device.monitored_accounts) || 0;
    const published = integerValue(device.published_accounts) || 0;
    const attached = monitored + published;
    if (!window.confirm(
      "Unlink device " + label + " from this Worker?"
        + (attached > 0
          ? " Its " + formatInteger(attached) + " attached account" + (attached === 1 ? "" : "s")
            + " and their stored history will be deleted from the Worker."
          : "")
        + " The device keeps its own local data and must scan a new link to reconnect. This cannot be undone."
    )) return;
    const epoch = state.viewEpoch;
    setText(els.devicesStatus, "Unlinking device " + label + "…");
    try {
      await runDeviceAction({
        url: "/v1/dashboard/devices/" + encodeURIComponent(deviceID),
        method: "DELETE",
        verifyReason: "Unlinking a device needs the recovery access key for this Worker.",
      }, trigger);
      if (epoch !== state.viewEpoch) return;
      showToast("Device " + label + " unlinked.");
      await loadDevices();
      await loadDashboard(false);
    } catch (error) {
      if (epoch !== state.viewEpoch) return;
      setText(els.devicesStatus, deviceActionFailed(
        error, "The device could not be unlinked. Nothing was reported as removed; try again."
      ));
      if (error instanceof Error && error.message === "device_not_found") await loadDevices();
    }
  }

  function renderRuns(runs) {
    clear(els.runsSummary);
    const values = [
      ["Pending", formatInteger(runs.pending)],
      ["Running", formatInteger(runs.running)],
      ["Succeeded · 24h", formatInteger(runs.succeeded_24h)],
      ["Failed · 24h", formatInteger(runs.failed_24h)],
      ["Last completed", formatDateTime(runs.last_completed_at)],
    ];
    values.forEach((entry) => els.runsSummary.append(labelledValue(entry[0], entry[1])));
  }

  function renderAccounts(accounts, devices) {
    clear(els.accountsGrid);
    els.accountsEmpty.hidden = accounts.length !== 0;
    if (accounts.length === 0) {
      const deviceCount = integerValue(devices.total) || 0;
      setText(
        els.accountsEmpty.querySelector("p"),
        deviceCount === 0
          ? "Link a device, then opt accounts into server monitoring from When Reset."
          : "No accounts are opted into this Worker yet. Enable server monitoring for an account in When Reset."
      );
      return;
    }
    accounts.forEach((account, index) => els.accountsGrid.append(renderAccountCard(account, index)));
  }

  function renderAccountCard(account, index) {
    const card = element("article", "account-card");
    const status = normalizeStatus(account.status);
    const source = account.source === "device" ? "device" : "worker";
    card.classList.add("status-" + status);

    const heading = element("div", "account-card__heading");
    const providerName = stringValue(
      account.provider_name, stringValue(account.provider_id, "Provider")
    );
    const avatar = element("span", "account-card__avatar", providerName.slice(0, 2));
    avatar.setAttribute("aria-hidden", "true");
    const identity = element("div", "account-card__identity");
    const name = element("h3", "account-card__name");
    name.id = "account-name-" + index;
    setText(name, stringValue(account.display_name, "Unnamed account"));
    const sourceLine = element("p", "account-card__source");
    setText(
      sourceLine,
      providerName + " · " + (source === "device" ? "Device upload" : "Worker polling")
    );
    identity.append(name, sourceLine);
    const badge = element("span", "status-badge", accountStatusLabel(status, source));
    badge.classList.add("status-badge--" + status);
    heading.append(avatar, identity, badge);
    card.append(heading);

    const planLine = element("p", "account-card__plan");
    setText(planLine, stringValue(account.plan, "Plan not reported"));
    card.append(planLine);

    const timing = element("div", "account-card__timing");
    timing.append(
      labelledValue(source === "device" ? "Last upload" : "Last check", formatRelative(account.last_checked_at)),
      labelledValue(source === "device" ? "Last observed" : "Last success", formatRelative(account.last_success_at)),
      labelledValue(source === "device" ? "Expected next" : "Next refresh", formatRelative(account.next_refresh_at)),
      labelledValue("Cadence", formatDuration(account.refresh_interval_seconds))
    );
    card.append(timing);

    const snapshot = isObject(account.snapshot) ? account.snapshot : null;
    const quotas = element("div", "quota-list");
    if (!snapshot) {
      quotas.append(element("p", "empty-inline", "No quota snapshot has been collected yet."));
    } else {
      const windows = arrayValue(snapshot.windows).filter(isObject);
      quotas.append(element("p", "eyebrow quota-eyebrow", "Provider-reported quotas"));
      if (windows.length === 0) {
        quotas.append(element("p", "empty-inline", "This provider did not report a quota window."));
      } else {
        windows.forEach((window, windowIndex) => {
          quotas.append(renderQuota(window, index + "-" + windowIndex));
        });
      }
      renderResetCredits(quotas, snapshot);
      if (isObject(snapshot.api_balance)) quotas.append(renderBalance(snapshot.api_balance));
      const fetched = element("p", "fine-print");
      setText(fetched, "Snapshot collected " + formatRelative(snapshot.fetched_at));
      quotas.append(fetched);
    }
    card.append(quotas);

    const retentionDays = integerValue(account.history_retention_days);
    const expiry = numberValue(account.trial_expires_at) !== null
      ? "Trial ends " + formatDateTime(account.trial_expires_at)
      : numberValue(account.plan_expires_at) !== null
        ? "Plan ends " + formatDateTime(account.plan_expires_at)
        : retentionDays === null ? "Retention not reported" : "Retention " + formatDuration(retentionDays * 86_400);
    const footer = element("div", "account-card__footer");
    const details = element("span", "fine-print");
    const sourceCount = integerValue(account.source_count);
    setText(details, expiry + " · " + (sourceCount === null ? "Source count not reported" : formatInteger(sourceCount) + " source" + (sourceCount === 1 ? "" : "s")));
    const historyButton = element("button", "button button--quiet button--small", "View history");
    historyButton.type = "button";
    historyButton.setAttribute("aria-describedby", name.id);
    historyButton.addEventListener("click", () => openHistory(account, historyButton));
    const actions = element("div", "account-card__actions");
    const keepDataButton = element(
      "button", "button button--quiet button--small", "Remove · keep data"
    );
    keepDataButton.type = "button";
    keepDataButton.setAttribute("aria-label", "Remove " + stringValue(account.display_name, "account") + " but keep its data");
    keepDataButton.addEventListener("click", () => {
      void deleteDashboardAccount(account, "preserve", keepDataButton);
    });
    const deleteDataButton = element(
      "button", "button button--quiet button--small button--danger", "Delete · all data"
    );
    deleteDataButton.type = "button";
    deleteDataButton.setAttribute("aria-label", "Delete " + stringValue(account.display_name, "account") + " and all stored data");
    deleteDataButton.addEventListener("click", () => {
      void deleteDashboardAccount(account, "purge", deleteDataButton);
    });
    actions.append(historyButton, keepDataButton, deleteDataButton);
    footer.append(details, actions);
    card.append(footer);
    return card;
  }

  async function deleteDashboardAccount(account, mode, trigger) {
    if (!state.authenticated || !isObject(account)) return;
    const name = stringValue(account.display_name, "this account");
    const message = mode === "preserve"
      ? "Remove " + name + " from Worker monitoring? Its sanitized quota history will be kept for a future re-add. Provider credentials are deleted from the Worker."
      : "Delete " + name + " and all stored quota history from this Worker? This cannot be undone.";
    if (!window.confirm(message)) return;
    if (state.accountDeleteController) state.accountDeleteController.abort();
    const controller = new AbortController();
    const epoch = state.viewEpoch;
    state.accountDeleteController = controller;
    if (trigger) trigger.disabled = true;
    setText(els.globalNotice, mode === "preserve" ? "Removing account and retaining history…" : "Deleting account data…");
    els.globalNotice.hidden = false;
    try {
      const response = await fetch(
        "/v1/dashboard/accounts/" + encodeURIComponent(stringValue(account.id, ""))
          + "?mode=" + encodeURIComponent(mode),
        {
          method: "DELETE",
          credentials: "same-origin",
          cache: "no-store",
          redirect: "error",
          signal: controller.signal,
        },
      );
      let body = null;
      if (!response.ok) {
        try { body = await readJSON(response); } catch (_) { body = null; }
        if (response.status === 403 && isObject(body)
            && body.error === "access_key_verification_required") {
          state.verifyReturnFocus = trigger || null;
          requireAccessKeyVerification("Removing a monitored account needs the recovery access key for this Worker. Verify it, then run the removal again.");
          throw new Error("management_expired");
        }
        throw new Error(isObject(body) && typeof body.error === "string" ? body.error : "delete_failed");
      }
      if (epoch !== state.viewEpoch || controller.signal.aborted) return;
      showToast(mode === "preserve" ? "Account removed; data kept for re-add." : "Account and stored data deleted.");
      setText(els.globalNotice, "Refreshing account list…");
      await loadDashboard(false);
    } catch (error) {
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      setText(els.globalNotice, error instanceof Error && error.message === "management_expired"
        ? "Verify the recovery access key to change monitored accounts."
        : "The account could not be changed. Nothing was reported as deleted; try again.");
      els.globalNotice.hidden = false;
    } finally {
      if (state.accountDeleteController === controller) {
        state.accountDeleteController = null;
        if (trigger) trigger.disabled = false;
      }
    }
  }

  function renderQuota(window, idSuffix) {
    const wrapper = element("section", "quota");
    const row = element("div", "quota__row");
    const title = element("span", "quota__title");
    setText(title, stringValue(window.title, "Quota"));
    const percent = clampPercent(window.remaining_percent);
    const amount = element("strong", "quota__amount");
    setText(amount, formatPercent(percent));
    row.append(title, amount);
    wrapper.append(row);

    if (percent === null) {
      wrapper.append(element("div", "quota__unreported", "Provider did not report an amount"));
    } else {
      const progress = document.createElement("progress");
      progress.className = "quota__progress";
      progress.max = 100;
      progress.value = percent;
      const labelID = "quota-label-" + idSuffix;
      title.id = labelID;
      progress.setAttribute("aria-labelledby", labelID);
      wrapper.append(progress);
    }

    const reset = element("span", "quota__reset");
    addCountdown(reset, window.resets_at);
    wrapper.append(reset);
    return wrapper;
  }

  function renderResetCredits(container, snapshot) {
    const count = integerValue(snapshot.available_reset_count);
    const credits = arrayValue(snapshot.reset_credits).filter(isObject);
    const authoritative = snapshot.reset_credits_authoritative !== false;
    if ((count || 0) === 0 && credits.length === 0 && authoritative) return;
    const panel = element("div", "credit-summary");
    const heading = element("strong", "credit-summary__title");
    const reportedCount = count === null ? credits.length : count;
    setText(
      heading,
      authoritative
        ? formatInteger(reportedCount) + " reset credit" + (reportedCount === 1 ? "" : "s") + " available"
        : reportedCount > 0
          ? formatInteger(reportedCount) + " reset credit" + (reportedCount === 1 ? "" : "s") + " reported · partial"
          : "Reset credits not fully reported"
    );
    panel.append(heading);
    const now = Date.now() / 1000;
    const expiring = credits
      .filter((credit) => {
        const status = stringValue(credit.status, "available").toLowerCase();
        return !["expired", "used", "spent", "consumed", "redeemed"].includes(status);
      })
      .map((credit) => numberValue(credit.expires_at))
      .filter((value) => value !== null && value > now)
      .sort((left, right) => left - right)[0];
    if (expiring !== undefined) {
      const expiry = element("span", "fine-print");
      setText(expiry, "Next expiry " + formatDateTime(expiring));
      panel.append(expiry);
    }
    if (!authoritative) panel.append(element("span", "fine-print", "The provider may have additional banked resets."));
    container.append(panel);
  }

  function renderBalance(balance) {
    const panel = element("section", "balance");
    const heading = element("div", "balance__heading");
    const title = element("strong", "balance__title");
    setText(title, stringValue(balance.title, "API balance"));
    const kind = element("span", "pill");
    setText(kind, stringValue(balance.kind, "Balance"));
    heading.append(title, kind);
    panel.append(heading);

    if (balance.is_unlimited === true) {
      panel.append(element("p", "balance__headline", "Unlimited allowance"));
    } else {
      const remaining = numberValue(balance.remaining);
      const limit = numberValue(balance.limit);
      const spent = numberValue(balance.spent);
      const headline = remaining !== null
        ? formatAmount(remaining, balance) + " remaining"
        : spent !== null
          ? formatAmount(spent, balance) + " used"
          : "Balance not reported";
      panel.append(element("p", "balance__headline", headline));
      if (limit !== null && limit > 0 && remaining !== null) {
        const percent = Math.max(0, Math.min(100, (remaining / limit) * 100));
        const progress = document.createElement("progress");
        progress.className = "quota__progress";
        progress.max = 100;
        progress.value = percent;
        progress.setAttribute("aria-label", "API balance remaining");
        panel.append(progress);
      }
      const amounts = element("div", "balance__amounts");
      if (spent !== null) amounts.append(labelledValue("Used", formatAmount(spent, balance)));
      if (limit !== null) amounts.append(labelledValue("Limit", formatAmount(limit, balance)));
      if (remaining !== null) amounts.append(labelledValue("Remaining", formatAmount(remaining, balance)));
      if (amounts.childElementCount > 0) panel.append(amounts);
    }
    const periodStart = numberValue(balance.period_start);
    const periodEnd = numberValue(balance.period_end);
    const accessExpiry = numberValue(balance.access_expires_at);
    if (periodStart !== null || periodEnd !== null || accessExpiry !== null) {
      let timing;
      if (periodStart !== null && periodEnd !== null) timing = "Period " + formatDateTime(periodStart) + " – " + formatDateTime(periodEnd);
      else if (periodEnd !== null) timing = "Period ends " + formatDateTime(periodEnd);
      else if (periodStart !== null) timing = "Period started " + formatDateTime(periodStart);
      else timing = "Access ends " + formatDateTime(accessExpiry);
      panel.append(element(
        "span",
        "fine-print",
        timing
      ));
      if (accessExpiry !== null && (periodStart !== null || periodEnd !== null)) {
        panel.append(element("span", "fine-print", "Access ends " + formatDateTime(accessExpiry)));
      }
    }
    return panel;
  }

  function openHistory(account, trigger) {
    const accountID = stringValue(account.id, "");
    if (!accountID) {
      showToast("History is unavailable for this account.");
      return;
    }
    state.selectedAccount = account;
    state.historyReturnFocus = trigger;
    els.historyPanel.hidden = false;
    setText(els.historyTitle, stringValue(account.display_name, "Account history"));
    setText(
      els.historyMeta,
      stringValue(account.provider_name, stringValue(account.provider_id, "Provider")) + " · " + stringValue(account.plan, "Plan not reported")
    );
    updateRangeButtons();
    void loadHistory();
    els.historyPanel.scrollIntoView({ behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth", block: "start" });
    els.historyPanel.focus({ preventScroll: true });
  }

  function closeHistory() {
    const returnFocus = state.historyReturnFocus;
    if (state.historyController) state.historyController.abort();
    state.selectedAccount = null;
    state.historyPayload = null;
    state.historyReturnFocus = null;
    els.historyPanel.hidden = true;
    clear(els.historyLegend);
    clearCanvas();
    if (returnFocus && returnFocus.isConnected) returnFocus.focus();
  }

  function updateRangeButtons() {
    els.rangeButtons.forEach((button) => {
      const selected = button.getAttribute("data-history-range") === state.selectedRange;
      button.setAttribute("aria-pressed", selected ? "true" : "false");
      button.classList.toggle("is-selected", selected);
    });
  }

  async function loadHistory() {
    const account = state.selectedAccount;
    if (!isObject(account)) return;
    const accountID = stringValue(account.id, "");
    if (!accountID) return;
    if (state.historyController) state.historyController.abort();
    const controller = new AbortController();
    state.historyController = controller;
    setText(els.historyStatus, "Loading history…");
    els.historyCanvas.hidden = true;
    clear(els.historyLegend);
    setText(els.historySummary, "");
    try {
      const response = await fetch(
        "/v1/dashboard/accounts/" + encodeURIComponent(accountID) + "/history?range=" + encodeURIComponent(state.selectedRange),
        {
          method: "GET",
          credentials: "same-origin",
          cache: "no-store",
          redirect: "error",
          headers: { Accept: "application/json" },
          signal: controller.signal,
        }
      );
      if (response.status === 401) {
        handleUnauthorized();
        return;
      }
      if (!response.ok) throw new Error("history_failed");
      const payload = await readJSON(response);
      if (!isObject(payload) || !Array.isArray(payload.series)) throw new Error("invalid_history");
      if (state.historyController !== controller) return;
      state.historyPayload = payload;
      renderHistory(payload);
    } catch (error) {
      if (error instanceof DOMException && error.name === "AbortError") return;
      setText(els.historyStatus, "History could not be loaded. Try another range or refresh the dashboard.");
      els.historyCanvas.hidden = true;
    }
  }

  function renderHistory(payload) {
    const series = arrayValue(payload.series).filter(isObject);
    const pointCount = series.reduce((total, item) => total + arrayValue(item.points).length, 0);
    if (series.length === 0 || pointCount === 0) {
      setText(els.historyStatus, "No retained samples are available for this range yet.");
      setText(els.historySummary, "No history points were reported for the selected range.");
      els.historyCanvas.hidden = true;
      clear(els.historyLegend);
      return;
    }
    const suffix = payload.truncated === true ? " Some older points were omitted to keep this response bounded." : "";
    setText(els.historyStatus, formatInteger(pointCount) + " samples across " + formatInteger(series.length) + " metric" + (series.length === 1 ? "" : "s") + "." + suffix);
    els.historyCanvas.hidden = false;
    renderLegend(series);
    renderHistorySummary(payload, series);
    drawHistory(payload, series);
  }

  const chartColors = ["#0a7aff", "#b35c00", "#008a65", "#aa3a79", "#6957d2", "#67717e", "#c33f2f", "#2c7a37"];

  function renderLegend(series) {
    clear(els.historyLegend);
    series.forEach((item, index) => {
      const row = element("li", "chart-legend__item");
      const swatch = element("span", "chart-legend__swatch");
      swatch.classList.add("chart-color-" + (index % chartColors.length));
      swatch.setAttribute("aria-hidden", "true");
      const label = element("span", "chart-legend__label");
      setText(label, stringValue(item.title, "Quota metric"));
      row.append(swatch, label);
      els.historyLegend.append(row);
    });
  }

  function renderHistorySummary(payload, series) {
    const pieces = [
      "Quota history from " + formatDateTime(payload.from) + " to " + formatDateTime(payload.to) + ".",
    ];
    series.forEach((item) => {
      const values = arrayValue(item.points)
        .map((point) => isObject(point) ? clampPercent(point.remaining_percent) : null)
        .filter((value) => value !== null);
      if (values.length === 0) return;
      const minimum = Math.min.apply(null, values);
      const maximum = Math.max.apply(null, values);
      const latest = values[values.length - 1];
      pieces.push(
        stringValue(item.title, "Quota metric") + " ranged from " + formatPercent(minimum) + " to " + formatPercent(maximum) + ", latest " + formatPercent(latest) + "."
      );
    });
    if (payload.truncated === true) pieces.push("The response was truncated.");
    setText(els.historySummary, pieces.join(" "));
  }

  function clearCanvas() {
    const context = els.historyCanvas.getContext("2d");
    if (context) context.clearRect(0, 0, els.historyCanvas.width, els.historyCanvas.height);
  }

  function drawHistory(payload, series) {
    const canvas = els.historyCanvas;
    const rect = canvas.getBoundingClientRect();
    if (rect.width < 1 || rect.height < 1) return;
    const ratio = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = Math.round(rect.width * ratio);
    canvas.height = Math.round(rect.height * ratio);
    const context = canvas.getContext("2d");
    if (!context) return;
    context.setTransform(ratio, 0, 0, ratio, 0, 0);
    context.clearRect(0, 0, rect.width, rect.height);

    const styles = getComputedStyle(els.html);
    const gridColor = styles.getPropertyValue("--chart-grid").trim() || "#d7dce2";
    const labelColor = styles.getPropertyValue("--muted").trim() || "#68717d";
    const left = 42;
    const right = 14;
    const top = 16;
    const bottom = 30;
    const width = Math.max(1, rect.width - left - right);
    const height = Math.max(1, rect.height - top - bottom);
    const from = timestampMilliseconds(payload.from) || Date.now() - 86_400_000;
    const to = Math.max(from + 1, timestampMilliseconds(payload.to) || Date.now());

    context.font = "12px -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif";
    context.textAlign = "right";
    context.textBaseline = "middle";
    context.lineWidth = 1;
    [0, 25, 50, 75, 100].forEach((percent) => {
      const y = top + height - (percent / 100) * height;
      context.strokeStyle = gridColor;
      context.beginPath();
      context.moveTo(left, y);
      context.lineTo(left + width, y);
      context.stroke();
      context.fillStyle = labelColor;
      context.fillText(percent + "%", left - 7, y);
    });

    context.textBaseline = "top";
    const startLabel = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", hour: "numeric" }).format(new Date(from));
    const endLabel = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", hour: "numeric" }).format(new Date(to));
    context.textAlign = "left";
    context.fillText(startLabel, left, top + height + 9);
    context.textAlign = "right";
    context.fillText(endLabel, left + width, top + height + 9);

    series.forEach((item, seriesIndex) => {
      const points = arrayValue(item.points)
        .filter(isObject)
        .map((point) => ({ time: timestampMilliseconds(point.recorded_at), value: clampPercent(point.remaining_percent) }))
        .filter((point) => point.time !== null && point.value !== null)
        .sort((leftPoint, rightPoint) => leftPoint.time - rightPoint.time);
      if (points.length === 0) return;
      context.strokeStyle = chartColors[seriesIndex % chartColors.length];
      context.fillStyle = chartColors[seriesIndex % chartColors.length];
      context.lineWidth = 2.25;
      context.lineJoin = "round";
      context.lineCap = "round";
      context.beginPath();
      points.forEach((point, pointIndex) => {
        const x = left + ((point.time - from) / (to - from)) * width;
        const y = top + height - (point.value / 100) * height;
        if (pointIndex === 0) context.moveTo(x, y);
        else context.lineTo(x, y);
      });
      context.stroke();
      if (points.length <= 30) {
        points.forEach((point) => {
          const x = left + ((point.time - from) / (to - from)) * width;
          const y = top + height - (point.value / 100) * height;
          context.beginPath();
          context.arc(x, y, 2.5, 0, Math.PI * 2);
          context.fill();
        });
      }
    });
  }

  function safeQRCodeSVG(markup) {
    if (typeof markup !== "string") return null;
    const trimmed = markup.trim();
    if (!/^<svg(?:\s|>)/i.test(trimmed)) return null;
    const parsed = new DOMParser().parseFromString(trimmed, "image/svg+xml");
    const root = parsed.documentElement;
    if (!root || root.localName !== "svg" || root.namespaceURI !== "http://www.w3.org/2000/svg") return null;
    if (parsed.querySelector("parsererror")) return null;
    const allowedElements = new Set(["svg", "rect", "path"]);
    const allowedAttributes = new Set(["xmlns", "viewBox", "width", "height", "x", "y", "fill", "d", "shape-rendering"]);
    const nodes = [root].concat(Array.from(root.querySelectorAll("*")));
    for (const node of nodes) {
      if (!allowedElements.has(node.localName)) return null;
      for (const attribute of Array.from(node.attributes)) {
        if (!allowedAttributes.has(attribute.name) || /^on/i.test(attribute.name) || /(?:url\s*\(|javascript:|data:)/i.test(attribute.value)) return null;
      }
    }
    return document.importNode(root, true);
  }

  async function createLink() {
    const epoch = state.viewEpoch;
    const controller = new AbortController();
    if (state.linkController) state.linkController.abort();
    state.linkController = controller;
    els.linkButton.disabled = true;
    els.linkResult.hidden = true;
    clear(els.qrCode);
    els.openLink.removeAttribute("href");
    state.linkExpiresAt = null;
    setText(els.linkStatus, "Creating a private one-use link…");
    try {
      const response = await fetch("/v1/link-sessions", {
        method: "POST",
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error",
        headers: { Accept: "application/json" },
        signal: controller.signal,
      });
      if (epoch !== state.viewEpoch) return;
      if (response.status === 401) {
        handleUnauthorized();
        return;
      }
      if (!response.ok) throw new Error("link_failed");
      const payload = await readJSON(response);
      if (epoch !== state.viewEpoch) return;
      if (!isObject(payload)) throw new Error("invalid_link");
      const svg = safeQRCodeSVG(payload.qr_svg);
      const linkURI = stringValue(payload.link_uri, "");
      const expiresAt = timestampMilliseconds(payload.expires_at);
      const linkURL = new URL(linkURI);
      if (!svg || linkURL.protocol !== "whenreset:" || linkURL.host !== "link-worker" || expiresAt === null) {
        throw new Error("invalid_link");
      }
      els.qrCode.replaceChildren(svg);
      els.openLink.href = linkURI;
      state.linkExpiresAt = expiresAt;
      els.linkResult.hidden = false;
      setText(els.linkStatus, "Scan this code with Camera, or open it on this device.");
      updateLinkExpiry();
    } catch (_) {
      if (controller.signal.aborted || epoch !== state.viewEpoch) return;
      setText(els.linkStatus, "Couldn’t create a link. Refresh the dashboard and try again.");
      els.linkResult.hidden = true;
      clear(els.qrCode);
    } finally {
      if (state.linkController === controller) {
        state.linkController = null;
        els.linkButton.disabled = false;
      }
    }
  }

  function updateLinkExpiry() {
    if (state.linkExpiresAt === null) return;
    const seconds = Math.max(0, Math.ceil((state.linkExpiresAt - Date.now()) / 1000));
    if (seconds === 0) {
      state.linkExpiresAt = null;
      clear(els.qrCode);
      els.openLink.removeAttribute("href");
      els.linkResult.hidden = true;
      setText(els.linkStatus, "That link expired. Create a new one when you’re ready.");
      return;
    }
    const minutes = Math.floor(seconds / 60);
    const remainder = String(seconds % 60).padStart(2, "0");
    setText(els.linkExpiry, "Expires in " + minutes + ":" + remainder);
  }

  function cycleTheme() {
    state.theme = state.theme === "auto" ? "light" : state.theme === "light" ? "dark" : "auto";
    els.html.setAttribute("data-theme", state.theme);
    const label = state.theme === "auto" ? "System" : state.theme === "light" ? "Light" : "Dark";
    setText(els.themeButton, label);
    els.themeButton.setAttribute("aria-label", "Colour theme: " + label.toLowerCase());
    if (state.historyPayload) window.requestAnimationFrame(() => drawHistory(state.historyPayload, arrayValue(state.historyPayload.series).filter(isObject)));
  }

  els.unlockForm.addEventListener("submit", authenticate);
  els.passkeyButton.addEventListener("click", () => void authenticateWithPasskey());
  els.logoutButton.addEventListener("click", logout);
  els.refreshButton.addEventListener("click", () => void loadDashboard(true));
  els.autoButton.addEventListener("click", () => {
    state.autoRefresh = !state.autoRefresh;
    els.autoButton.setAttribute("aria-pressed", state.autoRefresh ? "true" : "false");
    setText(els.autoButton, state.autoRefresh ? "Auto-refresh on" : "Auto-refresh off");
    state.nextRefreshAt = state.autoRefresh ? Date.now() + AUTO_REFRESH_MS : 0;
    updateAllCountdowns();
  });
  els.historyClose.addEventListener("click", closeHistory);
  els.rangeButtons.forEach((button) => button.addEventListener("click", () => {
    const range = button.getAttribute("data-history-range");
    if (!["24h", "7d", "30d"].includes(range) || range === state.selectedRange) return;
    state.selectedRange = range;
    updateRangeButtons();
    void loadHistory();
  }));
  els.linkButton.addEventListener("click", createLink);
  els.verifyForm.addEventListener("submit", verifyAccessKey);
  els.addPasskeyButton.addEventListener("click", () => void addPasskey());
  els.removePasskeysButton.addEventListener("click", () => void removeAllPasskeys());
  els.themeButton.addEventListener("click", cycleTheme);

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible" && state.authenticated && state.autoRefresh && Date.now() >= state.nextRefreshAt) {
      void loadDashboard(false);
    }
  });

  window.addEventListener("pagehide", () => {
    state.viewEpoch += 1;
    if (state.dashboardController) state.dashboardController.abort();
    state.dashboardController = null;
    if (state.linkController) state.linkController.abort();
    state.linkController = null;
    if (state.devicesController) state.devicesController.abort();
    state.devicesController = null;
    if (state.deviceActionController) state.deviceActionController.abort();
    state.deviceActionController = null;
    if (state.authMethodsController) state.authMethodsController.abort();
    state.authMethodsController = null;
    if (state.passkeySettingsController) state.passkeySettingsController.abort();
    state.passkeySettingsController = null;
    if (state.passkeyOperationController) state.passkeyOperationController.abort();
    state.passkeyOperationController = null;
    els.linkButton.disabled = false;
    state.dashboardLoading = false;
    clearSensitiveView();
    state.dashboardPayload = null;
    state.historyPayload = null;
  });
  window.addEventListener("pageshow", (event) => {
    if (!event.persisted) return;
    if (state.authenticated) {
      void loadDashboard(false);
    } else {
      void loadAuthMethods();
    }
  });

  let resizeTimer = 0;
  window.addEventListener("resize", () => {
    window.clearTimeout(resizeTimer);
    resizeTimer = window.setTimeout(() => {
      if (state.historyPayload && !els.historyPanel.hidden) drawHistory(state.historyPayload, arrayValue(state.historyPayload.series).filter(isObject));
    }, 120);
  });

  const colorPreference = window.matchMedia("(prefers-color-scheme: dark)");
  colorPreference.addEventListener("change", () => {
    if (state.theme === "auto" && state.historyPayload) drawHistory(state.historyPayload, arrayValue(state.historyPayload.series).filter(isObject));
  });

  state.refreshTimer = window.setInterval(updateAllCountdowns, 1000);
  updateAllCountdowns();
  void (async () => {
    await loadDashboard(false);
    await loadAuthMethods();
  })();
})();
`;

export function renderDashboardPage(origin: string, displayName: string, nonce: string): string {
  const safeOrigin = escapeHTML(origin);
  const safeDisplayName = escapeHTML(displayName);
  const safeNonce = escapeHTML(nonce);
  return `<!doctype html>
<html lang="en" data-theme="auto">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <meta name="robots" content="noindex,nofollow,noarchive">
  <meta name="referrer" content="no-referrer">
  <title>When Reset · Monitor</title>
  <style nonce="${safeNonce}">
    /* One coherent system: a quiet ink-and-indigo console. Depth comes from layered
       surfaces and hairlines rather than heavy shadows, so dense data stays legible. */
    :root {
      color-scheme: light dark;

      --page: #f5f6f9;
      --page-tint: #eceef4;
      --surface: #ffffff;
      --surface-2: #fbfcfd;
      --sunken: #f2f4f7;
      --line: #e4e7ee;
      --line-soft: #eef0f5;
      --line-strong: #cfd4de;
      --text: #121722;
      --muted: #5d6675;
      --faint: #8b93a2;

      --accent: #4256d0;
      --accent-strong: #33429f;
      --accent-soft: #edf0fd;
      --accent-line: #c8d1f7;

      --good: #0e7a55;
      --good-soft: #e5f5ee;
      --warn: #98590a;
      --warn-soft: #fcf0dc;
      --danger: #b32a24;
      --danger-soft: #fdecea;
      --neutral-soft: #eceef3;

      --chart-grid: #e6e9ef;
      --on-accent: #ffffff;
      --shadow-sm: 0 1px 2px rgba(17, 24, 39, .05);
      --shadow-md: 0 1px 2px rgba(17, 24, 39, .04), 0 10px 26px -14px rgba(17, 24, 39, .22);
      --shadow-lg: 0 2px 4px rgba(17, 24, 39, .05), 0 22px 48px -24px rgba(17, 24, 39, .32);
      --ring: color-mix(in srgb, var(--accent) 42%, transparent);

      --r-xs: .375rem;
      --r-sm: .5rem;
      --r-md: .75rem;
      --r-lg: 1rem;
      --r-xl: 1.35rem;
      --content: 84rem;

      font-family: ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", Inter, Roboto, sans-serif;
      font-synthesis-weight: none;
    }

    :root[data-theme="dark"] {
      --page: #0a0c11;
      --page-tint: #0e1118;
      --surface: #14181f;
      --surface-2: #171c24;
      --sunken: #10141a;
      --line: #242a34;
      --line-soft: #1b202a;
      --line-strong: #333b48;
      --text: #e9edf5;
      --muted: #98a1b2;
      --faint: #6d7688;

      --accent: #93a4ff;
      --accent-strong: #b4c0ff;
      --accent-soft: #1a2044;
      --accent-line: #2f3a72;

      --good: #4fd6a0;
      --good-soft: #0f3128;
      --warn: #efb964;
      --warn-soft: #382a12;
      --danger: #ff9d95;
      --danger-soft: #3f211f;
      --neutral-soft: #1f242e;

      --chart-grid: #262d38;
      --on-accent: #0a0f1c;
      --shadow-sm: 0 1px 2px rgba(0, 0, 0, .5);
      --shadow-md: 0 1px 2px rgba(0, 0, 0, .45), 0 12px 30px -16px rgba(0, 0, 0, .8);
      --shadow-lg: 0 2px 6px rgba(0, 0, 0, .5), 0 26px 56px -28px rgba(0, 0, 0, .9);
    }

    @media (prefers-color-scheme: dark) {
      :root[data-theme="auto"] {
        --page: #0a0c11;
        --page-tint: #0e1118;
        --surface: #14181f;
        --surface-2: #171c24;
        --sunken: #10141a;
        --line: #242a34;
        --line-soft: #1b202a;
        --line-strong: #333b48;
        --text: #e9edf5;
        --muted: #98a1b2;
        --faint: #6d7688;
        --accent: #93a4ff;
        --accent-strong: #b4c0ff;
        --accent-soft: #1a2044;
        --accent-line: #2f3a72;
        --good: #4fd6a0;
        --good-soft: #0f3128;
        --warn: #efb964;
        --warn-soft: #382a12;
        --danger: #ff9d95;
        --danger-soft: #3f211f;
        --neutral-soft: #1f242e;
        --chart-grid: #262d38;
        --on-accent: #0a0f1c;
        --shadow-sm: 0 1px 2px rgba(0, 0, 0, .5);
        --shadow-md: 0 1px 2px rgba(0, 0, 0, .45), 0 12px 30px -16px rgba(0, 0, 0, .8);
        --shadow-lg: 0 2px 6px rgba(0, 0, 0, .5), 0 26px 56px -28px rgba(0, 0, 0, .9);
      }
    }

    * { box-sizing: border-box; }
    html { min-width: 20rem; scroll-behavior: smooth; background: var(--page); }
    body {
      margin: 0;
      min-height: 100vh;
      background:
        radial-gradient(58rem 30rem at 82% -14rem, color-mix(in srgb, var(--accent) 11%, transparent), transparent 70%) no-repeat,
        radial-gradient(46rem 26rem at -6% -8rem, color-mix(in srgb, var(--accent) 6%, transparent), transparent 66%) no-repeat,
        var(--page);
      color: var(--text);
      font-size: 15px;
      line-height: 1.5;
      -webkit-font-smoothing: antialiased;
    }
    h1, h2, h3 { font-weight: 640; letter-spacing: -.021em; }
    button, input, a { font: inherit; }
    button, a { -webkit-tap-highlight-color: transparent; }
    button { color: inherit; }
    [hidden] { display: none !important; }
    :focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; border-radius: var(--r-xs); }
    .skip-link { position: fixed; z-index: 100; top: .6rem; left: .6rem; padding: .65rem 1rem; border-radius: var(--r-sm); background: var(--text); color: var(--page); font-weight: 600; transform: translateY(-160%); }
    .skip-link:focus { transform: translateY(0); }
    .visually-hidden { position: absolute !important; width: 1px !important; height: 1px !important; overflow: hidden !important; clip: rect(0, 0, 0, 0) !important; white-space: nowrap !important; clip-path: inset(50%) !important; }
    .eyebrow { margin: 0 0 .3rem; color: var(--accent); font-size: .68rem; font-weight: 700; letter-spacing: .085em; text-transform: uppercase; }
    .num { font-variant-numeric: tabular-nums; }

    /* ---------- header ---------- */
    .site-header {
      position: sticky;
      z-index: 20;
      top: 0;
      border-bottom: 1px solid var(--line);
      background: color-mix(in srgb, var(--page) 82%, transparent);
      -webkit-backdrop-filter: saturate(180%) blur(14px);
      backdrop-filter: saturate(180%) blur(14px);
    }
    .site-header__inner { width: min(var(--content), calc(100% - 2.5rem)); min-height: 4rem; margin: 0 auto; display: flex; align-items: center; gap: 1rem; }
    .brand { display: flex; min-width: 0; align-items: center; gap: .7rem; }
    .brand__mark {
      width: 2.15rem; height: 2.15rem; flex: 0 0 auto; display: grid; place-items: center;
      border-radius: .68rem;
      background: linear-gradient(150deg, var(--accent), color-mix(in srgb, var(--accent) 55%, #7b3fe4));
      box-shadow: inset 0 1px 0 rgba(255, 255, 255, .32), var(--shadow-sm);
      color: #fff; font-size: .74rem; font-weight: 800; letter-spacing: .04em;
    }
    .brand__text { min-width: 0; display: grid; }
    .brand__name { font-size: .93rem; font-weight: 650; letter-spacing: -.015em; }
    .brand__host { max-width: 30ch; overflow: hidden; color: var(--faint); font-size: .73rem; text-overflow: ellipsis; white-space: nowrap; }
    .header-actions { display: flex; margin-left: auto; align-items: center; gap: .45rem; }
    .control-group { display: flex; align-items: center; gap: .15rem; border: 1px solid var(--line); border-radius: var(--r-sm); padding: .16rem; background: var(--sunken); }
    .control-group .button { min-height: 1.95rem; border-color: transparent; background: transparent; box-shadow: none; color: var(--muted); font-weight: 570; }
    .control-group .button:hover { background: var(--surface); color: var(--text); }
    .control-group .button[aria-pressed="true"] { background: var(--surface); box-shadow: var(--shadow-sm); color: var(--text); }
    .control-group .button[aria-pressed="false"] { color: var(--faint); }

    .status-pill {
      display: inline-flex; align-items: center; gap: .4rem;
      border: 1px solid var(--line); border-radius: 999px;
      padding: .28rem .62rem .28rem .5rem;
      background: var(--surface); color: var(--muted);
      font-size: .75rem; font-weight: 560; white-space: nowrap;
    }
    .status-pill::before { width: .44rem; height: .44rem; border-radius: 50%; background: var(--faint); content: ""; }
    .status-pill.is-live { border-color: color-mix(in srgb, var(--good) 32%, var(--line)); background: var(--good-soft); color: var(--good); }
    .status-pill.is-live::before { background: currentColor; box-shadow: 0 0 0 .22rem color-mix(in srgb, var(--good) 22%, transparent); }
    .status-pill.is-busy { border-color: color-mix(in srgb, var(--accent) 32%, var(--line)); background: var(--accent-soft); color: var(--accent); }
    .status-pill.is-busy::before { background: currentColor; }
    .status-pill.is-bad { border-color: color-mix(in srgb, var(--danger) 32%, var(--line)); background: var(--danger-soft); color: var(--danger); }
    .status-pill.is-bad::before { background: currentColor; }

    /* ---------- buttons ---------- */
    .button {
      min-height: 2.5rem;
      display: inline-flex; align-items: center; justify-content: center; gap: .4rem;
      border: 1px solid transparent; border-radius: var(--r-sm);
      padding: .5rem .95rem;
      background: var(--accent); color: var(--on-accent);
      box-shadow: var(--shadow-sm);
      cursor: pointer; font-size: .88rem; font-weight: 600; text-decoration: none; white-space: nowrap;
      transition: background-color .15s ease, border-color .15s ease, color .15s ease, transform .12s ease, box-shadow .15s ease;
    }
    .button:hover { background: var(--accent-strong); }
    .button:active { transform: translateY(1px); }
    .button:disabled { cursor: not-allowed; opacity: .5; transform: none; }
    .button--quiet { border-color: var(--line); background: var(--surface); color: var(--text); }
    .button--quiet:hover { border-color: var(--line-strong); background: var(--surface-2); color: var(--text); }
    .button--ghost { border-color: transparent; background: transparent; box-shadow: none; color: var(--muted); }
    .button--ghost:hover { background: var(--neutral-soft); color: var(--text); }
    .button--ghost:disabled { opacity: .45; }
    .button--danger { color: var(--danger); }
    .button--danger:hover { border-color: color-mix(in srgb, var(--danger) 42%, var(--line)); background: var(--danger-soft); color: var(--danger); }
    .button--small { min-height: 2.1rem; padding: .35rem .68rem; font-size: .8rem; }


    /* ---------- shell ---------- */
    main { width: min(var(--content), calc(100% - 2.5rem)); margin: 0 auto; padding: 1.75rem 0 4rem; }

    /* ---------- locked view ---------- */
    .locked-layout { min-height: calc(100vh - 12rem); display: grid; grid-template-columns: minmax(0, 1.05fr) minmax(20rem, .68fr); align-items: center; gap: clamp(2rem, 6vw, 5.5rem); padding: clamp(1.5rem, 6vw, 4rem) 0 4rem; }
    .locked-copy h1 { max-width: 12ch; margin: .6rem 0 1.1rem; font-size: clamp(2.6rem, 6.4vw, 4.9rem); font-weight: 660; line-height: 1.02; letter-spacing: -.042em; }
    .locked-copy h1 em { display: block; background: linear-gradient(96deg, var(--accent), color-mix(in srgb, var(--accent) 50%, #8b5cf6)); -webkit-background-clip: text; background-clip: text; color: transparent; font-style: normal; }
    .locked-copy__lead { max-width: 36rem; margin: 0; color: var(--muted); font-size: clamp(1rem, 1.6vw, 1.16rem); line-height: 1.62; }
    .trust-list { max-width: 38rem; display: grid; gap: .8rem; margin: 2.1rem 0 0; padding: 0; list-style: none; }
    .trust-list li { display: flex; align-items: flex-start; gap: .7rem; color: var(--muted); font-size: .92rem; line-height: 1.5; }
    .trust-list li::before { width: 1.25rem; height: 1.25rem; flex: 0 0 auto; display: grid; place-items: center; margin-top: .1rem; border-radius: 50%; background: var(--good-soft); color: var(--good); content: "✓"; font-size: .7rem; font-weight: 800; }

    .unlock-card { border: 1px solid var(--line); border-radius: var(--r-xl); padding: clamp(1.5rem, 3vw, 2rem); background: var(--surface); box-shadow: var(--shadow-lg); }
    .unlock-card__host { margin: 0 0 .4rem; overflow-wrap: anywhere; color: var(--faint); font-size: .76rem; font-weight: 560; letter-spacing: 0; }
    .unlock-card h2 { margin: 0 0 .5rem; font-size: 1.32rem; }
    .unlock-card > p { margin: 0; color: var(--muted); font-size: .9rem; line-height: 1.55; }
    .unlock-card .button { width: 100%; margin-top: 1rem; }
    .field { margin-top: 1.15rem; }
    .field label { display: block; margin-bottom: .42rem; color: var(--text); font-size: .84rem; font-weight: 600; }
    .field input {
      width: 100%; min-height: 2.85rem;
      border: 1px solid var(--line-strong); border-radius: var(--r-sm);
      padding: .65rem .8rem; background: var(--surface-2); color: var(--text);
      transition: border-color .15s ease, box-shadow .15s ease;
    }
    .field input:focus { border-color: var(--accent); box-shadow: 0 0 0 3px var(--ring); outline: none; }
    .field input::placeholder { color: var(--faint); }
    .auth-divider { display: flex; align-items: center; gap: .75rem; margin: 1.35rem 0 .1rem; color: var(--faint); font-size: .72rem; letter-spacing: .02em; }
    .auth-divider::before, .auth-divider::after { height: 1px; flex: 1; background: var(--line); content: ""; }
    .form-status { min-height: 2.6rem; margin: .9rem 0 0; color: var(--muted); font-size: .84rem; line-height: 1.45; }
    .security-note { display: flex; gap: .65rem; margin: .1rem 0 0; border-top: 1px solid var(--line-soft); padding-top: 1rem; color: var(--faint); font-size: .77rem; line-height: 1.55; }
    .security-note strong { color: var(--text); font-weight: 620; }

    /* ---------- dashboard shell ---------- */
    .dashboard-stack { display: grid; gap: 1.25rem; }
    .page-head { display: flex; flex-wrap: wrap; align-items: flex-end; justify-content: space-between; gap: 1rem; padding: .25rem .25rem 0; }
    .page-head h1 { margin: 0; font-size: clamp(1.6rem, 3vw, 2.05rem); letter-spacing: -.03em; }
    .page-head__text > p:last-child { margin: .35rem 0 0; max-width: 46rem; color: var(--muted); font-size: .89rem; }
    .page-head__meta { display: grid; gap: .12rem; border-left: 2px solid var(--accent-line); padding-left: .85rem; text-align: left; }
    .page-head__meta strong { font-size: .88rem; font-weight: 620; }
    .page-head__meta span { color: var(--faint); font-size: .78rem; font-variant-numeric: tabular-nums; }

    .notice { display: flex; align-items: flex-start; gap: .6rem; border: 1px solid color-mix(in srgb, var(--warn) 30%, var(--line)); border-radius: var(--r-md); padding: .8rem 1rem; background: var(--warn-soft); color: var(--warn); font-size: .85rem; line-height: 1.5; }
    .notice::before { content: "!"; flex: 0 0 auto; width: 1.15rem; height: 1.15rem; display: grid; place-items: center; margin-top: .05rem; border-radius: 50%; background: color-mix(in srgb, var(--warn) 22%, transparent); font-size: .72rem; font-weight: 800; }

    /* ---------- overview ---------- */
    .overview-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(12.5rem, 1fr)); gap: .85rem; }
    .overview-card {
      position: relative; overflow: hidden;
      display: flex; flex-direction: column; gap: .1rem;
      border: 1px solid var(--line); border-radius: var(--r-lg);
      padding: 1rem 1.05rem 1.05rem;
      background: var(--surface); box-shadow: var(--shadow-md);
    }
    .overview-card::before { position: absolute; inset: 0 0 auto; height: 2px; background: var(--accent); content: ""; opacity: .85; }
    .overview-card:nth-child(2)::before { background: var(--good); }
    .overview-card:nth-child(3)::before { background: var(--warn); }
    .overview-card:nth-child(4)::before { background: #8b5cf6; }
    .overview-card__label { display: flex; align-items: center; gap: .42rem; color: var(--muted); font-size: .78rem; font-weight: 580; }
    .overview-card__value { margin: .5rem 0 .1rem; font-size: clamp(1.9rem, 3.4vw, 2.5rem); font-weight: 660; font-variant-numeric: tabular-nums; letter-spacing: -.045em; line-height: 1.05; }
    .overview-card__detail { margin-top: auto; padding-top: .5rem; color: var(--faint); font-size: .76rem; line-height: 1.4; }

    /* ---------- section cards ---------- */
    .section-card { border: 1px solid var(--line); border-radius: var(--r-xl); padding: clamp(1.05rem, 2vw, 1.5rem); background: var(--surface); box-shadow: var(--shadow-md); }
    .section-card--flush { padding-bottom: .6rem; }
    .section-heading { display: flex; align-items: flex-start; justify-content: space-between; gap: 1rem; margin-bottom: 1.1rem; }
    .section-heading h2 { margin: 0; font-size: 1.08rem; }
    .section-heading p { margin: .3rem 0 0; max-width: 52rem; color: var(--muted); font-size: .84rem; line-height: 1.5; }
    .section-count { min-width: 1.9rem; height: 1.9rem; flex: 0 0 auto; display: grid; place-items: center; border: 1px solid var(--line); border-radius: 999px; padding: 0 .5rem; background: var(--sunken); color: var(--muted); font-size: .78rem; font-weight: 650; font-variant-numeric: tabular-nums; }
    .section-status { min-height: 1.2rem; margin: 0 0 .9rem; color: var(--faint); font-size: .79rem; }

    /* ---------- accounts ---------- */
    .accounts-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(20.5rem, 1fr)); gap: .9rem; }
    .account-card {
      position: relative; min-width: 0; overflow: hidden;
      display: flex; flex-direction: column;
      border: 1px solid var(--line); border-radius: var(--r-lg);
      background: var(--surface-2);
      transition: border-color .15s ease, box-shadow .15s ease, transform .15s ease;
    }
    .account-card:hover { border-color: var(--line-strong); box-shadow: var(--shadow-md); transform: translateY(-1px); }
    .account-card::before { position: absolute; inset: 0 auto 0 0; width: 3px; background: var(--faint); content: ""; }
    .account-card.status-active::before { background: var(--good); }
    .account-card.status-stale::before, .account-card.status-unchecked::before { background: var(--warn); }
    .account-card.status-expired::before, .account-card.status-error::before { background: var(--danger); }

    .account-card__heading { display: flex; align-items: flex-start; gap: .7rem; padding: 1rem 1rem .1rem 1.15rem; }
    .account-card__avatar {
      width: 2.3rem; height: 2.3rem; flex: 0 0 auto; display: grid; place-items: center;
      border: 1px solid var(--accent-line); border-radius: .65rem;
      background: var(--accent-soft); color: var(--accent);
      font-size: .8rem; font-weight: 720; letter-spacing: .01em; text-transform: uppercase;
    }
    .account-card__identity { min-width: 0; flex: 1; }
    .account-card__name { margin: 0; overflow-wrap: anywhere; font-size: 1rem; font-weight: 620; letter-spacing: -.018em; }
    .account-card__source { margin: .12rem 0 0; color: var(--faint); font-size: .74rem; }
    .account-card__plan { margin: .7rem 1rem 0 1.15rem; color: var(--muted); font-size: .81rem; }

    .status-badge { flex: 0 0 auto; display: inline-flex; align-items: center; border-radius: 999px; padding: .24rem .5rem; background: var(--neutral-soft); color: var(--muted); font-size: .68rem; font-weight: 640; letter-spacing: .005em; white-space: nowrap; }
    .status-badge::before { width: .36rem; height: .36rem; margin-right: .34rem; border-radius: 50%; background: currentColor; content: ""; }
    .status-badge--active { background: var(--good-soft); color: var(--good); }
    .status-badge--stale, .status-badge--unchecked { background: var(--warn-soft); color: var(--warn); }
    .status-badge--expired, .status-badge--error { background: var(--danger-soft); color: var(--danger); }

    .account-card__timing { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: .6rem .9rem; margin: .95rem 1rem; border-top: 1px solid var(--line-soft); border-bottom: 1px solid var(--line-soft); padding: .8rem .15rem; margin-left: 1.15rem; }
    .labelled-value { min-width: 0; }
    .labelled-value__label, .labelled-value__value { display: block; }
    .labelled-value__label { margin-bottom: .15rem; color: var(--faint); font-size: .65rem; font-weight: 640; letter-spacing: .055em; text-transform: uppercase; }
    .labelled-value__value { overflow-wrap: anywhere; font-size: .81rem; font-weight: 520; font-variant-numeric: tabular-nums; }

    .quota-list { display: grid; gap: .8rem; padding: 0 1rem 0 1.15rem; }
    .quota-eyebrow { margin: 0 0 -.3rem; color: var(--faint); font-size: .62rem; letter-spacing: .075em; }
    .quota { display: grid; gap: .34rem; }
    .quota__row { display: flex; align-items: baseline; justify-content: space-between; gap: .7rem; font-size: .82rem; }
    .quota__title { min-width: 0; overflow-wrap: anywhere; color: var(--muted); }
    .quota__amount { font-weight: 620; font-variant-numeric: tabular-nums; white-space: nowrap; }
    .quota__progress { width: 100%; height: .4rem; overflow: hidden; border: 0; border-radius: 999px; background: var(--neutral-soft); color: var(--accent); accent-color: var(--accent); }
    .quota__progress::-webkit-progress-bar { border-radius: 999px; background: var(--neutral-soft); }
    .quota__progress::-webkit-progress-value { border-radius: 999px; background: linear-gradient(90deg, color-mix(in srgb, var(--accent) 72%, transparent), var(--accent)); }
    .quota__progress::-moz-progress-bar { border-radius: 999px; background: var(--accent); }
    .quota__reset, .fine-print, .quota__unreported { color: var(--faint); font-size: .72rem; font-variant-numeric: tabular-nums; line-height: 1.45; }
    .quota__unreported { border-radius: var(--r-xs); padding: .35rem .5rem; background: var(--sunken); }

    .credit-summary { display: flex; flex-wrap: wrap; align-items: baseline; justify-content: space-between; gap: .3rem .7rem; border: 1px solid var(--accent-line); border-radius: var(--r-sm); padding: .55rem .7rem; background: var(--accent-soft); color: var(--accent); }
    .credit-summary__title { font-size: .78rem; font-weight: 620; }
    .credit-summary .fine-print { color: color-mix(in srgb, var(--accent) 78%, var(--muted)); }
    .balance { display: grid; gap: .45rem; border: 1px solid var(--line); border-radius: var(--r-sm); padding: .7rem .75rem; background: var(--sunken); }
    .balance__heading { display: flex; align-items: center; justify-content: space-between; gap: .6rem; }
    .balance__title { overflow-wrap: anywhere; font-size: .79rem; font-weight: 620; }
    .balance__headline { margin: 0; font-size: 1.02rem; font-weight: 640; font-variant-numeric: tabular-nums; letter-spacing: -.02em; }
    .balance__amounts { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: .5rem; border-top: 1px solid var(--line-soft); padding-top: .55rem; }
    .pill { border: 1px solid var(--line); border-radius: 999px; padding: .16rem .45rem; background: var(--surface); color: var(--muted); font-size: .63rem; font-weight: 640; text-transform: capitalize; }

    .account-card__footer { display: grid; gap: .6rem; margin-top: auto; border-top: 1px solid var(--line-soft); padding: .8rem 1rem .85rem 1.15rem; background: color-mix(in srgb, var(--sunken) 55%, transparent); }
    .account-card__actions { display: flex; flex-wrap: wrap; justify-content: flex-end; gap: .35rem; }
    .empty-inline { margin: .1rem 0; color: var(--muted); font-size: .81rem; line-height: 1.5; }
    .empty-state { border: 1px dashed var(--line-strong); border-radius: var(--r-lg); padding: 2.2rem 1.5rem; background: var(--sunken); text-align: center; }
    .empty-state h3 { margin: 0 0 .45rem; font-size: 1rem; }
    .empty-state p { max-width: 32rem; margin: 0 auto; color: var(--muted); font-size: .86rem; line-height: 1.55; }

    /* ---------- devices ---------- */
    .stat-strip { display: grid; grid-template-columns: repeat(auto-fit, minmax(7rem, 1fr)); gap: .5rem; margin-bottom: 1.1rem; border: 1px solid var(--line); border-radius: var(--r-md); padding: .1rem; background: var(--sunken); }
    .stat-strip .labelled-value { border-radius: var(--r-sm); padding: .6rem .75rem; background: var(--surface); }
    .stat-strip .labelled-value__value { font-size: 1.02rem; font-weight: 640; }

    .device-list { display: grid; gap: .55rem; margin: 0; padding: 0; list-style: none; }
    .device-row {
      display: grid; align-items: center; gap: .75rem 1rem;
      grid-template-columns: minmax(11rem, 1.5fr) minmax(8rem, 1fr) minmax(9rem, 1.1fr) auto;
      border: 1px solid var(--line); border-radius: var(--r-lg);
      padding: .8rem .9rem;
      background: var(--surface-2);
      transition: border-color .15s ease, background-color .15s ease;
    }
    .device-row:hover { border-color: var(--line-strong); background: var(--surface); }
    .device-row.is-current { border-color: var(--accent-line); background: color-mix(in srgb, var(--accent-soft) 45%, var(--surface-2)); }
    .device-row.is-retired { opacity: .72; }
    .device-identity { min-width: 0; display: flex; align-items: center; gap: .65rem; }
    .device-avatar {
      width: 2.2rem; height: 2.2rem; flex: 0 0 auto; display: grid; place-items: center;
      border: 1px solid var(--line); border-radius: .6rem;
      background: var(--surface); color: var(--muted);
      font-size: .72rem; font-weight: 700; font-variant-numeric: tabular-nums; letter-spacing: .04em;
    }
    .device-row.is-current .device-avatar { border-color: var(--accent-line); background: var(--accent-soft); color: var(--accent); }
    .device-identity__text { min-width: 0; display: grid; gap: .1rem; }
    .device-name { display: flex; align-items: center; gap: .4rem; font-size: .89rem; font-weight: 620; }
    .device-meta { color: var(--faint); font-size: .73rem; font-variant-numeric: tabular-nums; }
    .device-usage { display: flex; flex-wrap: wrap; gap: .3rem; }
    .device-tag { border: 1px solid var(--line); border-radius: 999px; padding: .16rem .48rem; background: var(--surface); color: var(--muted); font-size: .68rem; font-weight: 560; font-variant-numeric: tabular-nums; white-space: nowrap; }
    .device-tag--idle { color: var(--faint); }
    .device-state { display: grid; gap: .22rem; }
    .device-actions { display: flex; flex-wrap: wrap; justify-content: flex-end; gap: .35rem; }

    /* ---------- verify panel ---------- */
    .verify-card { border-color: var(--accent-line); background: linear-gradient(180deg, var(--accent-soft), var(--surface) 62%); }
    .verify-layout { display: grid; grid-template-columns: minmax(0, 1fr) minmax(17rem, .62fr); align-items: start; gap: 1.4rem; }
    .verify-layout h2 { margin: 0; font-size: 1.05rem; }
    .verify-layout > div > p { margin: .35rem 0 0; color: var(--muted); font-size: .85rem; line-height: 1.55; }
    .verify-form .field { margin-top: 0; }
    .verify-form .button { width: 100%; margin-top: .7rem; }
    .verify-status { min-height: 1.2rem; margin: .55rem 0 0; color: var(--muted); font-size: .79rem; line-height: 1.45; }

    /* ---------- history ---------- */
    .history-card { scroll-margin-top: 5.5rem; }
    .history-heading { align-items: center; }
    .history-toolbar { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: .75rem; }
    .range-picker { display: inline-flex; gap: .15rem; border: 1px solid var(--line); border-radius: var(--r-sm); padding: .18rem; background: var(--sunken); }
    .range-picker button { min-height: 2rem; border: 0; border-radius: calc(var(--r-sm) - .12rem); padding: .35rem .7rem; background: transparent; color: var(--muted); cursor: pointer; font-size: .79rem; font-weight: 580; transition: background-color .15s ease, color .15s ease; }
    .range-picker button:hover { color: var(--text); }
    .range-picker button.is-selected { background: var(--surface); color: var(--text); box-shadow: var(--shadow-sm); }
    .history-status { margin: 0; color: var(--faint); font-size: .79rem; }
    .chart-wrap { min-height: 19rem; margin-top: 1rem; border: 1px solid var(--line); border-radius: var(--r-md); padding: .9rem; background: var(--sunken); }
    #history-canvas { width: 100%; height: 17rem; display: block; }
    .chart-legend { display: flex; flex-wrap: wrap; gap: .5rem 1.05rem; margin: .9rem 0 0; padding: 0; list-style: none; }
    .chart-legend__item { display: inline-flex; align-items: center; gap: .42rem; color: var(--muted); font-size: .75rem; }
    .chart-legend__swatch { width: .8rem; height: .2rem; border-radius: 999px; }
    .chart-color-0 { background: #4256d0; }
    .chart-color-1 { background: #0e7a55; }
    .chart-color-2 { background: #b5651d; }
    .chart-color-3 { background: #9333a8; }
    .chart-color-4 { background: #0e7490; }
    .chart-color-5 { background: #b32a24; }
    .chart-color-6 { background: #5b6472; }
    .chart-color-7 { background: #2f7d32; }

    /* ---------- operations, link, passkeys, security ---------- */
    .operations-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 1rem; align-items: start; }
    .summary-list { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: .5rem; border: 1px solid var(--line); border-radius: var(--r-md); padding: .1rem; background: var(--sunken); }
    .summary-list .labelled-value { border-radius: var(--r-sm); padding: .65rem .8rem; background: var(--surface); }
    .summary-list .labelled-value:last-child:nth-child(odd) { grid-column: 1 / -1; }
    .summary-list .labelled-value__value { font-size: 1rem; font-weight: 640; }

    .link-layout { display: flex; flex-wrap: wrap; align-items: flex-start; gap: 1.4rem 2rem; }
    .link-copy { flex: 1 1 22rem; min-width: 0; }
    .link-result { flex: 0 1 17rem; min-width: 0; }
    .link-copy h2 { margin: 0 0 .4rem; font-size: 1.08rem; }
    .link-copy p { margin: 0 0 1rem; color: var(--muted); font-size: .86rem; line-height: 1.55; }
    .link-status { min-height: 1.4rem; margin: .7rem 0 0; color: var(--faint); font-size: .8rem; }
    .link-result { text-align: center; }
    .qr-code { display: grid; place-items: center; border: 1px solid var(--line); border-radius: var(--r-md); padding: .7rem; background: #fff; }
    .qr-code svg { width: min(100%, 16rem); height: auto; display: block; }
    .link-expiry { margin: .6rem 0 .1rem; color: var(--muted); font-size: .8rem; font-variant-numeric: tabular-nums; }
    .link-result .button { width: 100%; margin-top: .5rem; }

    .passkey-layout { display: grid; grid-template-columns: minmax(0, 1fr) minmax(16rem, .6fr); align-items: start; gap: 1.4rem; }
    .passkey-overview { display: grid; grid-template-columns: auto minmax(0, 1fr); align-items: center; gap: 1rem; }
    .passkey-count { min-width: 3.6rem; min-height: 3.6rem; display: grid; place-items: center; border: 1px solid var(--accent-line); border-radius: var(--r-md); background: var(--accent-soft); color: var(--accent); font-size: 1.7rem; font-weight: 680; font-variant-numeric: tabular-nums; }
    .passkey-overview h2 { margin: 0 0 .3rem; font-size: 1.08rem; }
    .passkey-overview p, .passkey-copy { margin: 0; color: var(--muted); font-size: .84rem; line-height: 1.55; }
    .passkey-copy { margin-top: 1.05rem; color: var(--faint); font-size: .78rem; }
    .passkey-controls { display: grid; gap: .7rem; }
    .passkey-actions { display: flex; flex-wrap: wrap; gap: .5rem; }
    .passkey-actions .button { flex: 1 1 8.5rem; }
    .passkey-status { min-height: 1.4rem; margin: 0; color: var(--faint); font-size: .79rem; line-height: 1.45; }

    .security-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: .8rem; }
    .security-item { border: 1px solid var(--line); border-radius: var(--r-md); padding: .9rem 1rem; background: var(--sunken); }
    .security-item h3 { margin: 0 0 .4rem; font-size: .86rem; font-weight: 640; }
    .security-item h3::before { display: inline-block; width: .4rem; height: .4rem; margin-right: .45rem; border-radius: 50%; background: var(--good); content: ""; vertical-align: middle; }
    .security-item p { margin: 0; color: var(--muted); font-size: .78rem; line-height: 1.6; }

    .footer { width: min(var(--content), calc(100% - 2.5rem)); display: flex; flex-wrap: wrap; justify-content: space-between; gap: .5rem 1rem; margin: 0 auto; border-top: 1px solid var(--line); padding: 1.2rem 0 calc(1.4rem + env(safe-area-inset-bottom)); color: var(--faint); font-size: .74rem; }
    .footer span:last-child { overflow-wrap: anywhere; text-align: right; }
    .toast { position: fixed; z-index: 50; right: max(1rem, env(safe-area-inset-right)); bottom: max(1rem, env(safe-area-inset-bottom)); max-width: min(24rem, calc(100% - 2rem)); border: 1px solid var(--line-strong); border-radius: var(--r-md); padding: .75rem 1rem; background: var(--surface); box-shadow: var(--shadow-lg); font-size: .84rem; line-height: 1.45; }

    /* ---------- responsive ---------- */
    @media (max-width: 74rem) {
      .security-grid { grid-template-columns: 1fr; }
      .device-row { grid-template-columns: minmax(10rem, 1.4fr) minmax(8rem, 1fr) auto; }
      .device-row .device-usage { grid-column: 1 / -1; }
    }

    @media (max-width: 48rem) {
      body { font-size: 14.5px; }
      .site-header__inner { width: min(100% - 1.25rem, var(--content)); min-height: 3.6rem; }
      .brand__host, #auto-button { display: none; }
      main { width: min(100% - 1.25rem, var(--content)); padding-top: 1.15rem; }
      .locked-layout { min-height: auto; grid-template-columns: 1fr; gap: 2rem; padding: 1.5rem 0 2.5rem; }
      .locked-copy h1 { font-size: clamp(2.4rem, 12vw, 3.8rem); }
      .page-head { align-items: flex-start; flex-direction: column; }
      .page-head__meta { border-left: 0; border-top: 2px solid var(--accent-line); padding: .5rem 0 0; }
      .operations-grid, .passkey-layout, .verify-layout { grid-template-columns: 1fr; }
      .link-result { flex: 1 1 auto; }
      .accounts-grid { grid-template-columns: 1fr; }
      .device-row { grid-template-columns: 1fr; }
      .device-actions { justify-content: flex-start; }
      .history-heading { align-items: flex-start; }
      .chart-wrap { min-height: 15rem; padding: .55rem; }
      #history-canvas { height: 14rem; }
      .footer { width: calc(100% - 1.25rem); flex-direction: column; }
      .footer span:last-child { text-align: left; }
    }

    @media (max-width: 34rem) {
      .header-actions { gap: .28rem; }
      .header-actions .button { padding: .45rem .6rem; font-size: .78rem; }
      #connection-status { display: none; }
      .overview-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: .55rem; }
      .overview-card { padding: .85rem .9rem .9rem; }
      .overview-card__value { font-size: 1.7rem; }
      .overview-card__detail { font-size: .72rem; }
      .account-card__heading { flex-wrap: wrap; }
      .account-card__footer { align-items: stretch; flex-direction: column; }
      .account-card__actions { justify-content: stretch; }
      .account-card__actions .button { flex: 1 1 auto; }
      .history-toolbar { align-items: stretch; flex-direction: column; }
      .range-picker { display: grid; grid-template-columns: repeat(3, 1fr); }
      .summary-list, .stat-strip { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .device-actions .button { flex: 1 1 auto; }
    }

    @media (prefers-reduced-motion: reduce) {
      *, *::before, *::after { scroll-behavior: auto !important; transition-duration: .001ms !important; animation-duration: .001ms !important; animation-iteration-count: 1 !important; }
      .account-card:hover { transform: none; }
    }

    @media (forced-colors: active) {
      .brand__mark, .status-badge, .status-pill, .credit-summary, .pill, .device-tag, .device-avatar { border: 1px solid CanvasText; }
      .account-card::before, .overview-card::before { forced-color-adjust: none; }
      .quota__progress { forced-color-adjust: none; }
      .locked-copy h1 em { color: CanvasText; }
    }
  </style>
</head>
<body>
  <a class="skip-link" href="#main-content">Skip to dashboard</a>
  <header class="site-header">
    <div class="site-header__inner">
      <div class="brand" aria-label="When Reset monitor">
        <span class="brand__mark" aria-hidden="true">WR</span>
        <span class="brand__text">
          <span class="brand__name">When Reset</span>
          <span class="brand__host">${safeDisplayName}</span>
        </span>
      </div>
      <div class="header-actions">
        <span id="connection-status" class="status-pill" role="status">Locked</span>
        <div id="session-controls" class="control-group" hidden>
          <button id="auto-button" class="button button--small" type="button" aria-pressed="true">Auto-refresh on</button>
          <button id="refresh-button" class="button button--small" type="button">Refresh</button>
        </div>
        <button id="theme-button" class="button button--quiet button--small" type="button" aria-label="Colour theme: system">System</button>
        <button id="logout-button" class="button button--quiet button--danger button--small" type="button" hidden>Sign out</button>
      </div>
    </div>
  </header>

  <main id="main-content" tabindex="-1">
    <section id="locked-view" class="locked-layout" aria-labelledby="locked-title">
      <div class="locked-copy">
        <p class="eyebrow">Private deployment monitor</p>
        <h1 id="locked-title">Know what <em>resets next.</em></h1>
        <p class="locked-copy__lead">Account health, quota windows, balances, collection runs, and linked devices—on one calm, private dashboard served by your own Worker.</p>
        <ul class="trust-list">
          <li>Account credentials are never returned to this website.</li>
          <li>The access key opens a short-lived, same-origin session and is cleared immediately.</li>
          <li>Provider sign-in and credential updates stay inside the When Reset app.</li>
        </ul>
      </div>
      <section class="unlock-card" aria-labelledby="unlock-title">
        <p class="unlock-card__host">${safeDisplayName}</p>
        <h2 id="unlock-title">Open private dashboard</h2>
        <p>Use a passkey saved by your device, or fall back to the recovery access key configured for this Worker.</p>
        <button id="passkey-button" class="button" type="button" hidden>Continue with a passkey</button>
        <div id="passkey-divider" class="auth-divider" hidden><span>or use the recovery access key</span></div>
        <form id="unlock-form" method="post" action="/v1/dashboard/session" autocomplete="off">
          <div class="field">
            <label for="server-key">Recovery access key</label>
            <input id="server-key" type="password" minlength="32" autocomplete="off" autocapitalize="none" spellcheck="false" required placeholder="Enter your recovery key">
          </div>
          <button id="unlock-button" class="button button--quiet" type="submit">Use recovery access key</button>
        </form>
        <p id="unlock-status" class="form-status" role="status" aria-live="polite">Checking for an existing private session…</p>
        <p class="security-note"><span aria-hidden="true">⌁</span><span><strong>Credential-free view.</strong> This page has no route, field, or control for downloading or editing provider credentials.</span></p>
      </section>
    </section>

    <div id="dashboard-view" class="dashboard-stack" hidden>
      <div class="page-head">
        <div class="page-head__text">
          <p class="eyebrow">Private operations console</p>
          <h1 id="dashboard-title">Quota monitor</h1>
          <p>What is healthy, what is stale, and what resets next—with account and device controls that stay explicit.</p>
        </div>
        <div class="page-head__meta">
          <strong id="generated-at">Waiting for data</strong>
          <span id="auto-status">Auto-refresh is on</span>
        </div>
      </div>

      <p id="global-notice" class="notice" role="status" hidden></p>

      <section id="verify-panel" class="section-card verify-card" aria-labelledby="verify-title" tabindex="-1" hidden>
        <div class="verify-layout">
          <div>
            <p class="eyebrow">Step-up required</p>
            <h2 id="verify-title">Verify recovery access key</h2>
            <p id="verify-reason">Removing a monitored account or a linked device needs the recovery access key for this Worker. The key is exchanged for a short grant and is never stored by this page.</p>
          </div>
          <form id="verify-form" class="verify-form" autocomplete="off">
            <div class="field">
              <label for="verify-key">Recovery access key</label>
              <input id="verify-key" type="password" minlength="32" autocomplete="off" autocapitalize="none" spellcheck="false" required placeholder="Enter your recovery key">
            </div>
            <button id="verify-button" class="button" type="submit">Verify recovery access</button>
            <p id="verify-status" class="verify-status" role="status" aria-live="polite"></p>
          </form>
        </div>
      </section>

      <section class="overview-grid" aria-label="Monitoring overview">
        <article class="overview-card">
          <span class="overview-card__label">Monitored accounts</span>
          <strong id="overview-accounts" class="overview-card__value">—</strong>
          <span id="last-success" class="overview-card__detail">Not reported</span>
        </article>
        <article class="overview-card">
          <span class="overview-card__label">Healthy</span>
          <strong id="overview-healthy" class="overview-card__value">—</strong>
          <span class="overview-card__detail">Active provider sessions</span>
        </article>
        <article class="overview-card">
          <span class="overview-card__label">Need attention</span>
          <strong id="overview-attention" class="overview-card__value">—</strong>
          <span id="nearest-reset" class="overview-card__detail">Reset not reported</span>
        </article>
        <article class="overview-card">
          <span class="overview-card__label">Linked devices</span>
          <strong id="overview-devices" class="overview-card__value">—</strong>
          <span id="overview-devices-detail" class="overview-card__detail">Managed below by short label</span>
        </article>
      </section>

      <section class="section-card" aria-labelledby="accounts-title">
        <div class="section-heading">
          <div>
            <h2 id="accounts-title">Accounts</h2>
            <p>Quota, reset, plan, balance, and collection health. Incomplete provider data stays explicitly marked.</p>
          </div>
          <span id="accounts-heading-count" class="section-count" aria-label="Account count">0</span>
        </div>
        <div id="accounts-empty" class="empty-state" hidden>
          <h3>No monitored accounts yet</h3>
          <p>Link a device, then opt accounts into server monitoring from When Reset.</p>
        </div>
        <div id="accounts-grid" class="accounts-grid"></div>
      </section>

      <section id="history-panel" class="section-card history-card" aria-labelledby="history-title" tabindex="-1" hidden>
        <div class="section-heading history-heading">
          <div>
            <p class="eyebrow">Retained quota samples</p>
            <h2 id="history-title">Account history</h2>
            <p id="history-meta">Provider · Plan</p>
          </div>
          <button id="history-close" class="button button--quiet button--small" type="button">Close</button>
        </div>
        <div class="history-toolbar">
          <div class="range-picker" aria-label="History range">
            <button type="button" data-history-range="24h" aria-pressed="true" class="is-selected">24 hours</button>
            <button type="button" data-history-range="7d" aria-pressed="false">7 days</button>
            <button type="button" data-history-range="30d" aria-pressed="false">30 days</button>
          </div>
          <p id="history-status" class="history-status" role="status" aria-live="polite">Choose a range.</p>
        </div>
        <div class="chart-wrap">
          <canvas id="history-canvas" role="img" aria-label="Quota history chart" aria-describedby="history-summary" hidden></canvas>
          <p id="history-summary" class="visually-hidden"></p>
          <ul id="history-legend" class="chart-legend" aria-label="Chart metrics"></ul>
        </div>
      </section>

      <section id="devices-panel" class="section-card" aria-labelledby="devices-title">
        <div class="section-heading">
          <div>
            <h2 id="devices-title">Linked devices</h2>
            <p>Every device holds its own key. Identifiers and push tokens stay private, so each device is managed by the short label the Worker derives for it.</p>
          </div>
          <span id="devices-heading-count" class="section-count" aria-label="Linked device count">0</span>
        </div>
        <div id="devices-summary" class="stat-strip"></div>
        <p id="devices-status" class="section-status" role="status" aria-live="polite">Loading linked devices…</p>
        <div id="devices-empty" class="empty-state" hidden>
          <h3>No devices are linked</h3>
          <p>Create a one-use link below and scan it with When Reset to attach your first device.</p>
        </div>
        <ul id="devices-list" class="device-list"></ul>
      </section>

      <section class="section-card" aria-labelledby="link-title">
        <div class="link-layout">
          <div class="link-copy">
            <p class="eyebrow">One-use link</p>
            <h2 id="link-title">Link another device</h2>
            <p>Create a five-minute QR code for When Reset. The existing private dashboard session authorizes creation, so the access key is never copied into the code.</p>
            <button id="link-button" class="button" type="button">Create device link</button>
            <p id="link-status" class="link-status" role="status" aria-live="polite">Nothing is uploaded until you confirm inside the app.</p>
          </div>
          <div id="link-result" class="link-result" hidden>
            <div id="qr-code" class="qr-code" aria-label="When Reset device link QR code"></div>
            <p id="link-expiry" class="link-expiry"></p>
            <a id="open-link" class="button" href="#">Open When Reset</a>
          </div>
        </div>
      </section>

      <div class="operations-grid">
        <article class="section-card">
          <div class="section-heading">
            <div>
              <h2>Collection runs</h2>
              <p>Coarse execution health without provider response bodies or account identifiers.</p>
            </div>
          </div>
          <div id="runs-summary" class="summary-list"></div>
        </article>
        <article id="passkey-settings" class="section-card">
          <div class="passkey-overview">
            <strong id="passkey-count" class="passkey-count" aria-label="Registered passkey count">—</strong>
            <div>
              <p class="eyebrow">Dashboard sign-in</p>
              <h2 id="passkey-settings-title">Passkeys</h2>
              <p id="passkey-summary">Passkey settings are loading.</p>
            </div>
          </div>
          <p class="passkey-copy">On Apple devices a passkey may be saved and synced by iCloud Keychain. This site cannot see whether a passkey is synced; removing passkeys here blocks them from this dashboard but does not remove saved copies from iCloud Keychain or another passkey provider.</p>
          <div class="passkey-controls">
            <div class="passkey-actions">
              <button id="add-passkey-button" class="button" type="button" disabled>Add passkey</button>
              <button id="remove-passkeys-button" class="button button--quiet button--danger" type="button" disabled>Remove all</button>
            </div>
            <p id="passkey-status" class="passkey-status" role="status" aria-live="polite"></p>
          </div>
        </article>
      </div>

      <section class="section-card" aria-labelledby="security-title">
        <div class="section-heading">
          <div>
            <h2 id="security-title">Security boundary</h2>
            <p>This monitor deliberately exposes less than the Worker knows.</p>
          </div>
        </div>
        <div class="security-grid">
          <article class="security-item">
            <h3>Credentials stay write-only</h3>
            <p>Provider tokens, encrypted envelopes, fingerprints, workspace identifiers, and raw provider identities are never included in dashboard responses.</p>
          </article>
          <article class="security-item">
            <h3>Your Worker is trusted</h3>
            <p>The Worker must temporarily decrypt provider sign-in material to collect usage. Operate it only in a Cloudflare account and deployment you control.</p>
          </article>
          <article class="security-item">
            <h3>Changes happen deliberately</h3>
            <p>Use When Reset to add accounts or renew a provider sign-in. From here you can remove a monitored account or unlink a device, and destructive steps ask for the recovery access key first.</p>
          </article>
        </div>
      </section>
    </div>
  </main>

  <footer class="footer">
    <span>When Reset self-hosted monitor</span>
    <span>${safeOrigin}</span>
  </footer>
  <div id="toast" class="toast" role="status" aria-live="polite" hidden></div>
  <script nonce="${safeNonce}">${DASHBOARD_SCRIPT}</script>
</body>
</html>`;
}

function escapeHTML(value: string): string {
  return value.replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "\"": "&quot;",
    "'": "&#39;",
  })[character] ?? character);
}
