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

## GitHub social preview

`github-social-preview.png` is the repository link card. `Scripts/make-social-preview.swift`
renders it from `Resources/AppIcon.png`, the same brand master that feeds the app
icon and the README hero. Regenerate the checked-in card after master changes
to keep these assets aligned.

```bash
swift Scripts/make-social-preview.swift
```

The script writes 1280x640 and fails rather than emitting a file over GitHub's
1 MB upload limit. Regenerating the file does not change the live card: GitHub
exposes no API for the social preview, so uploading it stays a human step under
**Settings -> General -> Social preview**.
