#!/usr/bin/env node

import { spawnSync } from "node:child_process";

const installerURL = process.env.DOWNRIGHT_INSTALLER_URL ?? "https://downright.cc/install";

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
  if (!script.startsWith("#!/usr/bin/env bash") || !script.includes("DMG checksum verified")) {
    throw new Error("installer endpoint did not return the expected Downright installer");
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
