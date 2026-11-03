#!/bin/bash
# Reject automatic events and non-main refs before production validation.
set -euo pipefail

if [ "${GITHUB_EVENT_NAME:-}" != workflow_dispatch ] \
    || [ "${GITHUB_REF:-}" != refs/heads/main ]; then
    echo "::error::Release requires manual workflow_dispatch on refs/heads/main" >&2
    exit 1
fi
