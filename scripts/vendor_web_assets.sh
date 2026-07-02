#!/bin/bash
# KaTeX·Mermaid 자산을 npm에서 받아 Sources/Resources/web/에 반영한다(버전 갱신 시 재실행).
# 원본 min.js/CSS는 수정하지 않고 그대로 복사하고, KaTeX CSS만 폰트 인라인 전처리 산출물을 별도 파일로 만든다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
npm pack katex@0.16 mermaid@11 --silent
tar xf katex-*.tgz; mv package katex
tar xf mermaid-*.tgz; mv package mermaid
DEST="$ROOT/Sources/Resources/web"
mkdir -p "$DEST/katex" "$DEST/mermaid"
cp katex/dist/katex.min.js "$DEST/katex/"
cp katex/dist/contrib/auto-render.min.js "$DEST/katex/"
cp katex/dist/contrib/mhchem.min.js "$DEST/katex/"
cp mermaid/dist/mermaid.min.js "$DEST/mermaid/"
# 폰트를 data URI로 인라인한 CSS 생성(원본 CSS+fonts/ → katex.inline.min.css)
python3 "$ROOT/scripts/inline_katex_fonts.py" katex/dist/katex.min.css katex/dist/fonts "$DEST/katex/katex.inline.min.css"
{ echo "katex $(node -p "require('./katex/package.json').version")";
  echo "mermaid $(node -p "require('./mermaid/package.json').version")"; } > "$DEST/VERSIONS.txt"
echo "완료: $DEST"
