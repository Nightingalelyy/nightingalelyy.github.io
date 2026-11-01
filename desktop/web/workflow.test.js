import test from 'node:test';
import assert from 'node:assert/strict';
import { publicationView, mergePublicationRecords, validationSummary, issueLocation, compareHistoryVersions, safeExternalURL, workspaceRecovery } from './workflow.js';

test('publication states distinguish local edits from the exact uploaded version', () => {
  const item = { path: '_docs/article.md', revision: 'current', isDraft: false, isQueued: false };
  for (const [status, label] of [['uploaded', 'Uploaded'], ['building', 'Building'], ['live', 'Live'], ['failed', 'Failed']]) {
    const publication = { status, sourceSHA256: 'current', matchesCurrentRevision: true };
    assert.equal(publicationView({ ...item, publication }).label, label);
    const draft = publicationView({ ...item, isDraft: true, revision: 'new-draft', publication });
    assert.equal(draft.label, 'Saved locally');
    assert.equal(draft.matchesCurrent, false);
    assert.match(draft.message, /Earlier version/);
    assert.match(draft.message, /latest edits remain local/);
    const dirty = publicationView({ ...item, publication }, { dirty: true });
    assert.equal(dirty.label, 'Editing');
    assert.equal(dirty.matchesCurrent, false);
  }
  assert.equal(publicationView({ ...item, isQueued: true, publication: { status: 'live', sourceSHA256: 'current' } }).label, 'Queued');
  assert.equal(publicationView(item).label, 'On GitHub');
});

test('a stale publication poll cannot replace draft content, revision, queue or selection state', () => {
  const article = { path: '_docs/a.md', rawContent: 'new local text', revision: 'new', isDraft: true, isQueued: false, selected: true };
  const untouched = { path: '_docs/b.md', rawContent: 'other text', revision: 'other' };
  const patch = { path: '_docs/a.md', status: 'live', sourceSHA256: 'old', matchesCurrentRevision: true, rawContent: 'server text' };
  const [merged, other] = mergePublicationRecords([article, untouched], [patch]);
  assert.equal(merged.rawContent, 'new local text');
  assert.equal(merged.revision, 'new');
  assert.equal(merged.isDraft, true);
  assert.equal(merged.isQueued, false);
  assert.equal(merged.selected, true);
  assert.equal(merged.publication.matchesCurrentRevision, false);
  assert.equal(publicationView(merged).label, 'Saved locally');
  assert.equal(other, untouched);
  assert.equal(article.publication, undefined);
});

test('unknown deployment remains unverified and newer remote source is not called live', () => {
  const old = { status: 'live', sourceSHA256: 'older', message: 'The uploaded version is live.' };
  const view = publicationView({ revision: 'newer', isDraft: false, publication: old });
  assert.equal(view.label, 'On GitHub');
  assert.match(view.message, /^Earlier version:/);
  assert.doesNotMatch(view.message, /remain local/);
  const unknown = publicationView({ revision: 'same', publication: { status: 'unknown', sourceSHA256: 'same' } });
  assert.equal(unknown.label, 'Status unavailable');
  assert.equal(unknown.pending, false);
  assert.match(unknown.message, /could not be confirmed/);
});

test('warnings require an explicitly successful validation; errors always block', () => {
  assert.deepEqual(validationSummary({ ok: true, issues: [] }), { canPublish: true, issues: [], errors: [], warnings: [] });
  const warning = { severity: 'warning', code: 'empty_body', path: '_docs/a.md', line: 9, message: 'The article body is empty.' };
  assert.equal(validationSummary({ ok: true, issues: [warning] }).canPublish, true);
  assert.equal(validationSummary({ ok: false, issues: [warning] }).canPublish, false);
  assert.equal(validationSummary({ ok: true, issues: [{ ...warning, severity: 'error' }] }).canPublish, false);
  assert.equal(validationSummary(null).canPublish, false);
});

test('validation lines navigate frontmatter fields and the correct Markdown body line', () => {
  const raw = '---\r\ntitle: A\r\ndate: 2026-11-02\r\ncategory: Test\r\norder: 1\r\ncustom: keep\r\n---\r\n\r\nfirst\r\nsecond';
  assert.deepEqual(issueLocation({ line: 2 }, raw), { kind: 'field', field: 'title', line: 2 });
  assert.deepEqual(issueLocation({ line: 6 }, raw), { kind: 'metadata', field: undefined, line: 6 });
  assert.deepEqual(issueLocation({ line: 9 }, raw), { kind: 'body', line: 9, bodyLine: 2 });
  assert.deepEqual(issueLocation({ line: 10 }, raw), { kind: 'body', line: 10, bodyLine: 3 });
  assert.deepEqual(issueLocation({ line: 1 }, 'plain body'), { kind: 'body', line: 1, bodyLine: 1 });
  assert.deepEqual(issueLocation({ line: 0 }, raw), { kind: 'unknown' });
});

test('history comparison highlights only changed lines and supports discarded article recovery', () => {
  const comparison = compareHistoryVersions('title\nold line\nend', 'title\nnew line\nend');
  assert.equal(comparison.exact, true);
  assert.equal(comparison.added, 1);
  assert.equal(comparison.removed, 1);
  assert.deepEqual(comparison.left.map((row) => row.kind), ['unchanged', 'removed', 'unchanged']);
  assert.deepEqual(comparison.right.map((row) => row.kind), ['unchanged', 'added', 'unchanged']);
  const discarded = compareHistoryVersions(null, 'Recovered article');
  assert.deepEqual(discarded.left, []);
  assert.equal(discarded.added, 1);
  assert.equal(discarded.right[0].text, 'Recovered article');
  const large = compareHistoryVersions('one\ntwo\nthree', 'a\nb\nc', 4);
  assert.equal(large.exact, false);
  assert.equal(large.added, null);
  assert.equal(large.left[0].text, 'one');
});

test('publication links reject script schemes, credentials and relative URLs', () => {
  assert.equal(safeExternalURL('https://nightingalelyy.github.io/article/'), 'https://nightingalelyy.github.io/article/');
  assert.equal(safeExternalURL('https://github.com/Nightingalelyy/nightingalelyy.github.io/actions/runs/1'), 'https://github.com/Nightingalelyy/nightingalelyy.github.io/actions/runs/1');
  for (const value of ['javascript:alert(1)', 'file:///tmp/data', '/article/', 'https://user:secret@github.com/', '', undefined]) assert.equal(safeExternalURL(value), null);
});

test('corrupt-workspace recovery is explicit and a successful restore clears read-only mode', () => {
  const corrupt = workspaceRecovery({ recovery: { needsRestore: true, message: 'Restore a backup to recover local drafts.' }, articles: [{ path: '_docs/a.md' }] });
  assert.equal(corrupt.needsRestore, true);
  assert.equal(corrupt.message, 'Restore a backup to recover local drafts.');
  assert.match(workspaceRecovery({ recovery: { needsRestore: true } }).message, /Restore a backup/);
  const restored = workspaceRecovery({ recovery: { needsRestore: false, message: 'Old recovery message' } });
  assert.deepEqual(restored, { needsRestore: false, message: '' });
  assert.deepEqual(workspaceRecovery({ recovery: { automaticBackupDirectory: '/private/backups' } }), { needsRestore: false, message: '' });
});
