# 오피스 본문 검색 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 폴더 검색이 HWP·오피스 본문에서도 일치 줄을 찾는다(kordoc 변환 + 세션 캐시), 결과 클릭 시 해당 파일을 연다.

**Architecture:** `KordocService`에 변환 마크다운 캐시(경로+mtime)를 두고 `markdown(for:)`를 추가한다. `performSearch`에 `includeOfficeBody` 분기를 더해 오피스 파일은 캐시된 마크다운을 `contentLineMatches`로 검색해 `.officeBody` 결과로 만든다. Omnisearch(실시간)는 opt-out한다. 결과 행은 "내용" 라벨, 클릭 시 `openDocument`(읽기전용 오피스 리더).

**Tech Stack:** Swift 5.9+ / SwiftUI / Foundation / 외부 kordoc / XCTest. macOS 14+.

## Global Constraints
- macOS 14+, Swift 5.9+. 비샌드박스. kordoc 직접 구현 금지(Process). 추가 의존성 없음.
- Phase 게이트: 각 Task 테스트 + **기존 94개 XCTest 전부 통과**. `swift test`는 정식 Xcode에서만.
- 기존 검색(md/txt/PDF/파일명)·읽기 동작 불변. **Omnisearch(실시간)는 오피스 변환 금지**(opt-out).
- 변환 실패는 조용히 건너뜀(파일명 매칭은 유지), 크래시 금지. 캐시는 세션 메모리(mtime 기준 무효화).
- 신규 로직 분리, 마크다운·이미지·PDF·오피스 읽기 동작 불변.
- 커밋 메시지 한국어. **모든 커밋 끝에**:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
  ```
- 작업 브랜치: `cmd-docu`.

## File Structure
| 파일 | 책임 | 변경 |
| --- | --- | --- |
| `Sources/Models/Workspace.swift` | `SearchMatchKind.officeBody` | 수정 |
| `Sources/Views/SidebarView.swift` | 결과 행 "내용" 라벨 + 클릭 분기 | 수정 |
| `Tests/CmdMDTests/SearchResultKindTests.swift` | `.officeBody` 케이스 | 수정 |
| `Sources/Services/KordocService.swift` | 변환 캐시 + `markdown(for:)` | 수정 |
| `Sources/App/AppState.swift` | `performSearch` includeOfficeBody + 분기, `searchContent` opt-out | 수정 |

현재 코드 참고:
- `SearchMatchKind { filename, line, pdfPage }`(`Workspace.swift`). `SearchResult` init kind 기본 `.line`.
- `SearchResultRow.badge`(switch kind)·`SearchResultsList` onTap(switch kind) — 둘 다 exhaustive switch라 새 케이스 추가 시 양쪽 갱신 필요.
- `KordocService` actor: `convert(fileURL:) async throws -> KordocResult`.
- `AppState.performSearch(query:in:includeFilenames:includePDFBody:)`: `textExtensions=[md,markdown,txt]` 본문 + `includePDFBody` PDF, 파일 루프 시작에 `if Task.isCancelled { return results }`, maxResults=500, `private let kordocService`.
- `AppState.searchContent(query:)`: `performSearch(..., includeFilenames:false, includePDFBody:false)`.
- `AppState.contentLineMatches(in:fileURL:query:)`: `.line` 결과 배열(줄번호 1-base).
- `DocumentKind.officeExtensions` 존재.

---

## Task 1: SearchMatchKind.officeBody + 결과 행 라벨/클릭

**Files:**
- Modify: `Sources/Models/Workspace.swift` (`enum SearchMatchKind`)
- Modify: `Sources/Views/SidebarView.swift` (`SearchResultRow.badge`, `SearchResultsList` onTap)
- Test: `Tests/CmdMDTests/SearchResultKindTests.swift`

**Interfaces:**
- Produces: `SearchMatchKind.officeBody`; 행 라벨 "내용"; `.officeBody` 클릭 → `openDocument(at:inNewTab:true)`

- [ ] **Step 1: 실패 테스트 작성**

`Tests/CmdMDTests/SearchResultKindTests.swift` 클래스 안에 추가(기존 `rangeIn` 헬퍼 사용):
```swift
    func testOfficeBodyKindPreserved() {
        let s = SearchResult(fileURL: URL(fileURLWithPath: "/tmp/report.hwp"),
                             lineNumber: 7, lineContent: "예산 내용 줄",
                             matchRange: rangeIn("예산 내용 줄"), kind: .officeBody)
        XCTAssertEqual(s.kind, .officeBody)
        XCTAssertEqual(s.lineNumber, 7)
    }
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter SearchResultKindTests`
Expected: FAIL — `type 'SearchMatchKind' has no member 'officeBody'`

- [ ] **Step 3: enum에 케이스 추가**

`Sources/Models/Workspace.swift` `enum SearchMatchKind`에 케이스 추가:
```swift
enum SearchMatchKind {
    case filename
    case line
    case pdfPage
    case officeBody
}
```

- [ ] **Step 4: SidebarView 라벨/클릭 갱신(exhaustive switch)**

`Sources/Views/SidebarView.swift`의 `SearchResultRow.badge` switch에 케이스 추가:
```swift
        case .officeBody: return "내용"
```
`SearchResultsList`의 onTap switch에 케이스 추가(읽기전용 오피스 리더가 kind 분기로 열림):
```swift
                                case .officeBody:
                                    appState.openDocument(at: result.fileURL, inNewTab: true)
```

- [ ] **Step 5: 통과 + 빌드**

Run: `swift test --filter SearchResultKindTests` 그리고 `swift build`
Expected: PASS + Build complete!(switch exhaustive 충족)

- [ ] **Step 6: 커밋**
```bash
git add Sources/Models/Workspace.swift Sources/Views/SidebarView.swift Tests/CmdMDTests/SearchResultKindTests.swift
git commit -m "$(cat <<'EOF'
오피스 본문 검색: SearchMatchKind.officeBody + 결과 행 "내용"·클릭

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
EOF
)"
```

---

## Task 2: KordocService 변환 캐시 + markdown(for:)

**Files:**
- Modify: `Sources/Services/KordocService.swift`

**Interfaces:**
- Consumes: 기존 `convert(fileURL:) async throws -> KordocResult`
- Produces: `func KordocService.markdown(for fileURL: URL) async throws -> String` (캐시 적용)

빌드 게이트(서브프로세스/파일시스템이라 단위테스트 없음; Task 4 실제 HWP로 검증).

- [ ] **Step 1: 캐시 + markdown(for:) 추가**

`Sources/Services/KordocService.swift`의 `actor KordocService` 안에, 기존 프로퍼티(`timeout`) 근처에 캐시 추가:
```swift
    /// 변환 마크다운 세션 캐시(키=경로, 값=수정시각+마크다운). 같은 파일 재검색 시 재변환 방지.
    private var markdownCache: [String: (mtime: Date, markdown: String)] = [:]
```
`convert(...)` 함수 아래(같은 actor 안)에 추가:
```swift
    /// 변환된 마크다운만 반환(캐시 사용). 파일 수정시각이 바뀌면 재변환한다.
    func markdown(for fileURL: URL) async throws -> String {
        let key = fileURL.path(percentEncoded: false)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: key))?[.modificationDate] as? Date
        if let mtime, let hit = markdownCache[key], hit.mtime == mtime {
            return hit.markdown
        }
        let result = try await convert(fileURL: fileURL)
        if let mtime {
            markdownCache[key] = (mtime, result.markdown)
        }
        return result.markdown
    }
```

- [ ] **Step 2: 빌드 + 전체 테스트**

Run: `swift build && swift test`
Expected: Build complete! + 기존 94 + Task1 신규 PASS(서비스는 아직 검색에서 미사용)

- [ ] **Step 3: 커밋**
```bash
git add Sources/Services/KordocService.swift
git commit -m "$(cat <<'EOF'
오피스 본문 검색: KordocService 변환 캐시 + markdown(for:)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
EOF
)"
```

---

## Task 3: performSearch 오피스 분기 + Omnisearch opt-out

**Files:**
- Modify: `Sources/App/AppState.swift` (`performSearch`, `searchContent`)

**Interfaces:**
- Consumes: `SearchMatchKind.officeBody`(Task 1), `KordocService.markdown(for:)`(Task 2), `DocumentKind.officeExtensions`, `contentLineMatches`
- Produces: 사이드바 검색이 오피스 본문 결과(`.officeBody`) 생성; Omnisearch는 오피스 변환 안 함

빌드 + 전체 테스트 게이트(통합은 Task 4 수동).

- [ ] **Step 1: performSearch 시그니처 + 오피스 분기**

`Sources/App/AppState.swift` `performSearch` 시그니처에 파라미터 추가:
```swift
    private func performSearch(query: String, in folder: URL,
                               includeFilenames: Bool = true,
                               includePDFBody: Bool = true,
                               includeOfficeBody: Bool = true) async -> [SearchResult] {
```
본문 if/else 체인에서 PDF 분기(`} else if includePDFBody, DocumentKind.pdfExtensions.contains(ext) { ... }`) **다음에** 오피스 분기 추가:
```swift
            } else if includeOfficeBody, DocumentKind.officeExtensions.contains(ext) {
                if let md = try? await kordocService.markdown(for: fileURL) {
                    for hit in Self.contentLineMatches(in: md, fileURL: fileURL, query: query) {
                        results.append(SearchResult(
                            fileURL: fileURL,
                            lineNumber: hit.lineNumber,
                            lineContent: hit.lineContent,
                            matchRange: hit.matchRange,
                            kind: .officeBody
                        ))
                        if results.count >= maxResults { return results }
                    }
                }
            }
```
(파일명 매칭은 기존대로 루프 앞에서 처리됨. 변환 실패는 `try?` nil → 조용히 건너뜀. 기존 `if Task.isCancelled { return results }`가 루프 시작에 있어 취소 시 중단.)

- [ ] **Step 2: searchContent opt-out**

같은 파일 `searchContent(query:)`의 호출에 `includeOfficeBody: false` 추가:
```swift
    func searchContent(query: String) async -> [SearchResult] {
        guard let folder = currentFolder, !query.isEmpty else { return [] }
        return await performSearch(query: query, in: folder,
                                   includeFilenames: false, includePDFBody: false,
                                   includeOfficeBody: false)
    }
```

- [ ] **Step 3: 빌드 + 전체 테스트**

Run: `swift build && swift test`
Expected: Build complete! + 모든 테스트 PASS(94 + Task1 신규)

- [ ] **Step 4: 커밋**
```bash
git add Sources/App/AppState.swift
git commit -m "$(cat <<'EOF'
오피스 본문 검색: performSearch 오피스 분기 + Omnisearch opt-out

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
EOF
)"
```

---

## Task 4: 수동 검증

코드 변경 없음. 실제 HWP 포함 폴더로 확인.

- [ ] **Step 1: 앱 실행**
```bash
pkill -f ".build/arm64-apple-macosx/debug/CmdMD" 2>/dev/null; true
swift run CmdMD
```

- [ ] **Step 2: 체크리스트** (`~/Desktop/cmd-docu-samples` 폴더를 Open Folder, 사이드바 검색)
- [ ] HWP 본문에 있는 단어로 검색 → **"내용"** 라벨 결과로 뜸
- [ ] 그 결과 클릭 → 해당 HWP가 (읽기전용) 열림
- [ ] 같은 검색 재실행 → 빠름(캐시); 파일을 수정 후 검색하면 갱신
- [ ] ⌘ 팔레트 **Omnisearch**는 오피스 본문 안 섞이고 빠름(텍스트 줄만 — 회귀 없음)
- [ ] md/txt 본문(Line N)·PDF 본문(p.N)·파일명(이름) 검색 회귀 없음
- [ ] HWP가 여러 개인 폴더 첫 검색은 느릴 수 있으나 크래시·멈춤 없음(취소 가능)

- [ ] **Step 3: 결과 기록** — 문제 없으면 완료. 이슈는 후속 Task로.

---

## Self-Review (계획 점검)
- **스펙 커버리지:** §3.2(officeBody)+§3.5(라벨/클릭)→Task1; §3.1(캐시 markdown(for:))→Task2; §3.3(performSearch 분기)+§3.4(searchContent opt-out)→Task3; §6 테스트→Task1 + Task4 수동. 누락 없음.
- **플레이스홀더 스캔:** 모든 코드 단계 실제 코드. 변환 실패/취소/캡 처리 구체.
- **타입 일관성:** `SearchMatchKind.officeBody`·`SearchResult(kind:)`·`KordocService.markdown(for:)`·`contentLineMatches`·`DocumentKind.officeExtensions`·`performSearch(...includeOfficeBody:)`가 정의/소비 Task에서 동일.
- **회귀 주의:** Task1은 두 exhaustive switch(badge·onTap) 모두 갱신해야 컴파일. Task3의 오피스 분기는 `else if`라 텍스트/PDF 분기 뒤에만 동작(상호배타). searchContent에 includeOfficeBody:false 빠뜨리면 Omnisearch가 실시간 HWP 변환 → 반드시 포함.
- **범위:** 단일 계획 적합. 위치 점프·FTS5 인덱싱은 비범위.
