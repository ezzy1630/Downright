# Release and distribution drafts

`Scripts/generate-release-marketing.mjs` turns the current changelog and
canonical version source into a reviewable `release_marketing.json` draft.
It is deliberately local and source-backed: it never posts to GitHub, social
networks, directories, or email services, and it does not add telemetry.

```bash
node Scripts/generate-release-marketing.mjs --output Docs/marketing/release_marketing.json
```

Review the generated highlights against the exact signed app before using any
channel copy. Public release, directory, social, and outreach actions remain
human/account gates.
