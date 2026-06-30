# Third-Party Notices

cmd-docu는 [CmdMD](https://github.com/johnfkoo951/CmdMD)(MIT, 구요한/CMDSPACE)의 포크이며,
아래 오픈소스 구성요소를 사용합니다. 각 구성요소의 저작권 및 라이선스 고지를 보존합니다.
원본 CmdMD와 cmd-docu 자체의 라이선스는 저장소 루트의 `LICENSE`를 참고하세요.

버전은 `Package.resolved` 기준이며, 라이선스 원문은 각 저장소의 LICENSE 파일에서 확인했습니다.

---

## 1. 앱 바이너리에 포함되는 구성요소 (Swift Package 의존성)

빌드 시 정적으로 링크되어 배포 `.app`에 포함됩니다.

### highlight.js 11.11.1
- 저장소: https://github.com/highlightjs/highlight.js
- 라이선스: BSD-3-Clause License
- Copyright (c) 2006-2025 Josh Goebel <hello@joshgoebel.com> and other contributors
- 라이선스 원문 헤더(highlight.min.js 상단): `License: BSD-3-Clause`
- 비고: Highlightr Swift 패키지가 내부적으로 번들하는 JavaScript 라이브러리. cmd-docu의
  미리보기 렌더러(`LocalWebAssets`)도 동일 번들 파일을 인라인 주입하므로 별도 항목으로 기재.
  §4 BSD-3-Clause 전문은 아래 별도 항목 참조.

### Highlightr 2.3.0
- 저장소: https://github.com/raspu/Highlightr
- 라이선스: MIT License
- Copyright (c) 2016 Illanes, Juan Pablo

### Yams 5.4.0
- 저장소: https://github.com/jpsim/Yams
- 라이선스: MIT License (The MIT License (MIT))
- Copyright (c) 2016 JP Simard

### swift-cmark 0.8.0 (cmark-gfm)
- 저장소: https://github.com/swiftlang/swift-cmark
- 라이선스: BSD 2-Clause "Simplified" License
- 원본 cmark 저작권: Copyright (c) 2014, John MacFarlane
- 비고: swift-markdown이 의존하는 GitHub-flavored CommonMark 파서. 원본 cmark의 BSD-2 라이선스가 동일하게 적용됩니다.

### swift-markdown 0.8.0
- 저장소: https://github.com/swiftlang/swift-markdown
- 라이선스: Apache License v2.0 with Runtime Library Exception
- Copyright (c) Apple Inc. and the Swift project authors
- 라이선스 원문: https://swift.org/LICENSE.txt
- 비고: Runtime Library Exception에 따라, 컴파일 결과 일부가 바이너리에 포함되어 재배포되더라도 별도 attribution 의무가 면제됩니다(본 고지는 보존 차원).

---

## 2. 런타임에 CDN으로 로드 (앱 바이너리에 미포함)

다이어그램·수식 렌더링을 위해 실행 시 CDN에서 불러오며, 앱에 번들되지 않습니다.

- **Mermaid** — 다이어그램. MIT License로 알려져 있습니다(정확한 고지는 https://github.com/mermaid-js/mermaid 참조).
- **KaTeX** — 수식. MIT License로 알려져 있습니다(정확한 고지는 https://github.com/KaTeX/KaTeX 참조).

> CDN 로드분은 재배포가 아니므로 라이선스 동봉 의무는 약하나, 사용 사실을 위와 같이 밝혀 둡니다.

## 3. 외부 CLI (Process 호출, 앱에 미포함)

별도 설치되어 서브프로세스로 호출됩니다. 앱에 재구현·번들되지 않으므로 본 앱의 배포물에 라이선스가 전파되지 않습니다.

- **kordoc** (Node) — 한글/오피스 문서 변환·편집. https://www.npmjs.com/package/kordoc
- **claude** (Claude CLI) — AI 질의. 사용자가 별도 설치·로그인합니다.

---

## 4. 라이선스 전문

### MIT License (Highlightr, Yams 공통 본문)

> 저작권 고지는 위 각 항목의 Copyright 줄을 따릅니다. 아래는 공통 본문입니다.

```
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### BSD-3-Clause License (highlight.js)

> Copyright (c) 2006-2025 Josh Goebel <hello@joshgoebel.com> and other contributors

```
Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this
   list of conditions and the following disclaimer in the documentation and/or
   other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors may
   be used to endorse or promote products derived from this software without
   specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
OF THE POSSIBILITY OF SUCH DAMAGE.
```

### BSD 2-Clause License (swift-cmark / 원본 cmark)

```
Copyright (c) 2014, John MacFarlane

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this
   list of conditions and the following disclaimer in the documentation and/or
   other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### Apache License v2.0 with Runtime Library Exception (swift-markdown)

전문은 https://swift.org/LICENSE.txt 를 참조하세요. Runtime Library Exception 요지는
"이 소프트웨어로 소스를 컴파일하여 그 일부가 바이너리에 포함되더라도, 원래 요구되는
attribution 없이 재배포할 수 있다"입니다.

---

*본 고지는 `Package.resolved`의 의존성을 기준으로 작성되었습니다. 의존성 버전이 바뀌면 이 파일도 함께 갱신하세요. (이 문서는 법률 자문이 아닙니다.)*
