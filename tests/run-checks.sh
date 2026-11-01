#!/usr/bin/env bash
# Проверки без macOS: Python-тесты демона + (если есть Swift) типизация Core и сквозной тест
# «Swift DaemonClient ↔ реальный демон».
#   tests/run-checks.sh
# Работает и на macOS, и на Linux (на Linux Combine подменяется шимом tests/linux-shim).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

VENV="${VENV:-$ROOT/.venv}"
if [[ ! -x "$VENV/bin/python3" ]]; then
  python3 -m venv "$VENV"
  "$VENV/bin/python3" -m pip install -q -r Resources/python/requirements.txt
fi
PY="$VENV/bin/python3"

echo "== Python: юнит-тесты демона =="
"$PY" -m unittest discover -s tests -p 'test_daemon.py' -v 2>&1 | tail -n 20
echo "== Python: интеграция с реальным pyatv =="
if [[ -z "${PYATV_SRC:-}" ]]; then
  SRC_TMP="$(mktemp -d)"
  ( cd "$SRC_TMP" && "$PY" -m pip download pyatv==0.18.0 --no-deps --no-binary :all: -q && tar xzf pyatv-*.tar.gz )
  PYATV_SRC="$(echo "$SRC_TMP"/pyatv-*/)"
fi
PYATV_SRC="$PYATV_SRC" "$PY" tests/integration_real_pyatv.py

if command -v swiftc >/dev/null; then
  echo "== Swift: Core + RemoteController (типизация) =="
  SHIM=()
  [[ "$(uname)" == "Darwin" ]] || SHIM=(tests/linux-shim/CombineShim.swift)   # на Linux нет Combine и String(localized:)
  swiftc -swift-version 5 -typecheck \
    Sources/ATVRemote/Core/*.swift Sources/ATVRemote/Remote/RemoteController.swift ${SHIM[@]+"${SHIM[@]}"}
  echo "== Swift: сквозной тест DaemonClient ↔ atvd.py --demo =="
  TMP="$(mktemp -d)"
  swiftc -swift-version 5 -parse-as-library -o "$TMP/clienttest" \
    Sources/ATVRemote/Core/*.swift tests/swift-client-test/main.swift ${SHIM[@]+"${SHIM[@]}"}
  "$TMP/clienttest" "$PY" Resources/python/atvd.py
else
  echo "swiftc не найден — Swift-проверки пропущены."
fi
echo "Все проверки пройдены."
