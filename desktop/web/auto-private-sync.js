const SAVE_DEBOUNCE_MS = 8_000;
const PULL_INTERVAL_MS = 120_000;
const RETRY_DELAYS_MS = [15_000, 30_000, 60_000, 120_000, 300_000];

// This scheduler has no publication or transport API. Its injected operation
// must transfer private drafts only, and apply its result before resolving.
export function createPrivateSyncScheduler({
  getContext,
  run,
  onState = () => {},
  now = () => Date.now(),
  setTimer = (callback, delay) => setTimeout(callback, delay),
  clearTimer = handle => clearTimeout(handle),
}) {
  if (typeof getContext !== 'function' || typeof run !== 'function') throw new TypeError('Private sync needs a context and private operation.');
  let started = false;
  let generation = 0;
  let changeVersion = 0;
  let eligibleBefore = false;
  let pendingBefore = false;
  let networkOverride;
  let onlineBefore;
  let networkVersion = 0;
  let inFlight = null;
  let timer = null;
  let timerVersion = 0;
  let urgentAt = null;
  let changedAt = null;
  let pullAt = null;
  let retryAt = null;
  let failures = 0;
  let publishedState = null;

  function context() {
    const value = getContext() || {};
    return { ...value, online: networkOverride ?? (value.online !== false) };
  }

  function emit(phase, nextAttemptAt = null) {
    const state = { inFlight: inFlight !== null, nextAttemptAt, phase };
    if (publishedState && Object.keys(state).every(key => state[key] === publishedState[key])) return;
    publishedState = state;
    // A display callback must not strand an operation or alter scheduling.
    try { onState({ ...state }); } catch { /* The next observer update can recover. */ }
  }

  function cancelTimer() {
    timerVersion++;
    if (timer) clearTimer(timer.handle);
    timer = null;
  }

  function clearDeadlines() {
    urgentAt = changedAt = pullAt = retryAt = null;
    failures = 0;
  }

  function failed(result) {
    return ['error', 'offline'].includes(result?.privateSync?.state);
  }

  function complete(result, requestChangeVersion, requestNetworkVersion = networkVersion) {
    if (failed(result)) {
      if (requestNetworkVersion !== networkVersion) {
        // The failed request began on an older connection. Try the newly
        // available network once, without overlapping the old operation.
        failures = 0; retryAt = null; urgentAt = now(); return;
      }
      retryAt = now() + RETRY_DELAYS_MS[Math.min(failures, RETRY_DELAYS_MS.length - 1)];
      failures++;
      urgentAt = now();
      return;
    }
    failures = 0;
    retryAt = null;
    urgentAt = null;
    pullAt = now() + PULL_INTERVAL_MS;
    if (changeVersion === requestChangeVersion) changedAt = null;
  }

  function schedule(at) {
    const deadline = at;
    if (timer?.at === deadline) return;
    cancelTimer();
    const ticket = timerVersion;
    timer = { at: deadline, handle: setTimer(() => {
      if (ticket !== timerVersion) return;
      timer = null;
      attempt();
    }, Math.max(0, deadline - now())) };
  }

  function inspect() {
    const value = context();
    const eligible = started && value.connected === true && value.autoSyncEnabled === true && value.ready === true && !value.recoveryMode;
    if (eligible !== eligibleBefore) {
      generation++;
      cancelTimer();
      clearDeadlines();
      eligibleBefore = eligible;
      if (eligible) urgentAt = now();
    }
    if (value.hasPendingChanges === true && !pendingBefore) {
      changeVersion++;
      changedAt = now() + SAVE_DEBOUNCE_MS;
    }
    pendingBefore = value.hasPendingChanges === true;
    onlineBefore = value.online;
    return { value, eligible };
  }

  function reconcile() {
    const { value, eligible } = inspect();
    if (!eligible) {
      cancelTimer();
      emit(started && value.connected && value.autoSyncEnabled && value.recoveryMode ? 'paused' : 'off');
      return;
    }
    if (inFlight) { cancelTimer(); emit(value.online ? 'syncing' : 'offline'); return; }
    if (!value.online) { cancelTimer(); emit('offline'); return; }
    if (value.blocked || Number(value.conflictCount) > 0) { cancelTimer(); emit('paused'); return; }
    const deadlines = [urgentAt, changedAt, pullAt].filter(value => value !== null);
    const due = deadlines.length ? Math.min(...deadlines) : now() + PULL_INTERVAL_MS;
    if (!deadlines.length) pullAt = due;
    const next = Math.max(due, retryAt ?? -Infinity);
    schedule(next);
    emit(retryAt !== null ? 'retrying' : 'waiting', timer.at);
  }

  function attempt() {
    const { value, eligible } = inspect();
    if (!eligible || inFlight || !value.online || value.blocked || Number(value.conflictCount) > 0) { reconcile(); return; }
    const request = { generation, changeVersion, networkVersion };
    inFlight = request;
    // This attempt consumes the current wake request. A subsequent saved edit
    // keeps its own deadline and receives another attempt after this one ends.
    urgentAt = null;
    emit('syncing');
    if (request.generation !== generation || !started) { inFlight = null; reconcile(); return; }
    let operation;
    try { operation = run(); } catch (error) { operation = Promise.reject(error); }
    Promise.resolve(operation).then(result => {
      if (request.generation === generation) complete(result, request.changeVersion, request.networkVersion);
    }, () => {
      if (request.generation === generation) complete({ privateSync: { state: 'error' } }, request.changeVersion, request.networkVersion);
    }).finally(() => {
      if (inFlight === request) inFlight = null;
      reconcile();
    });
  }

  return Object.freeze({
    start() { if (started) return; started = true; reconcile(); },
    stop() { started = false; generation++; eligibleBefore = false; cancelTimer(); clearDeadlines(); emit('off'); },
    changed() { changeVersion++; changedAt = now() + SAVE_DEBOUNCE_MS; reconcile(); },
    contextChanged() { reconcile(); },
    networkChanged(online) {
      const previous = onlineBefore ?? context().online;
      networkOverride = online === true;
      if (networkOverride && previous === false) {
        networkVersion++;
        failures = 0; retryAt = null;
        if (!inFlight) urgentAt = now();
      }
      reconcile();
    },
    wake() {
      // Repeated focus/visibility events must not bypass failure backoff.
      if (!inFlight) urgentAt = now();
      reconcile();
    },
    manualCompleted(result) {
      // A later explicit operation supersedes any older background completion.
      generation++;
      failures = 0; retryAt = null;
      complete(result, changeVersion);
      reconcile();
    },
  });
}
