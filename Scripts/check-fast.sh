#!/bin/bash
# Cheap deterministic checks; this never replaces the source or native gates.
set -euo pipefail
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${CHECK_ROOT:-$SCRIPT_ROOT}"
ACTIONLINT="${ACTIONLINT:-$SCRIPT_ROOT/.build-tools/actionlint}"
if [ ! -x "$ACTIONLINT" ]; then
    "$SCRIPT_ROOT/Scripts/install-actionlint.sh" "$(dirname "$ACTIONLINT")"
fi
cd "$ROOT"
Scripts/sync-versions.sh
python3 -B Scripts/check-contrast.py
for file in Scripts/*.sh .githooks/*; do
    [ -f "$file" ] || continue
    bash -n "$file"
done
python3 -B - <<'PY'
import ast
from pathlib import Path
for root in (Path("Scripts"), Path("Tests/ScriptTests")):
    for path in root.glob("*.py"):
        ast.parse(path.read_text(), filename=str(path))
PY
"$ACTIONLINT" -shellcheck=''
echo "Fast checks passed (versions, contrast, shell/Python syntax, workflows)"
