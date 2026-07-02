# Phase 10 설계 — 다듬기·배포 (cmdALL 개명·단축키·Tools 탭·DMG)

- 날짜: 2026-07-02
- 상태: 사용자 설계 승인 완료(대화), 스펙 리뷰 대기
- 선행 결정(브레인스토밍 문답):
  - 개명 범위 = **겉면만**. 이름 반영 방식 = **리터럴 검색-치환**(중앙 상수 도입 안 함)
  - 서명·설치 = **ad-hoc + DMG**
  - 단축키 = 4개 전부(내용 검색·RAG·라이브러리 토글·폴더 정리)
  - 설정 정리 = **통합 Tools 탭 1개**, CLI 상태는 **동기 경로 표시만**(버전 프로브 없음)
  - 버전 = **0.9.0**
  - 추가 범위 = VaultManagerView:660 배타성 트랩 검증·수정 + README·문서 마무리
  - 제외 = LLM-Wiki 스키마(별도 세션), Developer ID 공증(스크립트 존치만)

## 0. 목표·비목표

**목표**: Phase 0~9로 완성된 기능을 개인용 배포 가능한 상태로 다듬는다 — 새 이름(cmdALL), 신규 기능 단축키, 설정 창 통합 탭, DMG 산출물, 문서 정리.

**비목표**: 번들ID·바이너리명·URL 스킴·데이터 디렉터리 변경(데이터 마이그레이션 없음), Developer ID 공증 실행, GitHub 저장소 개명, 신규 기능 추가.

## 1. cmdALL 겉면 개명

### 1.1 소스 문자열 치환 (`"cmd-docu"` → `"cmdALL"`)

노출 문자열 12곳 + 주석 2곳. 전수 조사 결과(2026-07-02 grep 기준):

| 파일:줄 | 내용 | 처리 |
|---|---|---|
| `Sources/App/CmdMDApp.swift:24` | `Button("About cmd-docu")` | 치환 |
| `Sources/App/CmdMDApp.swift:284` | `MenuBarExtra("cmd-docu", …)` | 치환 |
| `Sources/App/AppState.swift:226` | `windowTitle` 폴백 `return "cmd-docu"` | 치환 |
| `Sources/App/AppState.swift:631` | 업데이트 확인 User-Agent | 치환 |
| `Sources/Views/SettingsView.swift:136` | `Label("cmd-docu (GitHub)", …)` | 치환(URL은 유지) |
| `Sources/Views/SettingsView.swift:138` | `Button("About cmd-docu…")` | 치환 |
| `Sources/Views/SettingsView.swift:142` | 크레딧 문구 | `"cmdALL — CmdMD(© 2026 CMDSPACE) 포크 · MIT License"` |
| `Sources/Views/MenuBarView.swift:18` | `Label("Open cmd-docu", …)` | 치환 |
| `Sources/Views/MainEditorView.swift:416` | `Text("cmd-docu")` | 치환 |
| `Sources/Views/ContentView.swift:317` | `Text("Welcome to cmd-docu")` | 치환 |
| `Sources/Views/ContentView.swift:464` | `Text("cmd-docu")` (About 카드) | 치환 |
| `Sources/Models/Brand.swift:112,139` | 주석 2곳 | 치환(무해) |

**유지(치환 금지)** — 저장소 주소이므로 그대로:
- `AppState.swift:630` `api.github.com/repos/learn-slowly/cmd-docu/releases/latest`
- `AppState.swift:644` `github.com/learn-slowly/cmd-docu/releases/latest`
- `ContentView.swift:434` `github.com/learn-slowly/cmd-docu`

**테스트 갱신**: `Tests/CmdMDTests/AppWindowTitleTests.swift:23` 어서션 `"cmd-docu"` → `"cmdALL"`. `RagPassageExtractorTests.swift:43`은 테스트 데이터 본문일 뿐이므로 유지.

**변경하지 않는 식별자**(겉면 결정): 번들ID `work.cmdspace.cmddocu`, SPM 타깃·바이너리명 `CmdMD`, `CFBundleExecutable=CmdMD`, URL 스킴 `cmdmd://`, 데이터 디렉터리 `Application Support/CmdMD`. 기존 설정·세션·인덱스·위키링크 전부 무손실. Activity Monitor에 프로세스명 CmdMD로 보이는 것은 감수(겉면 개명의 의도된 한계).

### 1.2 스크립트·CI 갱신

- **`scripts/package_app.sh`**:
  - `.app` 파일명 `cmdALL.app`(dist), 내부 실행파일은 `Contents/MacOS/CmdMD` 유지
  - Info.plist: `CFBundleDisplayName=cmdALL`, `CFBundleName=cmdALL`(메뉴바·Dock 표기), `CFBundleExecutable=CmdMD` 유지, `CFBundleShortVersionString=0.9.0`, 번들ID·URL 스킴 유지
  - zip 산출물 `cmdALL-macos.zip`
  - 변수 분리: 앱 번들명(cmdALL)과 실행파일명(CmdMD)을 별도 변수로(현재는 `APP_NAME` 하나가 둘 다 담당)
- **`scripts/make_dmg.sh`**: 기본 앱 경로 `dist/cmdALL.app`, 볼륨명 `cmdALL 0.9.0`, 산출물 `dist/cmdALL-0.9.0.dmg`
- **`scripts/test_package_app.sh`**: 검증 경로를 `cmdALL.app`/`Contents/MacOS/CmdMD`/`cmdALL-macos.zip`으로 갱신
- **`scripts/sign_and_notarize.sh`**: `dist/cmdALL.app`·DMG 파일명 참조 갱신(공증 실행은 비목표, 경로 일관성만)
- **`.github/workflows/release.yml`**: 산출물명 `cmdALL-macos.zip`·`cmdALL-*.dmg`·SHA256SUMS 대상 갱신. 버전-태그 체크는 `CFBundleShortVersionString` grep이라 무수정 동작
- `scripts/make_icon.swift` 등 스크립트 내 이름 언급은 구현 시 grep으로 확인해 노출 산출물에 영향 있는 것만 갱신

## 2. 단축키 4개 (전부 리맵 가능)

`AppShortcut` enum(Sources/Models/Shortcuts.swift)에 case 4개 추가. CaseIterable이라 Shortcuts 설정 탭에 자동 등장. 설정 파일에 저장된 적 없는 새 키는 기존 메커니즘상 `defaultBinding` 폴백(구현 시 `keyBinding(for:)` 폴백 경로 확인).

| case | title | 기본값 | 메뉴 위치 | 동작 |
|---|---|---|---|---|
| `indexSearch` | "Search Index (내용 검색)" | ⌥⌘F | Find 메뉴(Find in Folder 아래) | `appState.showIndexSearch = true` |
| `askCorpus` | "Ask Corpus (자료에 묻기)" | ⌥⌘A | Find 메뉴 | `appState.showAskCorpus = true` |
| `toggleLibraryMode` | "Toggle Reader/Library" | ⇧⌘L | View 메뉴 | `mainMode` reader⇄library 토글 |
| `folderCleanup` | "Folder Cleanup (폴더 정리)" | ⌥⌘K | View 메뉴(기존 "폴더 정리 (배치)" 항목에 부착) | 기존 항목의 액션 그대로(reset 후 열기) |

- 기본값 충돌 검증 완료(2026-07-02): ⇧⌘F는 "Find in Folder" 하드코딩이 선점 → ⌥⌘F 채택. ⌥⌘A·⇧⌘L·⌥⌘K는 하드코딩·리맵 기본값 어느 쪽과도 충돌 없음.
- Find 메뉴 신규 항목 2개는 커맨드팔레트 항목("내용 검색 (인덱스)"·"자료에 묻기 (RAG)")과 같은 AppState 플래그를 쓰므로 동작 동일. 커맨드팔레트 항목은 그대로 유지.

## 3. Tools 설정 탭

`SettingsView`에 6번째 탭 `Tools`(아이콘 `wrench.and.screwdriver`) 추가. 새 파일 분리 없이 SettingsView.swift 안에 `ToolsSettingsView` struct(기존 탭 뷰들과 같은 파일 관례).

- **kordoc 섹션**: `KordocService.resolveNpxPath()` 결과 표시 — 찾으면 경로(모노스페이스·secondary), 못 찾으면 "미설치 — Node 18+와 npx가 필요합니다" 안내. 새로고침 버튼.
- **Claude 섹션**: `ClaudeService.resolveClaudePath()` 동일 패턴 + "Claude 스마트 라우팅" 토글(`settings.claudeRoutingEnabled` 바인딩 재사용 — VaultManager PARA 탭과 같은 값이라 자동 동기화).
- **검색 섹션**: 인덱스 등록 폴더(`settings.indexedFolders`) **읽기 전용 목록**(비었으면 "등록된 폴더 없음") + "내용 검색 열기" 버튼(`showIndexSearch = true` — 설정 창은 별도 윈도우이므로 메인 윈도우에서 시트가 뜨는 것으로 충분) + "질의 확장(RAG)" 토글(`settings.ragExpandQuery` 바인딩).
- 경로 탐지 결과는 `@State` 캐시, `onAppear`와 새로고침 버튼에서 재탐지. 외부 프로세스 실행 없음(A안).
- 추가·해제 같은 인덱스 변경 동작은 넣지 않는다(IndexSearchView와 로직 중복 방지, 읽기 전용).

## 4. VaultManagerView:660 배타성 트랩 검증·수정

- 대상: `rule.conditions.removeAll { $0.id == condition.id }` — `ForEach($rule.conditions)` 류 바인딩 요소의 `condition.id`를 `removeAll`(쓰기 접근) 클로저 안에서 재읽기하면 버킷 삭제 즉사(2026-07-02 수정분)와 동형인 Swift 배타적 접근 위반.
- 코드를 읽어 동형 여부 확정. 동형이면 같은 수정(id를 클로저 밖 `let`으로 hoist). 동형이 아니면(값 복사 요소 등) 근거를 기록하고 무수정.
- 배타성 트랩은 러너 프로세스를 죽여 스위트 내 회귀 테스트 불가 — 코드 검증 + 수동 스모크(조건 삭제 버튼 클릭)로 확인.

## 5. 검증·산출물

- **Phase 게이트**: 작업 전후 `swift test` — 기존 382개(XCTest 364+Testing 18) 유지.
- **신규 단위 테스트**: `AppShortcut` 신규 4 case의 기본값이 의도대로인지 + `AppShortcut` 전체 case의 기본 바인딩(modifier+key 조합)끼리 중복이 없는지(하드코딩 단축키와의 충돌은 §2의 수동 검증으로 갈음 — enum 밖이라 자동화 대상 아님). `AppWindowTitleTests` 어서션 갱신.
- **패키징 실행**: `scripts/package_app.sh` → `scripts/make_dmg.sh` → `dist/cmdALL-0.9.0.dmg` 생성 확인(`test_package_app.sh` 포함).
- **수동 스모크**(사용자): DMG 마운트 → /Applications 드래그 → 실행. 확인 항목: 메뉴바·Dock·About·Welcome에 cmdALL 표시, 새 단축키 4개 동작, Shortcuts 탭에 4개 등장·리맵 가능, Tools 탭 상태 표시, 기존 데이터(설정·세션·인덱스) 그대로 열림.
- **격리 해제**: 로컬 생성 DMG·앱에는 quarantine이 붙지 않음(격리는 인터넷 다운로드 시 부여). GitHub 릴리스 등에서 zip/DMG를 받는 경우를 위해 README에 `xattr -dr com.apple.quarantine /Applications/cmdALL.app` 안내를 기록. 앱이 자체적으로 격리를 만지는 코드는 넣지 않는다.

## 6. 문서 마무리

- **README.md**: 앱 이름 cmdALL 반영, 다운로드/설치 섹션(DMG 드래그 설치 + zip 수령 시 xattr 안내), 출처(CmdMD © CMDSPACE, MIT)·라이선스 문구 확인, 테스트 수치 갱신.
- **CLAUDE.md**: Phase 10 완료 기록(현재 상태 섹션), 다음 액션 갱신(남은 별건: LLM-Wiki 스키마, Phase 9 후속 선택지).
- **CmdMD-fork_prd.md**: Phase 10 항목 완료 표기.
- **옵시디언 데일리 로그**: 세션 종료 시 규칙대로 한 줄 추가.

## 7. 구현 순서(계획 단계에서 태스크화)

1. 단축키 4개(+테스트) → 2. Tools 탭 → 3. VaultManagerView:660 → 4. 소스 개명 치환(+테스트 갱신) → 5. 스크립트·CI 개명·버전 → 6. 패키징 실행·DMG 검증 → 7. README·문서. 각 단계 사이 `swift build`/`swift test` 게이트.

## 8. 리스크·한계

- 메뉴바 앱 이름은 실행 중 `CFBundleName`을 따르므로 `swift run` 개발 실행에서는 여전히 CmdMD로 보일 수 있음(패키징된 .app에서만 cmdALL) — 감수.
- `MenuBarExtra` 라벨·창 제목 등 소스 치환분은 `swift run`에서도 cmdALL.
- 업스트림(CmdMD) 머지 시 노출 문자열 충돌 가능성은 기존 cmd-docu 치환 때와 동일 수준 — 감수(겉면 리터럴 치환의 알려진 트레이드오프).
