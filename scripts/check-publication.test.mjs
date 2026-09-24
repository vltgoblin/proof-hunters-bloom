// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { inspectText, isSourcePath, checkRepository, sourceHeader, originalHeader } from './check-publication.mjs';

const inspect = text => inspectText(Buffer.from(text));
test('allows project contacts, examples and ordinary source', () => {
  assert.deepEqual(inspect('social@proofhunter.fun demo@example.com ' + sourceHeader), []);
  assert.deepEqual(inspect('import {Test} from "forge-std/Test.sol";'), []);
});
test('flags personal paths without including their values', () => {
  const sample = ['/', 'Users', '/', 'example-person', '/wallet'].join('');
  assert.deepEqual(inspect(sample), ['personal-filesystem-path']);
});
test('flags unexpected email identities', () => {
  assert.deepEqual(inspect(['person', 'mail.invalid'].join('@')), ['non-project-email']);
});
test('flags private key markers', () => {
  assert.deepEqual(inspect(['-----BEGIN ', 'PRIVATE KEY-----'].join('')), ['private-key-marker']);
});
test('flags credential-bearing URLs and private infrastructure', () => {
  assert.deepEqual(inspect(['https://', 'demo:fixture@', 'example.com'].join('')), ['credential-url']);
  assert.deepEqual(inspect(['192', '168', '50', '20'].join('.')), ['private-network-reference']);
  assert.deepEqual(inspect(['host', 'ts', 'net'].join('.')), ['private-network-reference']);
});
test('rejects binary, invalid UTF-8 and oversized files', () => {
  assert.deepEqual(inspectText(Buffer.from([0, 1])), ['binary-file']);
  assert.deepEqual(inspectText(Buffer.from([0xff])), ['invalid-utf8']);
  assert.deepEqual(inspectText(Buffer.alloc(3 * 1024 * 1024 + 1)), ['oversize-file']);
});
test('source allowlist rejects traversal, wallet files and unrelated documents', () => {
  assert.ok(isSourcePath('contracts/src/bloom/DirectLoan.sol'));
  assert.ok(isSourcePath('contracts/test/helpers/HunterReserveFixtures.sol'));
  for (const file of ['../secret.sol', 'contracts/src/bloom/../secret.sol', 'contracts/test/wallet.json', 'docs/private.md', '/contracts/test/X.sol']) assert.equal(isSourcePath(file), false);
});

test('indexed package rejects extra files, changed source, missing files and changed pins', t => {
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
  const fixture = mkdtempSync(path.join(os.tmpdir(), 'bloom-publication-test-'));
  t.after(() => rmSync(fixture, {recursive: true, force: true}));
  const git = (cwd, args, input) => execFileSync('git', ['-C', cwd, ...args], {input, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe']});
  git(fixture, ['init', '-b', 'test']);
  const entries = git(root, ['ls-files', '--stage', '-z']).split('\0').filter(Boolean).map(row => {
    const [meta, file] = row.split('\t');
    const [mode, oid] = meta.split(' ');
    return {mode, oid, file};
  });
  const stage = (file, text) => {
    const oid = git(fixture, ['hash-object', '-w', '--stdin'], text).trim();
    git(fixture, ['update-index', '--add', '--cacheinfo', '100644,' + oid + ',' + file]);
    return oid;
  };
  for (const {mode, oid, file} of entries) {
    if (mode === '160000') git(fixture, ['update-index', '--add', '--cacheinfo', mode + ',' + oid + ',' + file]);
    else stage(file, git(root, ['cat-file', 'blob', oid]));
  }
  assert.equal(checkRepository(fixture).findings, 0);
  stage('notes.txt', 'Unlisted file\n');
  assert.throws(() => checkRepository(fixture), /outside-publication-allowlist/);
  git(fixture, ['update-index', '--force-remove', 'notes.txt']);
  const original = git(root, ['show', ':contracts/src/bloom/DirectLoan.sol']);
  stage('contracts/src/bloom/DirectLoan.sol', original + '// changed\n');
  assert.throws(() => checkRepository(fixture), /source-hash-mismatch/);
  const originalManifest = git(root, ['show', ':SOURCE-MANIFEST.json']);
  const changedManifest = JSON.parse(originalManifest);
  changedManifest.files.find(entry => entry.path === 'contracts/src/bloom/DirectLoan.sol').sha256 = createHash('sha256').update(original + '// changed\n').digest('hex');
  stage('SOURCE-MANIFEST.json', JSON.stringify(changedManifest) + '\n');
  assert.throws(() => checkRepository(fixture), /original-source-body-mismatch/);
  stage('SOURCE-MANIFEST.json', originalManifest);
  stage('contracts/src/bloom/DirectLoan.sol', original);
  stage('contracts/src/bloom/DirectLoan.sol', originalHeader + original.slice(sourceHeader.length));
  assert.throws(() => checkRepository(fixture), /missing-source-license/);
  stage('contracts/src/bloom/DirectLoan.sol', original);
  const license = git(root, ['show', ':LICENSE']);
  stage('LICENSE', license + 'Additional terms\n');
  assert.throws(() => checkRepository(fixture), /noncanonical-apache-license/);
  stage('LICENSE', license);
  const notice = git(root, ['show', ':NOTICE']);
  stage('NOTICE', notice.replace('2026 vltgoblin', '2026 example'));
  assert.throws(() => checkRepository(fixture), /missing-project-attribution/);
  stage('NOTICE', notice);
  git(fixture, ['update-index', '--force-remove', 'NOTICE']);
  assert.throws(() => checkRepository(fixture), /missing-publication-file/);
  stage('NOTICE', notice);
  git(fixture, ['update-index', '--force-remove', 'LICENSE']);
  assert.throws(() => checkRepository(fixture), /missing-publication-file/);
  stage('LICENSE', git(root, ['show', ':LICENSE']));
  git(fixture, ['update-index', '--cacheinfo', '160000,' + '1'.repeat(40) + ',contracts/lib/forge-std']);
  assert.throws(() => checkRepository(fixture), /dependency-pin-mismatch/);
});
