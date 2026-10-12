#!/usr/bin/env bash
# Optional: runs before packaging. Fail the build by exiting non-zero.
set -euo pipefail
python3 -m py_compile function_app.py
echo "syntax OK"
