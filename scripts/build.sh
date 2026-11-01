#!/usr/bin/env bash
# Собирает ATVRemote.app (ad-hoc подпись, без аккаунта разработчика).
# Использование:  scripts/build.sh [--install] [--open]
#   --install  скопировать в /Applications (нужно для автозапуска при входе)
#   --open     запустить после сборки
set -euo pipefail

cd "$(dirname "$0")/.."

command -v xcodebuild >/dev/null || { echo "Нужен Xcode (xcodebuild)." >&2; exit 1; }
if ! command -v xcodegen >/dev/null; then
  echo "Нужен XcodeGen:  brew install xcodegen" >&2
  exit 1
fi

# мусор в папке ресурсов не должен попасть в бандл
find Resources/python -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

xcodegen generate

xcodebuild \
  -project ATVRemote.xcodeproj \
  -scheme ATVRemote \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
  build

APP="build/Build/Products/Release/ATVRemote.app"
[[ -d "$APP" ]] || { echo "Сборка не создала $APP" >&2; exit 1; }

# повторная ad-hoc подпись всего бандла (на случай «Sign to Run Locally»)
codesign --force --deep --sign - "$APP"
echo "Собрано: $APP"

WANT_OPEN=0
for arg in "$@"; do
  case "$arg" in
    --install)
      rm -rf /Applications/ATVRemote.app
      cp -R "$APP" /Applications/
      xattr -dr com.apple.quarantine /Applications/ATVRemote.app 2>/dev/null || true
      echo "Установлено: /Applications/ATVRemote.app"
      APP="/Applications/ATVRemote.app"
      ;;
    --open) WANT_OPEN=1 ;;
  esac
done
[[ "${WANT_OPEN:-0}" == "1" ]] && open "$APP"
exit 0
