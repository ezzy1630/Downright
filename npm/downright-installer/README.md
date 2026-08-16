# @ezzy/downright-installer

Install the signed Downright macOS app into `/Applications`:

```bash
npx --yes @ezzy/downright-installer
```

The launcher fetches the first-party installer at `https://downright.cc/install`.
That installer downloads the latest GitHub release DMG, verifies its published
SHA-256 checksum and code signature, installs the app, registers Quick Look,
and links the `down` and `md` CLI commands in `~/.local/bin` when possible.

Downright keeps its built-in Sparkle updater after installation. The installer
is macOS-only and requires Node.js 18 or newer.
