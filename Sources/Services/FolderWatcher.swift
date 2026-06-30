import Foundation
import CoreServices

/// FSEvents로 등록 폴더들을 감시한다. 변경 경로 배치를 onChangedPaths로 전달.
/// 0.5s 디바운스, 파일 단위 이벤트. 시스템 콜백이라 단위테스트 제외(수동 검증).
final class FolderWatcher {
    var onChangedPaths: (([String]) -> Void)?

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "work.cmdspace.cmddocu.folderwatcher")

    func start(folders: [String]) {
        stop()
        guard !folders.isEmpty else { return }
        let info = Unmanaged.passUnretained(self).toOpaque()
        var ctx = FSEventStreamContext(version: 0, info: info, retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, clientInfo, numEvents, eventPaths, _, _ in
            guard let clientInfo else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
            watcher.onChangedPaths?(Array(paths.prefix(numEvents)))
        }
        let created = FSEventStreamCreate(
            kCFAllocatorDefault, cb, &ctx, folders as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
            // UseCFTypes: eventPaths를 CFArray<CFString>로 전달 → fromOpaque 캐스트가 유효해짐
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes))
        guard let created else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
