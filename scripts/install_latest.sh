#!/bin/bash
#
# cmdALL 최신 릴리스 설치 스크립트 (맥미니·맥북 공용)
#
# 왜 이 스크립트인가:
#   cmdALL은 adhoc 서명(Apple 공증 안 함)이라, 브라우저·AirDrop·메시지로 받으면
#   macOS Gatekeeper가 격리(com.apple.quarantine) 속성을 붙여
#   "Apple이 악성 코드 없음을 확인할 수 없습니다" 경고로 실행을 막는다.
#   반면 curl로 받은 파일에는 격리 속성이 붙지 않는다. 이 스크립트는 최신 릴리스를
#   curl로 받아 설치하므로 그 경고가 뜨지 않는다. 소스·Xcode 없이 어느 맥에서든 동작.
#
# 사용법:  ./scripts/install_latest.sh
#   (레포 없이 스크립트만 있어도 동작. /Applications 쓰기 권한 없으면 앞에 sudo)
#
set -euo pipefail

REPO="learn-slowly/cmd-docu"
APP="cmdALL.app"
DEST="/Applications"
ZIP_URL="https://github.com/$REPO/releases/latest/download/cmdALL-macos.zip"
SUMS_URL="https://github.com/$REPO/releases/latest/download/SHA256SUMS.txt"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "▸ 최신 릴리스 내려받는 중…"
curl -fL --progress-bar -o "$TMP/cmdALL-macos.zip" "$ZIP_URL"

# 무결성 검증 (SHA256SUMS.txt가 있으면)
if curl -fsL -o "$TMP/SHA256SUMS.txt" "$SUMS_URL"; then
  EXPECTED="$(grep 'cmdALL-macos.zip' "$TMP/SHA256SUMS.txt" | awk '{print $1}')"
  ACTUAL="$(shasum -a 256 "$TMP/cmdALL-macos.zip" | awk '{print $1}')"
  if [ -n "$EXPECTED" ] && [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "✗ 체크섬 불일치 — 설치 중단"
    echo "  기대: $EXPECTED"
    echo "  실제: $ACTUAL"
    exit 1
  fi
  echo "  ✓ 체크섬 일치"
fi

echo "▸ 압축 해제 중…"
ditto -x -k "$TMP/cmdALL-macos.zip" "$TMP/unpacked"
[ -d "$TMP/unpacked/$APP" ] || { echo "✗ zip 안에서 $APP 을(를) 찾지 못함"; exit 1; }

# 실행 중이면 종료
if pgrep -f "$DEST/$APP/Contents/MacOS/" >/dev/null 2>&1; then
  echo "▸ 실행 중인 cmdALL 종료…"
  osascript -e 'quit app "cmdALL"' 2>/dev/null || true
  sleep 1
fi

echo "▸ 설치 중… ($DEST/$APP)"
rm -rf "$DEST/$APP"
cp -R "$TMP/unpacked/$APP" "$DEST/"

# 만일을 대비한 격리 제거 (curl 경로면 원래 없음)
xattr -cr "$DEST/$APP" 2>/dev/null || true

VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
QCNT="$(find "$DEST/$APP" -xattrname com.apple.quarantine 2>/dev/null | wc -l | tr -d ' ')"
echo "✓ 설치 완료 — cmdALL ${VER}  (격리 파일 ${QCNT}개)"
echo "  실행: open \"$DEST/$APP\""
