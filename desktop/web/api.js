export async function call(method, params = {}) {
  const started = Date.now();
  while (!window.native?.call) {
    if (Date.now() - started > 10000) {
      throw new Error('Open Nightingale Writer on your Mac to access your local library.');
    }
    await new Promise((resolve) => setTimeout(resolve, 30));
  }
  return window.native.call(method, params);
}

export const api = {
  bootstrap: () => call('bootstrap'),
  status: () => call('status'),
  read: (path) => call('readArticle', { path }),
  save: (path, rawContent, expectedRevision) => call('saveDraft', { path, rawContent, expectedRevision }),
  create: (path, rawContent) => call('createArticle', { path, rawContent }),
  refresh: () => call('refresh'),
  queue: (path) => call('queuePublish', { path }),
  process: () => call('processQueue'),
  cancel: (path) => call('cancelQueued', { path }),
  resolve: (path, rawContent) => call('resolveConflict', { path, rawContent }),
  discard: (path) => call('discardDraft', { path }),
  chooseImage: () => call('chooseImage'),
  readAsset: (path) => call('readAsset', { path }),
};
