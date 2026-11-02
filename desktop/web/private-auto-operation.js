// Network work stays outside the editor lock. Only the latest local save and
// native optimistic finish share a brief lock before applying a fresh snapshot.
export function createPrivateAutoOperation({ begin, finish, cancel, saveActive, isEnabled, isIdle, setLocked, protectedPaths,
  applySnapshot, applyStatus = () => {}, getGeneration = () => 0, wait = () => new Promise(resolve => setTimeout(resolve, 50)) }) {
  let active = null;
  function current(job) { return active === job && !job.cancelled && job.generation === getGeneration() && isEnabled(); }
  function cancelNative(job) {
    if (!job.cancelRequest) job.cancelRequest = Promise.resolve().then(cancel).catch(error => { job.cancelRequest = null; throw error; });
    return job.cancelRequest;
  }
  async function cancelCurrent() {
    const job = active;
    if (!job) return;
    job.cancelled = true;
    // Waiting for a short local finish is safe; never wait for network here.
    await Promise.all([cancelNative(job), job.localDone || Promise.resolve()]);
  }
  return {
    isRunning: () => active !== null,
    cancel: cancelCurrent,
    async run() {
      if (active) throw new Error('Automatic private sync is already running.');
      const job = { generation: getGeneration(), cancelled: false, finished: false, localDone: null, cancelRequest: null };
      active = job;
      let unlock = false, finishLocal;
      try {
        await saveActive();
        while (current(job) && !isIdle()) await wait();
        if (!current(job)) return { cancelled: true };
        const prepared = await begin(protectedPaths());
        if (!current(job)) return { cancelled: true };
        if (prepared.cancelled) return prepared;
        if (!prepared.pendingToken) { job.finished = true; applyStatus(prepared); return prepared; }
        while (current(job) && !isIdle()) await wait();
        if (!current(job)) return { cancelled: true };
        job.localDone = new Promise(resolve => { finishLocal = resolve; });
        setLocked(true); unlock = true;
        await saveActive();
        if (!current(job)) return { cancelled: true };
        const snapshot = await finish(prepared.pendingToken, protectedPaths());
        job.finished = true;
        if (current(job)) applySnapshot(snapshot);
        return snapshot;
      } finally {
        if (unlock) setLocked(false);
        finishLocal?.();
        try { if (!job.finished) await cancelNative(job); }
        finally { if (active === job) active = null; }
      }
    },
  };
}

export function preservePrivateActive(snapshot, active) {
  if (!active || !Array.isArray(snapshot?.articles)) return snapshot;
  return { ...snapshot, articles: snapshot.articles.map(article => article.path === active.path ? { ...article, rawContent: active.rawContent, revision: active.revision } : article) };
}
