# Phase 5b — kordoc fill(양식 채우기) 설계

> 작성일 2026-06-30. cmd-docu 티어 2. 기존 Phase 5a(kordoc patch) 패턴을 그대로 따른다.
> 원칙: 비샌드박스 유지 · kordoc은 Process로만 호출 · 원본 불변 · 제안→확인→실행 · Phase 게이트(swift test).

## 1. 목표

한글·오피스 **서식 문서의 빈칸**을 kordoc `fill`로 채워 **새 .hwpx**로 저장한다.
사용자는 `--dry-run`으로 감지된 필드 라벨 목록을 보고 값을 직접 입력한다(수동 값).
원본은 절대 건드리지 않고, 새 uniquified 출력 파일을 만든다.

## 2. kordoc fill 실제 동작 (CLI 검증, v3.5.1)

`npx -y kordoc fill --help` 및 샘플 문서로 검증한 결과:

```
kordoc fill [options] <template>
  -f, --fields <pairs>  key=value 쉼표구분 또는 JSON
  -j, --json <path>     채울 필드 JSON 파일 경로
  -o, --output <path>   출력 경로
  --format <type>       hwpx-preserve(기본)/hwpx/markdown
  --dry-run             채우지 않고 서식 필드 목록만 출력
  --silent              진행 메시지 숨김
```

검증으로 확인한 **중요한 실제 동작**(help와 다른 부분):

1. **`fill`은 `-o`를 무시하고 채운 문서를 stdout으로 스트리밍한다.** (`patch`는 `-o` 파일을 쓰는 것과 다름.)
   → fill 서비스는 stdout을 직접 받아 출력 파일을 우리가 쓴다.
2. **`--dry-run --silent`은 깨끗한 JSON을 stdout으로, 진행 메시지는 stderr로** 낸다.
   JSON 형태: `{ "fields": [ { "label": String, "value": String, "row": Int, "col": Int } ], "confidence": Number }`.
   - `label` = 셀 텍스트(채울 라벨), `value` = kordoc가 추정한 인접 셀 값(빈 서식이면 보통 빈 문자열).
3. 출력 포맷은 기본 **hwpx-preserve** → `.hwp` 입력이어도 **출력은 .hwpx**. (`--format markdown`/`-o .md`도 검증상 무시되고 hwpx로 나옴 → 출력 확장자는 항상 `.hwpx`로 강제한다.)
4. 일부 라벨이 문서와 매칭되지 않으면 **비치명적**으로 stderr에 `⚠️ 매칭 실패: <라벨>`을 내고 종료코드 0으로 끝난다(부분 채움). 채운 개수도 stderr(`N개 필드 채움`)에 나온다.
5. dry-run 감지는 휴리스틱이라 데이터표(채워진 표)도 필드로 잡힌다(샘플에서 144개). 빈 서식이면 빈칸 위주로 잡힌다. 우리는 감지 결과를 그대로 노출한다.

## 3. 아키텍처 (신규 파일 위주, 업스트림 머지 용이)

### 3.1 `Sources/Models/FillField.swift` (신규)
```swift
struct FillField: Decodable, Identifiable {
    let label: String
    let value: String
    let row: Int
    let col: Int
    // 중복 label 구분용 안정 id (label+row+col)
    var id: String { "\(row)-\(col)-\(label)" }
}
struct FillDetection: Decodable {
    let fields: [FillField]
    let confidence: Double?   // 0.0~1.0, 없을 수 있음
}
```

### 3.2 `Sources/Services/KordocFillService.swift` (신규 actor)
KordocWriteService와 동일한 골격(resolveNpxPath 재사용, 120s 타임아웃 폴링, isSameFile 가드).

- `func dryRun(template: URL) async throws -> FillDetection`
  - `npx -y kordoc fill --dry-run --silent <template>`
  - stdout을 임시 파일로 받아(`process.standardOutput = FileHandle(임시.json)`) 종료 후 `FillDetection` 디코드.
  - 실패 시 `KordocFillError.dryRunFailed(stderr)`.

- `func fill(template: URL, values: [String: String], output: URL) async throws -> [String]`(반환=경고 목록)
  - `isSameFile(template, output)`이면 `fillFailed("출력이 원본과 같습니다…")` (원본 보호).
  - `values`를 임시 `.json`(UTF-8, JSONEncoder)로 적는다.
  - `npx -y kordoc fill <template> -j <tmp.json> --silent`
  - **stdout을 임시 `.hwpx` FileHandle로 리다이렉트**(파이프 버퍼 교착 회피). stderr는 Pipe(작음).
  - 종료코드 ≠ 0 → `fillFailed(stderr prefix 500)`.
  - 종료코드 0 → 임시 .hwpx를 `output`으로 이동(이미 있으면 교체 전 제거). stderr에서 `매칭 실패: X` 라인을 파싱해 경고 배열로 반환. 출력 파일 존재 확인.

- `enum KordocFillError { case toolNotFound, dryRunFailed(String), fillFailed(String), timeout, decodeFailed }`

> stdout 리다이렉트 이유: fill의 hwpx 바이너리는 수십~수백 KB. Pipe로 받으며 종료를 기다리면 버퍼가 차서 교착될 수 있다. FileHandle로 직접 받으면 안전(convert/patch가 nullDevice를 쓰는 것과 같은 이유).

### 3.3 `Sources/Models/DocumentKind.swift` (수정)
```swift
static let fillableExtensions: Set<String> = ["hwp", "hwpx"]
static func isFillable(_ url: URL) -> Bool {
    fillableExtensions.contains(url.pathExtension.lowercased())
}
```

## 4. 상태 (AppState 수정)

- `var officeFillSession: OfficeFillRequest?`  — 시트 구동.
- `var officeFillInProgress: Set<UUID>` — dry-run/fill 진행 스피너.
- `let kordocFillService = KordocFillService()` (기존 서비스 인스턴스 옆).

신규 모델(AppState.swift 하단, OfficeSaveRequest 옆):
```swift
struct OfficeFillRequest: Identifiable {
    let id = UUID()
    let tabID: UUID
    let fileURL: URL
    let detection: FillDetection
    var output: URL   // 제안 기본 경로(시드)
}
```

메서드:
- `static func filledOutputURL(for original: URL) -> URL`
  - 같은 폴더, `"<이름> (채움).hwpx"`, uniquified. (확장자는 항상 hwpx.)
- `@MainActor func beginOfficeFill(tabID:, fileURL:)`
  - `isFillable` 가드, 진행중이면 무시. inProgress 추가.
  - Task: `kordocFillService.dryRun` → 성공 시 `officeFillSession = OfficeFillRequest(…, detection, output: filledOutputURL(for: fileURL))`; 실패 시 `errorMessage`. 끝에 inProgress 제거.
- `@MainActor func confirmOfficeFill(tabID:, fileURL:, values:[String:String], output:)`
  - 진행중이면 무시. `officeFillSession = nil`, inProgress 추가.
  - Task: `let warnings = try await kordocFillService.fill(template: fileURL, values: values, output: output)`
    - 성공 → `toastMessage = "양식 채움: \(output.lastPathComponent)" + (warnings 있으면 " · 매칭 실패 \(warnings.count)개")`.
    - 실패 → `errorMessage = kordocFillErrorMessage(error)`.
  - 끝에 inProgress 제거.
- `static func kordocFillErrorMessage(_:) -> String` — toolNotFound(설치 안내, write와 동일 문구)/timeout/fillFailed/dryRunFailed/기본.

## 5. UI

### 5.1 `Sources/Views/OfficeFillView.swift` (신규, 모달 시트)
- `let request: OfficeFillRequest`
- `@State private var values: [String: String]` — 초기값: 감지 필드의 `field.id → field.value`(프리필).
- `@State private var output: URL` — `request.output` 시드.
- 레이아웃:
  - 헤더 "양식 채우기" + 부제 "원본은 그대로 두고 새 .hwpx로 저장합니다."
  - confidence 있으면 "확신도 NN%" 캡션.
  - `ScrollView` + `LazyVStack`: 각 `field`마다 `Text(field.label)`(읽기, 좌) + `TextField("값", text: binding(field.id))`(우). 빈 라벨은 "(빈 라벨)" 표시.
  - 출력 경로 GroupBox + "위치 변경…"(NSSavePanel, .hwpx; 원본 선택 시 uniquify) — OfficeSaveConfirmView와 동일 로직.
  - 하단: 취소 / 채우기(.borderedProminent, defaultAction).
- "채우기" 동작:
  - **변경/입력분만 전송**: `field.value`와 다르거나 비어있지 않은 값만. 최종 전송 맵은 **label 키**(`[field.label: 입력값]`). 중복 label은 마지막 입력이 우선(kordoc 매칭 한계라 그대로 노출).
  - 빈 문자열만 있고 원래도 빈 값이면 제외.
  - `appState.confirmOfficeFill(tabID:, fileURL:, values:, output:)`.
- 폭 ~520, 목록 최대 높이 제한(예: 420) + 스크롤.

### 5.2 진입점
- `OfficeReaderView` 툴바: `isFillable(fileURL) && !isEditing`일 때 "양식 채우기"(systemImage: "square.and.pencil" 등) 버튼 → `appState.beginOfficeFill`. `officeFillInProgress.contains(tabID)`면 ProgressView + 비활성.
- `ContentView`에 `.sheet(item: $state.officeFillSession) { OfficeFillView(request: $0) }` 추가(저장확인 시트 옆).
- 커맨드 팔레트: 기존 office 액션 패턴이 있으면 "양식 채우기" 항목 추가(있을 때만; 없으면 후속).

## 6. 에러·규칙

- 원본 불변: `isSameFile` 가드 + 출력 항상 `.hwpx` + uniquify. 삭제 없음.
- 미설치: write와 동일한 Node/kordoc 설치 안내.
- 타임아웃 120s.
- 매칭 실패는 비치명적 → 토스트로 개수 안내(어느 라벨인지 경고 배열 보유).
- 제안→확인→실행: dry-run 결과를 시트로 제안, 사용자가 값·경로 확인 후 실행.

## 7. 테스트 (Phase 게이트)

Process를 부르는 서비스는 단위테스트하지 않는다(KordocWriteService와 동일). **순수 함수만** 테스트:
- `DocumentKind.isFillable` — hwp/hwpx 참, 대소문자 무시, docx/pdf/md 거짓.
- `AppState.filledOutputURL(for:)` — `(채움).hwpx` 네이밍, 확장자 hwpx 강제, 충돌 시 uniquify.
- `FillDetection` JSON 디코딩 — 검증 샘플 형태(`fields`/`label`/`value`/`row`/`col`/`confidence`) 디코드, confidence 없는 경우도.
- (선택) 전송 맵 빌더를 OfficeFillView에서 순수 헬퍼로 분리해 "변경분만·label 키" 로직 테스트.

게이트: 시작·종료 시 `swift test`로 기존 ~121개 + 신규 통과 확인. (swift test는 정식 Xcode 필요 — 없으면 `swift build`로 최소 검증하고 사용자에게 보고.)

## 8. 범위 밖(후속)

- generate(미지원, 폐기), -f 쉼표 입력(이스케이프 취약 → -j JSON만 사용), 중복 label 정밀 매칭(kordoc 한계), 채운 결과 자동 열기/미리보기.
