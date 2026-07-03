# UI 다듬기 3건 설계 — 탭 일괄 닫기·탭 파일명 말줄임·즐겨찾기 폴더 열기

- 날짜: 2026-07-03
- 상태: 사용자 설계 승인(①② 대화 승인, ③ 문답 확정 — 작업 폴더 전환), 스펙 리뷰 대기
- 선행 결정(브레인스토밍 문답): ①일괄 닫기 더티 처리 = **요약 확인 1회**(핀 탭은 기존 벌크 관례대로 건너뜀) ③즐겨찾기 폴더 클릭 = **작업 폴더 전환**(File > Open Folder와 동일 — 라이브러리 보기·혼합 방식 탈락)

## 0. 목표·비목표

**목표**: 탭이 잔뜩 열렸을 때 한 번에 닫기, 긴 파일명 탭 폭 제한, 즐겨찾기에 등록한 폴더가 실제로 열리게(버그 수정).

**비목표**: 탭 그룹/세로 탭 등 탭 UI 재설계, 즐겨찾기 별칭 편집 UI, 존재하지 않는 즐겨찾기 경로의 정리 UI(현행 무동작 유지).

## 1. Close All Tabs (일괄 닫기)

**`AppState.closeAllTabs()`** 신규:
- 대상 = **핀 고정 제외** 전 탭(기존 `closeOtherTabs`/`closeTabsToRight`가 `!$0.isPinned` 필터를 쓰는 관례와 동일).
- 대상 중 더티 탭(`isTabDirty`)이 있고 `settings.confirmBeforeClosingDirtyTabs`가 켜져 있으면(기본 ON) **요약 NSAlert 1회**: messageText "저장 안 된 변경이 있는 탭이 N개 있습니다." / 버튼 3개 = "모두 저장 후 닫기" · "저장 안 하고 닫기" · "취소"(기존 `closeTabWithConfirmation`의 Save/Don't Save/Cancel 3버튼 패턴 준용).
  - 모두 저장 후 닫기: 더티 탭 각각의 문서를 저장한 뒤 대상 전체 닫기(저장 실패 탭은 닫지 않고 남김 — 유실 방지).
  - 저장 안 하고 닫기: 대상 전체 닫기. / 취소: 아무것도 안 함.
- 설정이 꺼져 있거나 더티 없음: 확인 없이 대상 전체 닫기(개별 x 버튼과 일관).
- 닫기는 기존 `closeTab(_:)` 반복 호출(세션 저장·activeTabId 정리 재사용). 전부 핀이면 no-op.

**진입점 2곳**:
- 탭 우클릭 메뉴(`TabContextMenu`): "Close Tabs to the Right" 아래 "Close All Tabs"(아이콘 `xmark.circle`).
- File 메뉴(`CmdMDApp`): 기존 "Close Tab"(⌘W) 바로 아래 "Close All Tabs" **⌥⌘W**(⌘W의 이웃 변형이라 하드코딩 — 리맵 대상 아님), `tabs.isEmpty`면 비활성(기존 Close Tab과 동일).

## 2. 탭 파일명 말줄임

`TabBarView`의 `Text(tab.displayTitle)`(:60)에 추가: `.truncationMode(.middle)` + `.frame(maxWidth: 180)`.
- maxWidth라 짧은 이름은 현행과 동일 폭, 긴 이름만 180pt에서 가운데 말줄임(파일명 앞부분+확장자 보존 — Finder 관례).
- 탭이 무한정 넓어지던 문제 해소. 다른 요소(핀·별·더티 점·x 버튼)는 불변.

## 3. 즐겨찾기 폴더 열기 (버그 수정)

**근본 원인(코드 추적 확정)**: 파일 트리 우클릭이 폴더에도 "Add to Favorites"를 노출해 폴더 URL이 등록되지만, `FavoritesListView`의 탭 핸들러(SidebarView:573)는 파일 전용 `openDocument(at:)`만 호출 — 디렉터리 분기 부재로 무동작(+mainMode만 reader로 바뀌는 부작용). 행 표시도 파일 가정(`deletingPathExtension`)이라 점(.) 든 폴더명이 잘림.

**수정**:
- `AppState.openFolder(at url: URL)` 신규 — 기존 `openFolder()`(NSOpenPanel)의 성공 분기 본문(AppState.swift:755-762: currentFolder·selectedFolder 설정, files 탭·사이드바 표시, loadFileTree·rebuildNoteIndex·saveSession)을 그대로 추출. `openFolder()`는 패널 확인 후 이를 호출(동작 불변).
- `FavoritesListView` 탭 핸들러: `fileExists` 가드 유지 + **디렉터리면 `openFolder(at:)`, 파일이면 기존 `openDocument(at:, inNewTab: true)`**. 디렉터리 판별은 `FileManager.fileExists(atPath:isDirectory:)`.
- `FavoriteRow` 표시: 디렉터리면 이름을 `url.lastPathComponent` 그대로(확장자 떼지 않음), 아이콘은 `folder.fill`(secondary)로 교체·파일은 현행 `star.fill` 유지. 디렉터리 판별은 행당 1회 FS 조회 — 즐겨찾기는 사용자가 손수 등록하는 소수 목록이라 허용(파일 트리의 "렌더 중 FS 0" 원칙은 수백 행 규모 얘기).
- `FavoriteItem` 모델(Codable)은 불변 — 기존 저장 데이터 그대로 호환.

## 4. 검증

- 단위 테스트(XCTest, `AppState(dataDirectory:)` 임시 디렉터리 주입 관례):
  - `closeAllTabs`: 핀 탭만 남음 / 전부 닫히면 activeTabId nil / 더티 없음(또는 설정 OFF)이면 확인 없이 진행(알림 경로는 NSAlert라 단위 테스트 밖 — 더티+설정 ON 조합은 수동).
  - `openFolder(at:)`: currentFolder·selectedFolder가 해당 URL로, selectedSidebarTab이 .files로 바뀌는지.
- 수동 스모크: 탭 여러 개(핀·더티 섞어) ⌥⌘W·우클릭 Close All(요약 알림 3버튼), 긴 파일명 탭 말줄임 렌더, 즐겨찾기 폴더 클릭→트리 루트 전환·파일 클릭→리더(기존), 점 든 폴더명 표시.
- 전후 `swift test`(현 396개) 유지.

## 5. 리스크·한계

- "모두 저장 후 닫기"의 저장은 탭별 순차 — 오피스 탭 등 저장 개념이 없는 종류는 더티가 될 수 없어(마크다운 편집 버퍼만 더티) 마크다운 저장 경로만 관여.
- 즐겨찾기 폴더가 삭제된 경우 현행처럼 무동작(가드) — 정리 UI는 비목표.
- 작업 폴더 전환은 세션에 저장되므로(saveSession) 재시작 후에도 그 폴더 — File > Open Folder와 동일한 기존 시맨틱.
