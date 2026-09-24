// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
// Checks indexed files, not ignored build output or third-party Git histories.
// Only categories/paths are reported; matching values are never logged.
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

export const sourceHeader = '// SPDX-License-Identifier: Apache-2.0\n// Copyright (c) 2026 vltgoblin\n';
export const originalHeader = '// SPDX-License-Identifier: MIT\n';
const apacheLicenseSha256 = 'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30';
const sha256 = data => createHash('sha256').update(data).digest('hex');

export const dependencies = new Map([
  ['contracts/lib/openzeppelin-contracts', 'cab19933c33c2ad1d4c7a84864a3601dddfd16f3'],
  ['contracts/lib/forge-std', 'bf647bd6046f2f7da30d0c2bf435e5c76a780c1b'],
]);
const packaging = new Set([
  '.gitignore', '.gitmodules', '.github/workflows/ci.yml',
  'README.md', 'LICENSE', 'NOTICE', 'NOTICE.md', 'CONTRIBUTING.md', 'SECURITY.md',
  'SOURCE-MANIFEST.json', 'docs/ARCHITECTURE.md', 'docs/STATUS.md', 'docs/VERIFICATION.md',
  'contracts/foundry.toml', 'contracts/foundry.lock',
  'contracts/specs/hunter-bloom/foundry.toml',
  'scripts/check-publication.mjs', 'scripts/check-publication.test.mjs',
]);

export function isSourcePath(file) {
  if (file.split('/').some(p => p === '..' || p === '.' || p === '')) return false;
  return /^contracts\/(?:src\/bloom\/(?:libraries\/)?[A-Za-z0-9]+\.sol|src\/(?:LiveHunt|ILiveHuntNFT)\.sol|test\/(?:helpers\/)?[A-Za-z0-9.]+\.sol|specs\/hunter-bloom\/(?:src\/[A-Za-z0-9]+\.sol|test\/[A-Za-z0-9.]+\.sol|test\/fixtures\/weighted-(?:ratio|reward)-vectors\.json))$/.test(file);
}

export function inspectText(data) {
  if (data.length > 3 * 1024 * 1024) return ['oversize-file'];
  if (data.includes(0)) return ['binary-file'];
  const text = data.toString('utf8');
  if (!Buffer.from(text).equals(data)) return ['invalid-utf8'];
  const findings = [];
  const rules = [
    ['personal-filesystem-path', /[/]Users[/][^/\s]+|[/]home[/](?!runner\b)[^/\s]+|[A-Z]:\\Users\\/i],
    ['private-key-marker', /-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----/],
    ['credential-url', /https?:\/\/[^\s/@:]+:[^\s/@]+@|[?&](?:access_token|api_key|apikey|auth_token|password)=[^\s&"']+/i],
    ['private-network-reference', /[a-z0-9.-]+\.ts\.net\b|\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3})\b/i],
  ];
  for (const [category, regex] of rules) if (regex.test(text)) findings.push(category);
  const emails = text.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi) || [];
  if (emails.some(email => !/@(?:proofhunter\.fun|(?:[^@.]+\.)?example\.(?:com|org|net))$/i.test(email))) findings.push('non-project-email');
  return findings;
}

export function checkRepository(root) {
  const git = (...args) => execFileSync('git', ['-C', root, ...args], {maxBuffer: 16 * 1024 * 1024});
  const entries = git('ls-files', '--stage', '-z').toString().split('\0').filter(Boolean).map(row => {
    const [meta, file] = row.split('\t');
    const [mode, oid, stage] = meta.split(' ');
    return {file, mode, oid, stage};
  });
  const byPath = new Map(entries.map(entry => [entry.file, entry]));
  const blob = file => {
    const entry = byPath.get(file);
    if (!entry || entry.mode !== '100644' || entry.stage !== '0') throw new Error('Missing or invalid indexed regular file: ' + file);
    return git('cat-file', 'blob', entry.oid);
  };
  const manifest = JSON.parse(blob('SOURCE-MANIFEST.json'));
  if (manifest.license !== 'Apache-2.0' || manifest.sourceLicense !== 'MIT' || manifest.transformation !== 'first-party-license-header-v1') throw new Error('Invalid source licensing metadata');
  const imported = new Map();
  for (const entry of manifest.files) {
    if (!isSourcePath(entry.path) || imported.has(entry.path) || !/^[a-f0-9]{64}$/.test(entry.sha256) || !/^[a-f0-9]{64}$/.test(entry.sourceSha256)) throw new Error('Invalid source manifest entry');
    imported.set(entry.path, entry);
  }
  const issues = [];
  for (const {file, mode, oid, stage} of entries) {
    if (stage !== '0') { issues.push(file + ': merge-conflict'); continue; }
    if (mode === '160000') {
      if (dependencies.get(file) !== oid) issues.push(file + ': unapproved-dependency');
      continue;
    }
    if (mode !== '100644') { issues.push(file + ': non-regular-publication-file'); continue; }
    if (!packaging.has(file) && !imported.has(file)) issues.push(file + ': outside-publication-allowlist');
    const data = git('cat-file', 'blob', oid);
    for (const category of inspectText(data)) issues.push(file + ': ' + category);
    const source = imported.get(file);
    if (source && sha256(data) !== source.sha256) issues.push(file + ': source-hash-mismatch');
    const isSolidity = file.endsWith('.sol');
    if ((isSolidity || file.endsWith('.mjs')) && !data.toString().startsWith(sourceHeader)) issues.push(file + ': missing-source-license');
    if (source) {
      const restored = isSolidity && data.toString().startsWith(sourceHeader)
        ? Buffer.from(originalHeader + data.toString().slice(sourceHeader.length)) : data;
      if (sha256(restored) !== source.sourceSha256) issues.push(file + ': original-source-body-mismatch');
    }
  }
  for (const file of [...packaging, ...imported.keys(), ...dependencies.keys()]) {
    if (!byPath.has(file)) issues.push(file + ': missing-publication-file');
  }
  for (const [file, rev] of dependencies) {
    const entry = byPath.get(file);
    if (entry && (entry.mode !== '160000' || entry.oid !== rev)) issues.push(file + ': dependency-pin-mismatch');
  }
  if (byPath.has('LICENSE') && sha256(blob('LICENSE')) !== apacheLicenseSha256) issues.push('LICENSE: noncanonical-apache-license');
  if (byPath.has('NOTICE') && !blob('NOTICE').toString().startsWith('Hunter Bloom\nCopyright (c) 2026 vltgoblin\n')) issues.push('NOTICE: missing-project-attribution');
  const expectedModules = [
    '[submodule "contracts/lib/openzeppelin-contracts"]',
    'path = contracts/lib/openzeppelin-contracts',
    'url = https://github.com/OpenZeppelin/openzeppelin-contracts',
    '[submodule "contracts/lib/forge-std"]',
    'path = contracts/lib/forge-std',
    'url = https://github.com/foundry-rs/forge-std',
  ].join('\n');
  if (blob('.gitmodules').toString().trim().split('\n').map(line => line.trim()).join('\n') !== expectedModules) issues.push('.gitmodules: unexpected-submodule-configuration');
  const lock = JSON.parse(blob('contracts/foundry.lock'));
  for (const [file, rev] of dependencies) {
    if (lock[file.replace('contracts/', '')]?.rev !== rev) issues.push('contracts/foundry.lock: dependency-pin-mismatch');
  }
  if (issues.length) throw new Error(issues.join('\n'));
  return {indexedEntries: entries.length, importedFiles: imported.size, dependencies: dependencies.size, findings: 0};
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
    console.log(JSON.stringify(checkRepository(root), null, 2));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
