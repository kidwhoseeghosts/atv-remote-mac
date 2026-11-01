#!/usr/bin/env bash
# Запускает демон atvd.py в демо-режиме (виртуальный Apple TV, PIN сопряжения 1234)
# и даёт вводить JSON-команды вручную, например:
#   {"id":1,"cmd":"hello"}
#   {"id":2,"cmd":"scan"}
#   {"id":3,"cmd":"key","key":"up","action":"tap"}
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PY="${PYTHON:-}"
if [[ -z "$PY" ]]; then
  if [[ "$(uname)" == "Darwin" && -x "$HOME/Library/Application Support/ATVRemote/venv/bin/python3" ]]; then
    PY="$HOME/Library/Application Support/ATVRemote/venv/bin/python3"
  else
    PY="$(command -v python3)"
  fi
fi
exec "$PY" "$HERE/../Resources/python/atvd.py" --demo
