# 세션 복원 경합 근본 수정 — 설계

날짜: 2026-07-06
상태: 구현 완료(2026-07-06) — 실기 스모크(§4)는 Downloads 정리 적용·재설치 후
브레인스토밍 결정(2026-07-05, 사용자 확정 4건): ①외부 열기=항상 새 탭 ②다중 열기=마지막 파일 활성 ③세션 복원=activate 없이 배치 ④WindowGroup→단일 창(Window 씬)

## §1 문제

앱 종료 상태에서 Finder로 문서(.hwp 등)를 더블클릭하면:

- (a) **이전 세션 복원과 외부 파일 열기가 경합** — 활성 탭·탭 구성이 비결정적. 2026-07-05 스모크(LS 열기)에서도 재관찰.
- (b) **두 번째 문서 창이 생김.**

근본 원인(코드 확인, 2026-07-06 정찰):

1. 외부 열기 `onOpenURL`(`CmdMDApp.swift:12`) → `handleURL`(`:347-353`)이 `openDocument(at:)`를 **`inNewTab: false`(기본값)** 로 호출 → `placeTab`(`AppState.swift:1082-1098`)이 **활성 탭을 그 자리에서 교체**. 복원 중인 탭이 교체당할 수 있다.
2. 세션 복원 `restoreSessionIfNeeded`(`AppState.swift:3322-3359`)가 파일마다 `loadAndActivateDocument(inNewTab: true)`를 순차 호출 — **매 파일마다 activeTabId가 바뀌고**, 이 Task와 외부 열기 Task가 같은 `tabs`/`activeTabId`를 인터리빙. 기존 가드 `shouldRestoreActiveTab`(`:3317-3320`)은 마지막 활성 탭 재지정만 부분 방어.
3. 씬이 `WindowGroup`(`CmdMDApp.swift:9`) — 다중 창 허용 씬이라, 콜드 런치 시 상태 복원 창과 외부 열기 이벤트 전달용 창이 **각각 생겨 중복 창 2개**(같은 AppState 공유라 내용도 동일).
4. 다중 파일 동시 열기의 순서 비보장 — `onOpenURL`은 파일마다 개별 발화하고(각각 활성 탭 교체 → 마지막 하나만 남는 버그성 동작), 드롭 경로 `openExternalFileDrops`(`AppState.swift:2433-2449`)는 `loadItem` 콜백이 비동기·순서 비보장이라 **마지막 활성 파일이 비결정적**.

## §2 설계 개요

결정 4건을 각각 원인 3·1·2·4에 대응시킨다. 신규 개념은 "직렬 열기 큐" 하나뿐이고, 나머지는 기존 경로의 파라미터·구조 정리다.

### §2.1 단일 창 씬 (결정 ④ → 원인 3)

`WindowGroup` → `Window`(`CmdMDApp.swift:9`). 창이 구조적으로 1개만 존재해 중복 창 경로가 사라진다.

- `.onOpenURL`/`.onDrop`/`.windowStyle`/`.defaultSize`/`.commands`는 그대로 유지.
- `Settings`·`MenuBarExtra` 씬 불변.
- 기존 창 관련 코드 영향 없음(정찰 확인): `willCloseNotification`+`canBecomeMain` 미디어 정지 필터(`CmdMDApp.swift:402-409`), 파일 키 로컬 모니터(`:413-416`), `handleFileOpsKeyEvent`의 keyWindow 가정 — 다중 창 존재를 가정하는 코드는 없다. 창이 1개가 되어 오히려 단순해진다.
- **창 재표시**: 외부 열기 처리 시 문서 창이 닫혀(숨겨져) 있으면 `NSApp.activate` + 메인 창 `makeKeyAndOrderFront`로 표시하는 헬퍼를 큐 처리부에 넣는다. `WindowGroup`은 새 창을 만들어 이벤트를 전달했지만 `Window`는 그러지 않으므로 필요.
- ⚠️ **확인 필요(실기 스모크)**: 창이 닫힌 상태에서 Finder 더블클릭 시 `Window` 씬이 `onOpenURL`을 전달하며 창을 재표시하는지. SwiftUI가 자체 재표시하면 헬퍼는 보험이 되고, 안 하면 헬퍼가 필수 경로가 된다. 어느 쪽이든 동작하도록 헬퍼는 무조건 넣는다.

### §2.2 외부 열기 = 항상 새 탭 (결정 ① → 원인 1)

`handleURL`의 파일 분기를 직렬 열기 큐 제출로 바꾸고, 큐는 `inNewTab: true`로 연다.

- **중복 URL 재사용 가드 유지**: `openDocument`(`AppState.swift:1044-1057`)의 "같은 URL 이미 열림 → 기존 탭 활성"은 그대로. "항상 새 탭"의 의미는 **활성 탭을 교체하지 않는다**이지 중복 탭 허용이 아니다.
- `cmdmd` 스킴 분기(`openInternalURL`)는 불변(경합 범위 밖 — §6 비범위).

### §2.3 직렬 열기 큐 = 다중 열기 결정성 (결정 ② → 원인 4)

AppState에 외부 열기 전용 직렬 큐를 둔다: `private var externalOpenChain: Task<Void, Never>?` + `func enqueueExternalOpen(_ urls: [URL])`.

- 체인 방식: `enqueueExternalOpen`은 이전 체인 Task를 캡처하고 `Task { @MainActor in await prev?.value; for url in urls { await loadAndActivateDocument(at: url, inNewTab: true) } }`로 잇는다. MainActor 직렬 + 도착 순 FIFO → **마지막 처리 파일이 활성**.
- `onOpenURL` 다발(파일마다 개별 발화)은 각 호출이 `enqueueExternalOpen([url])`로 제출 — 도착 순이 곧 처리 순.

> **정정(2026-07-06 실기 스모크):** 단일 `Window` 씬에선 배치 열기(Finder 다중 선택)가
> `.onOpenURL`에 **첫 URL만** 전달된다(실측 — WindowGroup은 URL마다 씬을 만들어 개별
> 발화했던 것). 정경로를 `AppDelegate.application(_:open:)`(URL 배열 수신)로 옮기고
> `.onOpenURL`은 폴백으로 유지.
- 드롭 다중은 **provider 순서 보존 수집 후 일괄 제출**: `openExternalFileDrops`를 "인덱스 슬롯 배열에 수집(콜백 순서 무관) → 완료 시 URL 배열로 `enqueueExternalOpen`" 구조로 재작성. 단일 드롭도 같은 경로(아래 시맨틱 변경 참고).
- **시맨틱 변경(F2 스펙과의 차이, 명시적 결정)**: F2는 "단일 드롭 = 기존 동작(활성 탭 교체)"였으나(`AppState.swift:2438` 주석), 본 설계로 **드롭도 외부 열기로 통일되어 항상 새 탭**이 된다. 활성 탭이 드롭 한 번에 교체당하는 놀람을 없애는 방향이며, 더블클릭과 드롭의 시맨틱이 일치한다.

### §2.4 배치 복원 (결정 ③ → 원인 2)

`restoreSessionIfNeeded`(`AppState.swift:3322-3359`)의 파일 열기 루프를 배치 경로로 바꾼다.

- `loadAndActivateDocument`에서 **"로드만"을 분리**: `loadDocument(at:) async -> EditorTab?`(문서 읽기·탭 생성까지, `placeTab`/활성화/saveSession 없음). 기존 `loadAndActivateDocument`는 이 위에서 재구성(동작 불변).
- 복원은: 각 파일을 `loadDocument`로 로드(세션 파일 내 중복 URL은 첫 것만) → **일괄 `tabs.append`** → `activeTabId`를 저장된 `activeFileIndex`로 **끝에 한 번만** 지정 → `saveSession` 한 번.
- **복원 Task를 큐 선두에 시드**: `externalOpenChain`의 첫 항목으로 복원 배치를 넣는다. 복원 중 도착한 외부 열기는 체인상 복원 뒤에 처리되어 자연스럽게 "외부 파일 = 마지막 = 활성"(더블클릭한 파일이 앞에 보이는 기대 동작과 일치).
- 기존 `shouldRestoreActiveTab` 가드는 직렬화로 원리상 불필요해지지만 **방어적으로 유지**(체인 밖에서 activeTabId를 바꾸는 경로 — 사용자 클릭 등 — 가 복원 완료 전에 개입한 경우 덮어쓰지 않음).

### §2.5 launch activate

`applicationDidFinishLaunching`의 무조건 `NSApp.activate`(`CmdMDApp.swift:384-390`)는 불변. 앱 활성화(창 앞으로) 축이지 탭 경합 축이 아니며, 콜드 런치에서 창을 앞으로 가져오는 기대 동작이다.

## §3 테스트

기존 `AppState(dataDirectory:)` 임시 디렉터리 주입 패턴(`TempDataDirectory`). 신규/변경 케이스:

1. **배치 복원**: session.json 시드(파일 3개+activeFileIndex=1) → 복원 후 탭 3개·activeTabId가 인덱스 1 탭·**중간 활성화 없음**(activeTabId 변경 횟수 1 — didSet 카운터 또는 관찰 헬퍼로 검증).
2. **복원↔외부 열기 인터리브**: 복원 시드 직후 `enqueueExternalOpen([외부URL])` → 완료 시 탭 = 복원분+외부 1, **활성 = 외부 파일**.
3. **다중 외부 열기 순서**: `enqueueExternalOpen`을 연속 3회 → 탭 순서 = 제출 순, 활성 = 마지막.
4. **재사용 가드**: 이미 열린 URL을 enqueue → 탭 수 불변, 그 탭 활성.
5. **드롭 수집 순서**: `openExternalFileDrops`의 수집부(인덱스 슬롯)를 순수 헬퍼로 분리해 콜백 역순 도착 시나리오에서도 provider 순서 보존 검증.
6. **loadDocument 분리 불변**: 기존 `loadAndActivateDocument` 경유 테스트(AppMediaOpenTests·AppImageTabTests 등 기존 스위트)가 그대로 통과 = 리팩터 동작 불변의 백스톱.
7. 기존 `AppSessionRestoreTests`(shouldRestoreActiveTab 4케이스) 유지.

**단위테스트 원리상 불가(실기 스모크 필수)**: 씬 구조(`Window` 단일 창·중복 창 부재), 콜드 런치 Finder 더블클릭(LS 이벤트 전달), 창 닫힘 상태 재표시(§2.1 확인 필요). — AVKit·배타성·드래그 파스테보드·IM 자판과 같은 부류.

## §4 실기 스모크 (연기 — Downloads 적용 후)

재패키징·재설치·앱 재시작이 필요하므로, **실행 중 앱의 Downloads 정리 미리보기(27분분)를 사용자가 적용한 뒤** 진행한다.

1. 앱 종료 상태에서 .hwp 더블클릭 → 창 1개, 세션 복원 탭들 + 더블클릭 파일이 **새 탭·활성**.
2. Finder에서 md 3개 선택 후 열기 → 3개 전부 새 탭, 마지막 파일 활성.
3. 앱 실행+창 닫힘(메뉴바 상주) 상태에서 더블클릭 → 창 재표시 + 새 탭(§2.1 확인 필요 해소).
4. 단일 파일 드롭 → 새 탭(활성 탭 교체 없음 — §2.3 시맨틱 변경 확인).
5. 세션 복원만(외부 열기 없이 재시작) → 이전 탭·활성 탭 복원, 창 1개.

## §5 비범위

- `cmdmd` URL 스킴 처리(`openInternalURL`) 변경 없음.
- 라이브러리/트리 내부 열기 경로(사용자 클릭) 변경 없음 — 큐를 타지 않는다(즉시 반응 유지).
- 세션 저장 포맷(`SessionState`) 변경 없음.
- 심링크 경로 정규화(기존 트리아지 항목) 별건 유지.
