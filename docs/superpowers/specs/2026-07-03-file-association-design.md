# 파일 연결(기본 앱 등록) 설계 — Tools 탭 "파일 연결" 섹션

- 날짜: 2026-07-03
- 상태: 사용자 설계 승인 완료(대화), 스펙 리뷰 대기
- 선행 결정(브레인스토밍 문답): UI 세분도 = **형식 그룹별 버튼**(일괄·확장자별 탈락). 등록 방식 = **UTType 기반**(`NSWorkspace.setDefaultApplication` 계열, 샘플 파일 방식 탈락). 위치 = Tools 설정 탭.

## 0. 목표·비목표

**목표**: 설정 → Tools 탭에서 형식 그룹별로 "cmdALL을 기본 앱으로" 등록. 등록 후 Finder 더블클릭으로 해당 형식이 cmdALL에서 열린다.

**비목표**: 등록 해제/이전 앱 복원 UI(macOS에 API 없음 — 안내 문구로 갈음), 확장자별 개별 제어, Finder 아이콘 커스텀, `swift run` 개발 실행 지원(LS 등록은 .app 번들 전제).

**전제 확인 완료**: 파일 열기 배선은 기존 완비 — `CmdMDApp.handleURL`(file URL → `appState.openDocument(at:)`)이 kind 분기까지 처리. 이 기능은 "macOS 쪽 등록"만 더한다.

## 1. 형식 그룹 (6개, 고정)

| 그룹 | 확장자 | 출처 |
|---|---|---|
| 한글 문서 | hwp, hwpx, hwpml | `DocumentKind.officeExtensions`의 한글 부분집합 — 그룹 분리는 UI 의도(한글만 연결하고 MS 오피스는 안 하는 선택 허용) |
| 오피스 문서 | doc, docx, xls, xlsx | `DocumentKind.officeExtensions`의 나머지 |
| 마크다운·텍스트 | md, markdown, mdown, txt | `DocumentKind.markdownExtensions` **신설**(현 Info.plist 선언 md/markdown/mdown + 앱이 여는 txt) — 이 기능 전용 이중 정의 금지, DocumentKind에 상수로 |
| PDF | pdf | `DocumentKind.pdfExtensions` |
| 이미지 | png, jpg, jpeg, heic, webp, gif | `DocumentKind.imageExtensions` |
| 미디어 | mp3, m4a, aac, wav, aiff, flac, mp4, mov, m4v | `DocumentKind.mediaExtensions` |

한글+오피스 그룹 합집합 = `officeExtensions` 전체와 일치해야 한다(테스트로 고정). 그룹 순서는 위 표 순서(한글이 첫 번째 — 이 기능의 핵심 동기).

## 2. `FileAssociationService` (새 파일 `Sources/Services/FileAssociationService.swift`)

- `struct FileTypeGroup: Identifiable` — `id`(String)·`name`(표시명)·`extensions: [String]`(표 순서 유지, 첫 원소가 대표 확장자). `static let all: [FileTypeGroup]` 6개.
- `@MainActor` 유틸(또는 enum 정적 메서드 — NSWorkspace는 스레드 제약 낮으나 UI 소비 전용이므로 MainActor로 단순화):
  - `static var appBundleURL: URL?` — `Bundle.main.bundleURL`이 `.app`으로 끝나면 그 URL, 아니면 nil(**swift run 가드**).
  - `static func currentDefaultAppName(for group: FileTypeGroup) -> String?` — 대표 확장자의 `UTType(filenameExtension:)` → `NSWorkspace.shared.urlForApplication(toOpen:)` → `FileManager.displayName`. 없으면 nil("없음" 표시).
  - `static func setAsDefault(group: FileTypeGroup) async -> Result<Void, FileAssociationError>` — 그룹 내 **모든** 확장자에 대해 `UTType(filenameExtension:)`을 구해 `NSWorkspace.setDefaultApplication(at: appBundleURL, toOpen(ContentType): utType)` 호출(정확한 인자 레이블은 macOS 12+ async API를 컴파일로 확정 — 의미: 해당 콘텐츠 타입의 기본 앱을 이 번들로). 실패 확장자를 모아 부분 실패면 `.partialFailure(failed: [String])`, UTType 자체를 못 얻으면 그 확장자도 실패로 집계. 전부 성공이면 `.success`.
- hwp/hwpx/hwpml처럼 시스템 UTType 선언이 없을 수 있는 확장자는 `UTType(filenameExtension:)`이 **동적 타입(dyn.\*)** 을 돌려준다. Launch Services는 동적 타입에도 기본 핸들러를 기록하는 것으로 알려져 있으나 **설치 앱에서 실측 검증을 구현 단계 필수 스텝으로 둔다**(§5). 실측 실패 시 대안: Info.plist `UTImportedTypeDeclarations`로 hwp 계열 타입 선언 추가 후 재검증.

## 3. Tools 탭 "파일 연결" 섹션 (ToolsSettingsView에 추가)

- 위치: 기존 "검색 인덱스" 섹션 뒤, "상태 새로고침" 섹션 앞.
- 각 그룹 행: `LabeledContent`(그룹명, 캡션=확장자 나열) — 값 영역에 현재 기본 앱 이름(secondary, 없으면 "없음") + "cmdALL로" 버튼.
- 버튼 동작: `setAsDefault` 호출(Task) → 성공 시 해당 행에 체크마크 표시+기본 앱 이름 재조회, 부분 실패 시 행 아래 caption으로 "일부 실패: <확장자들>" 표시.
- 상태는 `@State private var associationResults: [String: 결과]`(그룹 id 키)와 `@State private var defaultAppNames: [String: String]` — `refresh()`에서 이름 일괄 재조회(기존 새로고침 버튼·onAppear 재사용). 이름 조회는 가벼운 LS 질의라 동기 허용(프로세스 스폰 없음 — Tools 탭 기존 원칙 유지).
- `FileAssociationService.appBundleURL == nil`이면 섹션 내용 대신 안내 한 줄: "패키징된 앱(/Applications의 cmdALL.app)에서만 사용할 수 있습니다." 버튼 비노출.
- 섹션 footer: "다른 앱으로 되돌리려면 Finder에서 파일 정보(⌘I) → 다음으로 열기에서 바꾸세요."

## 4. 패키징 — Info.plist 문서형 선언 확장 (`scripts/package_app.sh`)

`CFBundleDocumentTypes` 배열에 dict 추가(전부 `CFBundleTypeRole: Viewer`, `LSHandlerRank: Alternate`):
- 기존 Markdown dict: `CFBundleTypeExtensions`에 `txt` 추가(이미 `public.plain-text` 콘텐츠 타입은 선언돼 있음).
- 신규 dict 5개: 한글 문서(hwp/hwpx/hwpml), Office Document(doc/docx/xls/xlsx), PDF(pdf + `LSItemContentTypes: com.adobe.pdf`), Image(png/jpg/jpeg/heic/webp/gif), Media(mp3/m4a/aac/wav/aiff/flac/mp4/mov/m4v).
- 목적: LS가 cmdALL을 각 형식의 후보 앱으로 등록(Finder "다음으로 열기" 노출 + 기본 앱 등록의 안정 전제). **Info.plist 변경이므로 재패키징·재설치 후에만 반영.**
- `test_package_app.sh`에 검증 1줄 추가: hwp가 문서형 선언에 포함됐는지(PlistBuddy로 CFBundleDocumentTypes 순회 또는 `grep`).

## 5. 검증

- 단위 테스트(XCTest, 순수): ①그룹 6개의 확장자가 `DocumentKind` 상수들과 정확히 정합(한글+오피스 합집합=officeExtensions, 이미지·PDF·미디어 동일, 마크다운=markdownExtensions) ②전 그룹 확장자 중복 없음 ③대표 확장자=첫 원소 규칙.
- 수동 스모크(설치 앱, 필수): 재패키징 DMG 설치 → Tools 탭에서 "한글 문서 → cmdALL로" → Finder에서 `.hwp` 더블클릭 시 cmdALL이 열리는지(**동적 UTType 실측** — §2의 열린 질문 확정). 실패 시 §2 대안(UTImportedTypeDeclarations) 적용 후 재검증. PDF·이미지 등 나머지 그룹 1개 이상 추가 확인. 현재 기본 앱 이름 표시·"없음"·부분 실패 캡션 확인.
- `swift run` 실행에서 섹션이 안내 문구로 대체되는지.
- 전후 `swift test`(현 389개) 유지.

## 6. 리스크·한계

- 기본 앱 등록은 사용자 머신 전역 상태 변경 — 버튼은 그룹별·사용자 클릭으로만(자동 없음), 해제는 Finder 안내(비목표).
- LS 데이터베이스 캐시 때문에 재설치 직후 Finder 반영이 늦을 수 있음 — 스모크에서 필요시 앱 재실행/재로그인 감안.
- hwp 동적 UTType 경로는 실측 전까지 미확정 — 스펙은 대안 경로까지 명시(§2·§5)로 막다른 길 방지.
