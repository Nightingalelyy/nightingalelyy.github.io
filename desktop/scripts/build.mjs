import { build } from 'esbuild';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildSitePreview } from './site-preview.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const repo = path.dirname(root);
const dist = path.join(root, 'dist');
const started = performance.now();
const sourceRevision = () => execFileSync('/usr/bin/git', ['rev-parse', 'HEAD'], { cwd: repo, encoding: 'utf8' }).trim();
const sourceDirty = () => execFileSync('/usr/bin/git', ['status', '--porcelain', '--untracked-files=all'], { cwd: repo, encoding: 'utf8' }).split('\n').some(line => line && line.slice(3) !== '.DS_Store');
const sourceCommit = sourceRevision();
const startedDirty = sourceDirty();
const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
if (!/^\d+\.\d+\.\d+$/.test(pkg.version) || !Number.isSafeInteger(pkg.buildNumber) || pkg.buildNumber < 1) throw new Error('Invalid release version or build number.');
fs.mkdirSync(path.join(root, '.build'), { recursive: true });
const staging = fs.mkdtempSync(path.join(root, '.build/app-stage-'));
const app = path.join(staging, 'Nightingale Writer.app');
const resources = path.join(app, 'Contents', 'Resources');
const run = (bin, args, options = {}) => execFileSync(bin, args, { cwd: root, stdio: 'inherit', ...options });
fs.mkdirSync(path.join(app, 'Contents', 'MacOS'), { recursive: true });
fs.mkdirSync(path.join(resources, 'web'), { recursive: true });
fs.mkdirSync(path.join(root, '.build', 'module-cache'), { recursive: true });
const nativeSnapshot = path.join(root, '.build', 'native-source');
fs.mkdirSync(nativeSnapshot, { recursive: true });
const nativeSources = ['Main.swift', 'RepositoryStore.swift', 'PrivateDraftGitHubTransport.swift', 'UpdateManager.swift', 'UpdateInstaller.swift', 'CodeHighlighter.swift', 'PublishingValidator.swift', 'DeploymentClient.swift', 'MediaProcessor.swift'];
for (const file of nativeSources) fs.copyFileSync(path.join(root, 'native', file), path.join(nativeSnapshot, file));
buildSitePreview(path.join(resources, 'web'));
await build({ entryPoints: [path.join(root, 'web/app.js')], bundle: true, format: 'iife', target: 'safari16', outfile: path.join(resources, 'web/app.js'), minify: true, sourcemap: false, logLevel: 'info' });
for (const css of ['styles.css', 'writing-tools.css', 'management.css', 'private-sync.css', 'updates.css']) fs.copyFileSync(path.join(root, 'web', css), path.join(resources, 'web', css));
const publicKey = fs.readFileSync(path.join(root, 'release/update-public-key.bin'));
if (publicKey.length !== 32) throw new Error('A pinned release verification key is required.');
fs.writeFileSync(path.join(resources, 'update-public-key.bin'), publicKey);
for (const directory of ['preview', 'vendor/rouge']) {
  const destination = path.join(resources, directory);
  fs.rmSync(destination, { recursive: true, force: true });
  fs.cpSync(path.join(root, directory), destination, { recursive: true });
}
fs.rmSync(path.join(resources, 'publishing'), { recursive: true, force: true });
fs.cpSync(path.join(repo, 'publishing'), path.join(resources, 'publishing'), { recursive: true });
run('/usr/bin/swiftc', ['-swift-version', '5', ...(process.env.WRITER_DEBUG_BUILD ? [] : ['-O']), '-parse-as-library', '-module-cache-path', path.join(root, '.build/module-cache'), '-target', 'arm64-apple-macosx13.0', ...nativeSources.map(file => path.join(nativeSnapshot, file)), '-framework', 'AppKit', '-framework', 'WebKit', '-o', path.join(app, 'Contents/MacOS/NightingaleWriter')]);
fs.mkdirSync(path.join(app, 'Contents/Helpers'), { recursive: true });
run('/usr/bin/swiftc', ['-swift-version', '5', '-O', '-parse-as-library', '-D', 'UPDATE_INSTALLER', '-module-cache-path', path.join(root, '.build/module-cache'), '-target', 'arm64-apple-macosx13.0', path.join(nativeSnapshot, 'UpdateManager.swift'), path.join(nativeSnapshot, 'UpdateInstaller.swift'), '-o', path.join(app, 'Contents/Helpers/NightingaleUpdateHelper')]);
run('/usr/bin/codesign', ['--force', '--sign', '-', path.join(app, 'Contents/Helpers/NightingaleUpdateHelper')]);

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
<key>CFBundleShortVersionString</key><string>${pkg.version}</string>
<key>CFBundleVersion</key><string>${pkg.buildNumber}</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Yuyang Liu</string>
</dict></plist>`);
if (sourceRevision() !== sourceCommit) throw new Error('Source commit changed during the build. Build again from one revision.');
const websiteCommit = execFileSync('/usr/bin/git', ['rev-parse', 'main'], { cwd: repo, encoding: 'utf8' }).trim();
const maintenancePath = process.env.WRITER_MAINTENANCE_REPORT || path.join(root, '.build/maintenance-report.json');
if (fs.existsSync(maintenancePath)) {
  const report = JSON.parse(fs.readFileSync(maintenancePath, 'utf8'));
  if (report.ok !== true || report.sourceCommit !== sourceCommit) throw new Error('Run maintenance checks for this exact source commit before packaging its report.');
  fs.copyFileSync(maintenancePath, path.join(resources, 'maintenance-report.json'));
}
const treeBytes = directory => fs.readdirSync(directory, { withFileTypes: true }).reduce((total, entry) => total + (entry.isDirectory() ? treeBytes(path.join(directory, entry.name)) : fs.lstatSync(path.join(directory, entry.name)).size), 0);
const buildReport = { schemaVersion: 1, version: pkg.version, build: pkg.buildNumber, sourceCommit, sourceDirty: startedDirty || sourceDirty(), websiteCommit, builtAt: new Date().toISOString(), architecture: 'arm64', minimumSystemVersion: '13.0', appBuildMeasuredMS: Math.round(performance.now() - started), bundleBytesBeforeSigning: treeBytes(app), maintenanceReportBundled: fs.existsSync(path.join(resources, 'maintenance-report.json')), signing: 'ad-hoc; release manifest uses Ed25519', node: process.versions.node };
fs.writeFileSync(path.join(resources, 'build-report.json'), JSON.stringify(buildReport, null, 2) + '\n');
run('/usr/bin/codesign', ['--force', '--deep', '--sign', '-', app]);
run('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
fs.mkdirSync(dist, { recursive: true });
const finalApp = path.join(dist, 'Nightingale Writer.app');
fs.rmSync(finalApp, { recursive: true, force: true });
fs.renameSync(app, finalApp); fs.rmdirSync(staging);
const zip = path.join(dist, 'Nightingale Writer.zip');
if (fs.existsSync(zip)) fs.unlinkSync(zip);
run('/usr/bin/ditto', ['-c', '-k', '--norsrc', '--noextattr', '--keepParent', finalApp, zip]);
const archiveVerifier = path.join(root, '.build/verify-release');
run('/usr/bin/swiftc', ['-swift-version', '5', '-parse-as-library', '-module-cache-path', path.join(root, '.build/module-cache'), path.join(nativeSnapshot, 'UpdateManager.swift'), path.join(nativeSnapshot, 'UpdateInstaller.swift'), path.join(root, 'scripts/verify-release.swift'), '-framework', 'AppKit', '-o', archiveVerifier]);
run(archiveVerifier, [finalApp, zip]);
fs.copyFileSync(zip, path.join(dist, `Nightingale-Writer-${pkg.version}-arm64.zip`));
fs.writeFileSync(path.join(dist, 'build-report.json'), JSON.stringify({ ...buildReport, archiveBytes: fs.statSync(zip).size, packagingCompletedMS: Math.round(performance.now() - started) }, null, 2) + '\n');
console.log(`Built ${finalApp}\nArchive: ${zip}`);
