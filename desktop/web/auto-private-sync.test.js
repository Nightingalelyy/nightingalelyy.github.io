import test from 'node:test';
import assert from 'node:assert/strict';
import { createPrivateSyncScheduler } from './auto-private-sync.js';

const synced = () => ({ privateSync: { state: 'synced' } });
const flush = async () => { for (let index = 0; index < 6; index++) await Promise.resolve(); };
function deferred() { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }

class FakeClock {
  time = 0;
  serial = 0;
  timers = new Map();
  now = () => this.time;
  setTimer = (callback, delay) => { const id = ++this.serial; this.timers.set(id, { callback, at: this.time + delay }); return id; };
  clearTimer = id => { this.timers.delete(id); };
  async advance(milliseconds) {
    const target = this.time + milliseconds;
    for (let count = 0; count < 1000; count++) {
      await flush();
      const next = [...this.timers].filter(([, timer]) => timer.at <= target).sort((a, b) => a[1].at - b[1].at || a[0] - b[0])[0];
      if (!next) { this.time = Math.max(this.time, target); await flush(); return; }
      this.time = Math.max(this.time, next[1].at); this.timers.delete(next[0]); next[1].callback();
    }
    throw new Error('Scheduler did not yield.');
  }
}

function harness({ context = {}, run = synced, observer } = {}) {
  const clock = new FakeClock(), states = [], calls = [];
  const current = { connected: true, autoSyncEnabled: true, ready: true, recoveryMode: false, blocked: false, conflictCount: 0, online: true, ...context };
  const scheduler = createPrivateSyncScheduler({ getContext: () => current, run: () => { calls.push(clock.time); return run(); },
    now: clock.now, setTimer: clock.setTimer, clearTimer: clock.clearTimer,
    onState: state => { states.push(state); observer?.(state, scheduler, clock); },
  });
  return { scheduler, clock, current, states, calls, latest: () => states.at(-1) };
}

test('startup is single-flight and successful pulls repeat at 120 seconds', async () => {
  const h = harness();
  h.scheduler.start(); h.scheduler.start(); h.scheduler.wake(); h.scheduler.contextChanged(); h.scheduler.networkChanged(true);
  assert.equal(h.clock.timers.size, 1);
  await h.clock.advance(0);
  assert.deepEqual(h.calls, [0]);
  assert.deepEqual(h.latest(), { inFlight: false, phase: 'waiting', nextAttemptAt: 120_000 });
  await h.clock.advance(119_999); assert.equal(h.calls.length, 1);
  await h.clock.advance(1); assert.deepEqual(h.calls, [0, 120_000]);
});

test('saved edits debounce for eight seconds without resetting the pull deadline on status updates', async () => {
  const h = harness(); h.scheduler.start(); await h.clock.advance(0);
  h.scheduler.changed(); await h.clock.advance(4000); h.scheduler.changed();
  for (let index = 0; index < 7; index++) { await h.clock.advance(1000); h.scheduler.contextChanged(); }
  assert.equal(h.calls.length, 1); assert.equal(h.latest().nextAttemptAt, 12_000);
  await h.clock.advance(1000); assert.deepEqual(h.calls, [0, 12_000]);
  for (let index = 0; index < 119; index++) { await h.clock.advance(1000); h.scheduler.contextChanged(); }
  assert.equal(h.calls.length, 2);
  await h.clock.advance(1000); assert.deepEqual(h.calls, [0, 12_000, 132_000]);
});

test('edits made during a request get one follow-up after the save debounce', async () => {
  const pending = deferred(); let first = true;
  const h = harness({ run: () => first ? (first = false, pending.promise) : synced() });
  h.scheduler.start(); await h.clock.advance(0);
  await h.clock.advance(1000); h.scheduler.changed();
  h.scheduler.wake(); h.scheduler.networkChanged(true); h.scheduler.contextChanged();
  assert.equal(h.clock.timers.size, 0); assert.equal(h.calls.length, 1);
  pending.resolve(synced()); await flush();
  assert.equal(h.latest().nextAttemptAt, 9000);
  await h.clock.advance(7999); assert.equal(h.calls.length, 1);
  await h.clock.advance(1); assert.deepEqual(h.calls, [0, 9000]);
});

test('busy and conflict states pause attempts until context becomes idle without a network poll', async () => {
  const h = harness({ context: { blocked: true } }); h.scheduler.start();
  assert.equal(h.latest().phase, 'paused'); assert.equal(h.clock.timers.size, 0);
  await h.clock.advance(500_000); assert.deepEqual(h.calls, []);
  h.current.blocked = false; h.current.conflictCount = 1; h.scheduler.contextChanged();
  await h.clock.advance(500_000); assert.deepEqual(h.calls, []);
  h.current.conflictCount = 0; h.scheduler.contextChanged(); await h.clock.advance(0);
  assert.deepEqual(h.calls, [1_000_000]);
});

test('disconnected, not ready, recovery and disabled contexts never start a private operation', async () => {
  for (const context of [{ connected: false }, { autoSyncEnabled: false }, { ready: false }, { recoveryMode: true }]) {
    const h = harness({ context }); h.scheduler.start(); h.scheduler.changed(); h.scheduler.wake(); h.scheduler.networkChanged(true);
    await h.clock.advance(900_000);
    assert.deepEqual(h.calls, []); assert.equal(h.clock.timers.size, 0);
    Object.assign(h.current, { connected: true, autoSyncEnabled: true, ready: true, recoveryMode: false });
    h.scheduler.contextChanged(); await h.clock.advance(0); assert.deepEqual(h.calls, [900_000]);
  }
});

test('offline cancels timers and one actual reconnect causes an immediate attempt', async () => {
  const h = harness({ context: { online: false } }); h.scheduler.start();
  assert.equal(h.latest().phase, 'offline'); await h.clock.advance(30_000); assert.deepEqual(h.calls, []);
  h.scheduler.networkChanged(true); h.scheduler.networkChanged(true); await h.clock.advance(0);
  assert.deepEqual(h.calls, [30_000]);
  h.scheduler.networkChanged(false); assert.equal(h.clock.timers.size, 0);
  await h.clock.advance(600_000); assert.equal(h.calls.length, 1);
  h.scheduler.networkChanged(true); await h.clock.advance(0); assert.deepEqual(h.calls, [30_000, 630_000]);
});

test('thrown and returned private errors use bounded exponential backoff', async () => {
  let count = 0;
  const h = harness({ run: () => { count++; if (count % 3 === 1) throw new Error('Offline'); return { privateSync: { state: count % 3 === 2 ? 'error' : 'offline' } }; } });
  h.scheduler.start(); await h.clock.advance(0);
  let time = 0;
  for (const delay of [15_000, 30_000, 60_000, 120_000, 300_000, 300_000]) {
    time += delay;
    assert.equal(h.latest().phase, 'retrying'); assert.equal(h.latest().nextAttemptAt, time);
    h.scheduler.contextChanged(); h.scheduler.networkChanged(true);
    await h.clock.advance(delay - 1); assert.equal(h.calls.at(-1) < time, true);
    await h.clock.advance(1); assert.equal(h.calls.at(-1), time);
  }
});

test('reconnection during a failed request retries once afterward, while success needs no duplicate request', async () => {
  for (const success of [true, false]) {
    const pending = deferred(); let first = true;
    const h = harness({ run: () => first ? (first = false, pending.promise) : synced() });
    h.scheduler.start(); await h.clock.advance(0);
    h.scheduler.networkChanged(false); await h.clock.advance(1000);
    h.scheduler.networkChanged(true); h.scheduler.networkChanged(true);
    assert.equal(h.calls.length, 1);
    if (success) pending.resolve(synced()); else pending.reject(new Error('The old connection failed'));
    await flush(); await h.clock.advance(0);
    assert.deepEqual(h.calls, success ? [0] : [0, 1000]);
    assert.equal(h.latest().nextAttemptAt, 121_000);
  }
});

test('stop and disable during a request discard stale completions without scheduling', async () => {
  for (const action of ['stop', 'disable', 'disconnect']) {
    const pending = deferred(), h = harness({ run: () => pending.promise });
    h.scheduler.start(); await h.clock.advance(0);
    if (action === 'stop') h.scheduler.stop();
    else { h.current[action === 'disable' ? 'autoSyncEnabled' : 'connected'] = false; h.scheduler.contextChanged(); }
    assert.equal(h.latest().phase, 'off'); assert.equal(h.latest().inFlight, true);
    pending.resolve({ privateSync: { state: 'error' } }); await flush();
    assert.deepEqual(h.latest(), { phase: 'off', inFlight: false, nextAttemptAt: null });
    await h.clock.advance(900_000); assert.equal(h.calls.length, 1); assert.equal(h.clock.timers.size, 0);
  }
});

test('repeated wake events preserve backoff, while reconnection and manual completion reset it', async () => {
  const h = harness({ run: () => ({ privateSync: { state: 'error' } }) });
  h.scheduler.start(); await h.clock.advance(0);
  for (let index = 0; index < 14; index++) { await h.clock.advance(1000); h.scheduler.wake(); assert.equal(h.latest().nextAttemptAt, 15_000); }
  assert.deepEqual(h.calls, [0]); await h.clock.advance(1000);
  assert.deepEqual(h.calls, [0, 15_000]); assert.equal(h.latest().nextAttemptAt, 45_000);
  h.scheduler.wake(); assert.equal(h.latest().nextAttemptAt, 45_000);
  h.scheduler.networkChanged(false); h.scheduler.networkChanged(true); await h.clock.advance(0);
  assert.deepEqual(h.calls, [0, 15_000, 15_000]); assert.equal(h.latest().nextAttemptAt, 30_000);
  await h.clock.advance(15_000); assert.equal(h.latest().nextAttemptAt, 60_000);
  h.scheduler.manualCompleted({ privateSync: { state: 'error' } }); assert.equal(h.latest().nextAttemptAt, 45_000);
});

test('reenabling during an older request waits for it, then starts one fresh request', async () => {
  const pending = deferred(); let first = true;
  const h = harness({ run: () => first ? (first = false, pending.promise) : synced() });
  h.scheduler.start(); await h.clock.advance(0);
  h.current.autoSyncEnabled = false; h.scheduler.contextChanged();
  h.current.autoSyncEnabled = true; h.scheduler.contextChanged();
  await h.clock.advance(1000); assert.equal(h.calls.length, 1);
  pending.resolve({ privateSync: { state: 'offline' } }); await flush(); await h.clock.advance(0);
  assert.deepEqual(h.calls, [0, 1000]); assert.equal(h.latest().phase, 'waiting');
});

test('manual completion resets retry scheduling and supersedes an older auto result', async () => {
  const pending = deferred(), h = harness({ run: () => pending.promise });
  h.scheduler.start(); await h.clock.advance(0);
  await h.clock.advance(5000); h.scheduler.manualCompleted(synced());
  pending.resolve({ privateSync: { state: 'error' } }); await flush();
  assert.equal(h.latest().phase, 'waiting'); assert.equal(h.latest().nextAttemptAt, 125_000);
  h.scheduler.manualCompleted({ privateSync: { state: 'offline' } });
  assert.equal(h.latest().phase, 'retrying'); assert.equal(h.latest().nextAttemptAt, 20_000);
});

test('a pending-change flag is edge triggered, so status refreshes cannot postpone it', async () => {
  const h = harness(); h.scheduler.start(); await h.clock.advance(0);
  h.current.hasPendingChanges = true; h.scheduler.contextChanged();
  for (let index = 0; index < 7; index++) { await h.clock.advance(1000); h.scheduler.contextChanged(); }
  assert.equal(h.latest().nextAttemptAt, 8000); await h.clock.advance(1000);
  assert.deepEqual(h.calls, [0, 8000]);
  h.scheduler.contextChanged(); assert.equal(h.latest().nextAttemptAt, 128_000);
});

test('reentrant status rendering and overdue deadlines cannot starve a scheduled attempt', async () => {
  const h = harness({ observer: (_, scheduler, clock) => { clock.time++; scheduler.contextChanged(); } });
  h.scheduler.start(); assert.equal(h.clock.timers.size, 1);
  await h.clock.advance(0); assert.equal(h.calls.length, 1);
  assert.ok(h.states.length < 10);
});

test('stopping from a state observer cannot start an already-cancelled request', async () => {
  const h = harness({ observer: (state, scheduler) => { if (state.phase === 'syncing') scheduler.stop(); } });
  h.scheduler.start(); await h.clock.advance(0);
  assert.deepEqual(h.calls, []); assert.equal(h.clock.timers.size, 0);
  assert.deepEqual(h.latest(), { phase: 'off', inFlight: false, nextAttemptAt: null });
});

test('automatic triggers call only the supplied private operation', async () => {
  const calls = [], privateAPI = { syncPrivateDrafts() { calls.push('private'); return synced(); }, processQueue() { throw new Error('Publication must stay manual'); }, queuePublish() { throw new Error('Publication must stay manual'); } };
  const h = harness({ run: () => privateAPI.syncPrivateDrafts() });
  h.scheduler.start(); await h.clock.advance(0); h.scheduler.changed(); await h.clock.advance(8000);
  h.scheduler.networkChanged(false); h.scheduler.networkChanged(true); await h.clock.advance(0);
  h.scheduler.wake(); await h.clock.advance(0);
  assert.deepEqual(calls, ['private', 'private', 'private', 'private']);
});
