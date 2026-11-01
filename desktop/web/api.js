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
  createCategory: (name) => call('createCategory', { name }),
  refresh: () => call('refresh'),
  queue: (path, expectedRevision) => call('queuePublish', { path, ...(expectedRevision != null ? { expectedRevision } : {}) }),
  process: () => call('processQueue'),
  cancel: (path) => call('cancelQueued', { path }),
  resolve: (path, rawContent) => call('resolveConflict', { path, rawContent }),
  discard: (path) => call('discardDraft', { path }),
  chooseImage: () => call('chooseImage'),
  readAsset: (path) => call('readAsset', { path }),
  highlightCode: (blocks) => call('highlightCode', { blocks }),
  validatePublication: (path, expectedRevision) => call('validatePublication', { path, ...(expectedRevision != null ? { expectedRevision } : {}) }),
  pollPublicationStatus: () => call('pollPublicationStatus'),
  listHistory: (path) => call('listHistory', path ? { path } : {}),
  readHistory: (id, path) => call('readHistory', { id, path }),
  restoreHistory: (id, path, expectedRevision) => call('restoreHistory', { id, path, ...(expectedRevision != null ? { expectedRevision } : {}) }),
  exportBackup: () => call('exportBackup'),
  chooseBackup: () => call('chooseBackup'),
  restoreBackup: (token, expectedStateRevision) => call('restoreBackup', { token, ...(expectedStateRevision != null ? { expectedStateRevision } : {}) }),
  cancelBackupImport: () => call('cancelBackupImport'),
  openExternal: (url) => call('openExternal', { url }),
};
