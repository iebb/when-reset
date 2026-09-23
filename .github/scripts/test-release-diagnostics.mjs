import assert from 'node:assert/strict';
import { createDecipheriv, generateKeyPairSync, privateDecrypt } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { context, sealReleaseLog } from './seal-release-log.mjs';

const recipient = generateKeyPairSync('rsa', { modulusLength: 3072 });
const publicPem = recipient.publicKey.export({ type: 'spki', format: 'pem' });
const canary = 'private-diagnostic-test-canary';

function decrypt(envelope) {
  const key = privateDecrypt({ key: recipient.privateKey, oaepHash: 'sha256' }, Buffer.from(envelope.wrappedKey, 'base64'));
  const cipher = createDecipheriv('aes-256-gcm', key, Buffer.from(envelope.iv, 'base64'));
  cipher.setAAD(Buffer.from(context));
  cipher.setAuthTag(Buffer.from(envelope.tag, 'base64'));
  return Buffer.concat([cipher.update(Buffer.from(envelope.ciphertext, 'base64')), cipher.final()]).toString();
}

test('diagnostics are encrypted for the recipient and reject ciphertext tampering', (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'release-diagnostics-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const input = join(directory, 'private.log');
  const output = join(directory, 'export.sealed.json');
  writeFileSync(input, canary);
  sealReleaseLog(input, output, publicPem);
  const encoded = readFileSync(output, 'utf8');
  assert.ok(!encoded.includes(canary));
  assert.equal(statSync(output).mode & 0o777, 0o600);
  const envelope = JSON.parse(encoded);
  assert.equal(decrypt(envelope), canary);
  const altered = Buffer.from(envelope.ciphertext, 'base64');
  altered[0] ^= 1;
  assert.throws(() => decrypt({ ...envelope, ciphertext: altered.toString('base64') }));
  assert.throws(() => sealReleaseLog(input, output, publicPem), { code: 'EEXIST' });
});

test('invalid recipients fail without publishing plaintext or diagnostic details', (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'release-diagnostics-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const input = join(directory, 'private.log');
  const output = join(directory, 'export.sealed.json');
  writeFileSync(input, canary);
  const privatePem = recipient.privateKey.export({ type: 'pkcs8', format: 'pem' });
  assert.throws(() => sealReleaseLog(input, output, privatePem), /public key/);
  const weak = generateKeyPairSync('rsa', { modulusLength: 2048 });
  assert.throws(() => sealReleaseLog(input, output, weak.publicKey.export({ type: 'spki', format: 'pem' })), /3072/);
  const result = spawnSync(process.execPath, [fileURLToPath(new URL('./seal-release-log.mjs', import.meta.url)), input, output], {
    env: { ...process.env, RELEASE_DIAGNOSTICS_PUBLIC_KEY: canary }, encoding: 'utf8',
  });
  assert.equal(result.status, 1);
  assert.equal(result.stdout, '');
  assert.equal(result.stderr, 'Could not encrypt release diagnostics; raw diagnostics were not published.\n');
  assert.ok(!existsSync(output));
});

test('failed exports retain only encrypted diagnostics and preserve the export exit status', (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'release-diagnostics-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const rawDirectory = join(directory, 'raw');
  const sealedDirectory = join(directory, 'sealed');
  mkdirSync(rawDirectory);
  const fakeXcode = join(directory, 'xcodebuild');
  writeFileSync(fakeXcode, `#!/bin/sh\nprintf '${canary}\\n'\nexit 70\n`);
  chmodSync(fakeXcode, 0o700);
  const result = spawnSync('bash', [fileURLToPath(new URL('./export-app-store.sh', import.meta.url)), 'archive', 'export', 'options'], {
    env: {
      ...process.env, PATH: `${directory}:${process.env.PATH}`, TMPDIR: `${rawDirectory}/`,
      ASC_KEY_PATH: 'synthetic-key', ASC_KEY_ID: 'synthetic-id', ASC_ISSUER_ID: 'synthetic-issuer',
      RELEASE_DIAGNOSTICS_NODE: process.execPath, RELEASE_DIAGNOSTICS_PUBLIC_KEY: publicPem,
      RELEASE_DIAGNOSTICS_DIRECTORY: sealedDirectory,
    }, encoding: 'utf8',
  });
  assert.equal(result.status, 70);
  assert.ok(!`${result.stdout}${result.stderr}`.includes(canary));
  assert.deepEqual(readdirSync(rawDirectory), []);
  assert.equal(decrypt(JSON.parse(readFileSync(join(sealedDirectory, 'export-1.sealed.json'), 'utf8'))), `${canary}\n`);
});
