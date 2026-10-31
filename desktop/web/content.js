import { parseDocument } from 'yaml';

export function parseArticle(rawContent) {
  const raw = String(rawContent || '');
  const match = raw.match(/^(---\r?\n)([\s\S]*?)(\r?\n---(?:\r?\n|$))([\s\S]*)$/);
  const header = match ? match[2] : '';
  const doc = parseDocument(header, { prettyErrors: false });
  if (doc.errors.length) throw new Error(`This article's metadata needs attention: ${doc.errors[0].message}`);
  const meta = doc.toJS() || {};
  if (typeof meta !== 'object' || Array.isArray(meta)) throw new Error('Article metadata must contain named fields.');
  return { raw, doc, meta, header, prefix: match ? match[1] + match[2] + match[3] : '', hasHeader: Boolean(match), body: match ? match[4] : raw };
}

export function normalizeDateForInput(value, fallback = '') {
  const match = String(value || '').match(/^(\d{4})-(\d{1,2})-(\d{1,2})(?=[T\s]|$)/);
  return match ? `${match[1]}-${match[2].padStart(2, '0')}-${match[3].padStart(2, '0')}` : fallback;
}

export function editorFields(parsed, path, defaultDate = '') {
  const fields = { title: String(parsed.meta.title ?? '') };
  if (path.startsWith('_docs/')) {
    fields.author = String(parsed.meta.author ?? '');
    fields.date = normalizeDateForInput(parsed.meta.date, defaultDate);
    fields.category = String(parsed.meta.category || 'Articles');
    fields.order = parsed.meta.order == null ? '' : String(parsed.meta.order);
  }
  return fields;
}

// Display normalization must never rewrite source values unless that field was edited.
export function serializeArticle(parsed, fields, body, initialFields) {
  const changes = Object.entries(fields).filter(([name, value]) => String(initialFields[name] ?? '') !== String(value ?? ''));
  if (!changes.length) return parsed.prefix + body;
  const doc = parsed.doc.clone();
  for (const [name, value] of changes) {
    if (name === 'order') {
      if (value === '') doc.delete(name);
      else {
        const number = Number(value);
        if (!Number.isFinite(number) || number < 0) throw new Error('Navigation order must be zero or a positive number.');
        doc.set(name, number);
      }
    } else doc.set(name, value);
  }
  return `---\n${doc.toString().replace(/\n$/, '')}\n---\n${body}`;
}
