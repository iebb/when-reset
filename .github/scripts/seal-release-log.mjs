import { createCipheriv, createPublicKey, publicEncrypt, randomBytes } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

export const context = 'when-reset-release-diagnostics-v1';

// Only ciphertext leaves the ephemeral runner. The recipient keeps the private
// key locally; no private key belongs in a repository variable or artifact.
export function sealReleaseLog(input, output, publicPem) {
  if (publicPem.includes('PRIVATE KEY')) throw new Error('A public key is required');
  const recipient = createPublicKey(publicPem);
  if (recipient.asymmetricKeyType !== 'rsa' || recipient.asymmetricKeyDetails.modulusLength < 3072) {
    throw new Error('Diagnostics require an RSA public key of at least 3072 bits');
  }
  const key = randomBytes(32);
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, iv);
  cipher.setAAD(Buffer.from(context));
  const ciphertext = Buffer.concat([cipher.update(readFileSync(input)), cipher.final()]);
  const envelope = {
    format: 1, keyAlgorithm: 'RSA-OAEP-SHA256', cipher: 'AES-256-GCM', context,
    wrappedKey: publicEncrypt({ key: recipient, oaepHash: 'sha256' }, key).toString('base64'),
    iv: iv.toString('base64'), tag: cipher.getAuthTag().toString('base64'),
    ciphertext: ciphertext.toString('base64'),
  };
  mkdirSync(dirname(output), { recursive: true, mode: 0o700 });
  writeFileSync(output, JSON.stringify(envelope), { flag: 'wx', mode: 0o600 });
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    if (process.argv.length !== 4) throw new Error('Expected input and output paths');
    sealReleaseLog(process.argv[2], process.argv[3], process.env.RELEASE_DIAGNOSTICS_PUBLIC_KEY);
  } catch {
    console.error('Could not encrypt release diagnostics; raw diagnostics were not published.');
    process.exitCode = 1;
  }
}
