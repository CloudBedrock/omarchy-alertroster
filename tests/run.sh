#!/bin/bash
# Everything that can be checked without a running shell:
#   - the scripts parse
#   - Model.js unit tests (node)
#   - the surface bridge and the CLI against a real alertroster-receiverd,
#     when ALERTROSTER_RECEIVERD points at one (skipped otherwise)
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

for f in bin/alertroster-api bin/alertroster-heartbeat bin/alertroster-local bin/alertroster-login bin/alertroster-page; do
  bash -n "$f"
done
python3 -m py_compile bin/alertroster-surface tests/surface_test.py
rm -rf bin/__pycache__ tests/__pycache__
echo "scripts: ok"

node --test tests/model.test.mjs

python3 tests/surface_test.py
