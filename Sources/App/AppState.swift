import SwiftUI
import Observation
import UniformTypeIdentifiers
import PDFKit
import AVFoundation
import WebKit

@Observable
final class AppState {
    /// Weak shared reference so the AppDelegate (created independently via
    /// @NSApplicationDelegateAdaptor) can consult app state on quit.
    static weak var shared: AppState?
    private static let launchDefaults = AppLaunchDefaults()

    // Tab System
    var tabs: [EditorTab] = []
    var activeTabId: UUID? {
        didSet { activeTabIdChangeCount += 1 }
    }
    /// 테스트 관찰용 — 배치 복원이 활성 탭을 정확히 1회만 지정하는지 검증(스펙 §3-1).
    private(set) var activeTabIdChangeCount = 0
    /// 외부 열기(더블클릭·드롭)와 세션 복원을 도착 순으로 직렬 처리하는 체인(스펙 §2.3).
    /// 마지막에 처리된 파일이 활성 탭이 된다. 내부 열기(라이브러리·트리 클릭)는 이 큐를 타지 않는다.
    var externalOpenChain: Task<Void, Never>?
    var documents: [UUID: MarkdownDocument] = [:]
    var originalContents: [UUID: String] = [:]
    /// kordoc 오피스 변환 상태(키 = EditorTab.id). office 탭은 MarkdownDocument가 없다.
    var officeStates: [UUID: OfficeState] = [:]
    /// 검색·옴니서치·RAG 등에서 짝꿍 노트를 줄 번호와 함께 열었다가 media 탭으로
    /// 리다이렉트된 경우, 알림 구독자가 없어 소실되던 줄 정보를 탭별로 담아둔다.
    /// MediaReaderView가 노트 로드 후 소비하고 지운다. 비영속(세션 저장 안 함).
    var pendingMediaScrollLines: [UUID: Int] = [:]
    /// media 탭의 AVPlayer(키 = EditorTab.id). 정지 책임은 뷰가 아니라 AppState가 가진다 —
    /// 창 숨김·탭 전환에서 onDisappear가 신뢰 불가함이 실측됐다(2026-07-03, 오디오 35초+ 잔존).
    /// 시맨틱(사용자 결정, 2026-07-03): 탭 전환 = 재생 유지(백그라운드 청취),
    /// 탭 닫기·메인 창 닫기 = 정지.
    var mediaPlayers: [UUID: AVPlayer] = [:]

    // View State
    var viewMode: ViewMode = AppState.launchDefaults.viewMode
    var sidebarVisible: Bool = AppState.launchDefaults.sidebarVisible
    var inspectorVisible: Bool = false
    var selectedSidebarTab: SidebarTab = .files

    // 라이브러리 모드 상태
    /// 메인 에디터 영역 모드(reader = 파일 리더, library = 폴더 라이브러리).
    var mainMode: MainMode = .reader
    /// 라이브러리 뷰가 보여줄 폴더. 기본·리셋값은 currentFolder.
    var selectedFolder: URL? = nil {
        didSet {
            restoreLibraryLayoutForSelectedFolder()
            restoreLibrarySortForSelectedFolder()
            // 히스토리 기록 — 전 진입로(드릴인·상위·사이드바 탭·openFolder·즐겨찾기)의
            // 단일 초크포인트. 새 호출부가 push를 빠뜨리는 태스크 경계 결함을 구조로 방지(스펙 §3.2).
            recordNavigationIfNeeded()
            // 폴더 이동 = 선택 해제(Finder 동일, F1b 스펙 §2). 같은 값 재대입은 무시.
            if oldValue != selectedFolder { clearFileSelection() }
        }
    }
    /// 라이브러리 뷰 레이아웃(grid/list). 폴더별 기억 포함.
    var libraryLayout: LibraryLayout = .grid {
        didSet { persistLibraryLayoutForCurrentFolder(oldValue: oldValue) }
    }
    /// 복원 중 libraryLayout didSet이 재저장하지 않도록 막는 플래그.
    private var isRestoringLayout = false

    /// 라이브러리·트리 정렬(F3). 폴더별 기억 포함 — 기억 없으면 PARA 기본.
    var librarySort: LibrarySort = .default {
        didSet { persistLibrarySortForCurrentFolder(oldValue: oldValue) }
    }
    /// 복원 중 librarySort didSet이 재저장하지 않도록 막는 플래그.
    private var isRestoringSort = false

    // MARK: - 폴더 네비게이션 히스토리 (F3)

    /// 뒤로/앞으로 폴더 히스토리(세션 내 휘발 — SessionState 무변경, 스펙 §3).
    var navHistory = NavigationHistory()
    /// 히스토리 이동·세션 복원·강제 재조준 중 didSet 기록을 막는 플래그(isRestoringLayout 동형).
    private var suppressHistoryRecording = false

    // MARK: - 다중 선택 (F1b)
    /// 라이브러리·트리 공유 선택 집합. URL 키 — FileTreeItem.id는 재빌드마다 새 UUID라 못 쓴다.
    var fileSelection: Set<URL> = []
    /// ⇧범위 선택 앵커(라이브러리 전용).
    var selectionAnchor: URL? = nil
    /// 라이브러리 뷰가 현재 **표시 중인** 항목 순서 — ⌘A·⇧범위의 진실원.
    /// LibraryView.reloadEntries가 갱신. 디스크 재열거 대신 화면에 보이는 목록만 선택하기 위함
    /// (외부에서 추가된, 화면에 없는 파일이 ⌘A로 선택돼 ⌘⌫에 휩쓸리는 것을 방지).
    var libraryOrderedURLs: [URL] = []

    // File System
    var vaults: [Vault] = []
    var drafts: [Draft] = []
    var favorites: [FavoriteItem] = []
    var recentFiles: [URL] = []
    var currentFolder: URL?
    var fileTree: [FileTreeItem] = []
    var expandedFolders: Set<URL> = []

    // Templates & Rules
    var templates: [VaultTemplate] = []
    var routingRules: [RoutingRule] = []

    // Settings
    var settings: AppSettings = AppSettings()

    // Modals & Dialogs
    var showCommandPalette: Bool = false
    var showSendToVault: Bool = false
    var showVaultManager: Bool = false
    var showQuickCapture: Bool = false
    var showOmnisearch: Bool = false
    var showAbout: Bool = false

    // Claude 연동
    var claudePanelVisible: Bool = false
    var claudePanelWidth: CGFloat = 340
    var claudePrompt: String = ""
    var claudeResponse: String?
    var claudeError: String?
    var claudeBusy: Bool = false
    /// 마크다운 에디터의 현재 선택영역 텍스트(없으면 빈 문자열). 질의 컨텍스트 우선순위 1.
    var currentSelectionText: String = ""
    /// PARA 스마트 라우팅 상태.
    var claudeRouteInProgress: Bool = false
    var claudeRouteError: String? = nil
    /// autoRoute 미매칭 → Send 시트가 onAppear에서 자동 제안하도록 켜는 1회성 플래그.
    var autoTriggerClaudeRoute: Bool = false

    // kordoc patch 편집 상태
    var officeEditing: Set<UUID> = []
    var officeEditBuffers: [UUID: String] = [:]
    var officePatchInProgress: Set<UUID> = []
    var officeSaveConfirm: OfficeSaveRequest?
    /// 양식 채우기 시트 구동(키 = 활성 office 탭). nil이면 시트 닫힘.
    var officeFillSession: OfficeFillRequest?
    /// 양식 채우기(dry-run·fill) 진행 중인 탭. 스피너·중복 실행 방지.
    var officeFillInProgress: Set<UUID> = []

    // Update checking (GitHub Releases)
    var updateAvailable: Bool = false
    var latestVersion: String?
    var updateURL: URL?
    var isCheckingForUpdate: Bool = false
    /// Editor/preview width ratio in split view (runtime-only).
    var splitFraction: CGFloat = 0.5
    /// Non-empty while the Send sheet is operating on a batch of files
    /// (e.g. "Send Folder to Vault…") instead of the active document.
    var batchSendURLs: [URL] = []

    // Search
    var folderSearchText: String = ""
    var searchResults: [SearchResult] = []
    var isSearching: Bool = false
    /// 사이드바 폴더 검색 Task(새 검색 시작 시 이전 것을 취소해 낡은 결과 덮어쓰기 방지).
    private var folderSearchTask: Task<Void, Never>?
    /// 파일트리 백그라운드 빌드 Task(연타·연속 호출 시 선행 task 취소).
    private var fileTreeTask: Task<Void, Never>?

    // MARK: 자료에 묻기(RAG)
    var showAskCorpus: Bool = false
    var ragQuestion: String = ""
    var ragAnswer: String? = nil
    var ragSources: [RagSource] = []
    var ragBusy: Bool = false
    var ragMessage: String? = nil   // noEvidence·에러 안내

    // 내용 검색(인덱스) UI 상태
    var showIndexSearch: Bool = false
    var indexSearchText: String = ""
    var indexSearchResults: [IndexHit] = []
    var indexInProgress: Bool = false
    var indexProgress: (done: Int, total: Int)? = nil

    // 폴더 정리(Phase 8) UI 상태
    var showFolderCleanup: Bool = false
    var cleanupMode: CleanupMode?
    var cleanupScheme: CleanupScheme = []
    var cleanupPlan: CleanupPlan?
    var cleanupBusy: Bool = false
    /// 배정 청크 진행 문구("배정 중… (3/10)") — busy 스피너 라벨로 표시. nil이면 기본 문구.
    var cleanupProgress: String? = nil
    var cleanupBatches: [MoveBatch] = []
    var cleanupError: String?

    // MARK: - 파일 작업(F1a) 상태

    /// 파일작업 세대 토큰 — rename/새폴더/휴지통/되돌리기마다 증가.
    /// LibraryView.folderKey가 결합해 같은 폴더 내 변경도 재열거되게 한다.
    var fileOpsGeneration: Int = 0
    /// 파일 작업 기록 시트.
    var showFileOpsHistory: Bool = false
    /// 이름 변경 시트 요청(.sheet(item:)).
    var renameRequest: RenameRequest? = nil
    /// 정보 보기 시트 요청(.sheet(item:)).
    var fileInfoRequest: FileInfoRequest? = nil
    /// F2: 진행 중인 내부 드래그의 페이로드(드래그 시작 시 스냅샷) — 드롭 타깃의 hover
    /// 하이라이트 게이팅(DropGuard.dropDecision)이 **내부 세션에서만** 읽는다. 불변식:
    /// 외부(Finder) 세션은 세션 타입으로 판별해 이 스냅샷을 절대 참조하지 않고(stale이어도
    /// 무해 — C1 수정), 내부 세션은 .onDrag가 매번 새로 채운다. 소비 경로(handleFileDrop·창
    /// 레벨·에디터 가드)가 각기 비우므로 잔존값은 사실상 무해(inert).
    var draggingURLs: [URL] = []

    // Claude 인증 상태(설정 화면)
    var claudeAuthStatus: ClaudeAuthStatus?   // nil = CLI 미설치 또는 미확인
    var claudeAuthChecked: Bool = false       // 한 번이라도 status를 조회했는가
    var claudeAuthBusy: Bool = false

    // Status
    var errorMessage: String?
    var toastMessage: String?

    // Editor caret (for the status bar)
    var cursorLine: Int = 1
    var cursorColumn: Int = 1

    // Completion index
    private(set) var linkableNotes: [VaultNote] = []
    private(set) var knownTags: Set<String> = []
    private var noteIndexTask: Task<Void, Never>?

    // Services
    private let fileService: FileService
    private let exportService: ExportService
    private let kordocService = KordocService()
    private let claudeService = ClaudeService()
    private let kordocWriteService = KordocWriteService()
    private let kordocFillService = KordocFillService()
    private let moveLogStore: MoveLogStore
    /// 파일 작업(F1a) 로그 — Task 6·7·8(시트·정보뷰)이 직접 읽으므로 private 아님.
    let fileOpsLogStore: FileOpsLogStore
    /// 테스트가 FakeClaude 주입 CleanupService로 교체할 수 있게 internal var(실사용 재대입 없음).
    var cleanupService: CleanupService
    private let moveExecutor: MoveExecutor
    private let dataURL: URL

    // 내용 검색(인덱스) — init에서 대입
    private let searchIndex: SearchIndex
    private let searchIndexer: SearchIndexer
    private let folderWatcher = FolderWatcher()
    private let ragService: RagService
    private var fileWatchers: [UUID: DispatchSourceFileSystemObject] = [:]

    // Computed Properties
    var activeTab: EditorTab? {
        guard let id = activeTabId else { return nil }
        return tabs.first { $0.id == id }
    }

    var currentDocument: MarkdownDocument? {
        get {
            guard let tab = activeTab else { return nil }
            return documents[tab.documentId]
        }
        set {
            guard let tab = activeTab, let doc = newValue else { return }
            documents[tab.documentId] = doc
        }
    }

    var originalContent: String {
        get {
            guard let tab = activeTab else { return "" }
            return originalContents[tab.documentId] ?? ""
        }
        set {
            guard let tab = activeTab else { return }
            originalContents[tab.documentId] = newValue
        }
    }

    var isDirty: Bool {
        guard let doc = currentDocument else { return false }
        return doc.fullText != originalContent
    }

    var hasAnyDirtyTabs: Bool {
        tabs.contains { isTabDirty($0) }
    }

    func isTabDirty(_ tab: EditorTab) -> Bool {
        guard let doc = documents[tab.documentId],
              let original = originalContents[tab.documentId] else { return false }
        return doc.fullText != original
    }

    var windowTitle: String {
        if let title = currentDocument?.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        if let url = currentTabFileURL {
            return url.deletingPathExtension().lastPathComponent
        }
        return "cmdALL"
    }

    /// 활성 탭의 종류(없으면 마크다운).
    var currentTabKind: DocumentKind {
        activeTab?.kind ?? .markdown
    }

    /// 활성 탭의 파일 URL(이미지 뷰 배선용).
    var currentTabFileURL: URL? {
        activeTab?.fileURL
    }

    var defaultVault: Vault? {
        if let id = settings.defaultVaultId, let vault = vaults.first(where: { $0.id == id }) {
            return vault
        }
        return vaults.first
    }

    /// Resolves the destination folder for a Send. A vault's own Inbox wins when
    /// it is set; otherwise the app-wide `settings.defaultSendFolder` applies,
    /// falling back to "Inbox" so a send always has a valid target.
    func effectiveSendFolder(for vault: Vault) -> String {
        Self.resolveSendFolder(vaultInbox: vault.inboxPath, globalDefault: settings.defaultSendFolder)
    }

    /// Pure resolution rule (extracted so it is unit-testable without a live
    /// AppState): trimmed vault Inbox wins; else the trimmed global default;
    /// else "Inbox".
    static func resolveSendFolder(vaultInbox: String, globalDefault: String) -> String {
        let inbox = vaultInbox.trimmingCharacters(in: .whitespacesAndNewlines)
        if !inbox.isEmpty { return inbox }
        let global = globalDefault.trimmingCharacters(in: .whitespacesAndNewlines)
        return global.isEmpty ? "Inbox" : global
    }

    /// The active binding for an action — user override or the default.
    func keyBinding(for shortcut: AppShortcut) -> KeyBinding {
        settings.keyBindings[shortcut.rawValue] ?? shortcut.defaultBinding
    }

    /// 편집 저장의 기본 출력 경로: 원본과 같은 폴더에 "<이름> (편집).<확장자>", 충돌 시 uniquify.
    /// 원본은 절대 건드리지 않으므로 항상 새 경로를 돌려준다.
    static func patchedOutputURL(for original: URL) -> URL {
        let ext = original.pathExtension
        let base = original.deletingPathExtension().lastPathComponent
        let folder = original.deletingLastPathComponent()
        let name = ext.isEmpty ? "\(base) (편집)" : "\(base) (편집).\(ext)"
        return folder.appendingPathComponent(name).uniquified()
    }

    /// fill 출력 기본 경로: 원본과 같은 폴더에 "<이름> (채움).hwpx". fill은 항상 hwpx로 내므로 확장자 강제.
    /// 원본은 절대 건드리지 않으므로 항상 새 경로를 돌려준다.
    static func filledOutputURL(for original: URL) -> URL {
        let base = original.deletingPathExtension().lastPathComponent
        let folder = original.deletingLastPathComponent()
        return folder.appendingPathComponent("\(base) (채움).hwpx").uniquified()
    }

    /// 시트에서 편집한 값(키=FillField.id) 중 "변경됐고 비어있지 않은" 것만 label→value로 모은다.
    /// 빈 문자열은 보내지 않는다(빈 덮어쓰기 방지). 중복 label은 마지막이 우선(kordoc 매칭 한계).
    static func fillValuesToSend(fields: [FillField], edited: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for field in fields {
            let v = edited[field.id] ?? field.value
            if v != field.value && !v.isEmpty {
                out[field.label] = v
            }
        }
        return out
    }

    // MARK: - kordoc patch 편집 저장

    /// 변환 마크다운을 편집 버퍼로 복사하고 편집모드로 들어간다(이미 버퍼가 있으면 유지).
    @MainActor
    func beginOfficeEdit(tabID: UUID) {
        guard case .loaded(let result)? = officeStates[tabID] else { return }
        if officeEditBuffers[tabID] == nil {
            officeEditBuffers[tabID] = result.markdown
        }
        officeEditing.insert(tabID)
    }

    /// 편집을 취소하고 버퍼를 버린다.
    @MainActor
    func cancelOfficeEdit(tabID: UUID) {
        officeEditing.remove(tabID)
        officeEditBuffers[tabID] = nil
    }

    /// 기본 출력 경로를 제안해 저장 확인 시트를 띄운다(아직 쓰지 않는다).
    @MainActor
    func requestOfficeSave(tabID: UUID, fileURL: URL) {
        officeSaveConfirm = OfficeSaveRequest(tabID: tabID, fileURL: fileURL,
                                              output: Self.patchedOutputURL(for: fileURL))
    }

    /// 확인된 출력 경로로 kordoc patch를 실행한다. 원본은 건드리지 않는다.
    @MainActor
    func confirmOfficeSave(tabID: UUID, fileURL: URL, output: URL) {
        guard let edited = officeEditBuffers[tabID],
              !officePatchInProgress.contains(tabID) else { return }
        officeSaveConfirm = nil
        officePatchInProgress.insert(tabID)
        Task { @MainActor in
            do {
                try await kordocWriteService.patch(original: fileURL, editedMarkdown: edited, output: output)
                toastMessage = "서식 보존 저장됨: \(output.lastPathComponent)"
                officeEditing.remove(tabID)
                officeEditBuffers[tabID] = nil
            } catch {
                errorMessage = Self.kordocWriteErrorMessage(error)
            }
            officePatchInProgress.remove(tabID)
        }
    }

    static func kordocWriteErrorMessage(_ error: Error) -> String {
        switch error {
        case KordocWriteError.toolNotFound:
            return "kordoc 실행에 필요한 Node(18+)/kordoc을 찾을 수 없습니다. 터미널에서 `npx kordoc` 또는 `npm i -g kordoc` 후 다시 시도하세요."
        case KordocWriteError.timeout:
            return "서식 보존 저장이 너무 오래 걸려 중단했습니다."
        case KordocWriteError.patchFailed(let m):
            return "서식 보존 저장에 실패했습니다.\n\(m)"
        default:
            return "저장에 실패했습니다: \(error.localizedDescription)"
        }
    }

    // MARK: - kordoc fill 양식 채우기

    /// dry-run으로 서식 필드를 조회해 양식 채우기 시트를 띄운다(아직 채우지 않는다).
    @MainActor
    func beginOfficeFill(tabID: UUID, fileURL: URL) {
        guard DocumentKind.isFillable(fileURL),
              !officeFillInProgress.contains(tabID) else { return }
        officeFillInProgress.insert(tabID)
        Task { @MainActor in
            do {
                let detection = try await kordocFillService.dryRun(template: fileURL)
                officeFillSession = OfficeFillRequest(tabID: tabID, fileURL: fileURL,
                                                      detection: detection,
                                                      output: Self.filledOutputURL(for: fileURL))
            } catch {
                errorMessage = Self.kordocFillErrorMessage(error)
            }
            officeFillInProgress.remove(tabID)
        }
    }

    /// 확인된 값·출력 경로로 kordoc fill을 실행한다. 원본은 건드리지 않는다.
    @MainActor
    func confirmOfficeFill(tabID: UUID, fileURL: URL,
                           values: [String: String], output: URL) {
        guard !officeFillInProgress.contains(tabID) else { return }
        officeFillSession = nil
        officeFillInProgress.insert(tabID)
        Task { @MainActor in
            do {
                let warnings = try await kordocFillService.fill(template: fileURL,
                                                                values: values, output: output)
                if warnings.isEmpty {
                    toastMessage = "양식 채움: \(output.lastPathComponent)"
                } else {
                    toastMessage = "양식 채움: \(output.lastPathComponent) · 매칭 실패 \(warnings.count)개"
                }
            } catch {
                errorMessage = Self.kordocFillErrorMessage(error)
            }
            officeFillInProgress.remove(tabID)
        }
    }

    static func kordocFillErrorMessage(_ error: Error) -> String {
        switch error {
        case KordocFillError.toolNotFound:
            return "kordoc 실행에 필요한 Node(18+)/kordoc을 찾을 수 없습니다. 터미널에서 `npx kordoc` 또는 `npm i -g kordoc` 후 다시 시도하세요."
        case KordocFillError.timeout:
            return "양식 채우기가 너무 오래 걸려 중단했습니다."
        case KordocFillError.dryRunFailed(let m):
            return "서식 필드를 읽지 못했습니다.\n\(m)"
        case KordocFillError.fillFailed(let m):
            return "양식 채우기에 실패했습니다.\n\(m)"
        case KordocFillError.decodeFailed:
            return "서식 필드 정보를 해석하지 못했습니다."
        default:
            return "양식 채우기에 실패했습니다: \(error.localizedDescription)"
        }
    }

    // MARK: - Claude 연동

    /// 선택영역은 마크다운 탭에서만 컨텍스트로 쓴다. 다른 종류 탭에선 이전 마크다운
    /// 선택이 새지 않도록 빈 문자열로 친다.
    static func claudeSelection(forKind kind: DocumentKind, selection: String) -> String {
        kind == .markdown ? selection : ""
    }

    /// 질의 컨텍스트를 고른다(순수 함수). 선택영역 > 마크다운 본문 > 오피스 변환 마크다운 > 빈 문자열.
    static func claudeContext(selection: String, markdown: String?, officeMarkdown: String?, mediaNote: String? = nil) -> String {
        let sel = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sel.isEmpty { return sel }
        if let md = markdown, !md.isEmpty { return md }
        if let om = officeMarkdown, !om.isEmpty { return om }
        if let mn = mediaNote, !mn.isEmpty { return mn }
        return ""
    }

    /// ClaudeError를 사용자용 한국어 안내로 변환한다(순수 함수).
    static func claudeErrorMessage(_ error: Error) -> String {
        switch error {
        case ClaudeError.toolNotFound:
            return "claude CLI를 찾을 수 없습니다. 설치 후 터미널에서 `claude`로 로그인하고 다시 시도하세요."
        case ClaudeError.notLoggedIn:
            return "Claude Code 로그인이 필요합니다. 터미널에서 `claude`를 실행해 로그인한 뒤 다시 시도하세요."
        case ClaudeError.creditExhausted:
            return "Claude 사용량(크레딧)이 소진되었습니다. 잠시 후 다시 시도하세요."
        case ClaudeError.timeout:
            return "응답이 너무 오래 걸려 중단했습니다."
        case ClaudeError.failed(let m):
            return "Claude 호출에 실패했습니다: \(m)"
        default:
            return "Claude 호출에 실패했습니다: \(error.localizedDescription)"
        }
    }

    // MARK: - PARA 스마트 라우팅

    /// PARA 볼트와 폴더가 모두 설정됐고 그 볼트가 실제 등록돼 있는가(버튼 활성/가드용).
    func isParaRoutingConfigured() -> Bool {
        guard let id = settings.paraVaultId, !settings.paraFolders.isEmpty else { return false }
        return vaults.contains { $0.id == id }
    }

    /// 설정된 PARA 볼트 객체(없으면 nil).
    var paraVault: Vault? {
        guard let id = settings.paraVaultId else { return nil }
        return vaults.first { $0.id == id }
    }

    /// 본문을 Claude에 보내 PARA 폴더 제안을 받는다. 실패 시 claudeRouteError 세팅 후 nil.
    @MainActor
    func requestClaudeRoute(noteBody: String) async -> RouteSuggestion? {
        guard isParaRoutingConfigured() else {
            claudeRouteError = "설정에서 PARA 볼트와 폴더를 먼저 추가하세요."
            return nil
        }
        claudeRouteError = nil
        claudeRouteInProgress = true
        defer { claudeRouteInProgress = false }
        let dests = settings.paraFolders
        let prompt = RouteHelper.buildRoutePrompt(destinations: dests)
        let context = RouteHelper.buildRouteContext(noteBody: noteBody)
        do {
            let out = try await claudeService.ask(prompt: prompt, context: context)
            if let suggestion = RouteHelper.parseRouteSuggestion(out, destinations: dests) {
                return suggestion
            }
            claudeRouteError = "Claude 제안을 해석하지 못했습니다. 직접 골라 주세요."
            return nil
        } catch {
            claudeRouteError = Self.claudeErrorMessage(error)
            return nil
        }
    }

    /// 현재 문서(또는 선택영역)를 프롬프트와 함께 claude에 보내고 응답을 패널에 표시한다.
    func askClaude() {
        let prompt = claudePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !claudeBusy else { return }

        let officeMarkdown: String? = {
            guard let tab = activeTab, case .loaded(let result)? = officeStates[tab.id] else { return nil }
            return result.markdown
        }()
        let selection = Self.claudeSelection(forKind: currentTabKind, selection: currentSelectionText)
        // media 탭이면 짝꿍 노트 전문을 컨텍스트로(frontmatter 포함 — duration·summary 메타가 질문에 유용).
        // 한계: 편집 중 미저장 버퍼는 뷰 로컬 @State라 디스크 기준(탭 전환 시 자동저장돼 실사용 영향 작음).
        let mediaNote: String? = {
            guard currentTabKind == .media, let url = currentTabFileURL else { return nil }
            return try? String(contentsOf: CompanionNote.noteURL(for: url), encoding: .utf8)
        }()
        let context = Self.claudeContext(selection: selection,
                                         markdown: currentDocument?.content,
                                         officeMarkdown: officeMarkdown,
                                         mediaNote: mediaNote)

        claudeBusy = true
        claudeError = nil
        claudeResponse = nil

        Task { @MainActor in
            do {
                var acc = ""
                let stream = await claudeService.askStream(prompt: prompt, context: context)
                for try await chunk in stream {
                    acc += chunk
                    claudeResponse = acc          // @Observable — 패널이 실시간 갱신
                }
                if acc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    claudeResponse = nil
                    claudeError = "Claude가 빈 응답을 반환했습니다. 다시 시도해 주세요."
                }
            } catch {
                claudeResponse = nil
                claudeError = Self.claudeErrorMessage(error)
            }
            claudeBusy = false
        }
    }

    // MARK: - Claude 응답 저장(본문 삽입·노트로 저장)

    /// 프롬프트를 새 노트 제목으로 다듬는다(순수 함수). 트림 후 개행은 공백으로 바꾸고
    /// 파일명이 과도하게 길어지지 않도록 40자에서 자른다. 빈 프롬프트는 기본 제목으로.
    static func noteTitle(fromPrompt prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !trimmed.isEmpty else { return "Claude 응답" }
        return String(trimmed.prefix(40))
    }

    /// Claude 응답을 현재 노트 본문에 반영한다. 마크다운 탭에서만 동작(다른 종류는 무시).
    /// 에디터가 붙어 있는 reader 모드의 source/split에선 커서 위치 삽입을 알림으로 위임하고,
    /// 그 외엔 본문 끝에 덧붙인다(insertImageMarkdown과 같은 패턴) — 라이브러리 모드는
    /// MarkdownTextEditor가 비마운트라 구독자가 없고, reader의 preview는 에디터가 오프스크린
    /// 마운트 상태지만 커서/포커스가 없어 커서 삽입이 무의미하다.
    func insertClaudeResponseIntoCurrentNote() {
        guard currentTabKind == .markdown, let doc = currentDocument,
              let resp = claudeResponse, !resp.isEmpty else { return }
        let block = "\n\n" + resp + "\n"
        if mainMode == .reader && viewMode != .preview {
            NotificationCenter.default.post(name: .insertClaudeResponse, object: block)
        } else {
            updateContent(doc.content + block)
        }
    }

    /// Claude 응답을 기본 볼트에 새 노트로 저장한다. 원본 문서는 손대지 않는다
    /// (QuickCaptureView.sendToVault와 같은 패턴 — 이쪽은 활성 탭 없이도 동작).
    /// 성공 시 true, 실패(응답 없음·볼트 미설정·sendToVault 오류)면 false를 반환한다 —
    /// 호출부가 이 반환값으로 성공 피드백 표시 여부를 게이트해야 한다(post-hoc claudeError
    /// 검사보다 견고: claudeError는 이전 호출의 stale 값이 남아있을 수 있음).
    @MainActor
    @discardableResult
    func saveClaudeResponseAsNote() async -> Bool {
        guard let resp = claudeResponse, !resp.isEmpty else { return false }
        guard let vault = defaultVault else {
            claudeError = "저장할 볼트가 없습니다. Vault Manager에서 볼트를 먼저 등록해 주세요."
            return false
        }
        let doc = MarkdownDocument(title: Self.noteTitle(fromPrompt: claudePrompt), content: resp, isDraft: true)
        var options = SendOptions()
        options.targetVault = vault
        options.targetFolder = effectiveSendFolder(for: vault)
        options.conflictResolution = settings.conflictResolution
        options.injectFrontmatter = settings.injectFrontmatterByDefault
        do {
            try await sendToVault(document: doc, options: options, quiet: true)
            return true
        } catch {
            claudeError = "노트 저장 실패: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Update checking

    /// Compares two version strings ("v1.4.4" / "1.4.4") component-wise.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "v "))
                .split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Checks the GitHub Releases API for a newer version. Silent checks are
    /// throttled to once every 6h; `userInitiated` checks always run and report.
    func checkForUpdates(userInitiated: Bool = false) {
        guard !isCheckingForUpdate else { return }

        let throttleKey = "lastUpdateCheck"
        if !userInitiated {
            let last = UserDefaults.standard.double(forKey: throttleKey)
            if Date().timeIntervalSince1970 - last < 6 * 3600 { return }
        }

        isCheckingForUpdate = true
        Task { @MainActor in
            defer { isCheckingForUpdate = false }
            let current = AppInfo.version
            do {
                // 포크 저장소의 릴리스를 본다(원본 CmdMD가 아님). 포크에 릴리스가
                // 없으면 업데이트를 권하지 않는다 — 원본 릴리스로 덮어쓰는 사고 방지.
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/learn-slowly/cmd-docu/releases/latest")!)
                request.setValue("cmdALL", forHTTPHeaderField: "User-Agent")
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 10

                let (data, _) = try await URLSession.shared.data(for: request)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    if userInitiated { showToast("Couldn't check for updates") }
                    return
                }

                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: throttleKey)
                latestVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                updateURL = URL(string: (json["html_url"] as? String) ?? "https://github.com/learn-slowly/cmd-docu/releases/latest")

                if Self.isVersion(tag, newerThan: current) {
                    updateAvailable = true
                    if userInitiated { showToast("Update available: \(latestVersion ?? tag)") }
                } else {
                    updateAvailable = false
                    if userInitiated { showToast("You're on the latest version (\(current))") }
                }
            } catch {
                if userInitiated { showToast("Couldn't check for updates") }
            }
        }
    }

    /// Copies the current document's filesystem path to the clipboard (⌥⌘C).
    func copyCurrentFilePath() {
        guard let url = currentDocument?.fileURL else {
            showToast("No file path — save the document first")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        showToast("Path copied")
    }

    /// - Parameter dataDirectory: 모든 영속(settings.json·session.json·drafts 등)을
    ///   둘 데이터 디렉터리. nil이면 기본 app-support/CmdMD를 쓴다(앱 실행 경로).
    ///   테스트는 빈 임시 디렉터리를 주입해 실제 사용자 설정 오염과 세션 복원
    ///   비결정성을 피한다(빈 디렉터리 → 깨끗한 기본값으로 시작, 세션 복원 없음).
    init(dataDirectory: URL? = nil) {
        // 서브프로세스 stdin write가 broken pipe를 만나도 SIGPIPE로 앱이 죽지 않게 한다.
        signal(SIGPIPE, SIG_IGN)

        let appDir: URL
        if let dataDirectory {
            appDir = dataDirectory
        } else if let override = ProcessInfo.processInfo.environment["CMDMD_DATA_DIR"], !override.isEmpty {
            // 데모·스크린샷용 격리 실행 편의 — applicationSupportDirectory는 $HOME 환경변수를
            // 무시하므로(디렉터리 서비스 기반), 실사용 데이터를 건드리지 않는 인스턴스를 띄우려면
            // 이 env로 데이터 디렉터리를 통째로 바꾼다. 일반 실행엔 영향 없음.
            appDir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            appDir = appSupport.appendingPathComponent("CmdMD")
        }
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        dataURL = appDir

        moveLogStore = MoveLogStore(directory: appDir)
        fileOpsLogStore = FileOpsLogStore(directory: appDir)
        cleanupService = CleanupService(claude: claudeService, kordoc: kordocService)
        moveExecutor = MoveExecutor(store: moveLogStore)

        fileService = FileService()
        exportService = ExportService()

        // 인덱스·인덱서 초기화(appDir 재사용, kordocService는 기본값으로 이미 초기화).
        let idx = SearchIndex(dbURL: appDir.appendingPathComponent("searchindex.sqlite"))
        self.searchIndex = idx
        self.searchIndexer = SearchIndexer(index: idx, kordoc: kordocService)
        self.ragService = RagService(index: idx, claude: claudeService, kordoc: kordocService)

        AppState.shared = self

        loadUserData()
        // 검색 인덱스 스키마가 바뀌어 재구성됐으면 등록 폴더를 자동 재인덱싱(1회).
        Task { @MainActor in await self.reindexAfterSchemaMigration() }
        // 등록 폴더 파일 감시 시작(앱 시작 시 1회).
        Task { @MainActor in self.startFolderWatching() }
        restoreSessionIfNeeded()
        rebuildNoteIndex()
        checkForUpdates()   // silent, throttled to once per 6h

        NotificationCenter.default.addObserver(
            forName: .showQuickCapture,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showQuickCapture = true
        }

        NotificationCenter.default.addObserver(
            forName: .openInternalLink,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let url = notification.object as? URL else { return }
            self?.openInternalURL(url)
        }
    }

    // MARK: - Opening Files

    func openFile() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.plainText, UTType(filenameExtension: "md")!,
                               .png, .jpeg, .heic, .webP, .gif, .pdf]
        types += DocumentKind.officeExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        if panel.runModal() == .OK {
            for url in panel.urls {
                openDocument(at: url, inNewTab: true)
            }
        }
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            openFolder(at: url)
        }
    }

    /// 작업 폴더를 지정 URL로 전환한다 — File > Open Folder의 성공 분기와 동일.
    /// 즐겨찾기 폴더 열기 등 패널 없는 진입로가 재사용한다.
    func openFolder(at url: URL) {
        currentFolder = url
        // currentFolder가 실제로 바뀌는 지점에서만 selectedFolder를 리셋한다.
        selectedFolder = url
        selectedSidebarTab = .files
        sidebarVisible = true
        loadFileTree()
        rebuildNoteIndex()
        saveSession()
    }

    /// 사이드바 폴더 행 탭 시 라이브러리 모드로 전환하고 표시 폴더를 설정한다.
    func selectFolderForLibrary(_ url: URL) {
        selectedFolder = url
        mainMode = .library
    }

    // MARK: - 뒤로/앞으로/상위 (F3)

    private func recordNavigationIfNeeded() {
        guard !suppressHistoryRecording, let root = currentFolder else { return }
        navHistory.record(FolderLocation(root: root, display: selectedFolder ?? root))
    }

    /// 히스토리 항목의 두 폴더가 모두 디렉터리로 실존하는가.
    private static func folderExists(_ loc: FolderLocation) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: loc.root.path, isDirectory: &isDir),
              isDir.boolValue else { return false }
        guard FileManager.default.fileExists(atPath: loc.display.path, isDirectory: &isDir),
              isDir.boolValue else { return false }
        return true
    }

    func goBackInHistory() {
        guard let loc = navHistory.goBack(isValid: Self.folderExists) else { return }
        applyHistoryLocation(loc)
    }

    func goForwardInHistory() {
        guard let loc = navHistory.goForward(isValid: Self.folderExists) else { return }
        applyHistoryLocation(loc)
    }

    /// 히스토리 항목 적용 — 루트가 다르면 openFolder 경로 재사용(트리·인덱스·세션까지 복원).
    /// 항상 라이브러리 모드로 전환 — 리더에 남아 화면이 안 바뀌는 함정 방지(스펙 §3.2).
    private func applyHistoryLocation(_ loc: FolderLocation) {
        suppressHistoryRecording = true
        defer { suppressHistoryRecording = false }
        if currentFolder?.standardizedFileURL.path != loc.root.standardizedFileURL.path {
            openFolder(at: loc.root)
        }
        selectedFolder = loc.display
        mainMode = .library
    }

    /// 라이브러리 표시 폴더 기준 상위 이동 가능 여부 — currentFolder(루트) 하한.
    /// (LibraryView에서 이전 — 메뉴·⌘↑가 호출할 수 있게 AppState 소유, 스펙 §6)
    var canGoUpInLibrary: Bool {
        guard let display = selectedFolder ?? currentFolder,
              let root = currentFolder else { return false }
        let displayStd = display.standardizedFileURL.path
        let rootStd = root.standardizedFileURL.path
        // '/' 경계를 포함해 형제 폴더 오감지를 방지한다.
        return displayStd != rootStd && displayStd.hasPrefix(rootStd + "/")
    }

    /// 상위 폴더로(⌘↑·메뉴·경로 바) — 라이브러리 모드에서만(리더의 NSTextView ⌘↑ 표준
    /// 동작 강탈 방지, 스펙 §6), root 하한 클램프.
    func goUpInLibrary() {
        guard mainMode == .library else { return }
        guard let current = selectedFolder ?? currentFolder,
              let root = currentFolder else { return }
        let parent = current.deletingLastPathComponent()
        let parentStd = parent.standardizedFileURL.path
        let rootStd = root.standardizedFileURL.path
        if parentStd == rootStd || parentStd.hasPrefix(rootStd + "/") {
            selectedFolder = parent
        }
    }

    /// View 메뉴 ⌘↑ 전용 진입점 — 텍스트 입력 포커스(시트 필드·사이드바 검색 등)의 캐럿 이동
    /// (macOS 표준 ⌘↑)을 강탈하지 않도록 responder를 확인한다(F1b ⌘C 가드 동형).
    /// 커맨드 팔레트는 goUpInLibrary()를 직접 호출한다 — dismiss 직후 동기 실행이라
    /// firstResponder가 아직 팔레트 필드일 수 있어 이 가드를 태우면 팔레트 진입점이 죽는다.
    func goUpInLibraryFromMenu(firstResponder: NSResponder? = NSApp.keyWindow?.firstResponder) {
        if Self.responderYieldsFileKeys(firstResponder) { return }
        goUpInLibrary()
    }

    /// 표시 중 폴더가 rename/trash로 사라졌으면 가장 가까운 존재 조상으로 재조준
    /// (F1a 트리아지 잔여 — 빈 라이브러리·죽은 경로 바 방지, 스펙 §5).
    /// 사용자 내비게이션이 아니므로 히스토리에 기록하지 않는다. internal = 테스트 접근용.
    func retargetStaleSelectedFolder() {
        guard let sel = selectedFolder else { return }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: sel.path, isDirectory: &isDir), isDir.boolValue { return }
        var candidate = sel.deletingLastPathComponent()
        while candidate.path != "/" {
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
               isDir.boolValue { break }
            candidate = candidate.deletingLastPathComponent()
        }
        suppressHistoryRecording = true
        selectedFolder = candidate
        suppressHistoryRecording = false
    }

    // MARK: - 폴더별 기억 (레이아웃 Phase 8.5-③ · 정렬 F3)

    /// 폴더별 기억(레이아웃·정렬) 딕셔너리 키 — 두 기능이 같은 규약을 쓴다.
    /// 심링크(/var↔/private/var)까지는 해소하지 않는다(libraryLayouts·F1b 관례, 스펙 §2.3).
    static func folderMemoryKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    /// 폴더별 기억의 기준 폴더 — 복원·저장이 같은 폴백을 쓴다(기존 restore가
    /// selectedFolder만 보던 비대칭 해소, 스펙 §2.3).
    private var folderMemoryTarget: URL? { selectedFolder ?? currentFolder }

    /// selectedFolder가 바뀔 때 해당 폴더의 기억된 레이아웃을 복원한다.
    /// 기억이 없으면 현재 레이아웃을 그대로 유지한다.
    private func restoreLibraryLayoutForSelectedFolder() {
        guard let url = folderMemoryTarget else { return }
        guard let remembered = settings.libraryLayouts[Self.folderMemoryKey(for: url)] else { return }
        guard remembered != libraryLayout else { return }
        isRestoringLayout = true
        libraryLayout = remembered
        isRestoringLayout = false
    }

    /// libraryLayout이 바뀔 때 현재 폴더에 레이아웃을 기억하고 즉시 영속한다.
    private func persistLibraryLayoutForCurrentFolder(oldValue: LibraryLayout) {
        guard !isRestoringLayout else { return }
        guard oldValue != libraryLayout else { return }
        guard let url = folderMemoryTarget else { return }
        settings.libraryLayouts[Self.folderMemoryKey(for: url)] = libraryLayout
        saveUserData()
    }

    /// selectedFolder가 바뀔 때 해당 폴더의 기억된 정렬을 복원한다.
    /// 레이아웃과 달리 기억이 없으면 **기본(PARA)으로 복귀**한다 — 정렬은 폴더 속성(스펙 §2.3).
    private func restoreLibrarySortForSelectedFolder() {
        guard let url = folderMemoryTarget else { return }
        let remembered = settings.librarySorts[Self.folderMemoryKey(for: url)] ?? .default
        guard remembered != librarySort else { return }
        isRestoringSort = true
        librarySort = remembered
        isRestoringSort = false
    }

    /// librarySort가 바뀔 때 현재 폴더에 정렬을 기억하고 즉시 영속한다.
    private func persistLibrarySortForCurrentFolder(oldValue: LibrarySort) {
        guard !isRestoringSort else { return }
        guard oldValue != librarySort else { return }
        guard let url = folderMemoryTarget else { return }
        settings.librarySorts[Self.folderMemoryKey(for: url)] = librarySort
        saveUserData()
    }

    /// 임의 폴더의 기억된 정렬(없으면 PARA 기본) — 사이드바 트리가 폴더별 렌더 정렬에 사용(스펙 §2.5).
    func sortForFolder(_ url: URL?) -> LibrarySort {
        guard let url else { return .default }
        return settings.librarySorts[Self.folderMemoryKey(for: url)] ?? .default
    }

    func openInternalURL(_ url: URL) {
        guard url.scheme == "cmdmd" else { return }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if let note = components.queryItems?.first(where: { $0.name == "note" })?.value {
                openLinkedNote(note)
                return
            }

            if let path = components.queryItems?.first(where: { $0.name == "path" })?.value {
                openDocument(at: URL(fileURLWithPath: path))
                return
            }
        }

        if url.host == "open", let path = url.pathComponents.dropFirst().first {
            openDocument(at: URL(fileURLWithPath: path))
        }
    }

    func openLinkedNote(_ rawTarget: String) {
        guard let target = LinkedNoteResolver.normalizedTarget(rawTarget) else { return }

        let roots = linkedNoteSearchRoots()
        let resolver = LinkedNoteResolver(roots: roots)

        if let directURL = resolver.resolveDirectCandidate(named: target) {
            openDocument(at: directURL, inNewTab: true)
            return
        }

        Task {
            let found = await Task.detached(priority: .userInitiated) {
                LinkedNoteResolver(roots: roots).resolve(normalizedTarget: target)
            }.value

            await MainActor.run {
                if let found {
                    self.openDocument(at: found, inNewTab: true)
                } else {
                    self.showToast("Linked note not found: \(target)")
                }
            }
        }
    }

    func openDocument(at url: URL, inNewTab: Bool = false,
                      scrollToLine line: Int? = nil, scrollToPDFPage pdfPage: Int? = nil) {
        mainMode = .reader
        if let existingTab = tabs.first(where: { $0.fileURL == url }) {
            activeTabId = existingTab.id
            if let line {
                // media 탭(짝꿍 노트 리다이렉트 등)은 알림 구독자가 없어 줄 정보가 소실된다.
                // 탭별 pending으로 담아뒀다가 MediaReaderView가 노트 로드 후 소비한다.
                if existingTab.kind == .media {
                    pendingMediaScrollLines[existingTab.id] = line
                } else {
                    scrollEditor(toLine: line)
                }
            }
            if let pdfPage { scrollPDF(toPage: pdfPage, url: url) }
            return
        }

        Task { @MainActor in
            await loadAndActivateDocument(at: url, inNewTab: inNewTab)
            if let line {
                // 로드 분기 — 짝꿍 노트를 열었다가 media로 리다이렉트된 경우도 포함.
                if currentTabKind == .media, let id = activeTabId {
                    pendingMediaScrollLines[id] = line
                } else {
                    scrollEditor(toLine: line)
                }
            }
            if let pdfPage { scrollPDF(toPage: pdfPage, url: url) }
        }
    }

    /// PDF 탭이 떠서 PDFReaderView가 구독을 마칠 시간을 준 뒤 페이지 점프 노티 게시.
    private func scrollPDF(toPage page: Int, url: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: .scrollToPDFPage,
                                            object: PDFPageJump(url: url, page: page))
        }
    }

    /// 외부에서 온 파일 열기 요청을 직렬 큐에 제출한다 — 항상 새 탭(같은 URL은 기존 탭 활성,
    /// 스펙 §2.2). 배치 안 순서 = 열리는 순서, 마지막 파일이 활성.
    func enqueueExternalOpen(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let prev = externalOpenChain
        externalOpenChain = Task { @MainActor in
            await prev?.value
            self.mainMode = .reader
            for url in urls {
                await self.loadAndActivateDocument(at: url, inNewTab: true)
            }
            self.presentMainWindowIfNeeded()
        }
    }

    /// 외부 열기 처리 후 문서 창을 앞으로 가져온다(닫혀 있으면 재표시). 단일 Window 씬은
    /// WindowGroup과 달리 이벤트 전달용 새 창을 만들지 않으므로 필요(스펙 §2.1).
    /// 닫힌(ordered-out) 창은 canBecomeMain이 항상 false라(최종 리뷰 프로브 실측) 그 조건으로는
    /// 못 찾는다 — Window(id: "main")가 NSWindow.identifier에 남기는 접두사로 우선 판별하고,
    /// (보이는 창용) canBecomeMain 폴백을 둔다. headless 테스트에선 NSApp이 nil이라 no-op.
    func presentMainWindowIfNeeded() {
        guard let app = NSApp else { return }
        app.activate(ignoringOtherApps: true)
        let main = app.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true })
            ?? app.windows.first(where: { $0.canBecomeMain })
        main?.makeKeyAndOrderFront(nil)
    }

    /// 새 탭을 추가하거나 활성 탭을 교체(교체 시 옛 탭 자원 정리).
    private func placeTab(_ tab: EditorTab, inNewTab: Bool) {
        if inNewTab || tabs.isEmpty {
            tabs.append(tab)
        } else if let activeIndex = tabs.firstIndex(where: { $0.id == activeTabId }) {
            let oldTab = tabs[activeIndex]
            stopWatchingFile(for: oldTab.id)
            documents.removeValue(forKey: oldTab.documentId)
            originalContents.removeValue(forKey: oldTab.documentId)
            officeStates.removeValue(forKey: oldTab.id)
            // 탭 id는 재사용되지 않으므로 여기서 안 지우면 플레이어가 영구 잔류(누수)한다.
            mediaPlayers.removeValue(forKey: oldTab.id)?.pause()
            tabs[activeIndex] = tab
        } else {
            tabs.append(tab)
        }
        activeTabId = tab.id
    }

    /// 짝꿍 노트 URL이면 대응 미디어 URL을 반환(미디어 실재 시). 아니면 nil.
    /// 검색·위키링크 등 모든 열기 진입로에서 노트 대신 미디어 뷰를 열기 위한 판별원.
    static func mediaRedirectTarget(for url: URL) -> URL? {
        guard let mediaURL = CompanionNote.mediaURL(for: url),
              FileManager.default.fileExists(atPath: mediaURL.path) else { return nil }
        return mediaURL
    }

    @MainActor
    private func loadAndActivateDocument(at url: URL, inNewTab: Bool) async {
        // 짝꿍 노트를 직접 열면 대응 미디어로 리다이렉트 — 노트는 미디어 뷰 안에서 열람·편집한다.
        let target = Self.mediaRedirectTarget(for: url) ?? url
        if let existingTab = tabs.first(where: { $0.fileURL == target }) {
            activeTabId = existingTab.id
            return
        }
        guard let tab = await loadDocument(at: target) else { return }
        placeTab(tab, inNewTab: inNewTab)
        finishOpening(tab)
        saveSession()
    }

    /// 문서를 읽어 "미배치" 탭을 만든다 — placeTab/활성화/saveSession 없음(스펙 §2.4).
    /// 리다이렉트·중복 판별은 호출자 몫. markdown 로드 실패 시 errorMessage 세팅 후 nil.
    @MainActor
    private func loadDocument(at url: URL) async -> EditorTab? {
        // 이미지·PDF·오피스·미디어: MarkdownDocument/워처/originalContents 없이 탭만.
        let kind = DocumentKind(from: url)
        if kind != .markdown {
            return EditorTab(
                fileURL: url,
                title: url.deletingPathExtension().lastPathComponent,
                kind: kind
            )
        }
        do {
            let document = try await fileService.loadDocument(from: url)
            let tab = EditorTab(
                documentId: document.id,
                fileURL: url,
                title: document.displayTitle
            )
            documents[document.id] = document
            originalContents[document.id] = document.fullText
            return tab
        } catch {
            errorMessage = "Failed to open file: \(error.localizedDescription)"
            return nil
        }
    }

    /// 열기 마무리 부수효과(최근 파일·오피스 변환 재시도·파일 워처·태그 수확) —
    /// 단건(loadAndActivateDocument)·배치(restoreSessionIfNeeded) 공용.
    @MainActor
    private func finishOpening(_ tab: EditorTab) {
        guard let url = tab.fileURL else { return }
        addToRecentFiles(url)
        switch tab.kind {
        case .office:
            retryOfficeConversion(tabID: tab.id, fileURL: url)
        case .markdown:
            startWatchingFile(at: url, for: tab.id)
            if let document = documents[tab.documentId] {
                harvestTags(from: document)
            }
        default:
            break
        }
    }

    /// Posts the scroll request after a short delay so a freshly-created editor
    /// (the editor subtree is keyed to document identity) has time to subscribe.
    private func scrollEditor(toLine line: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            NotificationCenter.default.post(name: .scrollToLine, object: line)
            guard let self, self.viewMode != .source else { return }
            // In preview/split, also bring the nearest preceding heading into view.
            if let slug = self.nearestHeadingSlug(before: line) {
                NotificationCenter.default.post(name: .scrollToHeading, object: slug)
            }
        }
    }

    private func nearestHeadingSlug(before line: Int) -> String? {
        Self.nearestHeadingSlug(in: currentDocument?.content ?? "", before: line)
    }

    /// 주어진 줄 앞에서 가장 가까운 헤딩의 slug. 순수 함수 — media 짝꿍 노트처럼
    /// currentDocument가 없는 콘텐츠(문자열만 있는 경우)에서도 쓸 수 있도록 분리.
    static func nearestHeadingSlug(in content: String, before line: Int) -> String? {
        let headings = TOCBuilder.extractHeadings(from: content)
        return headings.last(where: { $0.lineNumber <= line })?.slug
    }

    func linkedNoteSearchRoots() -> [URL] {
        var roots: [URL] = []

        if let documentFolder = currentDocument?.fileURL?.deletingLastPathComponent() {
            roots.append(documentFolder)
        }
        if let currentFolder {
            roots.append(currentFolder)
        }
        roots.append(contentsOf: vaults.map(\.rootPath))

        var seen: Set<String> = []
        return roots.compactMap { root in
            let standardized = root.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return nil }
            return standardized
        }
    }

    // MARK: - Completion Index

    /// Rebuilds the wiki-link completion index off the main thread. Scans the
    /// open folder and registered vault roots for note files (names only — file
    /// contents are never read here).
    func rebuildNoteIndex() {
        noteIndexTask?.cancel()
        var roots: [URL] = []
        if let currentFolder { roots.append(currentFolder) }
        roots.append(contentsOf: vaults.map(\.rootPath))

        guard !roots.isEmpty else {
            linkableNotes = []
            return
        }

        // Hop back through the static ref instead of capturing self across the
        // detached-task boundary (AppState itself is not Sendable).
        noteIndexTask = Task.detached(priority: .utility) {
            let notes = NoteIndexService.buildIndex(roots: roots)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                AppState.shared?.linkableNotes = notes
            }
        }
    }

    private static let inlineTagPattern = try! NSRegularExpression(
        pattern: #"(?<!\S)#([a-zA-Z][a-zA-Z0-9_/-]*)"#
    )

    /// Collects tags from a document (frontmatter + inline #tags) so the tag
    /// completion popup learns vocabulary from everything the user opens.
    func harvestTags(from document: MarkdownDocument) {
        var tags = Set(document.frontmatter?.tags ?? [])
        let ns = document.content as NSString
        Self.inlineTagPattern.enumerateMatches(in: document.content, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            tags.insert(ns.substring(with: match.range(at: 1)))
        }
        knownTags.formUnion(tags)
    }

    // MARK: - File Watching

    private func startWatchingFile(at url: URL, for tabId: UUID) {
        stopWatchingFile(for: tabId)

        let fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.handleExternalFileChange(at: url, event: source.data)
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        source.resume()
        fileWatchers[tabId] = source
    }

    private func stopWatchingFile(for tabId: UUID? = nil) {
        if let tabId = tabId {
            fileWatchers[tabId]?.cancel()
            fileWatchers.removeValue(forKey: tabId)
        } else {
            for watcher in fileWatchers.values {
                watcher.cancel()
            }
            fileWatchers.removeAll()
        }
    }

    private func handleExternalFileChange(at url: URL, event: DispatchSource.FileSystemEvent) {
        guard let tab = tabs.first(where: { $0.fileURL == url }) else { return }

        // Atomic saves (Obsidian, vim, VS Code, and most editors) write to a temp
        // file then rename it over the original. That swaps the inode, so the
        // watched fd — bound to the OLD inode — receives .rename/.delete (never
        // .write) and stops seeing changes. So on rename/delete we re-resolve the
        // path and re-arm the watch on the new file, which is why external edits
        // now reflect instead of going silent.
        if event.contains(.rename) || event.contains(.delete) {
            stopWatchingFile(for: tab.id)   // close the stale descriptor
            // Brief delay so the atomic replacement is fully in place.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, let tab = self.tabs.first(where: { $0.fileURL == url }) else { return }
                if FileManager.default.fileExists(atPath: url.path) {
                    self.startWatchingFile(at: url, for: tab.id)   // re-arm on the new inode
                    self.reloadExternally(url: url, tab: tab)
                } else {
                    self.showToast("File was removed externally")
                    if var doc = self.documents[tab.documentId] {
                        doc.fileURL = nil
                        self.documents[tab.documentId] = doc
                    }
                    if let index = self.tabs.firstIndex(where: { $0.id == tab.id }) {
                        self.tabs[index].fileURL = nil
                    }
                }
            }
            return
        }

        if event.contains(.write) || event.contains(.extend) {
            reloadExternally(url: url, tab: tab)
        }
    }

    /// Reloads a tab's content from disk after an external change, preserving the
    /// document's identity (so scroll/selection survive). Won't clobber unsaved
    /// in-app edits — those get a toast prompting a manual reload instead.
    private func reloadExternally(url: URL, tab: EditorTab) {
        guard !isTabDirty(tab) else {
            showToast("File changed externally — ⌥⌘R to reload")
            return
        }
        Task { @MainActor in
            do {
                let fresh = try await fileService.loadDocument(from: url)
                if var existing = documents[tab.documentId] {
                    existing.content = fresh.content
                    existing.frontmatter = fresh.frontmatter
                    existing.modifiedAt = Date()
                    documents[tab.documentId] = existing
                    originalContents[tab.documentId] = existing.fullText
                } else {
                    documents[tab.documentId] = fresh
                    originalContents[tab.documentId] = fresh.fullText
                }
                showToast("Reloaded from disk")
            } catch {
                errorMessage = "Failed to reload file: \(error.localizedDescription)"
            }
        }
    }

    func reloadCurrentDocument() {
        guard let url = currentDocument?.fileURL else { return }
        Task { @MainActor in
            do {
                let document = try await fileService.loadDocument(from: url)
                currentDocument = document
                originalContent = document.fullText
                showToast("Reloaded")
            } catch {
                errorMessage = "Failed to reload: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - 내용 검색(인덱스)

    /// 등록 폴더 목록 정규화: 중복·기존 하위 추가는 무시하고, 새 상위가 기존 하위를 흡수한다.
    /// 경로는 표준화 후 접두 비교("/a"는 "/a/"로 보고 "/a/sub"를 하위로 본다).
    static func normalizedIndexFolders(_ existing: [String], adding: String) -> [String] {
        func norm(_ p: String) -> String { (p as NSString).standardizingPath }
        let add = norm(adding)
        func isAncestor(_ anc: String, _ desc: String) -> Bool {
            desc == anc || desc.hasPrefix(anc.hasSuffix("/") ? anc : anc + "/")
        }
        // 이미 등록됐거나 기존 항목의 하위면 변화 없음.
        for e in existing where isAncestor(norm(e), add) { return existing }
        // 새 항목의 하위인 기존 항목들을 제거(흡수)하고 새 항목 추가.
        var kept = existing.filter { !isAncestor(add, norm($0)) }
        // standardizingPath는 /private 접두를 떼므로 비교에만 쓰고, 저장은 호출자가 넘긴 canonical 경로 그대로 둔다.
        kept.append(adding)
        return kept
    }

    /// 폴더를 등록 목록에 정규화 추가하고 인덱싱·감시를 시작한다.
    @MainActor
    func registerIndexFolder(_ url: URL) {
        let canonical = SearchIndexer.canonicalURL(url)
        let next = Self.normalizedIndexFolders(settings.indexedFolders, adding: canonical.path)
        guard next != settings.indexedFolders else { return }
        settings.indexedFolders = next
        saveUserData()
        startFolderWatching()
        reindexFolder(canonical.path)
    }

    /// 등록 해제: 목록에서 빼고 인덱스에서 그 하위를 제거한다(디스크 파일은 불변).
    @MainActor
    func unregisterIndexFolder(_ path: String) {
        let canonicalPath = SearchIndexer.canonicalURL(URL(fileURLWithPath: path)).path
        settings.indexedFolders.removeAll { $0 == canonicalPath || $0 == path }
        saveUserData()
        startFolderWatching()
        Task { _ = await searchIndex.removeUnder(folder: canonicalPath) }
    }

    /// 인덱스 DB가 스키마 변경으로 재구성됐으면 등록된 모든 폴더를 재인덱싱한다.
    @MainActor
    private func reindexAfterSchemaMigration() async {
        guard await searchIndex.didResetForSchemaChange else { return }
        for folder in settings.indexedFolders {
            reindexFolder(folder)
        }
    }

    /// 한 폴더를 (재)인덱싱한다(진행률 표시).
    @MainActor
    func reindexFolder(_ path: String) {
        indexInProgress = true
        indexProgress = (0, 0)
        Task {
            await searchIndexer.indexFolder(URL(fileURLWithPath: path)) { done, total in
                Task { @MainActor in self.indexProgress = (done, total) }
            }
            await MainActor.run {
                self.indexInProgress = false
                self.indexProgress = nil
                if !self.indexSearchText.isEmpty {
                    Task { await self.runIndexSearch(query: self.indexSearchText) }
                }
            }
        }
    }

    /// 인덱스 검색 실행(결과를 indexSearchResults에 채운다).
    @MainActor
    func runIndexSearch(query: String) async {
        guard !query.isEmpty else { indexSearchResults = []; return }
        let hits = await searchIndex.search(query: query)
        indexSearchResults = hits
    }

    /// 결과 경로를 연다.
    @MainActor
    func openIndexHit(_ hit: IndexHit) {
        let url = URL(fileURLWithPath: hit.path)
        showIndexSearch = false
        Task { await loadAndActivateDocument(at: url, inNewTab: true) }
    }

    /// 자료에 묻기(RAG) 실행. 근거 없으면 안내, 성공하면 답변+출처를 채운다.
    @MainActor
    func runRagQuery() async {
        let q = ragQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !ragBusy else { return }   // 빈 질문·중복 실행 방지
        ragBusy = true
        defer { ragBusy = false }
        ragAnswer = nil
        ragSources = []
        ragMessage = nil
        let outcome = await ragService.ask(question: q, expandQuery: settings.ragExpandQuery)
        switch outcome {
        case .answered(let a):
            ragAnswer = a.text
            ragSources = a.sources
        case .noEvidence:
            ragMessage = "자료에서 관련 내용을 찾지 못했습니다."
        case .failed(let e):
            ragMessage = AppState.claudeErrorMessage(e)
        }
    }

    /// 근거 출처를 그 위치(줄/페이지)로 연다.
    @MainActor
    func openRagSource(_ source: RagSource) {
        showAskCorpus = false
        let url = URL(fileURLWithPath: source.path)
        switch source.location {
        case .line(let n): openDocument(at: url, inNewTab: true, scrollToLine: n)
        case .page(let p): openDocument(at: url, inNewTab: true, scrollToPDFPage: p)
        case .unknown: openDocument(at: url, inNewTab: true)
        }
    }

    /// 등록 폴더로 파일 감시를 (재)시작한다. 변경 경로를 증분 재인덱싱.
    @MainActor
    func startFolderWatching() {
        folderWatcher.onChangedPaths = { [weak self] paths in
            guard let self else { return }
            Task { @MainActor in
                for p in Set(paths) {
                    await self.searchIndexer.reindex(path: p)
                }
                if !self.indexSearchText.isEmpty {
                    await self.runIndexSearch(query: self.indexSearchText)
                }
            }
        }
        folderWatcher.start(folders: settings.indexedFolders)
    }

    // MARK: - File Tree

    func loadFileTree() {
        guard let folder = currentFolder else { return }
        // selectedFolder를 건드리지 않는다(펼치기·새로고침·이름변경 시 호출될 수 있음).
        // 스냅샷을 메인에서 캡처 후 detached 태스크로 파일시스템 탐색(멈춤 방지).
        let snapshot = expandedFolders
        fileTreeTask?.cancel()
        fileTreeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let tree = AppState.buildFileTree(at: folder, expanded: snapshot)
            guard !Task.isCancelled, let self else { return }
            // 호출 인스턴스에 대입 — static shared 참조 제거(다중 인스턴스·테스트 안전).
            // let 재바인딩으로 Swift 6 'captured var self' 경고 해소.
            await MainActor.run { self.fileTree = tree }
        }
    }

    /// 사이드바 파일 트리에 표시할 파일인지 — 마크다운류(md/markdown/txt) + 이미지 + PDF + 오피스 + 미디어.
    /// 각 확장자 집합은 DocumentKind(단일 판별원)를 따른다.
    static func isListableInFileTree(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown" || ext == "txt"
            || DocumentKind.imageExtensions.contains(ext)
            || DocumentKind.pdfExtensions.contains(ext)
            || DocumentKind.officeExtensions.contains(ext)
            || DocumentKind.mediaExtensions.contains(ext)
    }

    /// 파일트리를 동기·순수하게 빌드한다. `Task.detached`에서 안전히 호출 가능.
    /// - Parameters:
    ///   - url: 탐색 루트 폴더 URL.
    ///   - expanded: 펼친 폴더 스냅샷(메인에서 캡처해 넘긴다).
    ///   - depth: 재귀 깊이(내부용). depth ≥ 10이면 빈 배열 반환.
    static func buildFileTree(at url: URL, expanded: Set<URL>, depth: Int = 0) -> [FileTreeItem] {
        guard depth < 10 else { return [] }

        // F3 정렬용 메타(사용자 결정: 트리도 정렬 적용, 스캔 비용 감수) — 파일 크기·수정일.
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var items: [FileTreeItem] = []
        // 같은 폴더 파일명 → 소문자 키(대소문자 무시) — 짝꿍 노트 숨김·배지 판별용(추가 FS 호출 없음).
        let siblingKeys = CompanionNote.siblingKeys(contents.map { $0.lastPathComponent })

        for itemURL in contents.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            guard let resourceValues = try? itemURL.resourceValues(
                forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else { continue }
            let isDirectory = resourceValues.isDirectory ?? false
            let modifiedAt = resourceValues.contentModificationDate

            if isDirectory {
                let isExpanded = expanded.contains(itemURL)
                let children = isExpanded ? buildFileTree(at: itemURL, expanded: expanded, depth: depth + 1) : []
                items.append(FileTreeItem(url: itemURL, isDirectory: true, isExpanded: isExpanded,
                                          children: children, modifiedAt: modifiedAt))
            } else {
                if isListableInFileTree(itemURL) {
                    // 짝꿍 노트는 목록에서 숨긴다 — 미디어 행이 대표(배지로 존재 표시).
                    if CompanionNote.isCompanionNote(itemURL, siblingKeys: siblingKeys) { continue }
                    let hasNote = CompanionNote.hasCompanionNote(for: itemURL, siblingKeys: siblingKeys)
                    items.append(FileTreeItem(url: itemURL, isDirectory: false, hasCompanionNote: hasNote,
                                              fileSize: resourceValues.fileSize.map(Int64.init),
                                              modifiedAt: modifiedAt))
                }
            }
        }

        return items.sorted { item1, item2 in
            if item1.isDirectory == item2.isDirectory {
                return item1.name.localizedCaseInsensitiveCompare(item2.name) == .orderedAscending
            }
            return item1.isDirectory && !item2.isDirectory
        }
    }

    func toggleFolderExpansion(_ url: URL) {
        if expandedFolders.contains(url) {
            expandedFolders.remove(url)
        } else {
            expandedFolders.insert(url)
        }
        loadFileTree()
    }

    /// 스프링로딩용 펼침 — insert 전용 멱등(스펙 §5). 기존 toggle은 드래그 오버
    /// 재발화 시 도로 접히는 비멱등이라 드래그 경로에 부적합.
    func expandFolder(_ url: URL) {
        guard !expandedFolders.contains(url) else { return }
        expandedFolders.insert(url)
        loadFileTree()
    }

    /// Creates a new, uniquely-named Markdown file in `folder` and opens it.
    /// (The old implementation blindly wrote an empty "Untitled.md", silently
    /// truncating an existing file of that name.)
    func createNewFile(in folder: URL) {
        let target = folder.appendingPathComponent("Untitled.md").uniquified()
        do {
            try "".write(to: target, atomically: true, encoding: .utf8)
            loadFileTree()
            openDocument(at: target, inNewTab: true)
            viewMode = .source
        } catch {
            errorMessage = "Failed to create file: \(error.localizedDescription)"
        }
    }

    /// parent 안에 새 폴더 생성 — FileOperations 위임(기본 이름 "새 폴더"·uniquify).
    /// 새 폴더는 작업 로그에 기록하지 않는다(되돌리기=삭제라 정책 충돌 — 스펙 §2).
    func createNewFolder(in parent: URL) {
        do {
            _ = try FileOperations.createFolder(in: parent)
            fileOpsGeneration += 1
            loadFileTree()
        } catch {
            errorMessage = (error as? FileOperationError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    // MARK: - Saving

    @MainActor
    func saveCurrentDocument() async {
        guard let document = currentDocument else { return }

        if let url = document.fileURL {
            do {
                try await fileService.saveDocument(document, to: url)
                // Update the dirty baseline to exactly what we wrote. We do NOT
                // reassign the whole captured snapshot back into currentDocument:
                // doing so would clobber any keystrokes the user made while the
                // async write was in flight. We only stamp modifiedAt on the
                // live document.
                originalContent = document.fullText
                if var current = currentDocument {
                    current.modifiedAt = Date()
                    currentDocument = current
                }
                showToast("Saved")
            } catch {
                errorMessage = "Failed to save: \(error.localizedDescription)"
            }
        } else {
            await saveDocumentAs()
        }
    }

    @MainActor
    func saveDocumentAs() async {
        guard let document = currentDocument else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md")!]
        panel.nameFieldStringValue = document.displayTitle + ".md"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                var doc = document
                doc.fileURL = url
                doc.modifiedAt = Date()
                let wasDraft = doc.isDraft
                doc.isDraft = false
                try await fileService.saveDocument(doc, to: url)
                currentDocument = doc
                originalContent = doc.fullText
                // Persist the new URL on the tab too, otherwise dedup/watching/
                // breadcrumb logic that keys off tab.fileURL stays out of sync.
                if let tabId = activeTabId, let index = tabs.firstIndex(where: { $0.id == tabId }) {
                    tabs[index].fileURL = url
                    tabs[index].title = doc.displayTitle
                    startWatchingFile(at: url, for: tabId)
                }
                // A draft that became a real file graduates out of the drafts list.
                if wasDraft {
                    drafts.removeAll { $0.id == doc.id }
                    saveUserData()
                }
                addToRecentFiles(url)
                saveSession()
                showToast("Saved")
            } catch {
                errorMessage = "Failed to save: \(error.localizedDescription)"
            }
        }
    }

    /// Saves every file-backed dirty tab. Used by the save-on-quit guard.
    /// Unsaved (no fileURL) tabs are skipped since they'd require a Save panel.
    @MainActor
    func saveAllDirtyTabs() async {
        for tab in tabs {
            guard let doc = documents[tab.documentId],
                  let url = doc.fileURL,
                  isTabDirty(tab) else { continue }
            do {
                try await fileService.saveDocument(doc, to: url)
                originalContents[tab.documentId] = doc.fullText
            } catch {
                errorMessage = "Failed to save \(tab.displayTitle): \(error.localizedDescription)"
            }
        }
    }

    func updateContent(_ newContent: String) {
        currentDocument?.content = newContent
        currentDocument?.modifiedAt = Date()
        if let tabId = activeTabId, let index = tabs.firstIndex(where: { $0.id == tabId }) {
            tabs[index].isDirty = isDirty
        }
        // Keep the backing draft in sync while a draft is being edited so its
        // content survives restarts even without an explicit save.
        if let doc = currentDocument, doc.isDraft,
           let draftIndex = drafts.firstIndex(where: { $0.id == doc.id }) {
            drafts[draftIndex].body = newContent
            drafts[draftIndex].updatedAt = Date()
            scheduleDraftPersist()
        }
        scheduleAutosaveIfNeeded()
    }

    func updateCursorPosition(line: Int, column: Int) {
        if cursorLine != line { cursorLine = line }
        if cursorColumn != column { cursorColumn = column }
    }

    /// Flips a `- [ ]`/`- [x]` marker on the given 1-based source line. Invoked
    /// by checkbox clicks in the preview. The line is re-validated against the
    /// task pattern before mutating so a stale line number can never corrupt
    /// unrelated text.
    func toggleTask(atLine line: Int, checked: Bool) {
        guard let doc = currentDocument else { return }
        var lines = doc.content.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return }

        let target = lines[line - 1]
        let ns = target as NSString
        guard let match = TaskLineQueue.taskLinePattern.firstMatch(
            in: target,
            range: NSRange(location: 0, length: ns.length)
        ) else {
            showToast("Couldn't toggle that task")
            return
        }

        let markerRange = match.range(at: 2)
        lines[line - 1] = ns.replacingCharacters(in: markerRange, with: checked ? "x" : " ")
        updateContent(lines.joined(separator: "\n"))
    }

    // MARK: - Autosave

    private var autosaveWorkItem: DispatchWorkItem?

    /// Debounced autosave: each edit reschedules, so a save fires only after the
    /// user pauses for `autosaveInterval` seconds. Only saves file-backed
    /// documents so it never pops a Save panel unexpectedly.
    private func scheduleAutosaveIfNeeded() {
        guard settings.autosaveEnabled, currentDocument?.fileURL != nil else { return }
        autosaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.settings.autosaveEnabled,
                      self.currentDocument?.fileURL != nil, self.isDirty else { return }
                await self.saveCurrentDocument()
            }
        }
        autosaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(2, settings.autosaveInterval), execute: work)
    }

    // MARK: - Drafts

    private var draftPersistWorkItem: DispatchWorkItem?

    private func scheduleDraftPersist() {
        draftPersistWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.persistDrafts()
        }
        draftPersistWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func createNewDraft() {
        let draft = Draft()
        drafts.insert(draft, at: 0)
        persistDrafts()
        openDraft(draft)
        viewMode = .source
    }

    func addDraft(_ draft: Draft) {
        drafts.insert(draft, at: 0)
        persistDrafts()
    }

    func deleteDraft(_ draft: Draft) {
        drafts.removeAll { $0.id == draft.id }
        // Close any tab editing this draft.
        if let tab = tabs.first(where: { $0.documentId == draft.id }) {
            closeTab(tab)
        }
        persistDrafts()
    }

    func openDraft(_ draft: Draft) {
        if let existingTab = tabs.first(where: { $0.documentId == draft.id }) {
            activeTabId = existingTab.id
            return
        }

        let document = draft.toDocument()
        let tab = EditorTab(
            documentId: document.id,
            title: draft.displayTitle
        )

        documents[document.id] = document
        originalContents[document.id] = document.fullText
        tabs.append(tab)
        activeTabId = tab.id
    }

    func createNewTab() {
        let document = MarkdownDocument()
        let tab = EditorTab(
            documentId: document.id,
            title: "Untitled"
        )

        documents[document.id] = document
        originalContents[document.id] = document.fullText
        tabs.append(tab)
        activeTabId = tab.id
        viewMode = .source
    }

    // MARK: - Tabs

    func closeTab(_ tab: EditorTab) {
        stopWatchingFile(for: tab.id)
        documents.removeValue(forKey: tab.documentId)
        originalContents.removeValue(forKey: tab.documentId)
        officeStates.removeValue(forKey: tab.id)
        pendingMediaScrollLines.removeValue(forKey: tab.id)
        mediaPlayers.removeValue(forKey: tab.id)?.pause()

        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)

        if activeTabId == tab.id {
            if tabs.isEmpty {
                activeTabId = nil
            } else if index < tabs.count {
                activeTabId = tabs[index].id
            } else {
                activeTabId = tabs.last?.id
            }
        }
        saveSession()
    }

    // MARK: - 미디어 플레이어 소유권
    // 시맨틱(사용자 결정, 2026-07-03): 탭 전환 = 재생 유지(백그라운드 청취),
    // 탭 닫기·메인 창 닫기 = 정지.

    /// 미디어 탭의 플레이어를 돌려준다 — 없으면 만들고, url이 바뀌었으면 이전 것을 정지 후 교체.
    /// 같은 탭을 여러 창이 보여줘도 인스턴스는 하나(컨트롤 동기화·고아 불가).
    /// 뷰가 직접 AVPlayer를 만들지 않는 것이 규칙 — 레지스트리 밖 플레이어가 없어야
    /// 탭 닫기·창 닫기 정지가 전수 보장된다(실측 근거, 2026-07-03: 창 2개가
    /// 같은 탭을 보여줄 때 뷰마다 따로 만들면 등록에서 밀려난 고아가 계속 울렸다).
    func mediaPlayer(forTab tabID: UUID, url: URL) -> AVPlayer {
        if let existing = mediaPlayers[tabID],
           (existing.currentItem?.asset as? AVURLAsset)?.url == url {
            return existing
        }
        mediaPlayers[tabID]?.pause()
        let player = AVPlayer(url: url)
        mediaPlayers[tabID] = player
        return player
    }

    /// 모든 미디어 플레이어를 정지한다(창 닫기 — 메뉴바 상주 앱이라 창은 숨겨질 뿐 뷰가 살아 있다).
    func pauseAllMediaPlayers() {
        for player in mediaPlayers.values { player.pause() }
    }

    func closeTabWithConfirmation(_ tab: EditorTab) {
        let alert = NSAlert()
        alert.messageText = "Do you want to save changes?"
        alert.informativeText = "Your changes to \"\(tab.displayTitle)\" will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                await saveCurrentDocument()
                closeTab(tab)
            }
        case .alertSecondButtonReturn:
            closeTab(tab)
        default:
            break
        }
    }

    func closeOtherTabs(except tab: EditorTab) {
        let otherTabs = tabs.filter { $0.id != tab.id && !$0.isPinned }
        for t in otherTabs {
            closeTab(t)
        }
    }

    func closeTabsToRight(of tab: EditorTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let tabsToRight = tabs.suffix(from: index + 1).filter { !$0.isPinned }
        for t in tabsToRight {
            closeTab(t)
        }
    }

    /// 핀 고정을 제외한 모든 탭을 닫는다. 더티 탭이 있고 확인 설정이 켜져 있으면
    /// 요약 알림 1회(모두 저장/저장 안 함/취소 — 개별 확인 연타 대신). 저장에
    /// 실패했거나 저장할 곳이 없는(URL 없는) 더티 탭은 닫지 않고 남긴다.
    func closeAllTabs() {
        let targets = tabs.filter { !$0.isPinned }
        guard !targets.isEmpty else { return }
        let dirtyTargets = targets.filter { isTabDirty($0) }

        guard !dirtyTargets.isEmpty, settings.confirmBeforeClosingDirtyTabs else {
            targets.forEach { closeTab($0) }
            return
        }

        let alert = NSAlert()
        alert.messageText = "저장 안 된 변경이 있는 탭이 \(dirtyTargets.count)개 있습니다."
        alert.informativeText = "저장하지 않고 닫으면 변경 내용이 사라집니다."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "모두 저장 후 닫기")
        alert.addButton(withTitle: "저장 안 하고 닫기")
        alert.addButton(withTitle: "취소")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                var keptTabIds = Set<UUID>()
                for tab in dirtyTargets {
                    // 저장 도중 사용자가 직접 닫은 탭은 건너뛴다(실패 집계 아님).
                    guard tabs.contains(where: { $0.id == tab.id }) else { continue }
                    let saved = await saveDocument(forTabId: tab.id)
                    if !saved { keptTabIds.insert(tab.id) }
                }
                for tab in targets where !keptTabIds.contains(tab.id) {
                    closeTab(tab)
                }
                if !keptTabIds.isEmpty {
                    showToast("저장하지 못한 탭 \(keptTabIds.count)개는 남겨뒀습니다")
                }
            }
        case .alertSecondButtonReturn:
            targets.forEach { closeTab($0) }
        default:
            break
        }
    }

    // MARK: - 파일 작업 (F1a — 이름변경·휴지통·되돌리기)

    /// 짝꿍 노트 동반 대상 — url이 미디어 파일이고 노트(파일명.ext.md)가 실재할 때만.
    static func companionNoteForOperation(mediaURL: URL) -> URL? {
        guard DocumentKind(from: mediaURL) == .media else { return nil }
        let note = CompanionNote.noteURL(for: mediaURL)
        guard FileManager.default.fileExists(atPath: note.path) else { return nil }
        return note
    }

    /// 이름 변경 + 로그 + 열린 탭·짝꿍 노트 정합. 성공 시 새 URL 반환.
    /// 검증 실패는 FileOperationError로 던진다 — 시트가 인라인 표시(전역 errorMessage 미사용).
    @discardableResult
    func performRename(at url: URL, to newName: String) async throws -> URL {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let companion = isDirectory ? nil : Self.companionNoteForOperation(mediaURL: url)

        // 짝꿍 노트가 있으면 rename 전에 편집 중이던 버퍼를 노트에 flush(동기 게시). 안 그러면
        // 옛 뷰의 stale onDisappear가 이미 옮겨진 옛 경로에 써서 고아 노트를 부활시킨다.
        if companion != nil {
            NotificationCenter.default.post(name: .flushMediaCompanionNote, object: url)
        }

        let newURL = try FileOperations.rename(at: url, to: newName)
        await fileOpsLogStore.append(FileOpEntry(kind: .rename, originalURL: url, resultURL: newURL))
        retargetOpenTabs(from: url, to: newURL, isDirectory: isDirectory)

        // 짝꿍 노트 동반 rename(파일명.ext.md 규칙 유지). 실패해도 본체 rename은 유지 — 토스트로 알림.
        if let companion {
            let newNoteName = CompanionNote.noteURL(for: newURL).lastPathComponent
            do {
                let movedNote = try FileOperations.rename(at: companion, to: newNoteName)
                await fileOpsLogStore.append(
                    FileOpEntry(kind: .rename, originalURL: companion, resultURL: movedNote))
                retargetOpenTabs(from: companion, to: movedNote, isDirectory: false)
            } catch {
                showToast("짝꿍 노트 이름은 바꾸지 못했습니다")
            }
        }

        completeFileOperation()
        return newURL
    }

    /// 휴지통 확인 대화상자(제안→확인→실행) — 확인 시 performTrash. NSAlert 관례는 closeAllTabs와 동일.
    func trashWithConfirmation(_ url: URL) {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let companion = isDirectory ? nil : Self.companionNoteForOperation(mediaURL: url)

        let alert = NSAlert()
        alert.messageText = "'\(url.lastPathComponent)'을(를) 휴지통으로 이동할까요?"
        var info = "휴지통에서 복구할 수 있고, '파일 작업 기록'에서 되돌릴 수 있습니다."
        if let companion {
            info = "짝꿍 메모('\(companion.lastPathComponent)')도 함께 이동합니다. " + info
        }
        if hasDirtyTab(under: url, isDirectory: isDirectory) {
            info = "저장 안 된 변경이 있는 탭이 닫힙니다. " + info
        }
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: "휴지통으로 이동")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in await performTrash(at: url) }
    }

    /// 휴지통 이동 + 로그 + 관련 탭 닫기(+짝꿍 노트 동반). 확인은 trashWithConfirmation 몫.
    @discardableResult
    func performTrash(at url: URL) async -> Bool {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let companion = isDirectory ? nil : Self.companionNoteForOperation(mediaURL: url)

        // 짝꿍 노트가 있으면 탭을 닫기 전에 편집 중이던 버퍼를 flush(동기 게시) — 그래야 최신
        // 편집이 노트와 함께 휴지통으로 가고(복구 가능), 탭 닫기 onDisappear의 stale write로
        // 고아 노트가 부활하지 않는다.
        if companion != nil {
            NotificationCenter.default.post(name: .flushMediaCompanionNote, object: url)
        }

        // 대상(하위 포함)·짝꿍 노트를 보는 탭 먼저 닫는다 — 워처·플레이어 정리는 closeTab이 담당.
        closeTabs(under: url, isDirectory: isDirectory)
        if let companion { closeTabs(under: companion, isDirectory: false) }

        do {
            let trashedURL = try FileOperations.trash(at: url)
            await fileOpsLogStore.append(
                FileOpEntry(kind: .trash, originalURL: url, resultURL: trashedURL))
            if let companion {
                do {
                    let trashedNote = try FileOperations.trash(at: companion)
                    await fileOpsLogStore.append(
                        FileOpEntry(kind: .trash, originalURL: companion, resultURL: trashedNote))
                } catch {
                    showToast("짝꿍 노트는 휴지통으로 옮기지 못했습니다")
                }
            }
            completeFileOperation()
            return true
        } catch {
            errorMessage = (error as? FileOperationError)?.errorDescription
                ?? error.localizedDescription
            return false
        }
    }

    /// 파일 작업 되돌리기 — 성공 시 갱신 트리거까지.
    func undoFileOp(_ entry: FileOpEntry) async -> Bool {
        // copy 되돌리기 = 사본이 휴지통으로 감 — 사본을 보던 탭 먼저 닫는다.
        if entry.kind == .copy {
            closeTabs(under: entry.resultURL, isDirectory: isDirectoryPath(entry.resultURL))
        }
        let ok = await fileOpsLogStore.undo(entry)
        if ok {
            // rename/move 되돌리기 = 파일이 resultURL → originalURL로 복귀. 그 경로를 보던
            // 탭도 재조준 — 안 그러면 워처가 "외부에서 삭제됨"으로 오인해 fileURL을 분리하고,
            // 미디어 탭이면 뷰가 사라져도 플레이어가 레지스트리에 남아 재생이 이어진다.
            // trash 되돌리기는 대상 탭이 이미 닫혀 있어(performTrash의 closeTabs) 재조준할 탭이 없다.
            if entry.kind == .rename || entry.kind == .move {
                let isDirectory = (try? entry.originalURL
                    .resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                retargetOpenTabs(from: entry.resultURL, to: entry.originalURL, isDirectory: isDirectory)
            }
            completeFileOperation()
        }
        return ok
    }

    // MARK: - 배치 파일 작업 (F1b)

    /// 배치 요약 확인(제안→확인→실행) — 항목별 모달 N회 금지, 요약 1회(Close All Tabs 관례).
    /// 단건이면 기존 trashWithConfirmation 재사용(문구 동일성).
    func batchTrashWithConfirmation(_ urls: [URL]) {
        let targets = FileSelectionHelper.ancestorsOnly(Set(urls))
        guard !targets.isEmpty else { return }
        if targets.count == 1 { trashWithConfirmation(targets[0]); return }

        let alert = NSAlert()
        alert.messageText = "\(targets.count)개 항목을 휴지통으로 이동할까요?"
        var info = "휴지통에서 복구할 수 있고, '파일 작업 기록'에서 한 번에 되돌릴 수 있습니다."
        if targets.contains(where: { Self.companionNoteForOperation(mediaURL: $0) != nil }) {
            info = "짝꿍 메모도 함께 이동합니다. " + info
        }
        if targets.contains(where: { hasDirtyTab(under: $0, isDirectory: isDirectoryPath($0)) }) {
            info = "저장 안 된 변경이 있는 탭이 닫힙니다. " + info
        }
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: "휴지통으로 이동")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in await self.performBatchTrash(urls: targets) }
    }

    /// 배치 휴지통 — 건별(flush→탭 선닫기→trash→엔트리 수집) 후 로그·갱신은 배치 끝 1회.
    /// 부분 실패는 계속 진행 + 요약. 확인은 batchTrashWithConfirmation 몫.
    @discardableResult
    func performBatchTrash(urls: [URL]) async -> (succeeded: Int, failed: Int) {
        let targets = FileSelectionHelper.ancestorsOnly(Set(urls))
        let batchId = UUID()
        var entries: [FileOpEntry] = []
        var failures: [String] = []
        var handled = Set<String>()   // 동반 처리된 짝꿍 노트(standardized path) — 이중 처리 방지

        for url in targets {
            if handled.contains(url.standardizedFileURL.path) { continue }
            let isDirectory = isDirectoryPath(url)
            let companion = isDirectory ? nil : Self.companionNoteForOperation(mediaURL: url)
            if companion != nil {
                NotificationCenter.default.post(name: .flushMediaCompanionNote, object: url)
            }
            closeTabs(under: url, isDirectory: isDirectory)
            if let companion { closeTabs(under: companion, isDirectory: false) }
            do {
                let trashed = try FileOperations.trash(at: url)
                entries.append(FileOpEntry(kind: .trash, originalURL: url,
                                           resultURL: trashed, batchId: batchId))
                if let companion {
                    do {
                        let trashedNote = try FileOperations.trash(at: companion)
                        entries.append(FileOpEntry(kind: .trash, originalURL: companion,
                                                   resultURL: trashedNote, batchId: batchId))
                        handled.insert(companion.standardizedFileURL.path)
                    } catch {
                        failures.append("짝꿍 노트: \(companion.lastPathComponent)")
                    }
                }
            } catch {
                failures.append(url.lastPathComponent)
            }
        }

        await fileOpsLogStore.appendBatch(entries)
        completeFileOperation()
        reportBatchFailures(failures, action: "휴지통 이동")
        let failedTargets = failures.filter { !$0.hasPrefix("짝꿍 노트") }.count
        return (targets.count - failedTargets, failedTargets)
    }

    /// "폴더로 이동…" — NSOpenPanel(디렉터리 선택)이 확인 역할. urls nil이면 현재 선택.
    func promptBatchMove(urls: [URL]? = nil) {
        let targets = urls ?? Array(fileSelection)
        guard !targets.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "이동"
        panel.message = "\(targets.count)개 항목을 이동할 폴더를 선택하세요"
        panel.directoryURL = selectedFolder ?? currentFolder
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { @MainActor in await self.performBatchMove(urls: targets, to: destination) }
    }

    /// 배치 이동 — 건별(flush→move→탭 재조준→짝꿍 동반) 후 로그·갱신은 배치 끝 1회.
    /// 이미 목적지에 있는 항목은 skip(실패 아님 — 제자리 이동은 uniquify가 복제 개명으로 둔갑).
    @discardableResult
    func performBatchMove(urls: [URL], to destinationDir: URL) async -> (succeeded: Int, failed: Int) {
        let destStd = destinationDir.standardizedFileURL
        let targets = FileSelectionHelper.ancestorsOnly(Set(urls)).filter {
            $0.standardizedFileURL.deletingLastPathComponent().path != destStd.path
        }
        let batchId = UUID()
        var entries: [FileOpEntry] = []
        var failures: [String] = []
        var handled = Set<String>()

        for url in targets {
            if handled.contains(url.standardizedFileURL.path) { continue }
            let isDirectory = isDirectoryPath(url)
            let companion = isDirectory ? nil : Self.companionNoteForOperation(mediaURL: url)
            if companion != nil {
                NotificationCenter.default.post(name: .flushMediaCompanionNote, object: url)
            }
            do {
                let moved = try FileOperations.move(at: url, to: destStd)
                entries.append(FileOpEntry(kind: .move, originalURL: url,
                                           resultURL: moved, batchId: batchId))
                retargetOpenTabs(from: url, to: moved, isDirectory: isDirectory)
                if let companion {
                    do {
                        let finalNote = try relocateCompanion(companion, mode: .move,
                                                              to: destStd, alongside: moved,
                                                              failures: &failures)
                        entries.append(FileOpEntry(kind: .move, originalURL: companion,
                                                   resultURL: finalNote, batchId: batchId))
                        retargetOpenTabs(from: companion, to: finalNote, isDirectory: false)
                        handled.insert(companion.standardizedFileURL.path)
                    } catch {
                        failures.append("짝꿍 노트: \(companion.lastPathComponent)")
                    }
                }
            } catch {
                failures.append(url.lastPathComponent)
            }
        }

        await fileOpsLogStore.appendBatch(entries)
        completeFileOperation()
        reportBatchFailures(failures, action: "이동")
        let failedTargets = failures.filter { !$0.hasPrefix("짝꿍 노트") }.count
        return (targets.count - failedTargets, failedTargets)
    }

    /// 배치 복사 — 원본·탭 불변, 로그만(undo=사본 휴지통). 같은 폴더 복사 = 사본 시맨틱.
    @discardableResult
    func performBatchCopy(urls: [URL], to destinationDir: URL) async -> (succeeded: Int, failed: Int) {
        let destStd = destinationDir.standardizedFileURL
        let targets = FileSelectionHelper.ancestorsOnly(Set(urls))
        let batchId = UUID()
        var entries: [FileOpEntry] = []
        var failures: [String] = []
        var handled = Set<String>()

        for url in targets {
            if handled.contains(url.standardizedFileURL.path) { continue }
            let isDirectory = isDirectoryPath(url)
            let companion = isDirectory ? nil : Self.companionNoteForOperation(mediaURL: url)
            if companion != nil {
                // 편집 중 버퍼를 원본 노트에 flush — 사본에 최신 내용이 담기게.
                NotificationCenter.default.post(name: .flushMediaCompanionNote, object: url)
            }
            do {
                let copied = try FileOperations.copy(at: url, to: destStd)
                entries.append(FileOpEntry(kind: .copy, originalURL: url,
                                           resultURL: copied, batchId: batchId))
                if let companion {
                    do {
                        let finalNote = try relocateCompanion(companion, mode: .copy,
                                                              to: destStd, alongside: copied,
                                                              failures: &failures)
                        entries.append(FileOpEntry(kind: .copy, originalURL: companion,
                                                   resultURL: finalNote, batchId: batchId))
                        handled.insert(companion.standardizedFileURL.path)
                    } catch {
                        failures.append("짝꿍 노트: \(companion.lastPathComponent)")
                    }
                }
            } catch {
                failures.append(url.lastPathComponent)
            }
        }

        await fileOpsLogStore.appendBatch(entries)
        completeFileOperation()
        reportBatchFailures(failures, action: "복사")
        let failedTargets = failures.filter { !$0.hasPrefix("짝꿍 노트") }.count
        return (targets.count - failedTargets, failedTargets)
    }

    private enum CompanionRelocateMode { case move, copy }

    /// 짝꿍 노트 동반 이동/복사 — 결과 이름은 본체 결과에서 파생(파일명.ext.md 규칙 유지).
    /// 본체가 uniquify로 개명됐으면(노래.mp3→노래 (1).mp3) 노트도 "노래 (1).mp3.md"로 맞춘다.
    /// 파생 이름이 점유돼 있으면 노트만 uniquify하고 연결 끊김을 failures에 기록(스펙 §4.3).
    private func relocateCompanion(_ companion: URL, mode: CompanionRelocateMode,
                                   to destinationDir: URL, alongside movedBody: URL,
                                   failures: inout [String]) throws -> URL {
        let relocated: URL
        switch mode {
        case .move: relocated = try FileOperations.move(at: companion, to: destinationDir)
        case .copy: relocated = try FileOperations.copy(at: companion, to: destinationDir)
        }
        let desiredName = CompanionNote.noteURL(for: movedBody).lastPathComponent
        guard relocated.lastPathComponent != desiredName else { return relocated }
        if let aligned = try? FileOperations.rename(at: relocated, to: desiredName) {
            return aligned
        }
        failures.append("짝꿍 노트 이름 정렬: \(relocated.lastPathComponent)")
        return relocated
    }

    /// 부분 실패 요약 — errorMessage는 단일 문자열이라 건별 나열 대신 개수+예시.
    private func reportBatchFailures(_ failures: [String], action: String) {
        guard !failures.isEmpty else { return }
        let sample = failures.prefix(3).joined(separator: ", ")
        errorMessage = "\(action) 중 \(failures.count)건을 처리하지 못했습니다: \(sample)"
    }

    /// 배치 되돌리기 — copy 사본 탭 선닫기 → 스토어 역순 undo → move/rename 성공분 탭 재조준.
    func undoFileOpBatch(batchId: UUID) async -> Bool {
        let entries = await fileOpsLogStore.load().filter { $0.batchId == batchId }
        for entry in entries where entry.kind == .copy {
            closeTabs(under: entry.resultURL, isDirectory: isDirectoryPath(entry.resultURL))
        }
        let result = await fileOpsLogStore.undoBatch(batchId: batchId)
        for entry in result.succeeded where entry.kind == .rename || entry.kind == .move {
            // 복원 = resultURL → originalURL. 그 경로를 보던 탭 재조준(F1a undo 함정의 동형 방지).
            retargetOpenTabs(from: entry.resultURL, to: entry.originalURL,
                             isDirectory: isDirectoryPath(entry.originalURL))
        }
        completeFileOperation()
        return result.failed.isEmpty
    }

    /// 현재 컨텍스트의 정보 보기 대상 — 리더=활성 탭 파일(없으면 무동작),
    /// 라이브러리=표시 중 폴더(selectedFolder ?? currentFolder). 스펙 §7.2.
    func showFileInfoForCurrentContext() {
        switch mainMode {
        case .reader:
            guard let url = activeTab?.fileURL else { return }
            fileInfoRequest = FileInfoRequest(url: url)
        case .library:
            guard let folder = selectedFolder ?? currentFolder else { return }
            fileInfoRequest = FileInfoRequest(url: folder)
        }
    }

    // MARK: - 페이스트보드·키 액션 (F1b)

    /// 선택 항목을 페이스트보드로(⌘C) — Finder에 붙여넣기 가능. 빈 선택이면 false(이벤트 미소비).
    @discardableResult
    func copySelectionToPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        guard !fileSelection.isEmpty else { return false }
        FilePasteboard.write(FileSelectionHelper.ancestorsOnly(fileSelection), to: pasteboard)
        return true
    }

    /// 페이스트보드 파일을 폴더에 복사/이동 실행(⌘V/⌥⌘V) — folder nil이면 표시 폴더.
    func pasteFromPasteboard(move: Bool, into folder: URL? = nil,
                             pasteboard: NSPasteboard = .general) {
        guard let destination = folder ?? selectedFolder ?? currentFolder else { return }
        let urls = FilePasteboard.readFileURLs(from: pasteboard)
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            if move {
                await self.performBatchMove(urls: urls, to: destination)
            } else {
                await self.performBatchCopy(urls: urls, to: destination)
            }
        }
    }

    // MARK: - 드래그&드롭 (F2)

    /// 드롭 수행 — providers에서 URL 수집 후 배치 1회 호출(이동 기본·⌥=복사).
    /// 무확인 실행(⌘V 선례 — 드롭 제스처가 곧 확인, 배치 undo 있음). 반환 = 수락 여부.
    /// ⚠️ F1b 붙여넣기(⌘V=복사·⌥⌘V=이동)와 ⌥ 의미가 역방향 — 둘 다 Finder 관례 준수(스펙 §0).
    @discardableResult
    func handleFileDrop(_ providers: [NSItemProvider], into destination: URL,
                        pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> Bool {
        // ⌥는 드롭 콜백 진입 직후 동기로 판독(비동기 수집 후엔 이미 떼었을 수 있음).
        let isCopy = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option)
        if DragPayload.isInternalDrag(pasteboard: pasteboard) {
            // 내부 드래그 — 페이로드는 드래그 시작 스냅샷(draggingURLs)이 유일한 채널.
            // 실측(2층): ①SwiftUI .onDrag 전사가 드롭 쪽 provider 재구성에서 커스텀 UTType을
            // 누락하고, ②드래그 파스테보드에 실려도 커스텀 타입 데이터 promise는 이행되지 않는다
            // (0바이트). 판별은 파스테보드의 타입 '선언'으로 하되, 전체 목록은 앱 내부 상태로 나른다.
            // 외부 세션은 선언이 없어 이 분기에 못 들어옴 → stale 스냅샷 미참조(C1 불변식 유지).
            completeFileDrop(draggingURLs, into: destination, isCopy: isCopy)
            return true
        }
        Self.collectDropURLs(providers) { [weak self] urls in
            self?.completeFileDrop(urls, into: destination, isCopy: isCopy)
        }
        return true
    }

    /// 드롭 다운스트림 공유 — 내부(동기 스냅샷)·외부(비동기 수집) 공통: draggingURLs 비우기 →
    /// 2차 필터(자기/하위 제거) → 배치 1회(이동/⌥복사) → 전량 same-parent skip 시 토스트.
    private func completeFileDrop(_ urls: [URL], into destination: URL, isCopy: Bool) {
        Task { @MainActor in
            self.draggingURLs = []
            // 2차 방어 — 뷰 사전 차단(1차)이 못 거른 경로(배경 타깃 등) 대비.
            let targets = urls.filter { DropGuard.canAccept(source: $0, destination: destination) }
            guard !targets.isEmpty else { return }
            if isCopy {
                await self.performBatchCopy(urls: targets, to: destination)
            } else {
                let result = await self.performBatchMove(urls: targets, to: destination)
                // 전량 same-parent skip → (0,0): 무동작 오인 방지 토스트(이동만 — 복사는
                // 같은 폴더도 uniquify 사본 생성이 정상, 스펙 §3).
                if result.succeeded == 0 && result.failed == 0 {
                    self.showToast("이동할 항목 없음 — 이미 이 폴더에 있습니다")
                }
            }
        }
    }

    /// providers → fileURL 수집(외부 Finder 드래그 전용). 내부 드래그는 handleFileDrop이
    /// draggingURLs 스냅샷으로 직접 처리해 이 경로에 오지 않는다(파스테보드/​provider 어느 쪽도
    /// 커스텀 페이로드 데이터를 나르지 못하는 실측 — DragPayload.isInternalDrag 주석 참조).
    /// 반환 순서 = provider 순서(인덱스 슬롯 — loadItem 콜백은 임의 스레드·임의 순서, 스펙 §2.3).
    static func collectDropURLs(_ providers: [NSItemProvider],
                                completion: @escaping ([URL]) -> Void) {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier("public.file-url")
        }
        var slots = [URL?](repeating: nil, count: fileProviders.count)
        let lock = NSLock()   // loadItem 콜백은 임의 스레드 — 슬롯 쓰기 직렬화
        let group = DispatchGroup()
        for (index, provider) in fileProviders.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    lock.lock(); slots[index] = url; lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(slots.compactMap { $0 }) }
    }

    /// 리더·창 레벨 외부(Finder) 파일 드롭 = 열기. 직렬 큐로 수렴해 더블클릭과 시맨틱 통일 —
    /// 항상 새 탭, 다중은 provider 순서대로 열고 마지막 활성(스펙 §2.3).
    /// 개정(2026-07-06): F2의 "단일 드롭 = 활성 탭 교체"를 폐기 — 드롭 한 번에 작업 중이던
    /// 탭이 교체당하는 놀람 제거, 더블클릭·드롭 시맨틱 일치.
    func openExternalFileDrops(_ providers: [NSItemProvider]) {
        Self.collectDropURLs(providers) { [weak self] urls in
            self?.enqueueExternalOpen(urls)
        }
    }

    /// 라이브러리가 표시 중인 목록 전체 선택(⌘A) — 디스크 재열거가 아니라 화면에 보이는
    /// libraryOrderedURLs만 대상으로 한다(외부에서 추가된 미표시 파일이 선택에 새는 것 방지).
    func selectAllInLibrary() {
        fileSelection = Set(libraryOrderedURLs)
        selectionAnchor = libraryOrderedURLs.first
    }

    /// 키 이벤트의 문자 판독(입력 소스 독립) — 두벌식 한글 등 비ASCII 입력 소스에서는
    /// charactersIgnoringModifiers가 자모("ㅁ"/"ㅊ"/"ㅍ")로 와 문자 매칭이 전멸한다(실측).
    /// ASCII 단일 문자면 그대로 쓰고, 아니면 Cmd 적용 문자(입력기 우회 ASCII·⌥도 벗김)로
    /// 폴백한다. 둘 다 비ASCII면 원값 반환(비교 실패로 자연 무시).
    static func keyLetter(ignoringModifiers: String?, commandApplied: String?) -> String {
        let ign = (ignoringModifiers ?? "").lowercased()
        if ign.count == 1, let s = ign.unicodeScalars.first, s.isASCII { return ign }
        let cmd = (commandApplied ?? "").lowercased()
        if cmd.count == 1, let s = cmd.unicodeScalars.first, s.isASCII { return cmd }
        return ign
    }

    /// 파일 키(⌘C 등)를 양보해야 하는 응답자인가 — 자체 복사/편집을 가진 뷰들.
    /// NSText(에디터·필드 에디터) 외에 WKWebView(미리보기)·PDFView(PDF 리더)도 자체 copy 구현.
    /// 뷰 계층 상위에 있을 수 있어(웹뷰 내부 서브뷰가 firstResponder) 조상 체인을 걷는다.
    static func responderYieldsFileKeys(_ responder: NSResponder?) -> Bool {
        if responder is NSText { return true }   // NSTextView 포함(필드 에디터도)
        var view = responder as? NSView
        while let v = view {
            if v is WKWebView || v is PDFView { return true }
            view = v.superview
        }
        return false
    }

    /// F1b 파일 키 라우팅 — 로컬 NSEvent 모니터에서 호출. true = 소비(모니터가 nil 반환).
    /// 가드(스펙 §5): 메인 창(시트 아님) + firstResponder가 자체 복사/편집 뷰가 아님.
    func handleFileOpsKeyEvent(_ event: NSEvent) -> Bool {
        guard let window = NSApp.keyWindow, window.canBecomeMain else { return false }
        // NSText 외에 미리보기(WKWebView)·PDF(PDFView)도 자체 copy를 양보한다.
        if Self.responderYieldsFileKeys(window.firstResponder) { return false }

        // deviceIndependentFlagsMask는 capsLock 비트를 포함 — CapsLock ON이면 정확 일치가
        // 전부 실패한다. 우리가 관심 있는 수식키만 교집합으로 추린다.
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        // 한글 입력 소스에서도 물리 키를 읽도록 입력 소스 독립 판독(keyLetter) 사용.
        let key = Self.keyLetter(ignoringModifiers: event.charactersIgnoringModifiers,
                                 commandApplied: event.characters(byApplyingModifiers: .command))

        // ⎋ 선택 해제
        if event.keyCode == 53, flags.isEmpty, !fileSelection.isEmpty {
            clearFileSelection()
            return true
        }
        // ⌘⌫ 휴지통(요약 확인 경유) — 이벤트 모니터 콜백 안에서 중첩 모달 루프(runModal)를
        // 돌리지 않도록 Task로 이연한다. 이벤트는 즉시 소비.
        if event.keyCode == 51, flags == .command, !fileSelection.isEmpty {
            let urls = Array(fileSelection)
            Task { @MainActor in self.batchTrashWithConfirmation(urls) }
            return true
        }
        switch (key, flags) {
        case ("c", [.command]):
            return copySelectionToPasteboard()
        case ("v", [.command]):
            guard mainMode == .library, !FilePasteboard.readFileURLs().isEmpty else { return false }
            pasteFromPasteboard(move: false)
            return true
        case ("v", [.command, .option]):
            guard mainMode == .library, !FilePasteboard.readFileURLs().isEmpty else { return false }
            pasteFromPasteboard(move: true)
            return true
        case ("a", [.command]):
            guard mainMode == .library else { return false }
            selectAllInLibrary()
            return true
        default:
            return false
        }
    }

    // MARK: - 다중 선택 (F1b)

    /// 라이브러리 클릭 한 번 처리 — 리졸버(순수)에 위임. ordered = 화면 표시 순서(entries).
    func handleFileClick(_ url: URL, modifier: SelectionModifier, ordered: [URL]) {
        let result = FileSelectionHelper.resolve(current: fileSelection, anchor: selectionAnchor,
                                                 clicked: url, modifier: modifier, ordered: ordered)
        fileSelection = result.selection
        selectionAnchor = result.anchor
    }

    /// 트리 ⌘클릭 토글 — 범위 선택이 없어 ordered 불필요.
    func toggleFileSelection(_ url: URL) {
        handleFileClick(url, modifier: .command, ordered: [])
    }

    func clearFileSelection() {
        fileSelection = []
        selectionAnchor = nil
    }

    /// 파일 작업 후 사라진 URL을 선택에서 제거 — 유령 선택에 배치가 실행되는 것을 방지.
    private func pruneFileSelection() {
        fileSelection = fileSelection.filter { FileManager.default.fileExists(atPath: $0.path) }
        if let anchor = selectionAnchor, !FileManager.default.fileExists(atPath: anchor.path) {
            selectionAnchor = nil
        }
    }

    /// 파일 작업 성공 후 공통 갱신 — 세대 토큰·트리·세션·선택 prune·표시 폴더/히스토리 정합(F3).
    private func completeFileOperation() {
        fileOpsGeneration += 1
        pruneFileSelection()
        retargetStaleSelectedFolder()
        navHistory.prune(isValid: Self.folderExists)
        loadFileTree()
        saveSession()
    }

    /// rename된 경로를 보는 열린 탭들의 URL·제목·문서·파일워처를 새 경로로 옮긴다.
    /// 폴더 rename이면 하위 경로 탭 전부 — '/' 경계 prefix 비교(형제 폴더 오매칭 방지).
    private func retargetOpenTabs(from oldURL: URL, to newURL: URL, isDirectory: Bool) {
        let oldPath = oldURL.standardizedFileURL.path
        for index in tabs.indices {
            guard let tabURL = tabs[index].fileURL else { continue }
            let tabPath = tabURL.standardizedFileURL.path
            let target: URL?
            if tabPath == oldPath {
                target = newURL
            } else if isDirectory, tabPath.hasPrefix(oldPath + "/") {
                target = newURL.appendingPathComponent(String(tabPath.dropFirst(oldPath.count + 1)))
            } else {
                target = nil
            }
            guard let target else { continue }
            let tab = tabs[index]
            tabs[index].fileURL = target
            // title 동기화 — EditorTab.displayTitle이 fileURL을 우선해 실제 표시엔
            // 영향이 적지만, 탭 생성부 관례(비마크다운 분기·saveDocumentAs)를 따라
            // 확장자 없는 이름으로 맞춘다.
            tabs[index].title = target.deletingPathExtension().lastPathComponent
            documents[tab.documentId]?.fileURL = target
            // 파일 워처 재장전 — 옛 경로 디스크립터를 닫고 새 경로로. 단, 원래 워처가 있던
            // 탭(마크다운)만 다시 건다. 비마크다운(이미지/PDF/오피스/미디어)은 애초에 워처가
            // 없으므로(loadAndActivateDocument), 여기서 새로 만들면 외부 도구가 그 파일을
            // 쓸 때 바이너리를 UTF-8로 읽다 스퓨리어스 "Failed to reload file" 에러가 난다.
            let hadWatcher = fileWatchers[tab.id] != nil
            stopWatchingFile(for: tab.id)
            if hadWatcher, !isDirectoryPath(target) {
                startWatchingFile(at: target, for: tab.id)
            }
        }
    }

    /// url(폴더면 하위 포함)을 보는 열린 탭들을 닫는다.
    private func closeTabs(under url: URL, isDirectory: Bool) {
        let basePath = url.standardizedFileURL.path
        let affected = tabs.filter { tab in
            guard let tabURL = tab.fileURL else { return false }
            let tabPath = tabURL.standardizedFileURL.path
            return tabPath == basePath || (isDirectory && tabPath.hasPrefix(basePath + "/"))
        }
        affected.forEach { closeTab($0) }
    }

    /// url 하위(또는 자신)에 더티 탭이 있는가 — 휴지통 확인 문구용.
    private func hasDirtyTab(under url: URL, isDirectory: Bool) -> Bool {
        let basePath = url.standardizedFileURL.path
        return tabs.contains { tab in
            guard let tabURL = tab.fileURL else { return false }
            let tabPath = tabURL.standardizedFileURL.path
            let affected = tabPath == basePath || (isDirectory && tabPath.hasPrefix(basePath + "/"))
            return affected && isTabDirty(tab)
        }
    }

    /// 경로가 디렉터리인가(워처 재장전 가드용 — 탭은 파일만 보지만 방어적으로).
    private func isDirectoryPath(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// 특정 탭의 문서를 디스크에 저장한다(파일 URL 있는 문서만 — 없으면 false).
    /// 성공 시 그 탭의 더티 기준선(originalContents)을 "디스크에 쓴 내용"으로 갱신한다.
    /// 스냅샷을 documents에 통째로 되돌려쓰지 않는다 — 비동기 쓰기 중 입력된
    /// 키스트로크를 덮어쓰는 레이스 방지(saveCurrentDocument와 동일 규칙).
    @MainActor
    private func saveDocument(forTabId tabId: UUID) async -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }),
              let document = documents[tab.documentId],
              let url = document.fileURL else { return false }
        do {
            try await fileService.saveDocument(document, to: url)
            originalContents[tab.documentId] = document.fullText
            if var live = documents[tab.documentId] {
                live.modifiedAt = Date()
                documents[tab.documentId] = live
            }
            return true
        } catch {
            return false
        }
    }

    func toggleTabPin(_ tab: EditorTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs[index].isPinned.toggle()

        if tabs[index].isPinned {
            let pinnedCount = tabs.prefix(index).filter { $0.isPinned }.count
            let movedTab = tabs.remove(at: index)
            tabs.insert(movedTab, at: pinnedCount)
        }
    }

    func moveTab(id: UUID, before targetId: UUID) {
        guard id != targetId,
              let sourceIndex = tabs.firstIndex(where: { $0.id == id }),
              let targetIndex = tabs.firstIndex(where: { $0.id == targetId }) else { return }
        let tab = tabs.remove(at: sourceIndex)
        let insertIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        tabs.insert(tab, at: insertIndex)
    }

    func selectNextTab() {
        guard !tabs.isEmpty, let currentId = activeTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
        activeTabId = tabs[nextIndex].id
    }

    func selectPreviousTab() {
        guard !tabs.isEmpty, let currentId = activeTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let prevIndex = currentIndex > 0 ? currentIndex - 1 : tabs.count - 1
        activeTabId = tabs[prevIndex].id
    }

    func selectTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        activeTabId = tabs[index].id
    }

    // MARK: - Export

    func exportAsHTML() {
        guard let document = currentDocument else { return }
        exportService.saveHTML(document: document, options: renderOptions())
    }

    func exportAsPDF() {
        guard let document = currentDocument else { return }
        exportService.savePDF(document: document, options: renderOptions())
    }

    func copyAsHTML() {
        guard let document = currentDocument else { return }
        exportService.copyAsHTML(document: document, options: renderOptions())
        showToast("Copied as HTML")
    }

    /// The render configuration shared by the live preview and all exporters.
    func renderOptions() -> MarkdownRenderOptions {
        MarkdownRenderOptions(
            theme: PreviewTheme(rawValue: settings.previewTheme) ?? .github,
            preview: settings.previewSettings,
            enableWikiLinks: settings.enableWikiLinks,
            enableCallouts: settings.enableCallouts,
            enableMermaid: settings.enableMermaid,
            enableKaTeX: settings.enableKaTeX,
            enableCodeHighlight: settings.enablePreviewCodeHighlight
        )
    }

    // MARK: - Recents & Favorites

    private func addToRecentFiles(_ url: URL) {
        recentFiles.removeAll { $0 == url }
        recentFiles.insert(url, at: 0)
        if recentFiles.count > 20 {
            recentFiles = Array(recentFiles.prefix(20))
        }
        saveUserData()
    }

    func clearRecentFiles() {
        recentFiles.removeAll()
        saveUserData()
    }

    func addToFavorites(_ url: URL) {
        guard !favorites.contains(where: { $0.url == url }) else { return }
        favorites.append(FavoriteItem(url: url))
        saveUserData()
        showToast("Added to favorites")
    }

    func removeFromFavorites(_ favorite: FavoriteItem) {
        favorites.removeAll { $0.id == favorite.id }
        saveUserData()
    }

    // MARK: - Office Conversion

    /// office 탭 변환을 시작/재시도한다(로딩 표시 후 비동기 변환).
    @MainActor
    func retryOfficeConversion(tabID: UUID, fileURL: URL) {
        officeStates[tabID] = .loading
        Task { @MainActor in
            do {
                let result = try await kordocService.convert(fileURL: fileURL)
                guard tabs.contains(where: { $0.id == tabID }) else { return }
                officeStates[tabID] = .loaded(result)
            } catch {
                guard tabs.contains(where: { $0.id == tabID }) else { return }
                officeStates[tabID] = .failed(Self.officeErrorMessage(error))
            }
        }
    }

    static func officeErrorMessage(_ error: Error) -> String {
        switch error {
        case KordocError.toolNotFound:
            return "kordoc 실행에 필요한 Node(18+)/kordoc을 찾을 수 없습니다. 터미널에서 `npx kordoc` 또는 `npm i -g kordoc` 후 다시 시도하세요."
        case KordocError.timeout:
            return "문서 변환 시간이 초과됐습니다. 다시 시도해 주세요."
        case KordocError.decodeFailed:
            return "변환 결과를 해석하지 못했습니다."
        case KordocError.conversionFailed(let m):
            return "문서 변환에 실패했습니다.\n\(m)"
        default:
            return "문서를 열 수 없습니다: \(error.localizedDescription)"
        }
    }

    // MARK: - Folder Search

    func searchInFolder(query: String) {
        // 새 검색을 시작하기 전 이전 검색 Task를 취소한다(느린 변환이 늦게 끝나
        // 낡은 결과로 현재 검색어 결과를 덮어쓰는 정합성 버그 방지).
        folderSearchTask?.cancel()
        guard let folder = currentFolder, !query.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true
        searchResults = []

        folderSearchTask = Task { [weak self] in
            guard let self else { return }
            let results = await self.performSearch(query: query, in: folder)
            if Task.isCancelled { return }
            await MainActor.run {
                // 결과가 늦게 와도 그 사이 검색어가 바뀌었으면 덮어쓰지 않음.
                guard self.folderSearchText == query else { return }
                self.searchResults = results
                self.isSearching = false
            }
        }
    }

    /// 파일명에 query(대소문자 무시)가 들어있으면 .filename 결과를 만든다.
    static func filenameMatch(_ url: URL, query: String) -> SearchResult? {
        guard !query.isEmpty else { return nil }
        let name = url.lastPathComponent
        guard let range = name.range(of: query, options: .caseInsensitive) else { return nil }
        return SearchResult(fileURL: url, lineNumber: 0, lineContent: name,
                            matchRange: range, kind: .filename)
    }

    /// text의 각 줄에서 query(대소문자 무시) 첫 위치를 찾아 .line 결과(줄번호 1-base)로.
    static func contentLineMatches(in text: String, fileURL: URL, query: String) -> [SearchResult] {
        guard !query.isEmpty else { return [] }
        var results: [SearchResult] = []
        let lines = text.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            if let range = line.range(of: query, options: .caseInsensitive) {
                results.append(SearchResult(fileURL: fileURL, lineNumber: index + 1,
                                            lineContent: line, matchRange: range, kind: .line))
            }
        }
        return results
    }

    private func performSearch(query: String, in folder: URL,
                              includeFilenames: Bool = true,
                              includePDFBody: Bool = true,
                              includeOfficeBody: Bool = true) async -> [SearchResult] {
        var results: [SearchResult] = []
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let maxResults = 500
        let textExtensions: Set<String> = ["md", "markdown", "txt"]

        // Pull all URLs up front: iterating an enumerator directly is a
        // makeIterator call that's unavailable from async contexts in Swift 6.
        let fileURLs = enumerator.allObjects.compactMap { $0 as? URL }

        for fileURL in fileURLs {
            if Task.isCancelled { return results }
            guard Self.isListableInFileTree(fileURL) else { continue }

            // 1) 파일명 매칭(모든 종류: md/txt·이미지·pdf) — Omnisearch는 끔
            if includeFilenames, let nameHit = Self.filenameMatch(fileURL, query: query) {
                results.append(nameHit)
                if results.count >= maxResults { return results }
            }

            let ext = fileURL.pathExtension.lowercased()

            // 2) 텍스트 본문(md/markdown/txt)
            if textExtensions.contains(ext) {
                if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                    for hit in Self.contentLineMatches(in: content, fileURL: fileURL, query: query) {
                        results.append(hit)
                        if results.count >= maxResults { return results }
                    }
                }
            // 3) PDF 본문(페이지별 추출 → .pdfPage) — Omnisearch는 끔(실시간 추출 방지)
            } else if includePDFBody, DocumentKind.pdfExtensions.contains(ext) {
                if let pdf = PDFDocument(url: fileURL) {
                    for pageIndex in 0..<pdf.pageCount {
                        if Task.isCancelled { return results }
                        guard let page = pdf.page(at: pageIndex),
                              let pageText = page.string else { continue }
                        for hit in Self.contentLineMatches(in: pageText, fileURL: fileURL, query: query) {
                            results.append(SearchResult(
                                fileURL: fileURL,
                                lineNumber: pageIndex + 1,        // 페이지 번호(1-base)
                                lineContent: hit.lineContent,
                                matchRange: hit.matchRange,
                                kind: .pdfPage
                            ))
                            if results.count >= maxResults { return results }
                        }
                    }
                }
            // 4) 오피스 본문(kordoc → 마크다운 → 줄 매칭 → .officeBody) — Omnisearch는 끔(변환 방지)
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
            // 이미지: 본문 없음 — 파일명 매칭만(위 1번)
        }

        return results
    }

    func clearSearch() {
        folderSearchText = ""
        searchResults = []
        isSearching = false
    }

    /// Content search over the open folder, used by Omnisearch.
    /// Omnisearch는 타이핑 중 실시간 검색이라 파일명·PDF 본문은 제외하고
    /// 텍스트 줄(.line) 결과만 받는다(성능·라벨/scrollToLine 정합).
    func searchContent(query: String) async -> [SearchResult] {
        guard let folder = currentFolder, !query.isEmpty else { return [] }
        return await performSearch(query: query, in: folder,
                                   includeFilenames: false, includePDFBody: false,
                                   includeOfficeBody: false)
    }

    // MARK: - Vaults

    func addVault(_ vault: Vault) {
        vaults.append(vault)
        saveUserData()
        rebuildNoteIndex()
    }

    func removeVault(_ vault: Vault) {
        vaults.removeAll { $0.id == vault.id }
        routingRules.removeAll { $0.targetVaultId == vault.id }
        saveUserData()
        rebuildNoteIndex()
    }

    // MARK: - Send to Vault

    func sendToVault(options: SendOptions) async throws {
        guard let document = currentDocument else {
            throw SendError.noDocumentOrVault
        }
        try await sendToVault(document: document, options: options)
    }

    /// Sends an explicit document. Used directly by menu-bar Quick Capture, which
    /// has no active tab and therefore can't rely on `currentDocument`.
    func sendToVault(document: MarkdownDocument, options: SendOptions, quiet: Bool = false) async throws {
        guard let vault = options.targetVault else {
            throw SendError.noDocumentOrVault
        }

        let targetDir = vault.rootPath.appendingPathComponent(options.targetFolder)
        if !FileManager.default.fileExists(atPath: targetDir.path) {
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        }

        let template: VaultTemplate? = options.applyTemplate
            ? templates.first(where: { $0.id == options.templateId })
            : nil

        let baseName = template?.generateFilename(title: document.displayTitle) ?? document.displayTitle
        let filename = Self.sanitizedFilename(baseName) + ".md"
        let candidateURL = targetDir.appendingPathComponent(filename)

        guard let targetURL = resolveConflict(for: candidateURL, resolution: options.conflictResolution) else {
            // .skip on an existing file must leave both target and source intact.
            if !quiet { showToast("Skipped: \(filename) already exists") }
            return
        }

        let body = template?.renderContent(for: document) ?? document.content

        let contentToWrite: String
        if options.injectFrontmatter {
            // Preserve the document's REAL frontmatter (tags, dates, custom keys)
            // instead of synthesizing a minimal one that discards user metadata.
            var frontmatter = document.frontmatter ?? Frontmatter(title: document.displayTitle, date: Date())
            if frontmatter.title == nil { frontmatter.title = document.displayTitle }
            if options.addSourceLink, let source = document.fileURL {
                frontmatter.custom["source"] = .string(source.path)
            }
            contentToWrite = frontmatter.toYAML() + "\n\n" + body
        } else if template != nil {
            contentToWrite = body
        } else {
            // No injection and no template: ship the file exactly as it is on
            // disk. Writing `content` alone silently stripped existing
            // frontmatter from the copy.
            contentToWrite = document.fullText
        }

        try contentToWrite.write(to: targetURL, atomically: true, encoding: .utf8)

        if options.action == .move, let sourceURL = document.fileURL {
            try FileManager.default.removeItem(at: sourceURL)
            // Detach the in-app tab from the now-deleted source file.
            if document.id == currentDocument?.id, var current = currentDocument {
                current.fileURL = nil
                currentDocument = current
                if let tabId = activeTabId, let index = tabs.firstIndex(where: { $0.id == tabId }) {
                    tabs[index].fileURL = nil
                    stopWatchingFile(for: tabId)
                }
            }
        }

        if !quiet { showToast("Sent to \(vault.displayName)") }

        if options.openAfterSend, let obsidianURL = vault.obsidianURL(forFile: targetURL) {
            NSWorkspace.shared.open(obsidianURL)
        }
    }

    /// Sends a batch of files with the same options. Returns counts for the
    /// summary toast. Used by "Send Folder to Vault…".
    @MainActor
    @discardableResult
    func sendFiles(_ urls: [URL], options: SendOptions) async -> (sent: Int, failed: Int) {
        var sent = 0, failed = 0
        for url in urls {
            do {
                let document = try await fileService.loadDocument(from: url)
                try await sendToVault(document: document, options: options, quiet: true)
                sent += 1
            } catch {
                failed += 1
            }
        }
        showToast("Sent \(sent) of \(urls.count) files" + (failed > 0 ? " (\(failed) failed)" : ""))
        return (sent, failed)
    }

    // MARK: - Routing Rules

    /// Highest-priority enabled rule whose conditions all match (a rule with no
    /// conditions acts as a catch-all) and whose target vault still exists.
    func matchingRoutingRule(for document: MarkdownDocument) -> RoutingRule? {
        routingRules
            .filter { $0.isEnabled }
            .sorted { $0.priority > $1.priority }
            .first { rule in
                vaults.contains(where: { $0.id == rule.targetVaultId }) &&
                rule.conditions.allSatisfy { $0.matches(document: document) }
            }
    }

    /// One-keystroke routed send: evaluates routing rules against the current
    /// document and sends without showing a dialog. Falls back to the Send
    /// sheet when no rule matches.
    func autoRouteCurrentDocument() {
        guard let document = currentDocument else { return }
        guard let rule = matchingRoutingRule(for: document),
              let vault = vaults.first(where: { $0.id == rule.targetVaultId }) else {
            if settings.claudeRoutingEnabled && isParaRoutingConfigured() {
                autoTriggerClaudeRoute = true   // 시트가 onAppear에서 소비해 자동 제안
            } else {
                showToast("No routing rule matches — opening Send dialog")
            }
            showSendToVault = true
            return
        }

        var options = SendOptions()
        options.targetVault = vault
        options.targetFolder = rule.targetFolder
        options.action = rule.action
        options.conflictResolution = settings.conflictResolution
        options.injectFrontmatter = rule.injectFrontmatter

        Task { @MainActor in
            do {
                try await sendToVault(document: document, options: options, quiet: true)
                showToast("Routed to \(vault.displayName)/\(rule.targetFolder) (\(rule.name))")
            } catch {
                errorMessage = "Auto-route failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Conflict Resolution

    /// Returns the URL to write to, or `nil` when the write should be skipped
    /// (the file exists and resolution is `.skip`). Distinguishing skip from
    /// overwrite is what stops "Skip" from silently clobbering the existing note.
    private func resolveConflict(for url: URL, resolution: FileConflictResolution) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }

        switch resolution {
        case .overwrite:
            return url
        case .skip:
            return nil
        case .rename:
            return url.uniquified()
        case .timestamp:
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let timestamp = formatter.string(from: Date())
            let baseName = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let parent = url.deletingLastPathComponent()
            return parent.appendingPathComponent("\(baseName)_\(timestamp).\(ext)").uniquified()
        }
    }

    static func sanitizedFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>\0")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    // MARK: - Toast

    // MARK: - 폴더 정리 (Phase 8)

    // busy(배정 등 진행) 중엔 아래 진입점들이 상태를 초기화하지 않는다 — 진행 중 세션
    // 위로 리셋하면 완료 시점 plan 대입이 새 세션을 덮어쓰고, plan.scheme이 시작 시점
    // 스냅샷이라 옛 폴더의 파일이 실제로 이동 가능해진다(적대적 리뷰 확증, 2026-07-05).
    // 시트가 닫혀 있어도 배정 태스크는 계속 돌므로(비구조적 Task) 시트만 다시 보여준다.

    /// subfolder 모드 진입: 시트를 열고 이전 상태를 초기화한다. busy 중엔 시트만 표시.
    func startCleanup(folder: URL) {
        guard !cleanupBusy else { showFolderCleanup = true; return }
        cleanupMode = .subfolder(root: folder)
        cleanupScheme = []
        cleanupPlan = nil
        cleanupError = nil
        showFolderCleanup = true
    }

    /// PARA 모드 진입: 설정된 PARA 폴더를 스킴으로 쓴다. busy 중엔 시트만 표시.
    func startCleanupToPara(vault: Vault) {
        guard !cleanupBusy else { showFolderCleanup = true; return }
        cleanupMode = .para(vault: vault)
        cleanupScheme = settings.paraFolders.map { CleanupBucket.from(para: $0) }
        cleanupPlan = nil
        cleanupError = nil
        showFolderCleanup = true
    }

    /// 정리 UI 상태를 완전히 초기화한다(커맨드팔레트 재진입 시 사용). busy 중엔 무시.
    func resetCleanup() {
        guard !cleanupBusy else { return }
        cleanupMode = nil
        cleanupScheme = []
        cleanupPlan = nil
        cleanupError = nil
    }

    /// 1단계: 폴더 스캔 후 스킴을 제안한다(배정은 하지 않음). subfolder 모드만 Claude 호출.
    @MainActor
    func proposeCleanupScheme() async {
        guard let mode = cleanupMode else { return }
        cleanupBusy = true
        cleanupError = nil
        defer { cleanupBusy = false }
        let metas = FileScanner.scan(mode.root)
        guard !metas.isEmpty else { showToast("정리할 파일이 없습니다"); return }
        do {
            if cleanupScheme.isEmpty {
                if case .subfolder = mode {
                    let proposed = try await cleanupService.proposeScheme(metas: metas)
                    // 방어선: 배정과 동일 — 세션이 그대로일 때만 반영(스테일 완료 폐기).
                    guard cleanupMode == mode else { return }
                    cleanupScheme = proposed
                } else {
                    showToast("PARA 폴더가 설정돼 있지 않습니다"); return
                }
            }
            // 스킴만 제시하고 사용자 편집을 기다린다. plan은 아직 만들지 않는다.
            cleanupPlan = nil
        } catch let error as ClaudeError {
            cleanupError = Self.claudeErrorMessage(error)
        } catch {
            showToast("Claude 응답을 해석하지 못했습니다")
        }
    }

    /// 2단계: 확정된(편집된) 스킴으로 배정해 미리보기 plan을 만든다.
    @MainActor
    func assignCleanupPlan() async {
        guard let mode = cleanupMode, !cleanupScheme.isEmpty else { return }
        cleanupBusy = true
        cleanupError = nil
        defer { cleanupBusy = false; cleanupProgress = nil }
        // 배정 시작 시점 스킴 스냅샷 — 배정(대형 폴더는 수십 분) 도중 스킴이 편집돼도
        // 배정 결과와 plan이 같은 스킴을 본다. 완료 시점에 live cleanupScheme을 다시 읽으면
        // 도중 삭제된 버킷의 move가 적용 시 MoveExecutor 가드에서 조용히 실패로 떨어진다.
        let scheme = cleanupScheme
        let metas = FileScanner.scan(mode.root)
        guard !metas.isEmpty else { showToast("정리할 파일이 없습니다"); return }
        do {
            let assignments = try await cleanupService.assign(scheme: scheme, metas: metas) { [weak self] done, total in
                guard total > 1 else { return }  // 단일 청크면 기본 문구 유지
                Task { @MainActor in self?.cleanupProgress = "배정 중… (\(done)/\(total))" }
            }
            // 방어선: 진입점 busy 가드로 도중 리셋은 차단되지만, 세션(cleanupMode)이
            // 그대로일 때만 결과를 반영한다 — 스테일 완료가 새 세션을 덮어쓰는 것 방지.
            guard cleanupMode == mode else { return }
            cleanupPlan = CleanupPlan(mode: mode, scheme: scheme,
                                      moves: CleanupPlanner.buildMoves(from: assignments))
        } catch let error as ClaudeError {
            cleanupError = Self.claudeErrorMessage(error)
        } catch {
            showToast("Claude 응답을 해석하지 못했습니다")
        }
    }

    /// 승인된 move만 실행하고 로그를 갱신한다.
    @MainActor
    func applyCleanup() async {
        guard let plan = cleanupPlan else { return }
        cleanupBusy = true
        defer { cleanupBusy = false }
        let outcome = await moveExecutor.apply(plan: plan, mode: plan.mode)
        await loadCleanupBatches()
        cleanupPlan = nil
        let failedNote = outcome.failed.isEmpty ? "" : ", 실패 \(outcome.failed.count)"
        showToast("정리 완료: \(outcome.moved)개 이동\(failedNote)")
    }

    /// 정리 배치를 되돌린다.
    @MainActor
    func undoCleanupBatch(_ batch: MoveBatch) async {
        let result = await moveExecutor.undo(batch)
        await loadCleanupBatches()
        showToast("되돌리기: \(result.restored)개 복귀")
    }

    /// 영속 로그에서 배치 목록을 불러온다(최신 순).
    @MainActor
    func loadCleanupBatches() async {
        cleanupBatches = await moveLogStore.load().reversed()
    }

    // MARK: - Claude 인증 (설정 화면)

    /// `claude auth status`를 조회해 화면 상태를 갱신한다.
    @MainActor
    func refreshClaudeAuth() async {
        claudeAuthBusy = true
        defer { claudeAuthBusy = false }
        claudeAuthStatus = await claudeService.authStatus()
        claudeAuthChecked = true
    }

    /// `claude auth login`(브라우저 로그인)을 실행하고 끝나면 상태를 새로고침한다.
    @MainActor
    func claudeLogin() async {
        claudeAuthBusy = true
        do {
            try await claudeService.login()
        } catch let error as ClaudeError {
            errorMessage = Self.claudeErrorMessage(error)
        } catch {
            errorMessage = "Claude 로그인에 실패했습니다."
        }
        claudeAuthBusy = false
        await refreshClaudeAuth()
    }

    /// 로그아웃 후 상태를 새로고침한다.
    @MainActor
    func claudeLogout() async {
        claudeAuthBusy = true
        try? await claudeService.logout()
        claudeAuthBusy = false
        await refreshClaudeAuth()
    }

    func showToast(_ message: String) {
        toastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.toastMessage == message {
                self?.toastMessage = nil
            }
        }
    }

    // MARK: - Session Persistence

    private var sessionURL: URL { dataURL.appendingPathComponent("session.json") }

    func saveSession() {
        let openFiles = tabs.compactMap(\.fileURL)
        var activeIndex: Int?
        if let activeURL = activeTab?.fileURL {
            activeIndex = openFiles.firstIndex(of: activeURL)
        }
        let session = SessionState(
            openFiles: openFiles,
            activeFileIndex: activeIndex,
            viewMode: viewMode,
            currentFolder: currentFolder,
            sidebarVisible: sidebarVisible,
            inspectorVisible: inspectorVisible
        )
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(session) {
            try? data.write(to: sessionURL)
        }
    }

    /// 콜드런치 세션 복원의 마지막 활성 탭 재지정 여부를 판정한다. 순수 함수 — 복원 루프가
    /// 파일들을 순차 로드하는 동안 Finder 더블클릭(`onOpenURL`) 같은 외부 열기가 끼어들어
    /// activeTabId를 이미 다른 탭으로 옮겼다면, 복원 마지막 줄이 그걸 덮어쓰지 않도록 막는다.
    /// current가 nil이거나 복원 루프가 만든/연 탭 중 하나면 재지정을 허용한다.
    static func shouldRestoreActiveTab(current: UUID?, restoredTabIds: Set<UUID>) -> Bool {
        guard let current else { return true }
        return restoredTabIds.contains(current)
    }

    private func restoreSessionIfNeeded() {
        guard settings.restoreLastSession,
              let data = try? Data(contentsOf: sessionURL),
              let session = try? JSONDecoder().decode(SessionState.self, from: data) else { return }

        viewMode = session.viewMode
        sidebarVisible = session.sidebarVisible
        inspectorVisible = session.inspectorVisible

        if let folder = session.currentFolder,
           FileManager.default.fileExists(atPath: folder.path) {
            suppressHistoryRecording = true
            currentFolder = folder
            // 세션 복원 시 currentFolder가 바뀌므로 selectedFolder도 리셋한다.
            selectedFolder = folder
            suppressHistoryRecording = false
            // 복원 위치를 히스토리 시작점으로 seed(가짜 뒤로 항목 없이).
            navHistory.record(FolderLocation(root: folder, display: folder))
            loadFileTree()
        }

        let files = session.openFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }

        // 배치 복원(스펙 §2.4) — 로드만 하고 일괄 append, 활성 탭은 끝에 정확히 1회.
        // 이 Task를 외부 열기 큐 선두에 시드해, 복원 중 도착한 외부 열기(onOpenURL·드롭)는
        // 체인상 복원 뒤에 처리된다 → 자연히 "외부 파일 = 마지막 = 활성".
        externalOpenChain = Task { @MainActor in
            var restored: [EditorTab] = []
            for url in files {
                let target = Self.mediaRedirectTarget(for: url) ?? url
                guard !tabs.contains(where: { $0.fileURL == target }),
                      !restored.contains(where: { $0.fileURL == target }) else { continue }
                if let tab = await loadDocument(at: target) {
                    restored.append(tab)
                }
            }
            guard !restored.isEmpty else { return }
            // 로드 도중 사용자가 내부 열기로 같은 파일을 먼저 열었을 수 있다(내부 열기는
            // 큐를 안 탄다 — 스펙 §5). append 직전 재필터로 중복 탭 창을 닫는다.
            let fresh = restored.filter { tab in
                !tabs.contains(where: { $0.fileURL == tab.fileURL })
            }
            guard !fresh.isEmpty else { return }
            tabs.append(contentsOf: fresh)
            for tab in fresh { finishOpening(tab) }

            // 방어적 가드 유지(스펙 §2.4) — 체인 밖 경로(사용자 클릭)가 먼저 활성 탭을
            // 만들었으면 덮어쓰지 않는다. 저장 인덱스는 openFiles 기준이므로 URL로 해석
            // (존재 필터·중복 제거로 인덱스가 밀리는 구버전 시프트 수정).
            if Self.shouldRestoreActiveTab(current: activeTabId,
                                           restoredTabIds: Set(fresh.map(\.id))) {
                var activeTab: EditorTab?
                if let index = session.activeFileIndex, index < session.openFiles.count {
                    let savedURL = session.openFiles[index]
                    let target = Self.mediaRedirectTarget(for: savedURL) ?? savedURL
                    activeTab = fresh.first(where: { $0.fileURL == target })
                }
                activeTabId = (activeTab ?? fresh.last)?.id
            }
            saveSession()
        }
    }

    // MARK: - User Data Persistence

    private func loadUserData() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
            guard let data = try? Data(contentsOf: dataURL.appendingPathComponent(filename)) else { return nil }
            return try? decoder.decode(type, from: data)
        }

        if let loaded = load(AppSettings.self, from: "settings.json") { settings = loaded }
        if let loaded = load([Vault].self, from: "vaults.json") { vaults = loaded }
        if let loaded = load([URL].self, from: "recents.json") {
            recentFiles = loaded.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        if let loaded = load([VaultTemplate].self, from: "templates.json") { templates = loaded }
        if let loaded = load([RoutingRule].self, from: "rules.json") { routingRules = loaded }
        if let loaded = load([FavoriteItem].self, from: "favorites.json") {
            favorites = loaded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        }
        if let loaded = load([Draft].self, from: "drafts.json") { drafts = loaded }
    }

    func saveUserData() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        func save<T: Encodable>(_ value: T, to filename: String) {
            if let data = try? encoder.encode(value) {
                try? data.write(to: dataURL.appendingPathComponent(filename))
            }
        }

        save(settings, to: "settings.json")
        save(vaults, to: "vaults.json")
        save(recentFiles, to: "recents.json")
        save(templates, to: "templates.json")
        save(routingRules, to: "rules.json")
        save(favorites, to: "favorites.json")
        persistDrafts()
    }

    func persistDrafts() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(drafts) {
            try? data.write(to: dataURL.appendingPathComponent("drafts.json"))
        }
    }
}

enum OfficeState {
    case loading
    case loaded(KordocResult)
    case failed(String)
}

/// 편집 저장 확인 시트를 구동하는 요청. output은 제안 기본 경로이며,
/// 시트의 로컬 상태가 이를 시드로 받아 '위치 변경'을 반영한다.
struct OfficeSaveRequest: Identifiable {
    let id = UUID()
    let tabID: UUID
    let fileURL: URL
    var output: URL
}

/// 양식 채우기 시트를 구동하는 요청. detection = dry-run 결과, output = 제안 기본 경로(시드).
struct OfficeFillRequest: Identifiable {
    let id = UUID()
    let tabID: UUID
    let fileURL: URL
    let detection: FillDetection
    var output: URL
}

/// 이름 변경 시트 요청 페이로드.
struct RenameRequest: Identifiable {
    let id = UUID()
    let url: URL
}

/// 정보 보기 시트 요청 페이로드.
struct FileInfoRequest: Identifiable {
    let id = UUID()
    let url: URL
}

enum SendError: LocalizedError {
    case noDocumentOrVault
    case fileConflict
    case writeError(Error)

    var errorDescription: String? {
        switch self {
        case .noDocumentOrVault:
            return "No document or vault selected"
        case .fileConflict:
            return "File already exists"
        case .writeError(let error):
            return "Write error: \(error.localizedDescription)"
        }
    }
}

// MARK: - URL Uniquifying

extension URL {
    /// Returns self if no file exists at this path, otherwise appends
    /// " (1)", " (2)", … before the extension until the name is free.
    func uniquified() -> URL {
        guard FileManager.default.fileExists(atPath: path) else { return self }
        let baseName = deletingPathExtension().lastPathComponent
        let ext = pathExtension
        let parent = deletingLastPathComponent()

        var counter = 1
        var candidate = self
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(ext)"
            candidate = parent.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }
}
