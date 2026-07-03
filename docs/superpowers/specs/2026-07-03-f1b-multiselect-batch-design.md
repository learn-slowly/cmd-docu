# F1b — 다중 선택 + 배치 파일 작업 설계

- 날짜: 2026-07-03
- 상태: 사용자 승인(대화). Finder 대체 로드맵(`2026-07-03-finder-replacement-roadmap.md`) 2단계.
- 선행: F1a(파일 작업 기반 — FileOperations·FileOpsLogStore·performRename/performTrash·정보 보기) 완료.

## 0. 사용자 결정 (2026-07-03 대화)

1. **클릭 시맨틱 = Finder식.** 라이브러리에서 클릭=선택, 더블클릭=열기/드릴인. 기존 "단일 클릭 즉시 열기"는 폐기.
2. **트리는 ⌘클릭 토글만.** ⇧범위 선택은 라이브러리 전용(트리는 수제 재귀 구조라 가시 행 평탄화 비용이 큼 — 후속 확장 가능).
3. **Finder 완전 호환.** ⌘C/⌘V/⌥⌘V를 NSPasteboard `.fileURL`로 — Finder와 양방향 상호운용. + 컨텍스트 메뉴 "폴더로 이동…"(폴더 선택 패널).
4. **복사 실행도 로그 + undo=사본 휴지통.** 영구삭제 금지 정책과 정합(새 폴더 미기록 선례와 달리, 복사는 휴지통 경유 undo가 가능하므로 기록).

## 1. 범위

**만드는 것**
- 라이브러리(그리드·리스트) 다중 선택: 클릭=선택 교체, ⌘클릭=토글, ⇧클릭=범위, 더블클릭=열기/드릴인, 배경 클릭=해제, ⌘A=전체 선택.
- 트리 다중 선택: ⌘클릭 토글만(선택 집합은 라이브러리와 공유).
- 배치 작업: 휴지통·폴더로 이동·복사(붙여넣기) — 각각 로그(batchId) + 배치 단위 되돌리기.
- ⌘C/⌘V/⌥⌘V/⌘⌫/⎋ 키 지원(로컬 NSEvent 모니터 + 엄격 가드), Finder 페이스트보드 상호운용.
- 선택 인지 컨텍스트 메뉴(라이브러리·트리), 기록 UI의 배치 그룹 표시.

**안 만드는 것**
- 배치 이름 변경, ⌘X 잘라내기(Finder도 미지원), 드래그&드롭(F2), 듀얼 페인(F4), 트리 ⇧범위, 빈 영역 우클릭 메뉴, 영구 삭제·휴지통 비우기(정책), 단축키 리맵(⌘C 등은 AppShortcut 밖 — Finder 패리티 고정).

## 2. 선택 모델

- `AppState.fileSelection: Set<URL>` — 단일 진실원, 라이브러리·트리 공유. `AppState.selectionAnchor: URL?` — ⇧범위 앵커.
- **URL 키인 이유**: `FileTreeItem.id`는 트리 재빌드마다 새 UUID(`Workspace.swift:136`) — id 기반 선택은 새로고침마다 증발. LibraryView가 같은 이유로 `ForEach(id: \.url)`을 쓰는 선례.
- **클리어 규칙**: `selectedFolder` 값이 바뀌면(드릴인·사이드바 폴더 클릭·openFolder·세션 복원) 선택+앵커 클리어 — Finder와 동일(폴더 이동=선택 해제). 트리 ⌘클릭은 폴더를 안 바꾸므로 여러 폴더에 흩어진 파일을 모아 선택 가능(의도된 기능).
- **prune 규칙**: `completeFileOperation`(세대 토큰 증가 지점)에서 `FileManager.fileExists` 검사로 소실 URL을 선택에서 제거 — 유령 선택에 배치가 실행되는 것을 방지.
- `mainMode` 전환은 선택을 유지(무해 — 키 가드가 오발동을 막음, §5).

## 3. 클릭 시맨틱

### 3.1 라이브러리 (그리드·리스트 동일 — 수동 구현)

그리드는 LazyVGrid라 네이티브 selection이 없고, 리스트도 동작 통일을 위해 수동으로 맞춘다(List(selection:)을 쓰면 그리드와 키보드/클릭 동작이 갈라짐).

| 입력 | 동작 |
|---|---|
| 클릭 | 선택을 그 항목 하나로 교체, 앵커=그 항목 |
| ⌘클릭 | 토글(추가/제거), 앵커=그 항목 |
| ⇧클릭 | 앵커~클릭 연속 구간으로 선택 교체(entries 정렬 순서 기준). 앵커 없으면 클릭=단일 선택과 동일 |
| 더블클릭 | 파일=`openDocument(inNewTab:)`, 폴더=드릴인(`selectedFolder=url` → 선택 클리어) |
| 배경 클릭 | 선택 해제(그리드 ScrollView 배경·리스트 빈 영역) |

- 수정키 판별: 탭 핸들러 안에서 `NSEvent.modifierFlags` 직접 읽기(메인 스레드) — `CmdMDApp.swift:368`·`SettingsView.swift:635` 전례. `TapGesture().modifiers(.command)` 조합은 일반 탭이 수식키와 무관하게 발화해 우선순위 함정이 있으므로 쓰지 않는다.
- 더블클릭: `.onTapGesture(count: 2)`를 단일 탭보다 먼저 선언. 단일탭(선택)이 더블클릭 첫 탭에서 먼저 발화해도 무해 — Finder도 mousedown에서 선택 후 열기.
- 선택 하이라이트: 그리드 셀=액센트 테두리+옅은 배경(RoundedRectangle), 리스트 행=행 배경. 기존 PARA 스타일(archive opacity 0.45·projects 액센트)과 겹쳐도 시인성 유지 확인.
- 라이브러리 헤더에 "N개 선택됨" 캡션(선택 비어있으면 숨김).

### 3.2 트리

- **⌘클릭(라벨)** = 선택 토글만. 모드 전환·파일 열기·폴더 라이브러리 전환 없음.
- 일반 클릭 = 기존 동작 유지(파일=열기, 폴더=selectFolderForLibrary) + 선택 클리어.
- chevron(펼침 버튼)에 ⌘클릭 = 그냥 펼침(선택 무관 — 무시).
- 하이라이트: labelRow 배경 수동 적용(자식 행이 List 행이 아니라 네이티브 선택 배경 불가). archive dim과 공존.

## 4. 연산 계층

### 4.1 FileOperations 확장 (순수 동기, 기존 3함수 불변)

```swift
static func move(at url: URL, to destinationDir: URL) throws -> URL
static func copy(at url: URL, to destinationDir: URL) throws -> URL
```

- 목적지 파일명 = `destinationDir/lastPathComponent`를 `uniquified()`로(충돌 시 " (1)" — 덮어쓰기 금지, 로드맵 관례).
- **move 가드**: 원본 부재=`.sourceMissing`. 원본의 부모 == 목적지(standardized 비교)면 에러 — 이 경우 uniquify가 "이름 (1)"을 만들어 **제자리 이동이 복제 개명으로 둔갑하는 함정**이 있으므로 반드시 사전 차단. 폴더를 자기 자신/자기 하위로 이동 금지('/' 경계 prefix 검사). 신규 에러 케이스 `.invalidDestination(String)`(한국어 메시지)을 `FileOperationError`에 추가.
- **copy**: 같은 폴더로 복사 허용(사본 시맨틱 — uniquify가 "이름 (1)" 생성, 의도된 동작). 폴더 복사는 `FileManager.copyItem` 재귀 그대로.

### 4.2 FileOpsLogStore 확장

- `FileOpKind`에 `.move`·`.copy` 추가. **호환성**: 구버전 앱이 신 kind가 든 로그를 읽으면 `load()`의 배열 단위 `try? decode`가 실패해 기록 전체가 빈 것으로 보임 — 앱은 전진만 하므로 수용(스펙에 명시, 코드 주석으로 남김).
- `FileOpEntry.batchId: UUID?` **옵셔널** 추가 — 기존 fileops-log.json 하위호환 디코드 유지(필수 필드 추가 금지). 단건 작업(F1a 경로)은 batchId=nil 그대로.
- `appendBatch(_ entries: [FileOpEntry])` — 1회 load→append→save(기존 append의 건당 전체 재기록을 배치에서 반복하지 않음).
- `undoBatch(batchId:) -> (succeeded: Int, failed: Int)` — 해당 배치 엔트리를 **역순**으로 undo(MoveExecutor `reversed()` 선례 — 순서 의존 점유 실패 방지). 엔트리별:
  - `.trash`/`.rename`/`.move`: 기존과 동일 — resultURL 존재+originalURL 비점유 가드 후 역이동.
  - `.copy`: 역이동이 아니라 **resultURL을 휴지통으로**(`FileOperations.trash` 재사용 — 사용자 결정 4).
  - 성공 엔트리만 로그에서 제거, 실패분 보존(기존 관례). 점유 시 실패·보존(uniquify 복원 안 함 — FileOpsLogStore 기존 정책 유지, MoveExecutor와 다름을 문서화).
- 단건 `undo(_:)`에도 `.copy` 분기 추가(사본 휴지통).

### 4.3 AppState 배치 배선 (신규 메서드 — 기존 단건 performRename/performTrash 불변)

**공통 전처리 — 중첩 정규화(순수 헬퍼 신설)**: 선택 집합에 부모 폴더와 그 하위 항목이 함께 있으면 조상만 남긴다(`normalizedIndexFolders` 유사 — '/' 경계 prefix). 부모가 먼저 처리되면 자식 연산이 경로 소실로 실패하는 것을 방지. trash/move/copy 공통 적용.

**짝꿍 노트 중복 가드**: 처리 순서대로 "이미 처리된 URL" 집합을 유지 — 본체 처리 시 그 짝꿍 노트를 집합에 넣고, 선택 집합에 이미 처리된 URL이 나오면 skip(검색 등 경로로 짝꿍 노트가 직접 선택에 들어온 경우의 이중 이동 방지).

**짝꿍 노트 결과 이름 규칙**: 동반 move/copy에서 본체가 목적지 uniquify로 이름이 바뀌면(`song.mp3`→`song (1).mp3`) 짝꿍 노트의 결과 이름은 **본체 결과 이름에서 파생**(`본체결과파일명.md` — CompanionNote `파일명.ext.md` 규칙 유지). 노트를 단순 uniquify하면 `song.mp3 (1).md`가 되어 짝꿍 연결이 끊어지므로 금지 — 동반 처리는 노트를 "목적지로 move/copy 후 본체 결과에 맞춘 이름으로" 넣는다(해당 이름이 점유돼 있으면 본체부터 다시 uniquify하는 대신 노트만 uniquify하고 연결 끊김을 부분 실패로 요약에 포함).

- `performBatchTrash(urls:)`
  1. 정규화 → ②요약 확인 **NSAlert 1회**(건수 + 더티 탭·짝꿍 메모 경고 합성 — Close All Tabs 관례, 항목별 모달 금지)
  2. 건별: `.flushMediaCompanionNote` 게시(미디어만) → `closeTabs(under:)` 선닫기(본체+짝꿍) → `FileOperations.trash` → 엔트리 수집(+짝꿍 동반 엔트리, 같은 batchId)
  3. `appendBatch` → `completeFileOperation` **1회**(트리 재스캔·saveSession·세대 증가 N회 금지)
  4. 부분 실패 시 계속 진행 + 끝에 요약 errorMessage("N건 중 M건 실패: 마지막 에러") — 실패 항목의 선닫은 탭 미복구는 F1a 트레이드오프 승계(문서화).
- `performBatchMove(urls:, to destinationDir:)`
  1. 정규화 + 사전 필터: 이미 그 폴더에 있는 항목 skip(카운트 제외), 목적지가 선택된 폴더 자신/하위면 해당 항목 skip+경고
  2. 건별: flush → `FileOperations.move` → `retargetOpenTabs(from:to:)`(폴더면 하위 탭까지 — 기존 함수 재사용) → 짝꿍 동반 move(+로그)
  3. `appendBatch` → `completeFileOperation` 1회. 확인 모달 없음 — 폴더 선택 패널이 확인 역할(F1a rename 시트 관례).
- `performBatchCopy(urls:, to destinationDir:)`
  - 건별 `FileOperations.copy` + 짝꿍 노트 동반 복사(+로그, 같은 batchId). 탭 조작 없음. `appendBatch` → `completeFileOperation` 1회. 확인 없음 — 붙여넣기 액션 자체가 의사 표시(원본 불변·undo 있음).
- `undoFileOpBatch(batchId:)` — ①배치 내 `.copy` 엔트리의 resultURL 탭 선닫기(사본을 열어놨을 수 있음) ②`store.undoBatch` ③`.rename`/`.move` 엔트리는 성공분에 한해 resultURL→originalURL 탭 재조준(**F1a 최종 리뷰가 잡은 "undo가 탭 재조준 안 함" 함정의 동형 재발 방지 — .move 포함 필수**) ④`completeFileOperation` 1회 ⑤부분 실패 요약.
- 기존 단건 `undoFileOp`의 재조준 분기도 `.rename`→`.rename || .move`로 확장, `.copy`면 탭 선닫기.

### 4.4 실행 순서 주의

- uniquified()는 존재검사-후-사용이라 배치는 **순차 실행**(병렬 금지 — 같은 이름 2건 충돌, MoveExecutor 순차 for 선례).
- 이동으로 표시 중 폴더(selectedFolder) 자체가 옮겨지는 경우: F1a 잔여(빈 라이브러리)와 동일 — F1b에서는 목적지 가드로 "선택에 포함된 폴더로의 이동"만 막고, selectedFolder 보정은 기존 잔여 트리아지에 합류(범위 밖).

## 5. 키보드 — 로컬 NSEvent 모니터

**방식**: `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` 1개(앱 기동 시 설치). 전역 `.keyboardShortcut`/메뉴 키 이퀴밸런트는 금지 — SwiftUI 메뉴 키는 앱 전역이라 에디터(NSTextView)·PDFView의 시스템 복사/붙여넣기를 강탈하고 기본 Edit 메뉴와 키 중복이 남(정찰 확정). 모니터는 가드 통과 시에만 이벤트를 소비(nil 반환), 아니면 그대로 통과.

**공통 가드**: keyWindow가 메인 윈도(시트·팔레트 아님) && `firstResponder`가 NSText/NSTextView 계열 아님.

| 키 | 동작 | 추가 가드 |
|---|---|---|
| ⌘C | 선택 항목을 페이스트보드에 복사 | 선택 비어있지 않음(모드 무관 — 트리 선택 지원) |
| ⌘V | 페이스트보드 파일 → 표시 폴더에 복사 실행 | `mainMode == .library` && 페이스트보드에 fileURL 존재 |
| ⌥⌘V | 페이스트보드 파일 → 표시 폴더로 **이동**(Finder 관례) | 위와 동일 |
| ⌘A | 표시 폴더 전체 선택(entries 전체) | `mainMode == .library` |
| ⌘⌫ | 선택 휴지통(요약 확인 경유) | 선택 비어있지 않음 |
| ⎋ | 선택 해제 | 선택 비어있지 않음 |

- **표시 폴더** = `selectedFolder ?? currentFolder`(LibraryView의 displayFolder와 동일 규칙). ⌘V/⌥⌘V·⌘A의 대상.
- ⌘⌫는 NSTextView의 deleteToBeginningOfLine과 겹치지만 firstResponder 가드로 해소(에디터 포커스 시 통과).
- 이 키들은 AppShortcut(리맵 체계) 밖 — Finder 패리티 고정. ShortcutDefaultsTests 대상 아님(스펙 명시).
- ⌥⌘V는 askCorpus(⌥⌘A)·copyFilePath(⌥⌘C)와 다른 콤보로 충돌 없음(정찰 확인 — ⇧⌘V·⌥⌘V 비어 있음).

## 6. 페이스트보드 (Finder 상호운용)

- 쓰기: `NSPasteboard.general.clearContents()` → `writeObjects(urls as [NSURL])` — Finder에서 ⌘V로 받기 가능(비샌드박스라 장애물 없음).
- 읽기: `readObjects(forClasses: [NSURL.self])` → 존재 검증 후 [URL] — Finder에서 ⌘C한 파일을 앱에서 ⌘V로 수신(드롭 경로에서 UTType 호환 기검증 — `CmdMDApp.swift:335`).
- 순수 헬퍼로 분리(`FilePasteboard` — 커스텀 이름 `NSPasteboard(name:)` 인스턴스 주입 가능하게 해 테스트).

## 7. 컨텍스트 메뉴 (선택 인지)

**분기 규칙**: 우클릭한 셀이 선택 집합에 포함되고 선택이 2개 이상이면 **배치 메뉴**, 아니면 기존 단건 메뉴 그대로. 선택 밖 셀 우클릭 시 Finder식 "선택 교체"는 생략(SwiftUI contextMenu는 표시 시점 부수효과가 불가) — 그 셀 단건 메뉴로 동작. 문서화된 트레이드오프.

- **배치 메뉴**(라이브러리 `LibraryCellContextMenu`·트리 `FileTreeContextMenu` 공통 분기): "N개 항목 복사" / "N개 항목 폴더로 이동…" / "N개 항목 휴지통으로 이동".
- **폴더 셀 추가 항목**: "이 폴더에 붙여넣기"(페이스트보드에 fileURL 있을 때만 표시) — 대상=그 폴더.
- "폴더로 이동…" = `NSOpenPanel`(canChooseDirectories=true, canChooseFiles=false, 시작 위치=현재 표시 폴더, prompt "이동") → `performBatchMove`.

## 8. 기록 UI (FileOpsHistoryView)

- batchId가 같은 엔트리를 한 그룹 행으로 묶어 표시: "이동 12건 · 날짜" + **"되돌리기" 1버튼**(`undoFileOpBatch`). 그룹 내 짝꿍 노트 엔트리도 포함(별도 행 아님).
- batchId=nil(F1a 단건)은 기존 행 그대로. 부분 실패 시 남은 엔트리로 그룹이 유지돼 재시도 가능.

## 9. 정합 요약

| 시스템 | F1b 처리 |
|---|---|
| 파일 트리·라이브러리 | `completeFileOperation` 배치당 1회(세대 토큰·loadFileTree·saveSession) |
| 열린 탭 | trash=선닫기(건별), move=retargetOpenTabs(건별), undo도 재조준(.move 포함) |
| 워처 | retargetOpenTabs의 hadWatcher 재장전 로직 그대로(비마크다운 탭 신설 금지) |
| 미디어 짝꿍 | 건별 flush 알림→동반 처리(F1a 검증 경로 재사용), 복사도 동반, 중복 가드 |
| 검색 인덱스 | 기존과 동일 — 인덱스는 mtime 기반 재인덱싱이 흡수(F1a와 같은 정책, 즉시 갱신 안 함) |
| 선택 상태 | selectedFolder 변경 시 클리어, completeFileOperation에서 prune |

## 10. 테스트 전략

**단위(자동)**
- `FileOperations.move/copy`: uniquify 충돌, 같은 부모 move 에러(제자리 복제 함정), 자기 자신/하위 이동 금지, 사본 시맨틱(같은 폴더 copy).
- 중첩 정규화 헬퍼: 부모+자식 → 조상만, 무관 항목 보존.
- `FileOpsLogStore`: batchId 옵셔널 하위호환 디코드(기존 JSON 픽스처), appendBatch 1회 기록, undoBatch 역순·copy=휴지통 분기·부분 실패 보존·성공분만 제거.
- `FilePasteboard`: 커스텀 이름 페이스트보드로 write→read 왕복.
- `AppState`(임시 디렉터리 주입): performBatchTrash/Move/Copy 정상·부분 실패, 짝꿍 동반+중복 가드, undoFileOpBatch 탭 재조준(.move)·copy 탭 선닫기, 선택 prune, selectedFolder 변경 클리어.

**수동 스모크**
- 클릭 시맨틱(클릭/⌘/⇧/더블/배경), 하이라이트와 PARA 스타일 공존, 트리 ⌘토글.
- Finder 상호운용 양방향(앱→Finder 붙여넣기, Finder→앱 붙여넣기).
- 키 가드: 에디터 포커스에서 ⌘C/⌘V/⌘⌫가 텍스트 편집으로 동작(강탈 없음), 시트 열림 시 무발동.
- 배치 undo(기록 시트에서 N건 되돌리기), 미디어+짝꿍 배치 이동.

## 11. 알려진 트레이드오프 (승인된 것)

- 선택 밖 셀 우클릭 시 선택 교체 생략(SwiftUI contextMenu 한계) — 단건 메뉴로 동작.
- 구버전 앱이 신 FileOpKind 로그를 읽으면 기록이 빈 것으로 보임(전진 전용 수용).
- undo 점유 시 실패·보존(uniquify 복원 안 함 — FileOpsLogStore 기존 정책 유지).
- 배치 trash 부분 실패 시 선닫은 탭 미복구(F1a 승계).
- 표시 중 폴더가 이동될 때 selectedFolder 미보정(기존 잔여 트리아지 합류).
- 트리 ⇧범위 미지원(후속 확장 여지 — 가시 행 평탄화 헬퍼).
