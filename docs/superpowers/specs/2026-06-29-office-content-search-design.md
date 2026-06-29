# 오피스 본문 검색 (변환 캐시) 설계

- 날짜: 2026-06-29
- 대상: cmd-docu (CmdMD 포크), `cmd-docu` 브랜치 (Phase 3 위)
- 범위: 폴더 검색이 HWP·오피스 **본문**까지 검색(kordoc 변환 + 캐시). 결과 클릭 = 파일 열기.
- 비범위: 백그라운드 자동 인덱싱·FTS5(Phase 7), 오피스 결과 위치 점프, 캐시 디스크 영구화.

## 1. 배경 / 목표
현재 폴더 검색(`AppState.performSearch`)은 본문을 `md/markdown/txt` + PDF만 읽고, 오피스 파일은 **파일명만** 매칭한다. 사용자는 HWP **내용**으로도 찾고 싶어 한다. 오피스 본문은 kordoc 변환이 필요하므로, 변환 결과를 캐시해 매 검색마다 재변환하지 않도록 한다.

**목표**
- 폴더 검색(사이드바 "Search in folder", Enter 시 1회)이 오피스(`hwp/hwpx/hwpml/doc/docx/xls/xlsx`) 본문에서 일치 줄을 찾는다.
- 변환 결과를 `KordocService` 내부 메모리 캐시(키=경로+수정시각)로 재사용 → 첫 검색만 변환, 이후 빠름.
- 오피스 본문 결과는 라벨 "내용"으로 표시, 클릭 시 해당 오피스 파일을 (읽기전용) 연다.
- **Omnisearch(실시간 타이핑) 보호**: 실시간 검색에서는 오피스 변환을 하지 않는다(opt-out).

**비목표(YAGNI)**
- FTS5/백그라운드 인덱싱(Phase 7), 오피스 결과 클릭 시 정확한 위치 점프, 캐시 영구 저장.

## 2. 현재 상태(기준)
- `AppState.performSearch(query:in:includeFilenames:includePDFBody:)`: 파일명(전종류) + 텍스트본문(md/markdown/txt) + PDF본문(`includePDFBody`). `Task.isCancelled` 가드 루프 존재. `private let kordocService = KordocService()` 보유(Phase 3).
- `searchContent(query:)`(Omnisearch): `performSearch(..., includeFilenames:false, includePDFBody:false)`.
- `SearchResult.kind: SearchMatchKind { filename, line, pdfPage }`. `SearchResultRow` 라벨 kind별, `SearchResultsList` onTap kind별 분기.
- `KordocService` actor: `convert(fileURL:) async throws -> KordocResult`, `resolveNpxPath()`.
- `DocumentKind.officeExtensions`, `.office`. office 파일 열기는 `openDocument`가 kind 분기로 처리(읽기전용 OfficeReaderView).

## 3. 설계

### 3.1 `KordocService` — 변환 캐시 (수정)
```
private var cache: [String: (mtime: Date, markdown: String)] = [:]   // actor 격리

func markdown(for fileURL: URL) async throws -> String {
    let key = fileURL.path(percentEncoded: false)
    let mtime = (try? FileManager.default.attributesOfItem(atPath: key)[.modificationDate] as? Date) ?? nil
    if let hit = cache[key], let mtime, hit.mtime == mtime { return hit.markdown }
    let result = try await convert(fileURL: fileURL)   // 기존 변환 재사용
    if let mtime { cache[key] = (mtime, result.markdown) }
    return result.markdown
}
```
- 캐시는 세션 메모리(actor 격리라 스레드 안전). mtime 변하면 재변환. mtime 못 읽으면 캐시 안 함(항상 변환).
- `convert`/`KordocError`/`resolveNpxPath`는 그대로.

### 3.2 `SearchMatchKind` — `.officeBody` 추가 (`Sources/Models/Workspace.swift`)
```
enum SearchMatchKind { case filename; case line; case pdfPage; case officeBody }
```
- `.officeBody`: lineNumber = 변환 마크다운 내 줄번호, lineContent = 일치 줄. (하위호환: 기존 `SearchResult` init의 kind 기본 `.line` 유지.)

### 3.3 `AppState.performSearch` — 오피스 본문 분기 (수정)
- 시그니처에 `includeOfficeBody: Bool = true` 추가.
- 파일 루프에서 PDF 분기 다음에 오피스 분기 추가:
  ```
  } else if includeOfficeBody, DocumentKind.officeExtensions.contains(ext) {
      if let md = try? await kordocService.markdown(for: fileURL) {
          for hit in Self.contentLineMatches(in: md, fileURL: fileURL, query: query) {
              results.append(SearchResult(fileURL: fileURL, lineNumber: hit.lineNumber,
                                          lineContent: hit.lineContent, matchRange: hit.matchRange,
                                          kind: .officeBody))
              if results.count >= maxResults { return results }
          }
      }
  }
  ```
  - 변환 실패(`try?` nil)는 조용히 건너뜀(파일명 매칭은 이미 위에서 됨). 크래시 없음.
  - 기존 `Task.isCancelled` 가드가 오피스 변환 루프도 중단(취소 시 폭주 방지).
  - `contentLineMatches`는 `.line` kind 결과를 주므로, 위처럼 `.officeBody`로 **재구성**(PDF가 `.pdfPage`로 재구성하는 것과 동일 패턴). lineNumber는 변환 마크다운 줄번호 그대로 사용.

### 3.4 `searchContent`(Omnisearch) — opt-out (수정)
```
return await performSearch(query: query, in: folder,
                           includeFilenames: false, includePDFBody: false, includeOfficeBody: false)
```
→ Omnisearch는 실시간이라 오피스 변환을 절대 안 함(텍스트 줄만).

### 3.5 `SidebarView` (수정)
- `SearchResultRow.badge`: `.officeBody → "내용"` 추가.
- `SearchResultsList` onTap: `.officeBody → appState.openDocument(at: result.fileURL, inNewTab: true)` (위치 점프 없음; office 리더가 kind 분기로 열림).

## 4. 데이터 흐름
```
사이드바 검색(Enter) → performSearch(includeOfficeBody:true)
  오피스 파일: kordocService.markdown(for:) [캐시 히트/변환] → contentLineMatches → .officeBody 결과
결과 행 "내용" → 클릭 → openDocument(office 리더, 읽기전용)
Omnisearch: includeOfficeBody:false → 오피스 변환 안 함
```

## 5. 에러 처리
- 변환 실패(미설치/손상/타임아웃) → 해당 오피스 본문 결과 0건(파일명 매칭만). 크래시·예외 없음.
- mtime 못 읽음 → 캐시 생략(매번 변환). 드문 경우.
- 검색 취소(타이핑 중 새 검색/탭 변경) → Task.isCancelled로 중단.

## 6. 테스트 (Phase 게이트)
**신규/확장(XCTest):**
- `SearchResultKindTests`(또는 신규): `SearchResult(kind: .officeBody)` 생성·kind 보존; 기본 init은 여전히 `.line`(하위호환).
- (선택) `SearchMatchKind`에 `.officeBody` 존재 확인.
- `contentLineMatches`는 기존 테스트로 충분(오피스 본문은 같은 함수 재사용).
- 캐시·변환·뷰는 실제 HWP로 수동 검증.

**게이트:** 기존 94개 + 신규 모두 통과. 수동(실제 HWP 포함 폴더):
- 사이드바에서 HWP 본문 단어 검색 → "내용" 결과로 뜸, 클릭 시 그 HWP가 열림
- 같은 검색 재실행 시 빠름(캐시), 파일 수정 후엔 갱신
- Omnisearch는 오피스 본문 안 섞이고 빠름(회귀 없음)
- md/txt/PDF 본문·파일명 검색 회귀 없음

## 7. 파일 변경 요약
| 파일 | 변경 |
| --- | --- |
| `Sources/Services/KordocService.swift` | 변환 캐시 + `markdown(for:)` |
| `Sources/Models/Workspace.swift` | `SearchMatchKind.officeBody` |
| `Sources/App/AppState.swift` | `performSearch` includeOfficeBody + 오피스 분기, `searchContent` opt-out |
| `Sources/Views/SidebarView.swift` | 행 라벨 "내용" + 클릭 분기 |
| `Tests/CmdMDTests/SearchResultKindTests.swift` | `.officeBody` 케이스 |

기존 검색·읽기 동작 불변. Omnisearch 실시간 변환 금지(opt-out). 캐시로 재변환 방지.
