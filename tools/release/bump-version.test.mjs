import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  bumpProjectPatchVersion,
  nextPatchVersion,
  plannedPatchFingerprint,
  readProjectVersion,
} from "./bump-version.mjs";

async function createFixture(t, versions = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), "pixiv-slides-release-test-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  await mkdir(path.join(root, "src-tauri"));

  const packageVersion = versions.packageJson ?? "1.2.9";
  const packageLockVersion = versions.packageLock ?? packageVersion;
  const packageLockRootVersion = versions.packageLockRoot ?? packageVersion;
  const cargoTomlVersion = versions.cargoToml ?? packageVersion;
  const cargoLockVersion = versions.cargoLock ?? packageVersion;
  const tauriVersion = versions.tauriConfig ?? packageVersion;

  const files = {
    "package.json": `${JSON.stringify(
      { name: "pixiv-slides", private: true, version: packageVersion },
      null,
      2,
    )}\n`,
    "package-lock.json": `${JSON.stringify(
      {
        name: "pixiv-slides",
        version: packageLockVersion,
        lockfileVersion: 3,
        packages: {
          "": {
            name: "pixiv-slides",
            version: packageLockRootVersion,
          },
          "node_modules/unrelated": { version: "1.2.9" },
        },
      },
      null,
      2,
    )}\n`,
    "src-tauri/Cargo.toml": `[package]\nname = "app"\nversion = "${cargoTomlVersion}"\n\n[dependencies]\nunrelated = "1.2.9"\n`,
    "src-tauri/Cargo.lock": `version = 3\n\n[[package]]\nname = "app"\nversion = "${cargoLockVersion}"\ndependencies = [\n "unrelated",\n]\n\n[[package]]\nname = "unrelated"\nversion = "1.2.9"\n`,
    "src-tauri/tauri.conf.json": `${JSON.stringify(
      {
        productName: "pixiv-slides",
        version: tauriVersion,
        identifier: "net.pixiv.slides",
      },
      null,
      2,
    )}\n`,
  };

  for (const [relativePath, contents] of Object.entries(files)) {
    await writeFile(path.join(root, relativePath), contents);
  }
  return { root, files };
}

function fingerprintFixture(files) {
  const aggregate = createHash("sha256");
  const paths = [
    "package-lock.json",
    "package.json",
    "src-tauri/Cargo.lock",
    "src-tauri/Cargo.toml",
    "src-tauri/tauri.conf.json",
  ];
  for (const relativePath of paths) {
    const digest = createHash("sha256")
      .update(files[relativePath])
      .digest("hex");
    aggregate.update(relativePath);
    aggregate.update("\0");
    aggregate.update(digest);
    aggregate.update("\0");
  }
  return aggregate.digest("hex");
}

async function readFixture(root) {
  const relativePaths = [
    "package.json",
    "package-lock.json",
    "src-tauri/Cargo.toml",
    "src-tauri/Cargo.lock",
    "src-tauri/tauri.conf.json",
  ];
  return Object.fromEntries(
    await Promise.all(
      relativePaths.map(async (relativePath) => [
        relativePath,
        await readFile(path.join(root, relativePath), "utf8"),
      ]),
    ),
  );
}

test("patch-bumps every project version without touching dependency versions", async (t) => {
  const { root } = await createFixture(t);
  const plannedFingerprint = await plannedPatchFingerprint(root);

  const result = await bumpProjectPatchVersion(root);

  assert.deepEqual(result, { previousVersion: "1.2.9", version: "1.2.10" });
  assert.equal(await readProjectVersion(root), "1.2.10");
  const files = await readFixture(root);
  assert.match(plannedFingerprint, /^[0-9a-f]{64}$/);
  assert.equal(fingerprintFixture(files), plannedFingerprint);
  const packageLock = JSON.parse(files["package-lock.json"]);
  assert.equal(packageLock.packages["node_modules/unrelated"].version, "1.2.9");
  assert.match(
    files["src-tauri/Cargo.lock"],
    /name = "unrelated"\nversion = "1\.2\.9"/,
  );
});

test("computes the next patch version without number precision loss", () => {
  assert.equal(nextPatchVersion("1.2.9"), "1.2.10");
  assert.equal(
    nextPatchVersion("1.2.9007199254740993"),
    "1.2.9007199254740994",
  );
});

test("rejects mismatched versions without changing any files", async (t) => {
  const { root } = await createFixture(t, { tauriConfig: "1.2.8" });
  const before = await readFixture(root);

  await assert.rejects(
    bumpProjectPatchVersion(root),
    /project versions are not synchronized/,
  );

  assert.deepEqual(await readFixture(root), before);
});

test("rejects non-plain semantic versions without changing any files", async (t) => {
  const { root } = await createFixture(t, { packageJson: "1.2.9-beta.1" });
  const before = await readFixture(root);

  await assert.rejects(
    bumpProjectPatchVersion(root),
    /plain numeric major\.minor\.patch version/,
  );

  assert.deepEqual(await readFixture(root), before);
});
