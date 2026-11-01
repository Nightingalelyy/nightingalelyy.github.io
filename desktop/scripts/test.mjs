import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
execFileSync(process.execPath, ['--test', 'web/content.test.js', 'web/markdown.test.js', 'tests/site-preview.test.mjs'], {cwd: root, stdio: 'inherit'});
const buildDir = path.join(root, '.build');
fs.mkdirSync(path.join(buildDir, 'module-cache'), { recursive: true });
const binary = path.join(buildDir, 'repository-tests');
execFileSync('/usr/bin/swiftc', ['-swift-version', '5', '-module-cache-path', path.join(buildDir, 'module-cache'), 'native/RepositoryStore.swift', 'tests/RepositoryStoreTests.swift', '-o', binary], {cwd: root, stdio: 'inherit'});
execFileSync(binary, [], {cwd: root, stdio: 'inherit'});
const highlighterTests = path.join(buildDir, 'highlighter-tests');
execFileSync('/usr/bin/swiftc', ['-swift-version', '5', '-module-cache-path', path.join(buildDir, 'module-cache'), 'native/CodeHighlighter.swift', 'tests/CodeHighlighterTests.swift', '-o', highlighterTests], {cwd: root, stdio: 'inherit'});
execFileSync(highlighterTests, [root], {cwd: root, stdio: 'inherit'});
