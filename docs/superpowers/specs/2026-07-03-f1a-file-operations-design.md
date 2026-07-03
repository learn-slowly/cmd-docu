# F1a 설계 — 파일 작업 기반 (이름변경·새 폴더·휴지통 + 작업 로그 + 정보 보기)

- 날짜: 2026-07-03
- 상태: 사용자 설계 승인(대화), 스펙 리뷰 대기. 같은 날 범위 추가: 정보 보기(§7) — 원래 F3에 있던 ⌘I 정보 보기를 F1a로 앞당김(사용자 결정, 로드맵 동반 수정)
- 상위 문서: `2026-07-03-finder-replacement-roadmap.md` (F1a — 첫 조각)
- 선행 결정(로드맵): 삭제 = **휴지통 이동만**(`FileManager.trashItem`, 영구삭제·비우기 없음) + **작업 로그·앱 내 되돌리기**. 단축키(⌘⌫ 등)·다중 선택은 F1b로.

## 0. 목표·비목표

**목표**: 단일 항목의 이름 변경·새 폴더·휴지통 이동을 트리·라이브러리 우클릭에서 처리하고, 휴지통·이름변경을 로그로 남겨 앱 안에서 되돌린다. 파일 정보(크기·생성/수정일 등)를 정보 시트(⌥⌘I)와 라이브러리 리스트 열로 본다(§7). "이름 하나 바꾸려고, 크기 하나 보려고 Finder 여는 일"을 없앤다.

**비목표**: 다중 선택·배치 작업·복사/붙여넣기(F1b), 드래그(F2), 영구 삭제·휴지통 비우기(로드맵 금지), 파일 내용 수정, 라이브러리 빈 영역 우클릭(셀 기반만), 리스트 열 헤더 클릭 정렬(F3 정렬 옵션에서), 권한·태그·최근 열람일 등 Finder 동급 전체 필드(후속).

## 1. `FileOperations` 서비스 (새 파일 `Sources/Services/FileOperations.swift`)

FileManager 기반 동기 함수(파일 작업은 로컬·즉시). 전부 throws, 결과 URL 반환:
- `rename(at url: URL, to newName: String) throws -> URL` — 같은 디렉터리 내 `moveItem`. `newName`은 전체 파일명(확장자 포함). 검증: 빈 이름·`/` 포함·기존과 동일 이름 거부, **대상 이름이 이미 존재하면 에러**(사용자 지정 이름이므로 uniquify 아님 — 오류 메시지로 안내, 덮어쓰기 금지).
- `createFolder(in parent: URL, name: String = "새 폴더") throws -> URL` — 이미 있으면 "새 폴더 2"식 uniquify(기존 `uniquified()` 관례 재사용).
- `trash(at url: URL) throws -> URL` — `FileManager.trashItem(at:resultingItemURL:)`로 휴지통 이동, **휴지통 내 실제 URL 반환**(로그·되돌리기용).
- 에러는 사용자에게 보일 한국어 메시지를 가진 `FileOperationError`(LocalizedError)로.

## 2. 작업 로그 + 되돌리기

**`FileOpsLogStore`** (새 파일, 기존 `MoveLogStore`의 load/append JSON 영속 패턴):
- 엔트리: `id`·`kind`(trash/rename)·`originalURL`·`resultURL`(휴지통 내 위치 또는 새 이름 경로)·`date`. 새 폴더는 기록하지 않음(되돌리기=삭제라 정책 충돌).
- 저장 위치: 기존 앱 데이터 디렉터리(`AppState.dataDirectory` 주입 경로 하위 — 테스트 격리 관례 준수).
- `undo(entry:)`: trash → 휴지통 위치에서 원위치로 `moveItem`(꺼내기), rename → 역방향 rename. **원위치(또는 옛 이름)에 다른 항목이 생겼으면 실패**(덮어쓰기 금지, 안내). 되돌리기 성공한 엔트리는 로그에서 **제거**(기록 시트 목록 = 아직 되돌릴 수 있는 작업). 실패한 엔트리는 보존(기존 정리 로그의 "부분 실패 시 보존" 관례).

**`FileOpsHistoryView`** (새 시트): 최근 작업 목록(종류 아이콘·이름·시각) + 행별 "되돌리기" 버튼 + 실패 시 행 캡션. 진입점: 커맨드 팔레트 "파일 작업 기록" + View 메뉴.

## 3. UI 배선

- **트리 우클릭**(`FileTreeContextMenu`): "이름 변경…"(파일·폴더 공통), "휴지통으로 이동"(파일·폴더, destructive role) 추가. "New Folder"는 기존 항목 유지.
- **라이브러리 셀 우클릭**(신설 — 현재 셀 컨텍스트 메뉴 없음): 파일 셀 = 이름 변경·휴지통(+기존 없던 "Finder에서 보기"류는 범위 밖), 폴더 셀 = 이름 변경·휴지통·"이 안에 새 폴더". 그리드·리스트 셀 공통.
- 두 메뉴 모두 "정보 보기" 항목 포함(파일·폴더 공통 — §7.2).
- **이름 변경 시트**(`RenameSheetView` 신설): 현재 파일명 프리필 TextField·Return 확정·Esc 취소·에러 인라인 표시(이미 존재 등).
- **휴지통 확인**: NSAlert(대상 파일명 명시, "휴지통으로 이동/취소"). 짝꿍 노트 동반 시 문구에 포함(§4).

## 4. 앱 상태 정합 (이 조각의 실제 난이도)

- **열린 탭 — rename**: 대상 URL과 같은 탭(또는 폴더 rename이면 그 하위 경로 탭들 — 경로 prefix는 **디렉터리 경계로 비교**, 8.5-②a에서 배운 prefix 경계 이슈 재발 방지)의 `tab.fileURL`·`documents[...].fileURL`을 새 경로로 갱신 + `saveSession()`. 문서 내용·더티 상태 불변.
- **열린 탭 — trash**: 대상 탭(폴더면 하위 탭들) `closeTab` — 더티면 휴지통 확인 대화상자에 "저장 안 된 변경이 있는 탭이 닫힙니다" 경고 문구 추가(개별 저장 확인까지는 안 함 — 휴지통에서 복구 가능).
- **짝꿍 노트 동반**: 대상이 미디어 파일이고 짝꿍 노트(`파일명.ext.md`, `CompanionNote` 규칙)가 존재하면 rename 시 노트도 새 이름 규칙으로 함께 rename, trash 시 함께 휴지통(확인 문구에 "메모도 함께" 명시). 로그에는 두 건 모두 기록(되돌리기도 각각). 역방향(노트만 단독 조작)은 동반 없음.
- **갱신 트리거**: 작업 성공 후 `loadFileTree()` + **라이브러리 재열거** — `AppState`에 파일작업 세대 토큰(Int, 작업마다 증가)을 두고 `LibraryView`의 `.task(id: folderKey)`를 토큰 결합 id로 확장(현재 folderKey만이라 같은 폴더 내 변경이 반영 안 됨 — 검증된 사실).
- **검색 인덱스**: 등록 폴더는 FolderWatcher(FSEvents)가 자동 감지 — 추가 배선 없음. 미등록 폴더는 기존과 동일(다음 인덱싱 때).

## 5. 검증

- 단위 테스트(임시 디렉터리): FileOperations(rename 성공/충돌 거부/검증 거부, createFolder uniquify), FileOpsLogStore(append/load/undo 성공·충돌 실패), 탭 URL 갱신 로직(폴더 rename 하위 탭 갱신·경계 케이스), 짝꿍 노트 동반 판별. **trash는 실제 휴지통을 쓰므로 임시 파일로만** 테스트(생성→trash→resultURL 존재 확인→undo로 복귀)하고, CI 환경에서 휴지통 접근 불가 시 XCTSkip. 정보 보기 검증은 §7.4.
- 수동 스모크: 트리·라이브러리 각각 이름 변경(열린 탭 제목 갱신 확인)·새 폴더·휴지통(확인 문구·Finder 휴지통에서 확인)·작업 기록 시트 되돌리기·미디어+짝꿍 노트 동반. 정보 보기 스모크는 §7.4.
- 전후 `swift test`(현 401=XCTest 383+Testing 18) 유지.

## 6. 리스크·한계

- 폴더 rename 시 하위 탭 URL 갱신은 열린 탭에 한정 — 세션·즐겨찾기·인덱스의 옛 경로는 각자 기존 메커니즘(세션은 saveSession, 즐겨찾기는 fileExists 가드로 무동작, 인덱스는 FSEvents/재인덱싱)에 맡김. 즐겨찾기 경로 자동 갱신은 후속.
- trash 되돌리기는 macOS 휴지통 내 파일이 사용자에 의해 비워지면 실패 — 안내로 처리.
- 라이브러리 셀 컨텍스트 메뉴 신설로 기존 탭/클릭 제스처와의 간섭 여부는 수동 스모크로 확인.
- 리스트 열·정보 시트의 크기/날짜는 표시 시점 스냅샷 — 외부(다른 앱)에서 바뀐 값은 재열거·시트 재열기 전까지 갱신 안 됨(현재 라이브러리 내용 자체와 동일한 stale 특성, 등록 폴더는 FSEvents가 커버).

## 7. 정보 보기 (범위 추가분 — 원 F3 ⌘I를 앞당김)

**형태(사용자 결정)**: 온디맨드 정보 시트 + 라이브러리 리스트 열 **둘 다**. 폴더 크기는 시트에서만 비동기 계산(리스트 열은 "--"). 필드는 기본 + 종류별 한 줄. 정렬은 F3 유지.

### 7.1 `FileInfo` 모델 + 로더 (새 파일 `Sources/Services/FileInfoService.swift`)

- 기본 필드: 이름·종류 라벨(`DocumentKind` 기반 한국어)·크기·위치(부모 경로)·생성일·수정일 — `URLResourceValues` 한 번에 조회(`fileSizeKey`·`creationDateKey`·`contentModificationDateKey`·`isDirectoryKey`).
- 종류별 한 줄(전부 기존/시스템 API, 비동기 로드): 이미지=해상도(ImageIO `CGImageSourceCopyPropertiesAtIndex` — 헤더만, 전체 디코드 없음), PDF=페이지 수(PDFKit `PDFDocument.pageCount`), 미디어=길이(기존 `MediaMetadata.load` 재사용·`formatDuration` 표기), 폴더=직속 항목 수.
- 폴더 크기: `computeFolderSize(url:) async throws -> Int64` — 재귀 합산(`FileManager.enumerator` + `totalFileAllocatedSizeKey` 폴백 `fileSizeKey`), `Task.checkCancellation`으로 취소 지원(시트 닫히면 취소). UI는 "계산 중…"→결과.
- 실패 필드는 nil로 두고 나머지는 진행(MediaMetadata 관례). 크기·날짜 표기는 `ByteCountFormatter`·기존 날짜 표기 관례.

### 7.2 `FileInfoView` 시트 + 진입점

- 앱의 기존 시트 관례(OfficeFillView·AskCorpusView류). 레이블-값 2열 폼, 폴더 크기·종류별 줄은 도착하면 채움(자리 예약으로 리플로우 방지 — 리스트 셀 summary 관례).
- 진입점 3곳:
  1. **컨텍스트 메뉴 "정보 보기"** — §3에서 신설·확장하는 트리(`FileTreeContextMenu`)·라이브러리 셀 메뉴에 항목 추가(파일·폴더 공통).
  2. **단축키 ⌥⌘I** — ⌘I는 Format>Italic이 선점(`CmdMDApp.swift:226`, 마크다운 에디터 관례라 유지), ⌥⌘I는 미사용 확인(Finder 인스펙터 단축키와도 일치). `ShortcutDefaultsTests`에 유일성 추가. 대상: 리더 모드=현재 탭 파일(탭 없으면 비활성), 라이브러리 모드=표시 중인 폴더(`selectedFolder ?? currentFolder`) — 라이브러리 셀 "선택" 개념은 F1b 다중선택과 함께라 지금은 폴더 단위.
  3. **커맨드 팔레트 "정보 보기"** — 대상 결정은 ⌥⌘I와 동일 규칙.

### 7.3 라이브러리 리스트 열 (크기·수정일)

- `LibraryListing.entries`의 열거 키에 `fileSizeKey`·`contentModificationDateKey` 추가 — **열거 시점에 한 번에** 읽는다("렌더 중 FS 호출 0" 규칙 유지).
- `FileTreeItem`에 옵셔널 `fileSize: Int64?`·`modifiedAt: Date?` 추가 — **라이브러리 열거 경로만 채움**. 사이드바 트리 스캔(`buildFileTree`)은 기존대로 nil이라 트리 비용 불변. `ForEach(id: \.url)` 동일성은 url 기준이라 영향 없음.
- `LibraryListCell` 트레일링에 고정폭 2열(크기·수정일, secondary 스타일). 폴더 크기는 "--"(수정일은 표시). 그리드 셀은 불변.
- 갱신: F1a §4의 파일작업 세대 토큰이 재열거를 강제하므로 별도 배선 없음.

### 7.4 검증 (정보 보기)

- 단위 테스트(임시 디렉터리): FileInfo 로더(실파일 크기·생성/수정일·종류 라벨; 이미지 해상도는 테스트 PNG 바이트 실생성 — WAV 실생성 관례, PDF 페이지 수는 PDFKit으로 1페이지 문서 실생성), `computeFolderSize`(중첩 폴더 합산·취소), `LibraryListing.entries` 메타데이터 채움(파일=값 존재·폴더=fileSize nil), 단축키 기본값 유일성(⌥⌘I).
- 수동 스모크: 트리·라이브러리 우클릭 "정보 보기"(파일·폴더), ⌥⌘I 리더/라이브러리 각 모드 대상 규칙, 큰 폴더 계산 중 시트 닫기(취소·크래시 없음), 리스트 열 표시·파일 작업 후 갱신.
