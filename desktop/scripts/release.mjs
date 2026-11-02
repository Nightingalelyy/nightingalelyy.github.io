import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { createHash, createPublicKey, verify } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const repo = path.dirname(root), dist = path.join(root, 'dist');
const repository = 'Nightingalelyy/nightingalelyy.github.io';
const args = process.argv.slice(2);
const value = flag => { const i = args.indexOf(flag); return i < 0 ? undefined : args[i + 1]; };
const keyPath = value('--key') || process.env.WRITER_RELEASE_KEY;
const runID = value('--ci-run');
if (!keyPath || !/^\d+$/.test(runID || '')) throw new Error('Usage: npm run release:prepare -- --key /private/path/signing-key.bin --ci-run RUN_ID [--publish]');
const command = (bin, commandArgs) => execFileSync(bin, commandArgs, { cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
const dirty = execFileSync('/usr/bin/git', ['status', '--porcelain', '--untracked-files=all'], { cwd: repo, encoding: 'utf8' }).split('\n').filter(line => line && line.slice(3) !== '.DS_Store');
if (dirty.length) throw new Error('Commit source changes before preparing a release.');
const sourceCommit = command('/usr/bin/git', ['rev-parse', 'HEAD']);
const run = JSON.parse(command('gh', ['api', `repos/${repository}/actions/runs/${runID}`]));
if (run.head_sha !== sourceCommit || run.status !== 'completed' || run.conclusion !== 'success' || !['push', 'workflow_dispatch'].includes(run.event) || run.path !== '.github/workflows/desktop.yml' || run.repository?.full_name.toLowerCase() !== repository.toLowerCase() || run.head_repository?.full_name.toLowerCase() !== repository.toLowerCase()) throw new Error('A successful desktop push/dispatch CI run for this exact commit is required.');
const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json')));
if (!/^\d+\.\d+\.\d+$/.test(pkg.version) || !Number.isSafeInteger(pkg.buildNumber) || pkg.buildNumber < 1) throw new Error('Invalid release version or build number.');
const app = path.join(dist, 'Nightingale Writer.app');
const resources = path.join(app, 'Contents/Resources');
const build = JSON.parse(fs.readFileSync(path.join(resources, 'build-report.json')));
const maintenance = JSON.parse(fs.readFileSync(path.join(resources, 'maintenance-report.json')));
if (build.sourceCommit !== sourceCommit || build.sourceDirty !== false || build.version !== pkg.version || build.build !== pkg.buildNumber || maintenance.sourceCommit !== sourceCommit || maintenance.sourceDirty !== false || maintenance.ok !== true) throw new Error('Rebuild the app and maintenance report from this exact clean commit.');
command('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
const tag = `writer-v${pkg.version}`;
const archiveName = `Nightingale-Writer-${pkg.version}-arm64.zip`;
const archivePath = path.join(dist, archiveName);
// Create the published archive from the exact verified bundle, never a stale ZIP.
fs.rmSync(archivePath, { force: true });
command('/usr/bin/ditto', ['-c', '-k', '--norsrc', '--noextattr', '--keepParent', app, archivePath]);
const verifier = path.join(root, '.build/verify-release');
command('/usr/bin/swiftc', ['-swift-version', '5', '-parse-as-library', '-module-cache-path', path.join(root, '.build/module-cache'), path.join(root, 'native/UpdateManager.swift'), path.join(root, 'native/UpdateInstaller.swift'), path.join(root, 'scripts/verify-release.swift'), '-framework', 'AppKit', '-o', verifier]);
command(verifier, [app, archivePath]);
const archive = fs.readFileSync(archivePath);
if (!archive.length || archive.length > 256 * 1024 * 1024) throw new Error('Release archive exceeds the updater size limit.');
const payload = {
  schemaVersion: 1, product: 'io.github.nightingalelyy.writer', version: pkg.version,
  sourceCommit,
  build: pkg.buildNumber, minimumSystemVersion: '13.0', architecture: 'arm64',
  archive: { url: `https://github.com/${repository}/releases/download/${tag}/${archiveName}`, sha256: createHash('sha256').update(archive).digest('hex'), size: archive.length },
  releaseURL: `https://github.com/${repository}/releases/tag/${tag}`,
  publishedAt: new Date().toISOString(),
  notes: 'Signed update verification and rollback, local diagnostics, and automated preview and website integrity checks.',
};
const payloadPath = path.join(dist, 'update-payload.json');
const envelopePath = path.join(dist, 'nightingale-writer-update.json');
fs.writeFileSync(payloadPath, JSON.stringify(payload) + '\n');
const signer = path.join(root, '.build/release-sign');
command('/usr/bin/swiftc', ['-parse-as-library', '-module-cache-path', path.join(root, '.build/module-cache'), path.join(root, 'scripts/release-sign.swift'), '-o', signer]);
command(signer, ['sign', path.resolve(keyPath), payloadPath, envelopePath]);
const envelope = JSON.parse(fs.readFileSync(envelopePath));
const publicBytes = fs.readFileSync(path.join(root, 'release/update-public-key.bin'));
const publicKey = createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), publicBytes]), format: 'der', type: 'spki' });
if (!verify(null, Buffer.from(envelope.payload, 'base64'), publicKey, Buffer.from(envelope.signature, 'base64'))) throw new Error('Signing key does not match the app verification key. Release was not published.');
const checksums = path.join(dist, 'SHA256SUMS.txt');
fs.writeFileSync(checksums, `${payload.archive.sha256}  ${archiveName}\n${createHash('sha256').update(fs.readFileSync(envelopePath)).digest('hex')}  nightingale-writer-update.json\n`);
const maintenancePath = path.join(dist, 'maintenance-report.json');
fs.copyFileSync(path.join(resources, 'maintenance-report.json'), maintenancePath);
fs.writeFileSync(path.join(dist, 'build-report.json'), JSON.stringify({ ...build, archiveBytes: archive.length }, null, 2) + '\n');
const notesPath = path.join(dist, 'release-notes.md');
fs.writeFileSync(notesPath, `Nightingale Writer ${pkg.version} for Apple Silicon Macs (macOS 13+).\n\n${payload.notes}\n\nDrafts and publishing queues remain in the existing local data folder. Updates are explicit; rollback preserves current writing.\n\nThis personal build uses ad-hoc app signing and a pinned Ed25519 update signature. It is not Apple-notarized.\n\nSource: ${sourceCommit}\nVerified desktop checks: https://github.com/${repository}/actions/runs/${runID}\n`);
console.log(`Prepared ${archiveName} and signed update manifest for ${sourceCommit}.`);
if (args.includes('--publish')) {
  // Never replace an existing release or tag. GitHub creates the tag at this exact tested commit.
  const tags = command('/usr/bin/git', ['ls-remote', '--tags', `https://github.com/${repository}.git`, `refs/tags/${tag}`]);
  if (tags) throw new Error('This version already has a tag. Increment the version before publishing.');
  const url = command('gh', ['release', 'create', tag, archivePath, envelopePath, checksums, path.join(dist, 'build-report.json'), maintenancePath,
    '--repo', repository, '--target', sourceCommit, '--title', `Nightingale Writer ${pkg.version}`, '--notes-file', notesPath, '--latest']);
  console.log(url);
}
