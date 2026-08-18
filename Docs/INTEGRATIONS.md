# Integration contracts

## Current stable entry points

- `down FILE` opens a file in Downright.
- `down open --line N FILE` opens at a one-based line.
- `down open --reveal FILE` opens Finder and does not require Downright.app.
- `down open --review FILE` opens Live mode with the local Review panel.
- `down doctor [--json]` reports installation and integration state without
  changing it.

## Proposed `downright://` handoff

This is documented as a security contract before it is registered in the app.
The only proposed operation is:

```text
downright://open?path=%2Fabsolute%2Fpath%2Fto%2Ffile.md&line=42&review=1
```

Rules for a future implementation:

1. Accept only the `downright` scheme and `open` host.
2. Accept only `path`, positive decimal `line`, and `review=1`; reject unknown
   query keys, fragments, user info, ports, commands, and shell syntax.
3. Require an absolute file path, canonicalize it, and confirm it is an
   existing regular Markdown file before opening.
4. Never execute the URL contents, expand a command, or grant folder access.
5. Treat the URL as an open request only; it cannot save, export, install,
   modify settings, or send data.
6. Register the scheme only after pure parser tests and installed-bundle QA.

The CLI contract is the supported integration today. A URL scheme remains a
separate, reviewable change because external links are an input boundary.
