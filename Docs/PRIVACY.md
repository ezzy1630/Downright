# Downright Privacy

## Default rule

Downright is local-first. A user can read, edit, save, search, compare, watch,
and export Markdown without an account or network access.

The app does not collect analytics, document content, prompts, model output, or
file names by default. It does not require a cloud service.

## Data flow

| Data | Default location | Use |
|---|---|---|
| Open document text | User-selected file and memory | Read, edit, render |
| External-write snapshot | Local Downright support data | Review and restore |
| Theme and settings | Local Downright support data | Preferences |
| Recent documents | macOS recent-document services | Start window |
| Workspace siblings | Memory during the workspace session | Sidebar display |
| Optional AI input | On-device Apple Intelligence | User-requested action |

Downright does not copy a whole folder into a database. It does not upload
workspace files. A path shown in a document is not opened or executed until the
user clicks it.

## Apple Intelligence

Apple Intelligence is optional, on-device, and off by default. A user action
must start each task. The feature can use selected local text for a summary or
explanation. It must show that the result is generated and must not save or
replace source text without an explicit action.

AI is never part of open, render, edit, save, search, external-write review, or
Quick Look. If Apple Intelligence is unavailable, these features continue with
no change in behavior.

Downright 1.0 has no remote model integration. Any later remote provider needs
separate opt-in, a clear data notice, and an implementation review.

## File access

Downright needs access to files the user opens. The direct-download build is
unsandboxed so it can watch arbitrary paths, resolve sibling files, and open a
path in the user's editor. It does not scan unrelated folders in the
background.

Quick Look receives only the file requested by Finder. It uses the same local
render path and keeps a memory limit. A preview does not send file data over
the network.

## Retention and deletion

Snapshots are local and content-addressed. Users can delete snapshot history
from the app. Settings and themes can be removed from the Downright support
folder. The app does not claim ownership of user Markdown files.

Crash logs and diagnostics are local unless the user chooses to share them.
Logs must not include document text, prompts, or full file paths when a stable
redacted identifier is enough.

## Security controls

- Keep source and rendered state separate.
- Do not execute code blocks, shell commands, or Mermaid scripts.
- Do not follow links or path tokens without a user action.
- Treat external file content as untrusted input.
- Validate revision and document identity before applying async results.
- Make dirty-buffer conflict choices explicit.
- Sign and notarise release builds when distribution work is complete.

## User-facing privacy promises

The product page and settings must state:

1. Local use is the default.
2. AI is optional and on-device in the supported feature.
3. The app does not need an account or cloud sync.
4. Files are not uploaded by the core app.
5. The user controls snapshots and shared diagnostics.

Privacy tests must cover offline operation, Quick Look, workspace scanning,
snapshot deletion, and unavailable Apple Intelligence.
