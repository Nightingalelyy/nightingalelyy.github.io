import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { compileString } from 'sass';
import { parse } from 'yaml';

const desktop = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const repo = path.dirname(desktop);

// Compile the same source as Jekyll, so a theme change reaches the next app build.
export function buildSitePreview(destination) {
  const sourcePath = path.join(repo, 'css/main.scss');
  const config = parse(fs.readFileSync(path.join(repo, '_config.yml'), 'utf8'));
  const source = fs.readFileSync(sourcePath, 'utf8')
    .replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, '')
    .replace(/\{\{\s*site\.baseurl\s*\}\}/g, config.baseurl || '');
  const result = compileString(source, {
    url: pathToFileURL(sourcePath),
    loadPaths: [path.join(repo, '_sass')],
    style: 'compressed',
    // The Jekyll theme still uses legacy imports and color functions.
    silenceDeprecations: ['import', 'global-builtin', 'color-functions', 'slash-div'],
  });
  fs.mkdirSync(destination, { recursive: true });
  fs.writeFileSync(path.join(destination, 'site-preview.css'), result.css);
  const title = String(config.title || '').replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);
  const previewHTML = fs.readFileSync(path.join(desktop, 'web/site-preview.html'), 'utf8').replace('__NIGHTINGALE_SITE_TITLE__', () => title);
  fs.writeFileSync(path.join(destination, 'site-preview.html'), previewHTML);
  const embeddedPreviewHTML = previewHTML.replace(/[&"<>]/g, char => ({ '&': '&amp;', '"': '&quot;', '<': '&lt;', '>': '&gt;' })[char]);
  fs.writeFileSync(path.join(destination, 'index.html'), fs.readFileSync(path.join(desktop, 'web/index.html'), 'utf8').replace('__NIGHTINGALE_PREVIEW_HTML__', () => embeddedPreviewHTML));
  fs.copyFileSync(path.join(desktop, 'web/site-fonts.css'), path.join(destination, 'site-fonts.css'));
  fs.cpSync(path.join(desktop, 'web/site-fonts'), path.join(destination, 'site-fonts'), { recursive: true });
  return { title: config.title || '', stylesheet: 'site-preview.css' };
}
