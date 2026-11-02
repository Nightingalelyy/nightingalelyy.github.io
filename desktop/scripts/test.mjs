import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
execFileSync(process.execPath, ['--test', 'web/content.test.js', 'web/markdown.test.js', 'web/workflow.test.js', 'web/writing-tools.test.js', 'web/management.test.js', 'web/private-sync.test.js', 'web/auto-private-sync.test.js', 'web/private-auto-operation.test.js', 'web/updates.test.js', 'tests/site-preview.test.mjs', 'tests/maintenance.test.mjs'], {cwd: root, stdio: 'inherit'});
const buildDir = path.join(root, '.build');
fs.mkdirSync(path.join(buildDir, 'module-cache'), { recursive: true });
const binary = path.join(buildDir, 'repository-tests');
execFileSync('/usr/bin/swiftc', ['-swift-version', '5', '-module-cache-path', path.join(buildDir, 'module-cache'), 'native/PrivateDraftGitHubTransport.swift', 'native/RepositoryStore.swift', 'tests/RepositoryStoreTests.swift', '-o', binary], {cwd: root, stdio: 'inherit'});
execFileSync(binary, [], {cwd: root, stdio: 'inherit'});
for (const [name, sources] of [
  ['private-sync-tests', ['native/PrivateDraftGitHubTransport.swift', 'native/RepositoryStore.swift', 'tests/PrivateDraftSyncTests.swift']],
  ['private-auto-sync-tests', ['native/PrivateDraftGitHubTransport.swift', 'native/RepositoryStore.swift', 'tests/PrivateAutoSyncTests.swift']],
  ['private-image-reference-tests', ['native/PrivateDraftGitHubTransport.swift', 'native/RepositoryStore.swift', 'tests/PrivateDraftAssetReferencesTests.swift']],
  ['private-transport-tests', ['native/PrivateDraftGitHubTransport.swift', 'tests/PrivateDraftGitHubTransportTests.swift']],
]) {
  const target = path.join(buildDir, name);
  execFileSync('/usr/bin/swiftc', ['-swift-version', '5', '-module-cache-path', path.join(buildDir, 'module-cache'), ...sources, '-o', target], {cwd: root, stdio: 'inherit'});
  execFileSync(target, [], {cwd: root, stdio: 'inherit'});
}
const highlighterTests = path.join(buildDir, 'highlighter-tests');
execFileSync('/usr/bin/swiftc', ['-swift-version', '5', '-module-cache-path', path.join(buildDir, 'module-cache'), 'native/CodeHighlighter.swift', 'tests/CodeHighlighterTests.swift', '-o', highlighterTests], {cwd: root, stdio: 'inherit'});
execFileSync(highlighterTests, [root], {cwd: root, stdio: 'inherit'});
const deploymentTests = path.join(buildDir, 'deployment-tests');
execFileSync('/usr/bin/swiftc', ['-swift-version', '5', '-module-cache-path', path.join(buildDir, 'module-cache'), 'native/DeploymentClient.swift', 'tests/DeploymentClientTests.swift', '-o', deploymentTests], {cwd: root, stdio: 'inherit'});
execFileSync(deploymentTests, [], {cwd: root, stdio: 'inherit'});
const validatorTests = path.join(buildDir, 'validator-tests');
execFileSync('/usr/bin/swiftc', ['-swift-version', '5', '-module-cache-path', path.join(buildDir, 'module-cache'), 'native/PublishingValidator.swift', 'tests/PublishingValidatorTests.swift', '-o', validatorTests], {cwd: root, stdio: 'inherit'});
execFileSync(validatorTests, [path.dirname(root)], {cwd: root, stdio: 'inherit'});

const mediaTests = path.join(buildDir, 'media-tests');
execFileSync('/usr/bin/swiftc', ['-swift-version', '5', '-module-cache-path', path.join(buildDir, 'module-cache'), 'native/MediaProcessor.swift', 'tests/MediaProcessorTests.swift', '-o', mediaTests], {cwd: root, stdio: 'inherit'});
execFileSync(mediaTests, [], {cwd: root, stdio: 'inherit'});

const updateTests = path.join(buildDir, 'update-tests');
execFileSync('/usr/bin/swiftc', ['-swift-version', '5', '-parse-as-library', '-module-cache-path', path.join(buildDir, 'module-cache'), 'native/UpdateManager.swift', 'native/UpdateInstaller.swift', 'tests/UpdateManagerTests.swift', '-framework', 'AppKit', '-o', updateTests], {cwd: root, stdio: 'inherit'});
execFileSync(updateTests, [], {cwd: root, stdio: 'inherit'});
