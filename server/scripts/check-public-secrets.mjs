import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const sharedKey = "server/apns/WhenResetSharedAPNs.p8";
const expectedHash = "9512a4e0063a0aa9ca5974d458c0d4fff6abd936c0d97e97d1814cd919530917";
const git = (...args) => execFileSync("git", args, { cwd: root, stdio: ["ignore", "pipe", "pipe"] });
const verify = (bytes) => {
  if (createHash("sha256").update(bytes).digest("hex") !== expectedHash) {
    throw new Error("The shared APNs key changed; review the public-key exception before publishing.");
  }
};

try {
  verify(readFileSync(resolve(root, sharedKey)));
  const files = git("ls-files", "-z").toString().split("\0").filter(Boolean);
  const forbidden = /(?:^|\/)(?:\.env(?:\..*)?|\.dev\.vars(?:\..*)?|server\.env(?:\..*)?)$|\.(?:sqlite(?:3)?(?:-(?:wal|shm))?|p8|p12|key|pem|mobileprovision)$/i;
  for (const file of files) {
    if (file !== sharedKey && !/(?:^|\/)\.(?:env|dev\.vars)\.example$/.test(file) && forbidden.test(file)) {
      throw new Error(`Private runtime/configuration file is tracked: ${file}`);
    }
  }
  // A path-only scanner exception must not hide a different private key anywhere
  // in published history, even if it was subsequently reverted.
  for (const commit of git("rev-list", "--all", "--", sharedKey).toString().trim().split("\n").filter(Boolean)) {
    if (git("ls-tree", "--name-only", commit, "--", sharedKey).length) {
      verify(git("show", `${commit}:${sharedKey}`));
    }
  }
  console.log("Tracked-file policy and intentional public APNs key fingerprint verified.");
} catch (error) {
  // Never print captured Git output: it may be the very secret under inspection.
  console.error(error instanceof Error && !Object.hasOwn(error, "stdout")
    ? error.message : "Secret policy verification failed.");
  process.exitCode = 1;
}
