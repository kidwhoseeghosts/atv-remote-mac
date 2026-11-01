#!/usr/bin/env bash
# Создаёт venv с pyatv для демона — то же, что делает кнопка «Установить pyatv» в приложении.
# Использование:  scripts/setup_venv.sh [путь_к_venv]
# По умолчанию:   ~/Library/Application Support/ATVRemote/venv  (macOS)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REQ="$HERE/../Resources/python/requirements.txt"

if [[ "$(uname)" == "Darwin" ]]; then
  DEFAULT_VENV="$HOME/Library/Application Support/ATVRemote/venv"
else
  DEFAULT_VENV="${XDG_DATA_HOME:-$HOME/.local/share}/ATVRemote/venv"
fi
VENV="${1:-$DEFAULT_VENV}"

# Ищем Python >= 3.9: сначала Homebrew, потом /usr/bin/python3 (Command Line Tools)
pick_python() {
  local c
  for c in \
    /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.11 \
    /opt/homebrew/bin/python3.10 /opt/homebrew/bin/python3 \
    /usr/local/bin/python3.13 /usr/local/bin/python3.12 /usr/local/bin/python3.11 \
    /usr/local/bin/python3.10 /usr/local/bin/python3 \
    "$(command -v python3.13 2>/dev/null || true)" "$(command -v python3.12 2>/dev/null || true)" \
    "$(command -v python3.11 2>/dev/null || true)" "$(command -v python3 2>/dev/null || true)" \
    /usr/bin/python3; do
    [[ -n "$c" && -x "$c" ]] || continue
    if "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1; then
      echo "$c"; return 0
    fi
  done
  return 1
}

PY="$(pick_python)" || {
  echo "Не найден Python 3.9+. Установите Command Line Tools (xcode-select --install)" >&2
  echo "или Homebrew Python (brew install python)." >&2
  exit 1
}
echo "Python: $PY ($("$PY" --version))"
echo "venv:   $VENV"

mkdir -p "$(dirname "$VENV")"
"$PY" -m venv "$VENV"
"$VENV/bin/python3" -m pip install --upgrade pip
"$VENV/bin/python3" -m pip install -r "$REQ"
"$VENV/bin/python3" -c 'import pyatv; print("pyatv", pyatv.const.__version__)'
echo "Готово."
