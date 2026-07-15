#!/usr/bin/env node

import {
  chmod,
  readFile,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { createHash } from "node:crypto";
import path from "node:path";
import { pathToFileURL } from "node:url";

const VERSION_PATTERN = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;

const FILES = {
  packageJson: "package.json",
  packageLock: "package-lock.json",
  cargoToml: "src-tauri/Cargo.toml",
  cargoLock: "src-tauri/Cargo.lock",
  tauriConfig: "src-tauri/tauri.conf.json",
};

const FINGERPRINT_ORDER = [
  "packageLock",
  "packageJson",
  "cargoLock",
  "cargoToml",
  "tauriConfig",
];

function parseJson(contents, description) {
  try {
    return JSON.parse(contents);
  } catch (error) {
    throw new Error(`${description} is not valid JSON: ${error.message}`);
  }
}

function requireString(value, description) {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${description} must be a non-empty string`);
  }
  return value;
}

function scalarFromBlock(block, key, description) {
  const pattern = new RegExp(`^${key}\\s*=\\s*"([^"]+)"\\s*$`, "gm");
  const matches = [...block.matchAll(pattern)];
  if (matches.length !== 1) {
    throw new Error(`${description} must contain exactly one ${key} string`);
  }
  return matches[0][1];
}

function replaceScalarInBlock(block, key, currentVersion, nextVersion, description) {
  const pattern = new RegExp(`^(${key}\\s*=\\s*")([^"]+)(".*)$`, "gm");
  let replacements = 0;
  const updated = block.replace(pattern, (_line, prefix, value, suffix) => {
    replacements += 1;
    if (value !== currentVersion) {
      throw new Error(
        `${description} changed while preparing the release: expected ${currentVersion}, found ${value}`,
      );
    }
    return `${prefix}${nextVersion}${suffix}`;
  });
  if (replacements !== 1) {
    throw new Error(`${description} must contain exactly one ${key} string`);
  }
  return updated;
}

function cargoTomlPackage(contents) {
  const headers = [...contents.matchAll(/^\[[^\r\n]+\]\s*$/gm)];
  const packageHeaders = headers.filter((match) => match[0].trim() === "[package]");
  if (packageHeaders.length !== 1) {
    throw new Error("src-tauri/Cargo.toml must contain exactly one [package] section");
  }

  const header = packageHeaders[0];
  const start = header.index;
  const nextHeader = headers.find((candidate) => candidate.index > start);
  const end = nextHeader?.index ?? contents.length;
  const block = contents.slice(start, end);

  if (scalarFromBlock(block, "name", "Cargo.toml [package]") !== "app") {
    throw new Error('src-tauri/Cargo.toml [package].name must be "app"');
  }

  return {
    version: scalarFromBlock(block, "version", "Cargo.toml [package]"),
    replaceVersion(currentVersion, nextVersion) {
      const updatedBlock = replaceScalarInBlock(
        block,
        "version",
        currentVersion,
        nextVersion,
        "Cargo.toml [package]",
      );
      return contents.slice(0, start) + updatedBlock + contents.slice(end);
    },
  };
}

function cargoLockAppPackage(contents) {
  const headers = [...contents.matchAll(/^\[\[package\]\]\s*$/gm)];
  const packages = headers.map((header, index) => {
    const start = header.index;
    const end = headers[index + 1]?.index ?? contents.length;
    return { start, end, block: contents.slice(start, end) };
  });
  const appPackages = packages.filter(
    ({ block }) => scalarFromBlock(block, "name", "Cargo.lock package") === "app",
  );
  if (appPackages.length !== 1) {
    throw new Error('src-tauri/Cargo.lock must contain exactly one package named "app"');
  }

  const appPackage = appPackages[0];
  return {
    version: scalarFromBlock(appPackage.block, "version", 'Cargo.lock package "app"'),
    replaceVersion(currentVersion, nextVersion) {
      const updatedBlock = replaceScalarInBlock(
        appPackage.block,
        "version",
        currentVersion,
        nextVersion,
        'Cargo.lock package "app"',
      );
      return (
        contents.slice(0, appPackage.start) +
        updatedBlock +
        contents.slice(appPackage.end)
      );
    },
  };
}

async function readProject(root) {
  const entries = await Promise.all(
    Object.entries(FILES).map(async ([key, relativePath]) => {
      const contents = await readFile(path.join(root, relativePath), "utf8");
      return [key, { relativePath, contents }];
    }),
  );
  const files = Object.fromEntries(entries);

  const packageJson = parseJson(files.packageJson.contents, FILES.packageJson);
  const packageLock = parseJson(files.packageLock.contents, FILES.packageLock);
  const tauriConfig = parseJson(files.tauriConfig.contents, FILES.tauriConfig);
  if (packageJson.name !== "pixiv-slides") {
    throw new Error('package.json name must be "pixiv-slides"');
  }
  if (packageLock.name !== "pixiv-slides" || packageLock.packages?.[""]?.name !== "pixiv-slides") {
    throw new Error('package-lock.json root package must be named "pixiv-slides"');
  }
  if (tauriConfig.productName !== "pixiv-slides") {
    throw new Error('src-tauri/tauri.conf.json productName must be "pixiv-slides"');
  }

  const cargoToml = cargoTomlPackage(files.cargoToml.contents);
  const cargoLock = cargoLockAppPackage(files.cargoLock.contents);
  const versions = [
    ["package.json", requireString(packageJson.version, "package.json version")],
    [
      "package-lock.json",
      requireString(packageLock.version, "package-lock.json version"),
    ],
    [
      'package-lock.json packages[""]',
      requireString(
        packageLock.packages?.[""]?.version,
        'package-lock.json packages[""] version',
      ),
    ],
    ["src-tauri/Cargo.toml", cargoToml.version],
    ["src-tauri/Cargo.lock app", cargoLock.version],
    [
      "src-tauri/tauri.conf.json",
      requireString(tauriConfig.version, "tauri.conf.json version"),
    ],
  ];

  const distinctVersions = new Set(versions.map(([, version]) => version));
  if (distinctVersions.size !== 1) {
    const details = versions.map(([label, version]) => `  ${label}: ${version}`).join("\n");
    throw new Error(`project versions are not synchronized:\n${details}`);
  }

  const currentVersion = versions[0][1];
  if (!VERSION_PATTERN.test(currentVersion)) {
    throw new Error(
      `release requires a plain numeric major.minor.patch version, found ${currentVersion}`,
    );
  }

  return {
    files,
    packageJson,
    packageLock,
    tauriConfig,
    cargoToml,
    cargoLock,
    currentVersion,
  };
}

export function nextPatchVersion(currentVersion) {
  const match = VERSION_PATTERN.exec(currentVersion);
  if (!match) {
    throw new Error(`cannot patch-bump invalid version ${currentVersion}`);
  }
  return `${match[1]}.${match[2]}.${BigInt(match[3]) + 1n}`;
}

async function replaceFilesAtomically(root, files, updatedContents) {
  const staged = [];
  const committed = [];
  const token = `${process.pid}-${Date.now()}`;

  try {
    let index = 0;
    for (const [key, contents] of updatedContents) {
      const source = files[key];
      const filePath = path.join(root, source.relativePath);
      const fileStat = await stat(filePath);
      const tempPath = path.join(
        path.dirname(filePath),
        `.${path.basename(filePath)}.release-${token}-${index}`,
      );
      await writeFile(tempPath, contents, {
        encoding: "utf8",
        flag: "wx",
        mode: fileStat.mode & 0o777,
      });
      await chmod(tempPath, fileStat.mode & 0o777);
      staged.push({ key, filePath, tempPath, fileStat });
      index += 1;
    }

    for (const item of staged) {
      await rename(item.tempPath, item.filePath);
      committed.push(item);
    }
  } catch (error) {
    const rollbackErrors = [];
    for (const item of committed.reverse()) {
      const rollbackPath = `${item.filePath}.release-rollback-${token}`;
      try {
        await writeFile(rollbackPath, files[item.key].contents, {
          encoding: "utf8",
          flag: "wx",
          mode: item.fileStat.mode & 0o777,
        });
        await chmod(rollbackPath, item.fileStat.mode & 0o777);
        await rename(rollbackPath, item.filePath);
      } catch (rollbackError) {
        rollbackErrors.push(rollbackError);
      } finally {
        await rm(rollbackPath, { force: true });
      }
    }
    if (rollbackErrors.length > 0) {
      throw new AggregateError(
        [error, ...rollbackErrors],
        "version update failed and could not be completely rolled back",
      );
    }
    throw error;
  } finally {
    await Promise.all(staged.map(({ tempPath }) => rm(tempPath, { force: true })));
  }
}

export async function readProjectVersion(root) {
  return (await readProject(root)).currentVersion;
}

function plannedPatchContents(project, nextVersion) {
  project.packageJson.version = nextVersion;
  project.packageLock.version = nextVersion;
  project.packageLock.packages[""].version = nextVersion;
  project.tauriConfig.version = nextVersion;

  return new Map([
    ["packageJson", `${JSON.stringify(project.packageJson, null, 2)}\n`],
    ["packageLock", `${JSON.stringify(project.packageLock, null, 2)}\n`],
    [
      "cargoToml",
      project.cargoToml.replaceVersion(project.currentVersion, nextVersion),
    ],
    [
      "cargoLock",
      project.cargoLock.replaceVersion(project.currentVersion, nextVersion),
    ],
    ["tauriConfig", `${JSON.stringify(project.tauriConfig, null, 2)}\n`],
  ]);
}

function patchFingerprint(project, updatedContents) {
  const aggregate = createHash("sha256");
  for (const key of FINGERPRINT_ORDER) {
    const contents = updatedContents.get(key);
    if (contents === undefined) {
      throw new Error(`planned patch is missing ${project.files[key].relativePath}`);
    }
    const digest = createHash("sha256").update(contents).digest("hex");
    aggregate.update(project.files[key].relativePath);
    aggregate.update("\0");
    aggregate.update(digest);
    aggregate.update("\0");
  }
  return aggregate.digest("hex");
}

async function inspectProjectPatch(root) {
  const project = await readProject(root);
  const nextVersion = nextPatchVersion(project.currentVersion);
  const updatedContents = plannedPatchContents(project, nextVersion);
  return {
    project,
    nextVersion,
    updatedContents,
    fingerprint: patchFingerprint(project, updatedContents),
  };
}

export async function plannedPatchFingerprint(root) {
  return (await inspectProjectPatch(root)).fingerprint;
}

export async function bumpProjectPatchVersion(root) {
  const { project, nextVersion, updatedContents } = await inspectProjectPatch(root);

  await replaceFilesAtomically(root, project.files, updatedContents);
  return { previousVersion: project.currentVersion, version: nextVersion };
}

async function main() {
  const args = process.argv.slice(2);
  let mode = "bump";
  if (args[0]?.startsWith("--")) {
    mode = args.shift().slice(2);
  }
  if (!new Set(["bump", "current", "next", "inspect"]).has(mode) || args.length > 1) {
    throw new Error(
      "usage: bump-version.mjs [--bump|--current|--next|--inspect] [PROJECT_ROOT]",
    );
  }
  const root = path.resolve(args[0] ?? process.cwd());
  if (mode === "bump") {
    const result = await bumpProjectPatchVersion(root);
    console.error(`Version bumped: ${result.previousVersion} -> ${result.version}`);
    process.stdout.write(`${result.version}\n`);
    return;
  }
  const inspection = await inspectProjectPatch(root);
  const currentVersion = inspection.project.currentVersion;
  if (mode === "current") {
    process.stdout.write(`${currentVersion}\n`);
    return;
  }
  const nextVersion = inspection.nextVersion;
  if (mode === "next") {
    process.stdout.write(`${nextVersion}\n`);
    return;
  }
  if (mode === "inspect") {
    process.stdout.write(`${currentVersion}\t${nextVersion}\t${inspection.fingerprint}\n`);
    return;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(`error: ${error.message}`);
    process.exitCode = 1;
  });
}
