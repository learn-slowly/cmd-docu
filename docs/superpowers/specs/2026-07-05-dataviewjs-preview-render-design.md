# dataviewjs 프리뷰 렌더 — 설계 (2026-07-05)

## 1. 배경·목표

옵시디언 Dataview 플러그인의 `dataviewjs` 블록(노트 안 JS가 `dv` API로 볼트를 질의해 표·목록을 렌더)을 cmdALL 프리뷰에서도 렌더한다. 사용자 볼트(notebox) 실사용은 주간리뷰·월간리뷰 템플릿 2종에서 파생된 37개 파일이 전부이고, 쓰는 API가 균일해 서브셋 경계가 명확하다(§3 전수 조사).

**성공 기준**: 주간·월간 회고 노트가 cmdALL 프리뷰에서 옵시디언과 같은 표/목록으로 보인다. 서브셋 밖 API를 쓰는 블록은 명확한 안내와 함께 코드 표시로 폴백한다.

## 2. 사용자 결정 (2026-07-05)

1. **지원 범위**: 실사용 서브셋 + 흔한 API 여유분(`dv.tasks`·태그 소스·`dv.page()`·frontmatter 필드 접근).
2. **실행 정책**: 볼트 안(등록 볼트 + 인덱스 등록 폴더 하위)만 자동 실행, 밖(Downloads 등)은 클릭-투-런.
3. **아키텍처**: C안 — JavaScriptCore 실행, 결과 HTML만 프리뷰에 삽입(§5).

## 3. 지원 API 범위

### 실사용 전수 (notebox 37파일 grep, 반드시 지원)

| API | 비고 |
|---|---|
| `dv.current()` | `.file.name`, `.file.folder` |
| `dv.pages('"<폴더>"')` | 폴더 소스, **하위 폴더 재귀 포함**(Dataview 시맨틱) |
| DataArray `.where/.sort/.map/.length` + 순회 | `dv.pages` 반환값 체이닝 |
| `p.file.name/folder/day/link/lists` | `lists`: 리스트 항목의 `text`·`header.subpath`·`tags` |
| `dv.date(문자열)` | 파일명 등에서 날짜 파싱 |
| `dv.luxon` | `DateTime.fromObject({weekYear,weekNumber,weekday})`·`.plus()`·비교 |
| `dv.table(headers, rows)` | 셀 안 `<br>` HTML 허용 |
| `dv.list(items)` / `dv.paragraph(text)` | |

### 여유분 (결정 1 — 실사용 0건이지만 흔한 API)

- `dv.tasks` 성격의 접근: `p.file.tasks`(lists 중 체크박스 항목, `completed`·`text`)
- 태그 소스: `dv.pages("#태그")`(frontmatter tags + 인라인 태그)
- `dv.page("이름/경로")` 단건 조회
- 페이지의 frontmatter 필드 접근(`p.필드명`, `p.file.frontmatter`)
- `p.file.path/mtime/ctime`, `dv.pages()`(무인자 — 현재 노트가 속한 볼트/등록 폴더 루트 하위 전체, 볼트 밖 클릭-투-런 문맥에서는 현재 노트의 폴더 재귀)
- `dv.header(level, text)`, `dv.span(text)` — 텍스트 출력 계열(DOM 불필요)

### 비지원 (명시 폴백)

`dv.el`/컨테이너 DOM 조작, `dv.view()`(외부 스크립트 로드), `dv.io`, `dv.query/tryQuery`(DQL 문자열 실행), DQL(` ```dataview `) 블록 — 전부 실사용 0건. DQL은 별도 파서가 필요한 사실상 딴 기능이라 후속 별건. 비지원 API 호출 시 그 블록만 오류 카드(§8)로 폴백.

## 4. 왜 JavaScriptCore인가 (C안 근거)

`dv.pages(...)`는 **동기 API**다. WKWebView의 JS→네이티브 브릿지는 비동기뿐이라, 웹뷰 안 실행은 "필요 데이터를 실행 전에 추측해 선주입"(빗나가면 빈 결과, 대형 폴더는 수 MB) 아니면 코드 변형이 필요하다. `JSContext`(JavaScriptCore, macOS 내장·의존성 0)는 네이티브 함수를 **동기로** 노출할 수 있어 온디맨드 공급이 자연스럽다.

보안 부수 효과: JSContext에는 fetch/XHR/DOM/네트워크 API가 아예 없어, 악성 블록이 볼트 메타데이터를 읽어도 **밖으로 보낼 방법 자체가 없다**. 실행 정책(결정 2)과 이중 방어.

트레이드오프: DOM 직접 조작 API 불가(실사용 0건 — §3 비지원에 명시).

## 5. 아키텍처

신규는 전부 별도 파일, 기존 코드는 가산만(업스트림 머지 용이 원칙).

### 신규 컴포넌트

- **`DataviewBlockExtractor`** (순수): 마크다운에서 ` ```dataviewjs ` 펜스 블록을 추출(코드·범위)하고, 각 블록을 고유 id의 placeholder `<div>`로 치환한 마크다운을 돌려준다. 기존 렌더러의 코드펜스 마스킹과 간섭하지 않도록 렌더 전 단계에서 동작.
- **`DataviewPageIndex`** (actor): 페이지 메타 공급자. 폴더(재귀)·태그·단건 조회에 대해 `DataviewPageMeta`(§6) 배열을 돌려준다. 파일당 mtime 캐시(ContentExtractor 캐시 패턴). frontmatter 분리는 `CompanionNote.splitFrontmatter` 공용 로직 재사용, 대상 확장자는 md/markdown(+txt 제외 — Dataview도 md만 색인).
- **`DataviewEngine`**: JSContext 래퍼. 초기화 시 `luxon.min.js`+`dv-shim.js`(둘 다 로컬 동봉) 로드, 블록 코드 실행, `dv.table/list/paragraph/header/span` 호출을 수집해 **HTML 문자열로 직렬화**해 반환. 네이티브 브릿지는 동기 함수 소수(`__dvPages(source)`·`__dvPage(path)`)만 JSExport. 실행 시간 제한은 `JSContextGroupSetExecutionTimeLimit`(JavaScriptCore C API, 3초)로 강제.
- **`Resources/web/dv-shim.js`**: `dv` 객체 구현(DataArray·current/pages/date/luxon/렌더 수집). luxon은 `scripts/vendor_web_assets.sh`에 luxon 3.x 다운로드 추가(KaTeX/Mermaid 동봉 패턴, THIRD-PARTY-NOTICES 갱신 — luxon은 MIT).

### 기존 코드 가산점

- **`MarkdownRenderer.renderToHTML`** 경로: 렌더 전에 Extractor로 블록 치환. placeholder에는 "실행 중…" 스피너 마크업(자동 실행 대상) 또는 코드 미리보기+실행 버튼(클릭-투-런).
- **`PreviewView`**(WKWebView): 렌더 후 백그라운드에서 엔진 실행 → 완료 시 `evaluateJavaScript`로 placeholder `innerHTML` 교체(Mermaid 후처리와 같은 결). 클릭-투-런 버튼은 기존 웹뷰→네이티브 메시지 핸들러 경로로 실행 요청.
- **링크**: `p.file.link`는 기존 위키링크와 동일한 `<a class="wiki-link" href=…>` 형태로 직렬화 — 클릭 시 기존 프리뷰 링크 동선(LinkedNoteResolver)을 그대로 탄다.

### 데이터 흐름

```
프리뷰 렌더 요청
→ DataviewBlockExtractor: 블록 추출·placeholder 치환
→ MarkdownRenderer: 본문 HTML 즉시 표시(블록 자리는 스피너/실행 버튼)
→ [자동 실행 대상] DataviewEngine(블록별): 코드 실행
     └ dv.pages(...) → 동기 브릿지 → DataviewPageIndex(mtime 캐시 파싱)
→ 결과 HTML → evaluateJavaScript로 placeholder 교체
```

## 6. 데이터 모델 (`DataviewPageMeta`)

JSContext에 넘기는 페이지 1건의 구조(JSON 직렬화):

```
{ name, folder, path,                    // 파일 식별
  day: "2026-07-05" | null,             // 파일명 날짜(YYYY-MM-DD) 또는 frontmatter date
  mtime, ctime,                          // epoch ms
  tags: [...],                           // frontmatter tags + 인라인 태그(#…)
  frontmatter: {...},                    // YAML 최상위 키(문자열/숫자/불리언/배열)
  lists: [ { text, headerSubpath, tags: [...],
             task: bool, completed: bool } ] }
```

- `file.day` 유래: 파일명에 든 날짜 우선, 없으면 frontmatter `date` — 실사용 블록이 `p.file.day || dv.date(p.file.name)` 형태라 어느 쪽이든 동작하지만, 옵시디언과의 우선순위 일치는 구현 시 실측으로 확정(확인 필요).
- `lists` 파싱: 마크다운 리스트 항목(`- `·`* `·체크박스)을 직전 헤딩 경로와 함께 수집. 중첩 리스트는 항목 단위로 평탄화(실사용 블록은 중첩 구분을 쓰지 않음).
- shim이 이 JSON을 Dataview 모양(`p.file.link` 객체, luxon `DateTime`으로의 `day` 변환 등)으로 감싼다.

## 7. 실행 정책 (결정 2)

- **자동 실행**: 노트 경로가 `settings.vaults[].path` 또는 `settings.indexedFolders` 하위('/' 경계 비교 — 기존 경로 prefix 관례)일 때.
- **클릭-투-런**: 그 외. 블록 자리에 코드(하이라이트)+"이 블록 실행" 버튼. 한 번 실행하면 그 탭에서 그 문서가 열려 있는 동안은 재렌더 시 자동 재실행, 탭을 닫으면 초기화. 영구 화이트리스트는 만들지 않는다(YAGNI).
- 설정 토글(예: "dataviewjs 렌더 끄기")은 두지 않는다 — 볼트 밖 기본이 이미 안전하고, 표면 최소화.

## 8. 에러 처리

- JS 예외·타임아웃(3s)·비지원 API 호출: 그 블록만 오류 카드 — 한국어 한 줄 원인(예: "이 블록은 cmdALL이 지원하지 않는 dv.el을 사용합니다") + 원본 코드 접힌 `<details>`. 다른 블록·본문 렌더는 계속.
- 개별 노트 파싱 실패(깨진 frontmatter 등): 그 노트만 건너뛰고 결과에 미포함(Dataview와 동일한 관용).
- 엔진/자산 로드 실패(shim 누락 등): 전 블록을 코드 표시 폴백 + 콘솔 로그.

## 9. 성능

- 위클리 블록은 Calendar 전체(하위 연도 폴더 포함, 수백 파일)를 질의 — 첫 실행 파싱 ~1초대 예상, 이후 mtime 캐시로 수십 ms. 엔진 실행은 백그라운드, 본문이 먼저 뜨고 블록이 채워진다.
- JSContext는 문서(탭)당 재사용하지 않고 **블록 실행 단위로 생성·폐기**(블록 간 전역 오염 방지).
- 캐시는 `DataviewPageIndex` actor 내부(경로→(mtime, meta)). 폴더 워처 연동은 하지 않는다 — 재렌더 시 mtime 비교로 충분.

## 10. 테스트 전략

- **엔진 e2e(핵심)**: JSContext는 헤드리스라 XCTest에서 결정적 실행 가능 — **실제 주간리뷰·월간리뷰 블록 전문을 fixture로**, 가짜 페이지 세트를 주입해 주차 계산·lists 집계·테이블/리스트 HTML까지 검증. 오류 카드(예외·타임아웃·비지원 API)도 단위 검증.
- **순수 단위**: Extractor(펜스 경계·인라인 코드 비오작동), PageIndex 파서(day 파싱·lists 헤딩 경로·태그·frontmatter), HTML 직렬화(이스케이프·`<br>` 허용·wiki-link 앵커), 실행 정책 판정('/' 경계).
- **수동**: 웹뷰 placeholder 교체, 클릭-투-런 동선, 실 notebox 위클리 노트 옵시디언 대조.

## 11. 안 만드는 것

DQL(` ```dataview `) 파서(후속 별건), `dv.el`/DOM 조작, `dv.view`/`dv.io`, 인라인 필드(`키:: 값`) 색인(실사용 0건 — frontmatter만), 영구 실행 화이트리스트, 폴더 워처 연동 캐시 무효화, 웹뷰 안 JS 실행.

## 12. 확인 필요 (구현 중 실측)

- `file.day`의 파일명 vs frontmatter 우선순위(옵시디언 실측 대조).
- Dataview 폴더 소스의 경로 매칭 세부(따옴표·상대경로 표기) — 실사용은 `dv.current().file.folder` 삽입 형태뿐이라 그 형태 우선.
- luxon `weekYear/weekNumber` 주차 계산이 옵시디언 동봉 luxon과 버전 차 없이 일치하는지(W27 경계 실측).
