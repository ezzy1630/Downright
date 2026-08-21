#!/usr/bin/env node

const repository = process.env.HOMEBREW_REPOSITORY || "ezzy1630/Downright";
const starsTarget = Number(process.env.HOMEBREW_STARS_TARGET || 75);
const forksTarget = Number(process.env.HOMEBREW_FORKS_TARGET || 30);
const watchersTarget = Number(process.env.HOMEBREW_WATCHERS_TARGET || 30);
const url = `https://api.github.com/repos/${repository}`;

if (process.argv.includes("--help")) {
  console.log("Usage: node Scripts/check-homebrew-eligibility.mjs [--json]");
  process.exit(0);
}

// Unauthenticated GitHub API calls share a 60 req/h budget per source IP, so
// a shared CI runner can be rate-limited into a raw failure.  Use
// GITHUB_TOKEN when the environment provides one (read-only public data; the
// token only raises the limit and is never logged).
const headers = { accept: "application/vnd.github+json", "user-agent": "downright-homebrew-readiness" };
if (process.env.GITHUB_TOKEN) headers.authorization = `Bearer ${process.env.GITHUB_TOKEN}`;

const response = await fetch(url, { headers });
if (!response.ok) throw new Error(`GitHub API returned ${response.status}`);
const repo = await response.json();
const result = {
  repository,
  observedAt: new Date().toISOString(),
  publicSignals: {
    stars: repo.stargazers_count,
    forks: repo.forks_count,
    watchers: repo.subscribers_count,
    openIssues: repo.open_issues_count,
  },
  heuristic: {
    starsTarget,
    forksTarget,
    watchersTarget,
    meetsConfiguredSignals: repo.stargazers_count >= starsTarget && repo.forks_count >= forksTarget && repo.subscribers_count >= watchersTarget,
    note: "A readiness heuristic is not Homebrew acceptance. Re-check current cask audit rules and independent-interest evidence before opening a PR.",
  },
  action: "monitor",
};
if (process.argv.includes("--json")) console.log(JSON.stringify(result, null, 2));
else {
  console.log(`${repository}: ${result.publicSignals.stars} stars, ${result.publicSignals.forks} forks, ${result.publicSignals.watchers} watchers`);
  console.log(result.heuristic.meetsConfiguredSignals ? "Configured signal threshold reached; verify current Homebrew rules before submitting." : "Keep building independent public interest; do not submit yet.");
}
