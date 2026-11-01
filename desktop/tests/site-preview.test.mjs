import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parse, stringify } from 'yaml';
import { buildSitePreview } from '../scripts/site-preview.mjs';

const desktop = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const repo = path.dirname(desktop);
const sha256 = data => createHash('sha256').update(data).digest('hex');
const read = filename => fs.readFileSync(filename, 'utf8');
const cssURLs = css => [...css.matchAll(/url\(\s*['"]?([^)'"\s]+)['"]?\s*\)/g)].map(match => match[1]);

function temporaryDirectory(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'nightingale-preview-assets-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  return directory;
}

function bundledPath(root, relative) {
  assert.ok(!/^(?:[a-z][a-z\d+.-]*:|\/)/i.test(relative), `Asset must use a relative local path: ${relative}`);
  const filename = path.resolve(root, relative);
  assert.ok(filename.startsWith(root + path.sep), `Asset must stay inside its bundle: ${relative}`);
  assert.ok(fs.statSync(filename).isFile(), `Bundled asset is missing: ${relative}`);
  return filename;
}

function embeddedPreview(indexHTML) {
  const frame = [...indexHTML.matchAll(/<iframe\b[^>]*>/g)].find(match => /id="site-preview-frame"/.test(match[0]))?.[0];
  assert.ok(frame, 'The built app must contain its article preview iframe');
  const attributes = Object.fromEntries([...frame.matchAll(/([\w:-]+)="([^"]*)"/g)].map(match => [match[1], match[2]]));
  assert.equal(attributes.sandbox, 'allow-same-origin', 'The child may share its parent origin but must not execute scripts');
  assert.ok(!('src' in attributes), 'The preview must not load a sibling file that WKWebView isolates from its parent');
  assert.ok(attributes.srcdoc, 'The built iframe needs an embedded document');
  assert.doesNotMatch(attributes.srcdoc, /[<>"]|&(?!amp;|quot;|lt;|gt;)/, 'The entire child document must be escaped for its HTML attribute');
  assert.doesNotMatch(attributes.srcdoc, /__NIGHTINGALE_(?:PREVIEW_HTML|SITE_TITLE)__/);
  const entities = { amp: '&', quot: '"', lt: '<', gt: '>' };
  return attributes.srcdoc.replace(/&(amp|quot|lt|gt);/g, (_, entity) => entities[entity]);
}

test('site preview build packages compiled shared styles and complete offline fonts', async t => {
  const destination = path.join(temporaryDirectory(t), 'web');
  const result = buildSitePreview(destination);
  const css = read(path.join(destination, 'site-preview.css'));
  const html = read(path.join(destination, 'site-preview.html'));
  const fonts = read(path.join(destination, 'site-fonts.css'));
  const manifest = JSON.parse(read(path.join(destination, 'site-fonts/SOURCES.json')));

  await t.test('the built app embeds the exact resolved preview document in a scriptless same-origin frame', () => {
    assert.equal(embeddedPreview(read(path.join(destination, 'index.html'))), html);
  });

  await t.test('shared Sass is compiled and HTML references packaged styles', () => {
    assert.equal(result.stylesheet, 'site-preview.css');
    assert.ok(css.length > 1000, 'The theme stylesheet must not be a placeholder');
    assert.match(css, /\.page-header\b/);
    assert.match(css, /\.content\b/);
    assert.match(css, /font-family:[^;}]*Merriweather/);
    assert.doesNotMatch(css, /\{\{|\{%|^---|@(?:include|mixin|import)\b|\$[\w-]+/m);
    assert.doesNotMatch(html, /__NIGHTINGALE_SITE_TITLE__|\{\{|\{%/);
    const styles = [...html.matchAll(/<link\b[^>]*>/g)]
      .filter(match => /rel=["']stylesheet["']/.test(match[0]))
      .map(match => /href=["']([^"']+)["']/.exec(match[0])?.[1]);
    assert.deepEqual(styles.map(value => path.basename(value)).sort(), ['site-fonts.css', 'site-preview.css']);
    for (const stylesheet of styles) bundledPath(destination, stylesheet);
    assert.doesNotMatch(css + fonts + html, /@import\b/);
    for (const face of (css + fonts).matchAll(/@font-face\s*\{([^}]+)\}/g)) {
      for (const fontURL of cssURLs(face[1])) bundledPath(destination, fontURL);
    }
  });

  await t.test('every font resolves offline and matches its source hash and binary format', () => {
    assert.equal(sha256(fs.readFileSync(path.join(destination, 'site-fonts.css'))), manifest.stylesheet.bundledSHA256);
    const manifestFiles = new Set(manifest.fonts.map(font => `./site-fonts/${font.file}`));
    const references = cssURLs(fonts);
    assert.deepEqual(new Set(references), manifestFiles, 'CSS and manifest must describe the same fonts');
    assert.equal(new Set(manifest.fonts.map(font => font.sourceURL)).size, manifest.uniqueSourceURLs);
    assert.equal(manifestFiles.size, manifest.uniqueBundledFontFiles);
    for (const reference of references) bundledPath(destination, reference);
    for (const font of manifest.fonts) {
      assert.equal(new URL(font.sourceURL).hostname, 'fonts.gstatic.com');
      const data = fs.readFileSync(bundledPath(destination, `./site-fonts/${font.file}`));
      assert.ok(data.length >= 48, `${font.file} must contain a WOFF2 header`);
      assert.equal(data.subarray(0, 4).toString('ascii'), 'wOF2', `${font.file} must not be an HTML download error`);
      assert.equal(data.readUInt32BE(8), data.length, `${font.file} must have a valid declared length`);
      assert.ok(data.readUInt16BE(12) > 0, `${font.file} must contain font tables`);
      assert.equal(data.length, font.bytes);
      assert.equal(sha256(data), font.sha256, `${font.file} must match its recorded source`);
    }
  });

  await t.test('all site font families, weights, styles, and glyph ranges are retained', () => {
    const faces = [...fonts.matchAll(/@font-face\s*\{([^}]+)\}/g)].map(match => match[1]);
    assert.equal(faces.length, manifest.fontFaceRules);
    const coverage = new Map();
    for (const face of faces) {
      const family = /font-family:\s*['"]([^'"]+)['"]/.exec(face)?.[1];
      const style = /font-style:\s*([^;]+)/.exec(face)?.[1].trim();
      const weight = /font-weight:\s*([^;]+)/.exec(face)?.[1].trim();
      assert.match(face, /unicode-range:\s*U\+[0-9A-F]/i, 'Every font subset needs its glyph range');
      assert.ok(family && style && weight, 'A font face needs family, style, and weight');
      if (!coverage.has(family)) coverage.set(family, new Set());
      coverage.get(family).add(`${style} ${weight}`);
    }
    const required = {
      Merriweather: ['normal 400', 'normal 700', 'italic 400', 'italic 700'],
      'Open Sans': ['normal 400', 'normal 600', 'normal 700', 'italic 400', 'italic 600', 'italic 700'],
      Inconsolata: ['normal 400', 'normal 700'],
    };
    for (const [family, variants] of Object.entries(required)) {
      assert.ok(coverage.has(family), `Missing site font family: ${family}`);
      for (const variant of variants) assert.ok(coverage.get(family).has(variant), `Missing ${family} ${variant}`);
    }
  });

  await t.test('font redistribution licenses are copied intact', () => {
    assert.deepEqual(manifest.licenses.map(license => license.family).sort(), ['Inconsolata', 'Merriweather', 'Open Sans']);
    for (const license of manifest.licenses) {
      const data = fs.readFileSync(bundledPath(destination, `./site-fonts/${license.file}`));
      assert.equal(sha256(data), license.sha256);
      assert.equal(data.length, license.bytes);
      assert.match(data.toString('utf8'), /SIL OPEN FONT LICENSE Version 1\.1/);
      assert.match(data.toString('utf8'), /Copyright/);
    }
  });
});

test('preview compilation resolves and escapes configuration without mutating site sources', async t => {
  // A copied miniature repository exercises configuration edge cases safely.
  const fixture = temporaryDirectory(t);
  const fixtureDesktop = path.join(fixture, 'desktop');
  fs.mkdirSync(path.join(fixtureDesktop, 'scripts'), { recursive: true });
  fs.mkdirSync(path.join(fixtureDesktop, 'web'), { recursive: true });
  fs.cpSync(path.join(repo, 'css'), path.join(fixture, 'css'), { recursive: true });
  fs.cpSync(path.join(repo, '_sass'), path.join(fixture, '_sass'), { recursive: true });
  fs.copyFileSync(path.join(desktop, 'scripts/site-preview.mjs'), path.join(fixtureDesktop, 'scripts/site-preview.mjs'));
  for (const name of ['index.html', 'site-preview.html', 'site-fonts.css', 'site-fonts']) {
    fs.cpSync(path.join(desktop, 'web', name), path.join(fixtureDesktop, 'web', name), { recursive: true });
  }
  fs.symlinkSync(path.join(desktop, 'node_modules'), path.join(fixtureDesktop, 'node_modules'), 'dir');
  const config = parse(read(path.join(repo, '_config.yml')));
  config.title = 'A & B <notes> "quoted" \'single\' $&';
  config.baseurl = '/offline-preview';
  fs.writeFileSync(path.join(fixture, '_config.yml'), stringify(config));
  fs.appendFileSync(path.join(fixture, 'css/main.scss'), '\n.preview-build-regression { color: $brand-colour; }\n');
  const originalConfig = fs.readFileSync(path.join(repo, '_config.yml'));
  const originalSass = fs.readFileSync(path.join(repo, 'css/main.scss'));
  const { buildSitePreview: buildFixture } = await import(pathToFileURL(path.join(fixtureDesktop, 'scripts/site-preview.mjs')));
  const destination = path.join(fixture, 'output');
  const result = buildFixture(destination);
  assert.equal(result.title, config.title);
  const html = read(path.join(destination, 'site-preview.html'));
  const css = read(path.join(destination, 'site-preview.css'));
  assert.match(html, /name="site-title" content="A &amp; B &lt;notes&gt; &quot;quoted&quot; &#39;single&#39; \$&amp;"/);
  assert.doesNotMatch(html, /__NIGHTINGALE_SITE_TITLE__|<notes>/);
  assert.equal(embeddedPreview(read(path.join(destination, 'index.html'))), html);
  assert.match(css, /url\(["']?\/offline-preview\/images\/menu\.svg["']?\)/);
  assert.match(css, /\.preview-build-regression\{color:#3583d6\}/);
  assert.doesNotMatch(css, /\{\{|\{%|^---|\$brand-colour/m);
  assert.deepEqual(fs.readFileSync(path.join(repo, '_config.yml')), originalConfig);
  assert.deepEqual(fs.readFileSync(path.join(repo, 'css/main.scss')), originalSass);
});
