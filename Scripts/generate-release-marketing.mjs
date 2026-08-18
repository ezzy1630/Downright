#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(scriptDirectory, "..");
const changelogPath = resolve(repositoryRoot, "CHANGELOG.md");
const versionPath = resolve(repositoryRoot, "Config/version.env");

function optionValue(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function git(args) {
  try {
    return execFileSync("git", args, { cwd: repositoryRoot, encoding: "utf8" }).trim();
  } catch {
    return "";
  }
}

function parseVersion(source) {
  return Object.fromEntries(
    source
      .split("\n")
      .map((line) => line.match(/^([A-Z_]+)=(.+)$/))
      .filter(Boolean)
      .map(([, key, value]) => [key, value])
  );
}

function cleanMarkdown(value) {
  return value
    .replace(/\*\*(.*?)\*\*/g, "$1")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/\[([^\]]+)\]\([^\)]+\)/g, "$1")
    .replace(/\s+/g, " ")
    .trim();
}

function parseChangelog(source) {
  const releases = [];
  let release;
  let section;

  for (const line of source.split("\n")) {
    const releaseMatch = line.match(/^## \[([^\]]+)\]/);
    if (releaseMatch) {
      release = { name: releaseMatch[1], sections: [] };
      releases.push(release);
      section = undefined;
      continue;
    }
    const sectionMatch = line.match(/^### (.+)$/);
    if (sectionMatch && release) {
      section = { name: sectionMatch[1], items: [] };
      release.sections.push(section);
      continue;
    }
    const itemMatch = line.match(/^[-*] (.+)$/);
    if (itemMatch && section) section.items.push(cleanMarkdown(itemMatch[1]));
    if (/^\s{2,}\S/.test(line) && section?.items.length) {
      section.items[section.items.length - 1] = cleanMarkdown(
        `${section.items.at(-1)} ${line.trim()}`
      );
    }
  }
  return releases;
}

function score(section, item) {
  const words = item.toLowerCase();
  let value = section === "Added" ? 3 : section === "Changed" ? 2 : 1;
  if (/agent|external|quick look|finder|cli|native|source|review|security|release/.test(words)) value += 2;
  if (/fixed|hardened|crash|xss|safe|signature/.test(words)) value += 1;
  return value;
}

function buildDraft() {
  const version = parseVersion(readFileSync(versionPath, "utf8"));
  const release = parseChangelog(readFileSync(changelogPath, "utf8"))[0] ?? { name: "Unreleased", sections: [] };
  const highlights = release.sections
    .flatMap((section) => section.items.map((item) => ({ section: section.name, item, score: score(section.name, item) })))
    .sort((left, right) => right.score - left.score)
    .slice(0, 8);
  const versionLabel = `${version.MARKETING_VERSION} (build ${version.CURRENT_PROJECT_VERSION})`;
  const first = highlights[0]?.item ?? "Native Markdown reading and editing for macOS.";
  const summary = first.length > 180 ? `${first.slice(0, 177)}...` : first;
  const commit = git(["rev-parse", "HEAD"]);
  const sourceDate = git(["show", "-s", "--format=%cs", "HEAD"]) || new Date().toISOString().slice(0, 10);

  return {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    source: {
      repository: "https://github.com/ezzy1630/Downright",
      commit,
      sourceDate,
      changelogSection: release.name,
    },
    release: {
      version: versionLabel,
      status: release.name === "Unreleased" ? "draft" : "release",
      title: `Downright ${version.MARKETING_VERSION}`,
      summary,
      highlights: highlights.map(({ section, item }) => ({ section, item })),
    },
    channels: {
      github: {
        title: `Downright ${version.MARKETING_VERSION} — ${summary}`,
        body: [
          `Downright ${versionLabel}`,
          "",
          summary,
          "",
          ...highlights.map(({ item }) => `- ${item}`),
          "",
          "Download: https://downright.cc/download/",
        ].join("\n"),
      },
      website: {
        heading: `Downright ${version.MARKETING_VERSION}`,
        excerpt: summary,
        sourceMarkdown: `/releases/${version.MARKETING_VERSION}.md`,
      },
      social: {
        draft: `Downright ${version.MARKETING_VERSION}: ${summary} Read the source-backed release notes and download the signed macOS build at downright.cc/download/.`,
        reviewRequired: true,
      },
    },
    measurement: {
      downloadMetric: "GitHub Downright.dmg asset requests; not unique people or completed installs",
      telemetry: "none",
      attribution: "Use tagged links or landing-page referrers only; do not add device identifiers",
    },
    humanReview: [
      "Confirm every highlighted claim against the shipped app and release artifact.",
      "Replace the draft download URL only after the signed public artifact is verified.",
      "Approve channel copy before publication; this script never posts externally.",
    ],
  };
}

if (process.argv.includes("--help")) {
  console.log("Usage: node Scripts/generate-release-marketing.mjs [--output path]");
  process.exit(0);
}

const output = JSON.stringify(buildDraft(), null, 2) + "\n";
const outputPath = optionValue("--output");
if (outputPath) {
  writeFileSync(resolve(repositoryRoot, outputPath), output, "utf8");
} else {
  process.stdout.write(output);
}
