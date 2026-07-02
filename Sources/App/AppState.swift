import SwiftUI
import Observation
import UniformTypeIdentifiers
import PDFKit

@Observable
final class AppState {
    /// Weak shared reference so the AppDelegate (created independently via
    /// @NSApplicationDelegateAdaptor) can consult app state on quit.
    static weak var shared: AppState?
    private static let launchDefaults = AppLaunchDefaults()

    // Tab System
    var tabs: [EditorTab] = []
    var activeTabId: UUID?
    var documents: [UUID: MarkdownDocument] = [:]
    var originalContents: [UUID: String] = [:]
    /// kordoc 오피스 변환 상태(키 = EditorTab.id). office 탭은 MarkdownDocument가 없다.
    var officeStates: [UUID: OfficeState] = [:]

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
        didSet { restoreLibraryLayoutForSelectedFolder() }
    }
    /// 라이브러리 뷰 레이아웃(grid/list). 폴더별 기억 포함.
    var libraryLayout: LibraryLayout = .grid {
        didSet { persistLibraryLayoutForCurrentFolder(oldValue: oldValue) }
    }
    /// 복원 중 libraryLayout didSet이 재저장하지 않도록 막는 플래그.
    private var isRestoringLayout = false

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
    var cleanupBatches: [MoveBatch] = []
    var cleanupError: String?

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
    private let cleanupService: CleanupService
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
        return "cmd-docu"
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
    static func claudeContext(selection: String, markdown: String?, officeMarkdown: String?) -> String {
        let sel = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sel.isEmpty { return sel }
        if let md = markdown, !md.isEmpty { return md }
        if let om = officeMarkdown, !om.isEmpty { return om }
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
        let context = Self.claudeContext(selection: selection,
                                         markdown: currentDocument?.content,
                                         officeMarkdown: officeMarkdown)

        claudeBusy = true
        claudeError = nil
        claudeResponse = nil

        Task { @MainActor in
            do {
                let answer = try await claudeService.ask(prompt: prompt, context: context)
                if answer.isEmpty {
                    claudeError = "Claude가 빈 응답을 반환했습니다. 다시 시도해 주세요."
                } else {
                    claudeResponse = answer
                }
            } catch {
                claudeError = Self.claudeErrorMessage(error)
            }
            claudeBusy = false
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
                request.setValue("cmd-docu", forHTTPHeaderField: "User-Agent")
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
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            appDir = appSupport.appendingPathComponent("CmdMD")
        }
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        dataURL = appDir

        moveLogStore = MoveLogStore(directory: appDir)
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
            currentFolder = url
            // currentFolder가 실제로 바뀌는 지점에서만 selectedFolder를 리셋한다.
            selectedFolder = url
            selectedSidebarTab = .files
            sidebarVisible = true
            loadFileTree()
            rebuildNoteIndex()
            saveSession()
        }
    }

    /// 사이드바 폴더 행 탭 시 라이브러리 모드로 전환하고 표시 폴더를 설정한다.
    func selectFolderForLibrary(_ url: URL) {
        selectedFolder = url
        mainMode = .library
    }

    // MARK: - 폴더별 레이아웃 기억 (Phase 8.5-③)

    /// selectedFolder가 바뀔 때 해당 폴더의 기억된 레이아웃을 복원한다.
    /// 기억이 없으면 현재 레이아웃을 그대로 유지한다.
    private func restoreLibraryLayoutForSelectedFolder() {
        guard let url = selectedFolder else { return }
        let key = url.standardizedFileURL.path
        guard let remembered = settings.libraryLayouts[key] else { return }
        guard remembered != libraryLayout else { return }
        isRestoringLayout = true
        libraryLayout = remembered
        isRestoringLayout = false
    }

    /// libraryLayout이 바뀔 때 현재 폴더에 레이아웃을 기억하고 즉시 영속한다.
    /// 복원 중이거나 값이 변하지 않으면 건너뛴다.
    private func persistLibraryLayoutForCurrentFolder(oldValue: LibraryLayout) {
        guard !isRestoringLayout else { return }
        guard oldValue != libraryLayout else { return }
        guard let url = selectedFolder ?? currentFolder else { return }
        let key = url.standardizedFileURL.path
        settings.libraryLayouts[key] = libraryLayout
        saveUserData()
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
            if let line { scrollEditor(toLine: line) }
            if let pdfPage { scrollPDF(toPage: pdfPage, url: url) }
            return
        }

        Task { @MainActor in
            await loadAndActivateDocument(at: url, inNewTab: inNewTab)
            if let line { scrollEditor(toLine: line) }
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
        if let mediaURL = Self.mediaRedirectTarget(for: url) {
            await loadAndActivateDocument(at: mediaURL, inNewTab: inNewTab)
            return
        }

        if let existingTab = tabs.first(where: { $0.fileURL == url }) {
            activeTabId = existingTab.id
            return
        }

        // 이미지·PDF·오피스: MarkdownDocument/워처/originalContents 없이 탭만.
        let kind = DocumentKind(from: url)
        if kind != .markdown {
            let tab = EditorTab(
                fileURL: url,
                title: url.deletingPathExtension().lastPathComponent,
                kind: kind
            )
            placeTab(tab, inNewTab: inNewTab)
            addToRecentFiles(url)
            if kind == .office {
                retryOfficeConversion(tabID: tab.id, fileURL: url)
            }
            saveSession()
            return
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
            placeTab(tab, inNewTab: inNewTab)
            addToRecentFiles(url)
            startWatchingFile(at: url, for: tab.id)
            harvestTags(from: document)
            saveSession()
        } catch {
            errorMessage = "Failed to open file: \(error.localizedDescription)"
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
        guard let content = currentDocument?.content else { return nil }
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
            guard !Task.isCancelled else { return }
            // 호출 인스턴스에 대입 — static shared 참조 제거(다중 인스턴스·테스트 안전).
            await MainActor.run { self?.fileTree = tree }
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

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var items: [FileTreeItem] = []
        // 같은 폴더 파일명 집합 — 짝꿍 노트 숨김·배지 판별용(추가 FS 호출 없음).
        let siblingNames = Set(contents.map { $0.lastPathComponent })

        for itemURL in contents.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            guard let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey]) else { continue }
            let isDirectory = resourceValues.isDirectory ?? false

            if isDirectory {
                let isExpanded = expanded.contains(itemURL)
                let children = isExpanded ? buildFileTree(at: itemURL, expanded: expanded, depth: depth + 1) : []
                items.append(FileTreeItem(url: itemURL, isDirectory: true, isExpanded: isExpanded, children: children))
            } else {
                if isListableInFileTree(itemURL) {
                    // 짝꿍 노트는 목록에서 숨긴다 — 미디어 행이 대표(배지로 존재 표시).
                    if CompanionNote.isCompanionNote(itemURL, siblings: siblingNames) { continue }
                    let hasNote = DocumentKind(from: itemURL) == .media
                        && siblingNames.contains(CompanionNote.noteURL(for: itemURL).lastPathComponent)
                    items.append(FileTreeItem(url: itemURL, isDirectory: false, hasCompanionNote: hasNote))
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

    func createNewFolder(in parent: URL) {
        let target = parent.appendingPathComponent("New Folder").uniquified()
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            loadFileTree()
        } catch {
            errorMessage = "Failed to create folder: \(error.localizedDescription)"
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

    /// subfolder 모드 진입: 시트를 열고 이전 상태를 초기화한다.
    func startCleanup(folder: URL) {
        cleanupMode = .subfolder(root: folder)
        cleanupScheme = []
        cleanupPlan = nil
        cleanupError = nil
        showFolderCleanup = true
    }

    /// PARA 모드 진입: 설정된 PARA 폴더를 스킴으로 쓴다.
    func startCleanupToPara(vault: Vault) {
        cleanupMode = .para(vault: vault)
        cleanupScheme = settings.paraFolders.map { CleanupBucket.from(para: $0) }
        cleanupPlan = nil
        cleanupError = nil
        showFolderCleanup = true
    }

    /// 정리 UI 상태를 완전히 초기화한다(커맨드팔레트 재진입 시 사용).
    func resetCleanup() {
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
                    cleanupScheme = try await cleanupService.proposeScheme(metas: metas)
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
        defer { cleanupBusy = false }
        let metas = FileScanner.scan(mode.root)
        guard !metas.isEmpty else { showToast("정리할 파일이 없습니다"); return }
        do {
            let assignments = try await cleanupService.assign(scheme: cleanupScheme, metas: metas)
            cleanupPlan = CleanupPlan(mode: mode, scheme: cleanupScheme,
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

    private func restoreSessionIfNeeded() {
        guard settings.restoreLastSession,
              let data = try? Data(contentsOf: sessionURL),
              let session = try? JSONDecoder().decode(SessionState.self, from: data) else { return }

        viewMode = session.viewMode
        sidebarVisible = session.sidebarVisible
        inspectorVisible = session.inspectorVisible

        if let folder = session.currentFolder,
           FileManager.default.fileExists(atPath: folder.path) {
            currentFolder = folder
            // 세션 복원 시 currentFolder가 바뀌므로 selectedFolder도 리셋한다.
            selectedFolder = folder
            loadFileTree()
        }

        let files = session.openFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }

        Task { @MainActor in
            for url in files {
                await loadAndActivateDocument(at: url, inNewTab: true)
            }
            if let index = session.activeFileIndex, index < tabs.count {
                activeTabId = tabs[index].id
            }
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
