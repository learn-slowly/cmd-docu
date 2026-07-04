# F2 드래그 이동 — 라이브러리·트리 안팎 드래그&드롭 (설계)

- 날짜: 2026-07-04
- 상태: 사용자 승인(대화). Finder 대체 로드맵(F1a→F1b→F3→**F2**→F4)의 네 번째 조각.
- 선행: `2026-07-03-finder-replacement-roadmap.md`, F1b(배치 이동/복사 인프라), F3(경로 바·히스토리·정렬)

## 0. 목표와 사용자 결정

파일을 끌어서 옮긴다 — 라이브러리·사이드바 트리 안에서, 그리고 Finder와 양방향으로. 실행부는 F1b 배치 인프라를 재사용해 로그·배치 undo·짝꿍 노트 동반·탭 정합을 공짜로 얻는다.

사용자 결정(2026-07-04 대화):

| # | 결정 | 내용 |
|---|---|---|
| 1 | 방향 범위 | **양방향 전부.** 앱 내부 이동(라이브러리·트리) + Finder→앱 인바운드(이동 기본·⌥ 복사) + 앱→Finder 아웃바운드는 **복사 한정**(Finder가 실행 주체라 앱 로그·undo 밖 — ⌘C→Finder ⌘V 선례와 동형, 정책 충돌 없음). |
| 2 | 폴스루 | **내부 드래그는 식별해 무시.** 내부 드래그 페이로드에 앱 전용 타입을 병행 탑재, 창 레벨 "드롭=열기" 핸들러가 내부 드래그면 no-op(빗나간 드롭=조용한 무동작 — Finder와 같은 감각). Finder발 외부 드롭의 "열기"는 유지. |
| 3 | 타깃 범위 | **기본 4곳 + 스프링로딩.** 라이브러리 폴더 셀(그리드·리스트)·라이브러리 배경(=표시 중 폴더)·트리 폴더 행·트리 빈 영역(=작업 폴더 루트). 드래그 오버 시 폴더 자동 펼침(스프링로딩) 포함. 경로 바 세그먼트·즐겨찾기 행은 후속. |

설계 결정(관례 정합 — 코디네이터):

- **무확인 실행 + 결과 토스트.** `pasteFromPasteboard`(⌘V/⌥⌘V)가 무확인 실행 선례 — 드롭 제스처가 곧 확인이고 배치 undo("모두 되돌리기")가 있다.
- **⌥=복사, 기본=이동**(Finder 드래그 관례). F1b 붙여넣기(⌘V=복사·⌥⌘V=이동)와 **의미가 역방향**임을 코드 주석·본 스펙에 명시 — 둘 다 Finder 관례 준수라 정당.
- **API는 SwiftUI 순정(A안)**: 소스 `.onDrag { NSItemProvider }`, 타깃 `.onDrop(of:isTargeted:)`, ⌥는 드롭 시점 `NSEvent.modifierFlags` 정적 읽기(F1b 클릭 판별 선례, capsLock 교집합 관례). 한계 수용: 드래그 커서의 복사(+) 배지를 move/copy에 맞춰 제어하지 못함(문서화). AppKit `NSDraggingDestination` 래핑(B안)은 스파이크가 A안 실패를 실증할 때만 국소 도입.

## 1. 현재 구조 (정찰 확정 사실)

- 기존 드롭 4곳: ①창 레벨 `.onDrop(of: [.fileURL])`(CmdMDApp.swift:15 — ContentView 전체가 "파일 열기" 타깃, **첫 provider만 열고 true**, isTargeted 없음) ②에디터 이미지 드롭(MainEditorView.swift:250 — [.image, .fileURL], assets/ 복사+링크 삽입, isTargeted 오버레이 선례) ③NSTextView `registerForDraggedTypes([.fileURL, .png, .tiff])`(EditorTextView.swift:282 — 오버라이드 0건, AppKit 기본 위임 잠복) ④탭바 `.draggable(String)`/`.dropDestination(String)`(탭 순서 전용). **드래그 소스는 탭 String뿐 — 파일 드래그 소스 0.**
- 실행 인프라(F1b): `performBatchMove/Copy(urls:to:) async -> (succeeded, failed)` — 건별 짝꿍 flush→FileOperations.move/copy→탭 재조준→짝꿍 동반, 배치 끝 appendBatch 1회+completeFileOperation 1회(F3의 stale 재조준·히스토리 prune 포함)+부분 실패 요약. 같은 부모 이동은 사전 필터로 조용한 skip. `FileOperations.move` 가드: 제자리 `.invalidDestination`·자기/하위 이동 '/' 경계·충돌 uniquify(덮어쓰기 금지).
- 선택 상태: `fileSelection: Set<URL>`(라이브러리·트리 공유)·`FileSelectionHelper.ancestorsOnly(Set<URL>) -> [URL]`(중첩 정규화, 멱등 — ⌘C·배치가 이중 호출).
- 트리 구조: List(.sidebar)에 최상위만 List 행, 자식은 부모 행 내부 VStack 재귀(List 행 아님 — 행별 onDrop 필요). `FileTreeItem.id`는 재빌드마다 새 UUID(선택·드롭 식별은 URL 기준이어야 함). `toggleFolderExpansion`은 비멱등 토글+loadFileTree(백그라운드 재빌드).
- ⌥ 감지 선례: 클릭 시점 `NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)`(LibraryView·SidebarView), 이벤트 기반 교집합 `[.command,.option,.shift,.control]`(AppState — capsLock 함정 주석).
- 미검증 런타임 거동(코드로 확정 불가 — §6 스파이크): 셀 탭 제스처와 onDrag 경합, 중첩 onDrop 우선순위(안쪽 우선 통례), 드롭 시점 ⌥ 정적 읽기 신뢰성, 재빌드 중 드롭 세션 연속성, 비이미지 드롭의 에디터 폴스루.

## 2. 드래그 소스

### 2.1 페이로드 규칙 (Finder 관례)

- 드래그 항목 ∈ `fileSelection` → `FileSelectionHelper.ancestorsOnly(fileSelection)` 전체를 끌기. 아니면 그 항목 하나만. **드래그 시작은 선택을 변경하지 않는다**(BatchSelectionMenu의 포함 검사와 동일 조건).
- 적용 표면: 라이브러리 그리드/리스트 셀(파일·폴더 모두), 트리 파일/폴더 행. 소스 제스처는 `.onDrag`(셀/labelRow 레벨 — 기존 onTapGesture(count:2)·onTapGesture·contextMenu 스택과의 경합은 스파이크 실측).

### 2.2 페이로드 구성 — `DragPayload` (신규 순수 헬퍼, 별도 파일)

- NSItemProvider에 **두 표현 병행 탑재**:
  - `.fileURL` — Finder 호환(아웃바운드 복사·다른 앱 수신). ⚠️ SwiftUI `.onDrag`는 provider
    1개 한계로 **아웃바운드 다중 드래그는 드래그한 항목 1개만 전달**된다(구현 확정 — 다중
    내보내기는 기존 ⌘C→Finder ⌘V, 완전한 다중 아웃바운드는 후속 B안/NSFilePromiseProvider).
  - 앱 전용 식별 타입 `work.cmdspace.cmddocu.drag`(exported UTType) — **파스테보드에 타입 '선언'을 얹어 내부 드래그를 판별**하는 신호 용도(데이터는 실전에서 전달 안 됨, 아래 실측). 내부 타깃/창 레벨 핸들러는 이 타입의 '존재'로 내부 드래그를 판별하고, **실제 URL 목록 전체는 `AppState.draggingURLs` 스냅샷**으로 나른다.
- `DragPayload` 책임: 페이로드 결정 규칙(§2.1)·직렬화(provider 등록용)·`isInternalDrag(pasteboard:)` 판별 — 전부 순수, 단위테스트 대상. **페이로드 채널은 `draggingURLs` 스냅샷**(파스테보드/​provider 아님 — 아래 2층 실측).
- **실측 정정(구현 후 확정, 2층)**: ①SwiftUI 드롭 쪽 provider 재구성은 **미등록 커스텀 UTType 표현을 누락**한다 — 드롭 콜백이 받는 provider의 `registeredTypeIdentifiers`엔 `public.file-url`만 남는다. ②게다가 `.onDrag` 전사는 커스텀 타입을 드래그 파스테보드에 **'선언'만 싣고 데이터 promise는 이행하지 않는다**(`NSPasteboard(name: .drag)`에 타입은 존재하나 `data(forType:)`는 **0바이트** — 실측). 즉 provider도 파스테보드도 커스텀 페이로드 '데이터'를 나르지 못한다. **대응 2가지로 분리**: (a) **판별**은 파스테보드의 커스텀 타입 '선언' 유무로(`isInternalDrag` — 창/에디터 폴스루 가드·델리게이트가 드래그/드롭 콜백 안에서 호출, 활성 세션 파스테보드 보장), (b) **페이로드**는 `.onDrag`가 세션 시작 시 채운 `AppState.draggingURLs` 스냅샷으로 수신부가 읽는다. Finder발 외부 드래그는 커스텀 타입 선언이 없어 판별 false → `draggingURLs`도 참조하지 않아 stale 오염(C1) 원천 차단(외부는 provider fileURL만 수집).
- 아웃바운드(앱→Finder): fileURL 표현을 Finder가 받아 **복사** 실행(앱은 로그하지 않음 — ⌘C 선례와 동형, 결정 1). 이동 시맨틱(NSFilePromiseProvider 등)은 범위 밖.

## 3. 드롭 타깃 4곳

| 타깃 | 목적지 | 부착 지점 |
|---|---|---|
| 라이브러리 폴더 셀 | 그 폴더 | 셀 뷰(그리드·리스트, `item.isDirectory`만) |
| 라이브러리 배경 | 표시 중 폴더(`selectedFolder ?? currentFolder`) | ScrollView(그리드)/List(리스트) 레벨 — 배경 탭(clearFileSelection)과 같은 층 |
| 트리 폴더 행 | 그 폴더 | FileTreeItemRow의 행 HStack 레벨(자식은 List 행 밖 VStack이라 행별 부착) |
| 트리 빈 영역 | 작업 폴더 루트(`currentFolder`) | 트리 List 레벨 |

- 수신 타입: `[커스텀 타입, .fileURL]` — 커스텀 타입은 내부 드래그 판별 신호(선언), 페이로드는 `draggingURLs` 스냅샷. Finder발은 fileURL 수집.
- **하이라이트**: `.onDrop(of:isTargeted:)` 바인딩 → 셀은 액센트 테두리(에디터 이미지 드롭 오버레이 선례·선택 하이라이트와 시각 구분), 트리 행은 행 폭 전체 배경(labelRow 밖 HStack 레벨 — 콘텐츠 폭만 덮는 함정 회피).
- **사전 차단(하이라이트만)**: 대상 폴더가 드래그 집합에 포함되거나 그 하위면 **하이라이트·스프링로딩만 비활성**하고 드롭 자체는 **소비**한다(최종 리뷰 fix wave — validateDrop=false로 타깃을 비활성하면 무효 내부 드롭이 상위 타깃(트리 루트 등)으로 폴스루해 조용히 루트로 이동하는 I2 결함). 무효 내부 드롭은 handleFileDrop의 2차 필터(standardizedFileURL + '/' 경계)가 조용한 무동작으로 만든다. 판정은 순수 함수 `DropGuard.dropDecision(isInternal:sources:destination:)`(진리표: 외부=수락·하이라이트 / 내부·유효=수락·하이라이트 / 내부·무효=수락·하이라이트 없음)로 추출해 단위테스트. 내부/외부 판별은 **드래그 파스테보드**(`NSPasteboard(name: .drag)`)의 `.cmdDocuDrag` 유무로 — SwiftUI가 드롭 provider에서 커스텀 타입을 누락(위 §2 실측)해 `info.hasItemsConforming`은 신뢰 불가이므로 파스테보드를 직판한다. 외부 세션은 커스텀 타입 부재로 false이고 `draggingURLs` 스냅샷도 참조하지 않아 stale 오염(C1)을 원천 차단.
- **실행**: 페이로드 확보 — **내부 드래그는 `draggingURLs` 스냅샷(동기)**, 외부(Finder)는 provider들에서 fileURL 수집(loadItem 콜백은 비메인 — 수집 완료 후 `Task { @MainActor in ... }`). 두 경로가 공통 다운스트림(`completeFileDrop`)으로 합류 → ⌥ 판독(`NSEvent.modifierFlags` 교집합, 드롭 진입 직후) → 2차 필터(자기/하위) → `performBatchCopy`(⌥) 또는 `performBatchMove`(기본) **1회 호출**(건별 호출 금지 — batchId 분해로 "모두 되돌리기"가 쪼개짐). 무확인, 결과 토스트(기존 부분 실패 요약 재사용). **이동에서 전량 same-parent skip으로 (0,0)이면 "이동할 항목 없음" 토스트**(무동작 오인 방지 — 복사는 같은 폴더여도 uniquify 사본 생성이 정상 동작이라 해당 없음).
- Finder→앱 인바운드도 같은 경로(이동 기본·⌥ 복사). 외부 원본의 undo 역이동 노출은 기존 ⌘V와 동일(신규 위험 없음).

## 4. 폴스루·기존 드롭과의 공존

- **창 레벨 핸들러 가드**: `DragPayload.isInternalDrag()`(드래그 파스테보드 직판 — provider는 커스텀 타입 누락, §2 실측)면 **true 반환 후 no-op**(false로 폴스루시키지 않고 소비해 "열기" 차단 — 결정 2). 에디터 폴스루 가드(`MainEditorView.handleDrop`)도 같은 파스테보드 판별. Finder발은 기존 열기 유지.
- **동반 수정: 창 레벨 다중 열기.** 현재 첫 provider만 여는 것(CmdMDApp.swift:356-367)을 **전부 열기**로 정정 — F1b 다중 선택 시대와 어긋나는 기존 결함. URL 전부 수집 후 메인에서 순차 `openDocument(at:, inNewTab: true)`.
- 에디터 이미지 드롭·NSTextView 등록·탭바 String dropDestination은 **불변**. 내부 드래그가 에디터 위에서 이미지 삽입으로 새는지 스파이크 실측 — 새면 에디터 핸들러(MainEditorView handleDrop)에도 내부 드래그 가드 1줄.
- 탭바 `.dropDestination(for: String.self)`이 fileURL 드래그를 String으로 오수신하는지 스파이크에서 확인(오발화 시 가드).

## 5. 스프링로딩 (트리)

- **전제 동반 개선**: 트리 ForEach identity를 `id: \.url`로 전환(최상위 List·자식 ForEach 둘 다 — 라이브러리(F3 §2.4)와 같은 안정화 패턴). 재빌드 시 행 재생성을 URL 불변 범위로 최소화.
- `AppState.expandFolder(_ url:)` **insert 전용 멱등 경로** 신설(`expandedFolders.insert` + 미포함이었을 때만 `loadFileTree()` — 기존 toggle은 재발화 시 도로 접히는 비멱등이라 드래그 오버용 부적합).
- 폴더 행 드래그 오버 **~0.8초** 유지 시 1회 발화: 행별 `@State` 타이머(Task.sleep), `isTargeted` false 전환·드롭·드래그 종료 시 취소. 이미 펼쳐진 폴더는 무동작.
- **격리 원칙**: 스프링로딩은 별도 수정자/상태로 격리 — 재빌드 중 드롭 세션 연속성이 실측에서 깨지면 스프링로딩만 제거해도 나머지 드롭 기능이 무사해야 한다.

## 6. 실측 스파이크 (계획 첫 태스크)

미검증 거동을 최소 구현으로 조기 확정(결과를 계획 후속 태스크에 반영, 실패 시 B안 국소 전환 판단):

1. 라이브러리 셀 `.onDrag`와 단일/더블 탭·⌘/⇧ 클릭 경합 — 클릭=선택이 드래그 시작으로 오발화하는지, 더블클릭 지연.
2. 중첩 드롭 우선순위 — 셀 onDrop > 배경 onDrop > 창 레벨 onDrop이 실제로 안쪽 우선인지.
3. 드롭 시점 `NSEvent.modifierFlags` 정적 읽기 신뢰성(⌥를 드롭 직후 떼는 타이밍 민감성).
4. 스프링로딩 재빌드 중 드롭 세션 연속성(하이라이트 리셋·드롭 수신 실패 여부).
5. 비이미지 파일 드래그가 에디터 위 경유/드롭 시 어디로 가는지(이미지 삽입 오발화·NSTextView 기본 동작 표면화).

## 7. 안전·정합 (기존 불변식 승계)

- 실행은 performBatchMove/Copy 재사용이므로: 로그(batchId)·"모두 되돌리기"·짝꿍 노트 동반(이름 파생)·열린 탭 재조준·completeFileOperation(세대 토큰·선택 prune·F3 stale 재조준·히스토리 prune·트리 재로드·세션 저장)이 자동 적용. **F2가 새로 만들 정합 작업 없음.**
- 표시 중 폴더 자체를 드래그로 이동하면 F3 retarget이 옛 경로의 존재 조상으로 후퇴(새 위치 추적 아님 — 화면이 부모로 점프하는 UX, 수용).
- 배치 undo 전 flush 없음(F1b 트리아지 잔여)이 드롭 이동에도 상속 — 승인 트레이드오프 재명시.
- 심링크(/var↔/private/var) 미해소 기존 한계 유지 — Finder발 URL의 standardized 비교 엣지 잔존.
- 삭제 없음·덮어쓰기 금지(uniquify)·원본 불변(아웃바운드는 Finder가 복사) — 로드맵 공통 원칙 준수.

## 8. 테스트

| 대상 | 내용 |
|---|---|
| `DragPayloadTests` (신규) | 페이로드 결정 규칙(선택 포함/미포함)·직렬화 라운드트립·isInternalDrag 판별·ancestorsOnly 결합 |
| `DropGuardTests` (신규) | 자기 자신/하위 드롭 거부·'/' 경계(형제 오감지)·정상 수락 |
| `AppExpandFolderTests` (신규) | expandFolder 멱등(재호출 무해)·미펼침→펼침 시만 loadFileTree |
| 기존 스위트 | performBatch*·FileOperations·FileSelectionHelper는 기존 테스트가 커버(불변) |

DnD 실기 동작(제스처·Finder 왕복·⌥·스프링로딩·폴스루)은 수동 스모크 — 스파이크(§6)와 최종 스모크 체크리스트로 이원 검증.

## 9. 범위 밖

경로 바·즐겨찾기 드롭 타깃, 아웃바운드 이동 시맨틱(NSFilePromiseProvider), 드래그 커서 배지(move/copy) 제어, 드래그 프리뷰 커스텀, 심링크 해소, 탭바로 드래그해 열기.
