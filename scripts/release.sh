#!/usr/bin/env bash
# Собирает релизный ATVRemote.app (universal arm64+x86_64, ad-hoc подпись) и пакует в dist/ATVRemote-<версия>.zip.
# Версия берётся из project.yml (MARKETING_VERSION).
#
#   scripts/release.sh            # universal (arm64 + x86_64)
#   UNIVERSAL=0 scripts/release.sh   # только архитектура этого Mac (быстрее)
#   scripts/release.sh --no-open     # (или NO_OPEN=1) не открывать Finder в конце; в CI не открывается
#
# Требуется: Xcode (xcodebuild), XcodeGen (brew install xcodegen).
set -euo pipefail
cd "$(dirname "$0")/.."

OPEN_FINDER=1
for arg in "$@"; do
  case "$arg" in
    --no-open) OPEN_FINDER=0 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done
[[ -n "${NO_OPEN:-}" || -n "${CI:-}" ]] && OPEN_FINDER=0

command -v xcodebuild >/dev/null || { echo "Need Xcode (xcodebuild)." >&2; exit 1; }
command -v xcodegen  >/dev/null || { echo "Need XcodeGen:  brew install xcodegen" >&2; exit 1; }

VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9A-Za-z.+-]*\)"\{0,1\}.*/\1/p' project.yml | head -n1)"
[[ -n "$VERSION" ]] || { echo "MARKETING_VERSION not found in project.yml" >&2; exit 1; }
echo "==> ATVRemote $VERSION"

find Resources/python -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

xcodegen generate

DERIVED="build/release"
rm -rf "$DERIVED"
ARCH_ARGS=()
if [[ "${UNIVERSAL:-1}" == "1" ]]; then
  ARCH_ARGS=(ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO)
fi

xcodebuild \
  -project ATVRemote.xcodeproj \
  -scheme ATVRemote \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
  build

APP="$DERIVED/Build/Products/Release/ATVRemote.app"
[[ -d "$APP" ]] || { echo "Build did not produce $APP" >&2; exit 1; }

# убираем мусор из бандла и подписываем целиком ad-hoc
find "$APP" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$APP" -name '.DS_Store' -delete 2>/dev/null || true
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "==> Architectures: $(lipo -archs "$APP/Contents/MacOS/ATVRemote")"

mkdir -p dist
ZIP="dist/ATVRemote-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "$SHA  $(basename "$ZIP")" > "$ZIP.sha256"
echo
echo "Release archive: $ZIP"
echo "SHA-256:         $SHA"
echo "Built app:       $(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"

# показываем собранное приложение в Finder
if [[ "$OPEN_FINDER" == "1" && "$(uname)" == "Darwin" ]]; then
  open -R "$APP"
fi
