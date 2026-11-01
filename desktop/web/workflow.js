export function publicationView(item, { dirty = false } = {}) {
  const publication = item?.publication || null;
  const labels = { uploaded: 'Uploaded', building: 'Building', live: 'Live', failed: 'Failed', unknown: 'Status unavailable' };
  const status = publication?.status;
  const matchesCurrent = Boolean(publication?.sourceSHA256 ? publication.sourceSHA256 === item?.revision : publication?.matchesCurrentRevision) && !dirty;
  let label = dirty ? 'Editing' : item?.isQueued ? 'Queued' : item?.isDraft ? 'Saved locally' : 'On GitHub';
  if (!dirty && !item?.isQueued && matchesCurrent && labels[status]) label = labels[status];
  let message = '';
  if (publication) {
    const messages = {
      uploaded: 'Uploaded to GitHub. Waiting for the website build.',
      building: 'GitHub is building the website.',
      live: 'This uploaded version is live on your website.',
      failed: 'The website build failed. Your uploaded article is still on GitHub.',
      unknown: 'Website publication could not be confirmed yet.',
    };
    message = publication.message || messages[status] || messages.unknown;
    if (!matchesCurrent) message = `Earlier version: ${message}${item?.isDraft || dirty ? ' Your latest edits remain local.' : ''}`;
  }
  return { label, status, message, matchesCurrent, pending: status === 'uploaded' || status === 'building', tone: status === 'failed' ? 'error' : status === 'live' ? 'success' : status === 'unknown' ? 'muted' : 'progress' };
}

export function mergePublicationRecords(articles, publications) {
  const patches = new Map(publications.filter((publication) => publication?.path).map((publication) => [publication.path, publication]));
  return articles.map((article) => {
    const publication = patches.get(article.path);
    return publication ? { ...article, publication: { ...publication, matchesCurrentRevision: publication.sourceSHA256 === article.revision } } : article;
  });
}

export function validationSummary(result) {
  const issues = Array.isArray(result?.issues) ? result.issues : [];
  const errors = issues.filter((issue) => issue.severity === 'error');
  const warnings = issues.filter((issue) => issue.severity !== 'error');
  return { issues, errors, warnings, canPublish: result?.ok === true && errors.length === 0 };
}

export function issueLocation(issue, rawContent) {
  const line = Number(issue?.line);
  if (!Number.isInteger(line) || line < 1) return { kind: 'unknown' };
  const lines = String(rawContent || '').split(/\r?\n/);
  const closing = lines[0] === '---' ? lines.findIndex((value, index) => index > 0 && (value === '---' || value === '...')) : -1;
  if (closing >= 0 && line <= closing + 1) {
    const field = lines[line - 1]?.match(/^(title|author|date|category|order)\s*:/)?.[1];
    return { kind: field ? 'field' : 'metadata', field, line };
  }
  return { kind: 'body', line, bodyLine: Math.max(1, line - (closing >= 0 ? closing + 1 : 0)) };
}

export function compareHistoryVersions(current, selected, maxCells = 250000) {
  const left = current == null ? [] : String(current).split('\n');
  const right = String(selected || '').split('\n');
  const leftRows = left.map((text, index) => ({ number: index + 1, text, kind: 'unchanged' }));
  const rightRows = right.map((text, index) => ({ number: index + 1, text, kind: 'unchanged' }));
  if ((left.length + 1) * (right.length + 1) > maxCells) return { left: leftRows, right: rightRows, exact: false, added: null, removed: null };
  const width = right.length + 1;
  const lengths = new Uint32Array((left.length + 1) * width);
  for (let i = left.length - 1; i >= 0; i--) {
    for (let j = right.length - 1; j >= 0; j--) {
      lengths[i * width + j] = left[i] === right[j] ? 1 + lengths[(i + 1) * width + j + 1] : Math.max(lengths[(i + 1) * width + j], lengths[i * width + j + 1]);
    }
  }
  let i = 0, j = 0, removed = 0, added = 0;
  while (i < left.length || j < right.length) {
    if (i < left.length && j < right.length && left[i] === right[j]) { i++; j++; }
    else if (i < left.length && (j === right.length || lengths[(i + 1) * width + j] >= lengths[i * width + j + 1])) { leftRows[i++].kind = 'removed'; removed++; }
    else { rightRows[j++].kind = 'added'; added++; }
  }
  return { left: leftRows, right: rightRows, exact: true, added, removed };
}

export function safeExternalURL(value) {
  if (!value) return null;
  try {
    const url = new URL(value);
    return ['https:', 'http:'].includes(url.protocol) && !url.username && !url.password ? url.href : null;
  } catch { return null; }
}

export function workspaceRecovery(snapshot) {
  const needsRestore = snapshot?.recovery?.needsRestore === true;
  return { needsRestore, message: needsRestore ? String(snapshot.recovery.message || 'Your local workspace could not be read. Restore a backup to continue editing.') : '' };
}
