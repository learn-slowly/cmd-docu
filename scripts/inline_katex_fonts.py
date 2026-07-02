#!/usr/bin/env python3
"""KaTeX CSS의 폰트 참조를 인라인한다.

원본 katex.min.css는 `@font-face`의 `src:`에서 `url(fonts/…woff2)` 같은 상대경로로
폰트를 참조한다. 이 CSS를 WKWebView에 인라인 `<style>`로 주입하면 상대경로 기준이
없어 폰트 로드가 깨진다. 그래서 각 `src:` 목록에서 woff2 파일을 base64 data URI로
치환하고, 같은 목록의 woff/ttf 폴백 참조는 제거한다(woff2만 유지 — WKWebView 지원).

사용법: inline_katex_fonts.py <입력 CSS> <fonts 디렉터리> <출력 CSS>
"""

import base64
import re
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 4:
        print("사용법: inline_katex_fonts.py <입력 CSS> <fonts 디렉터리> <출력 CSS>",
              file=sys.stderr)
        return 2

    css_path = Path(sys.argv[1])
    fonts_dir = Path(sys.argv[2])
    out_path = Path(sys.argv[3])

    css = css_path.read_text(encoding="utf-8")

    # `src:` 선언 하나를 통째로 매칭한다(값 뒤 종결자는 `;` 또는 `}` — 최소화 CSS 대응).
    src_pattern = re.compile(r"src:([^;}]+)([;}])")
    # 값 목록에서 woff2 참조만 골라 파일명 추출.
    woff2_pattern = re.compile(r"url\(\s*fonts/([^)\s]+\.woff2)\s*\)")

    missing: list[str] = []

    def replace_src(match: re.Match) -> str:
        value = match.group(1)
        terminator = match.group(2)

        found = woff2_pattern.search(value)
        if not found:
            # woff2가 없는 src는 그대로 둔다(KaTeX 0.16은 전부 woff2 보유 — 방어적 처리).
            return match.group(0)

        filename = found.group(1)
        font_file = fonts_dir / filename
        if not font_file.is_file():
            missing.append(filename)
            return match.group(0)

        b64 = base64.b64encode(font_file.read_bytes()).decode("ascii")
        data_uri = f"url(data:font/woff2;base64,{b64}) format(\"woff2\")"
        # woff/ttf 폴백은 버리고 woff2 data URI 하나만 남긴다.
        return f"src:{data_uri}{terminator}"

    inlined = src_pattern.sub(replace_src, css)

    if missing:
        print(f"경고: fonts 디렉터리에서 찾지 못한 파일 {len(missing)}개: {missing}",
              file=sys.stderr)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(inlined, encoding="utf-8")

    remaining = inlined.count("url(fonts/")
    print(f"인라인 완료: {out_path} (잔존 url(fonts/ = {remaining})")
    if remaining != 0:
        print("오류: url(fonts/ 참조가 남아 있다 — 인라인 실패.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
