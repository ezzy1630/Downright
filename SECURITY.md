# Security Policy

Downright is a local-first Markdown editor. It is **unsandboxed by design** —
that is what lets it watch arbitrary paths, open `file.ts:42` in your editor,
and ship the `down` CLI — so the app's security posture is the same as any
native tool you choose to run: it operates with the privileges of the user who
launches it.

## What Downright does not do

- **No telemetry, analytics, or crash reporting.** The only network request the
  app ever makes is the Sparkle update check, and only in production-signed
  builds. See `Docs/PRIVACY.md`.
- **No code execution.** `.mdx`, `.qmd`, and `.rmd` documents can carry
  executable chunks; Downright renders them as text and never evaluates them.
- **No cloud.** The AI assistance panel runs locally when you enable it and
  requires no network.

## Supported versions

| Version | Supported          |
|---------|--------------------|
| 1.x     | :white_check_mark: |

Only the latest release receives security fixes. Updates are delivered through
Sparkle; because Sparkle never downgrades, the fix policy is: **a security fix
ships as a higher-build-number release**, never by modifying or replacing a
published archive.

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

- Use GitHub's private reporting: open the repository's
  **Security → Report a vulnerability** flow. It reaches the maintainers and
  stays private until a fix ships.
- Include the affected version (from `Config/version.env` or the app's About
  window), a minimal reproduction, and — if you have one — a suggested fix.

The maintainers will acknowledge within 5 business days and coordinate a
disclosure timeline (default: 90 days from confirmation).

## Update chain integrity

Updates are the one network conversation the app starts, so they are the one
place an attacker could interfere:

- The appcast feed is Ed25519-signed (`SURequireSignedFeed=YES`); Sparkle
  refuses unsigned or wrong-key feeds.
- Every archive is individually signed with the same Ed25519 key
  (`generate_appcast`), and downloads are validated before extraction.
- The public key is injected into production bundles from the CI secret
  `SPARKLE_ED25519_PUBLIC_KEY`; the committed value in `Config/Downright-Info.plist`
  is a placeholder that disables the updater, never a usable key.

**Key handling rules** (full procedure in `Docs/RELEASE.md`):

- The private key exists only in the `release` environment secret and an
  encrypted offline backup. Never commit it, never put it in a workflow that
  runs on pull requests, and never weaken feed validation to work around a lost
  key.
- Suspected key compromise: stop publishing updates, rotate the key pair,
  ship an anchored recovery release, then replace the CI secrets.

## Reporting a security issue in dependencies

Dependency CVEs (Sparkle, swift-cmark, BeautifulMermaid, SwiftMath) should be
reported through the same private channel, or upstream where the advisory
predates Downright. `Package.resolved` pins exact versions; dependabot-style
updates land in the `[Unreleased]` section of `CHANGELOG.md`.
