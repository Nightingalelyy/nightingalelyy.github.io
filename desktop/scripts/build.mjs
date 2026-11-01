import { build } from 'esbuild';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildSitePreview } from './site-preview.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const repo = path.dirname(root);
const dist = path.join(root, 'dist');
const app = path.join(dist, 'Nightingale Writer.app');
const resources = path.join(app, 'Contents', 'Resources');
const run = (bin, args, options = {}) => execFileSync(bin, args, { cwd: root, stdio: 'inherit', ...options });
fs.mkdirSync(path.join(app, 'Contents', 'MacOS'), { recursive: true });
fs.mkdirSync(path.join(resources, 'web'), { recursive: true });
fs.mkdirSync(path.join(root, '.build', 'module-cache'), { recursive: true });
const nativeSnapshot = path.join(root, '.build', 'native-source');
fs.mkdirSync(nativeSnapshot, { recursive: true });
const nativeSources = ['Main.swift', 'RepositoryStore.swift', 'CodeHighlighter.swift', 'PublishingValidator.swift', 'DeploymentClient.swift'];
for (const file of nativeSources) fs.copyFileSync(path.join(root, 'native', file), path.join(nativeSnapshot, file));
buildSitePreview(path.join(resources, 'web'));
await build({ entryPoints: [path.join(root, 'web/app.js')], bundle: true, format: 'iife', target: 'safari16', outfile: path.join(resources, 'web/app.js'), minify: true, sourcemap: false, logLevel: 'info' });
fs.copyFileSync(path.join(root, 'web/styles.css'), path.join(resources, 'web/styles.css'));
for (const directory of ['preview', 'vendor/rouge']) {
  const destination = path.join(resources, directory);
  fs.rmSync(destination, { recursive: true, force: true });
  fs.cpSync(path.join(root, directory), destination, { recursive: true });
}
fs.rmSync(path.join(resources, 'publishing'), { recursive: true, force: true });
fs.cpSync(path.join(repo, 'publishing'), path.join(resources, 'publishing'), { recursive: true });
run('/usr/bin/swiftc', ['-swift-version', '5', ...(process.env.WRITER_DEBUG_BUILD ? [] : ['-O']), '-parse-as-library', '-module-cache-path', path.join(root, '.build/module-cache'), '-target', 'arm64-apple-macosx13.0', ...nativeSources.map(file => path.join(nativeSnapshot, file)), '-framework', 'AppKit', '-framework', 'WebKit', '-o', path.join(app, 'Contents/MacOS/NightingaleWriter')]);

const seed = path.join(resources, 'Seed.git');
if (fs.existsSync(seed)) fs.rmSync(seed, { recursive: true });
run('/usr/bin/git', ['clone', '--quiet', '--bare', '--no-local', '--single-branch', '--branch', 'main', repo, seed]);
run('/usr/bin/git', ['--git-dir', seed, 'remote', 'set-url', 'origin', 'https://github.com/Nightingalelyy/nightingalelyy.github.io.git']);

run('/usr/bin/swift', ['-module-cache-path', path.join(root, '.build/module-cache'), 'scripts/icon.swift', path.join(root, '.build', 'AppIcon.iconset')]);
const iconChunks = [['ic07', 128], ['ic08', 256], ['ic09', 512], ['ic10', 1024]].map(([type, size]) => {
  const filename = size === 1024 ? 'icon_512x512@2x.png' : `icon_${size}x${size}.png`;
  const png = fs.readFileSync(path.join(root, '.build', 'AppIcon.iconset', filename));
  const header = Buffer.alloc(8); header.write(type); header.writeUInt32BE(png.length + 8, 4);
  return Buffer.concat([header, png]);
});
const iconHeader = Buffer.alloc(8); iconHeader.write('icns'); iconHeader.writeUInt32BE(8 + iconChunks.reduce((size, chunk) => size + chunk.length, 0), 4);
fs.writeFileSync(path.join(resources, 'AppIcon.icns'), Buffer.concat([iconHeader, ...iconChunks]));
fs.writeFileSync(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Nightingale Writer</string>
<key>CFBundleDisplayName</key><string>Nightingale Writer</string>
<key>CFBundleIdentifier</key><string>io.github.nightingalelyy.writer</string>
<key>CFBundleExecutable</key><string>NightingaleWriter</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>6</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Yuyang Liu</string>
</dict></plist>`);
run('/usr/bin/codesign', ['--force', '--deep', '--sign', '-', app]);
const zip = path.join(dist, 'Nightingale Writer.zip');
if (fs.existsSync(zip)) fs.unlinkSync(zip);
run('/usr/bin/ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, zip]);
console.log(`Built ${app}\nArchive: ${zip}`);
