#!/usr/bin/env node

import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";

const installerURL = process.env.DOWNRIGHT_INSTALLER_URL ?? "https://downright.cc/install";

// The installer endpoint serves the repository's Scripts/install-release.sh.
// Piping a fetched script straight into bash would make any compromise of
// that endpoint arbitrary code execution at user privileges, so the expected
// SHA-256 is pinned here and verified before a single byte runs.  Update this
// constant in the same commit that changes install-release.sh.
const INSTALLER_SHA256 =
  "f16cc08d8c3048c9e37b2aeaac1adfd84b0059036986ef009d9c03dda1d2b0f2";

if (process.platform !== "darwin") {
  console.error("Downright is currently available through this installer on macOS only.");
  process.exit(1);
}

try {
  const response = await fetch(installerURL, {
    headers: { Accept: "text/plain" },
    redirect: "follow",
  });

  if (!response.ok) {
    throw new Error(`installer endpoint returned HTTP ${response.status}`);
  }

  const script = await response.text();
  const digest = createHash("sha256").update(script).digest("hex");
  if (digest !== INSTALLER_SHA256) {
    throw new Error(
      `installer script failed integrity check (expected ${INSTALLER_SHA256}, got ${digest})`,
    );
  }

  const result = spawnSync("/bin/bash", ["-s", "downright-release-installer"], {
    env: process.env,
    input: script,
    stdio: ["pipe", "inherit", "inherit"],
  });

  if (result.error) throw result.error;
  process.exit(result.status ?? 1);
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`Downright installer failed: ${message}`);
  process.exit(1);
}
