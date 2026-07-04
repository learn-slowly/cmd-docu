import AppKit
import UniformTypeIdentifiers

// MARK: - 앱 전용 드래그 타입

extension UTType {
    /// F2 내부 드래그 식별 타입 — 같은 프로세스 안에서만 소비(visibility .ownProcess).
    /// Finder 등 외부 앱은 병행 탑재된 .fileURL 표현만 읽는다(아웃바운드=복사, 스펙 §2.2).
    static let cmdDocuDrag = UTType(exportedAs: "work.cmdspace.cmddocu.drag")
}

// MARK: - DragPayload

/// 드래그 페이로드 — 순수 헬퍼(스펙 §2). 규칙 결정·직렬화·내부 판별·provider 생성.
enum DragPayload {

    /// 페이로드 결정(Finder 관례): 드래그 항목이 선택에 포함되면 선택 전체(ancestorsOnly 정규화),
    /// 아니면 그 항목 하나. 드래그 시작은 선택을 바꾸지 않는다(호출부 계약).
    static func urls(for dragged: URL, selection: Set<URL>) -> [URL] {
        if selection.contains(dragged) {
            return FileSelectionHelper.ancestorsOnly(selection)
        }
        return [dragged]
    }

    /// URL 목록 → plist Data(경로 문자열 배열). 내부 드래그 페이로드 직렬화.
    static func encode(_ urls: [URL]) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: urls.map(\.path),
                                             format: .binary, options: 0)) ?? Data()
    }

    /// plist Data → URL 목록. 손상 데이터는 빈 배열(크래시 없음).
    static func decode(_ data: Data) -> [URL] {
        guard let paths = (try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)) as? [String] else { return [] }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    /// 드래그 파스테보드용 타입 상수 — 내부 드래그 판별 신호(타입 '선언') 용도.
    static let pasteboardType = NSPasteboard.PasteboardType(UTType.cmdDocuDrag.identifier)

    /// 내부 드래그 판별 — 드래그 파스테보드에 커스텀 타입이 '선언'돼 있는지만 본다.
    /// 실측(2층): ①SwiftUI가 드롭 쪽 provider를 재구성할 때 커스텀 UTType 표현을 누락하고,
    /// ②드래그 파스테보드에 실려도 커스텀 타입의 데이터 promise는 이행되지 않는다(0바이트).
    /// 즉 어느 채널도 페이로드 '데이터'를 나르지 못한다 — 단, 타입 '선언' 자체는 내부 세션
    /// 동안 파스테보드에 존재한다(실측, Finder발 세션엔 없음). 그래서 판별은 이 선언만 쓰고,
    /// 실제 페이로드(전체 목록)는 AppState.draggingURLs 스냅샷으로 나른다. 드래그/드롭 콜백
    /// 안에서만 호출해야 활성 세션 파스테보드가 보장된다. Finder발 외부 드래그는 이 커스텀
    /// 타입 선언이 없어 false(외부 판별 정확성 유지 — 외부는 draggingURLs를 참조하지 않음).
    static func isInternalDrag(pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> Bool {
        pasteboard.types?.contains(pasteboardType) ?? false
    }

    /// 드래그 소스용 provider — 커스텀 표현(.ownProcess) + Finder 호환 fileURL(드래그 항목 자신).
    /// ⚠️ 커스텀 표현의 '데이터'는 실전에서 전달되지 않는다(실측 0바이트) — 등록 목적은 파스테보드에
    /// 타입 '선언'을 얹어 내부 드래그 판별 신호를 만드는 것뿐(페이로드는 AppState.draggingURLs).
    /// SwiftUI .onDrag는 provider 1개 한계 — 아웃바운드 다중은 드래그 항목 1개만 전달된다
    /// (다중 내보내기는 ⌘C, 스펙 정정). fileURL만 .all로 두어 Finder(외부 프로세스)가 읽게 한다.
    static func makeProvider(for urls: [URL], primary: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = encode(urls)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.cmdDocuDrag.identifier,
                                            visibility: .ownProcess) { completion in
            completion(payload, nil)
            return nil
        }
        let urlData = primary.dataRepresentation
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier,
                                            visibility: .all) { completion in
            completion(urlData, nil)
            return nil
        }
        return provider
    }
}

// MARK: - DropGuard

/// 드롭 수락 판정 — 순수(스펙 §3). 뷰 사전 차단(1차)과 수행 시 필터(2차)가 공유한다.
enum DropGuard {

    /// 목적지가 소스 자신이거나 그 하위면 거부 — standardized + '/' 경계(형제 오감지 방지).
    static func canAccept(source: URL, destination: URL) -> Bool {
        let src = source.standardizedFileURL.path
        let dst = destination.standardizedFileURL.path
        return dst != src && !dst.hasPrefix(src + "/")
    }

    /// hover 사전 차단용 — 소스 목록을 모르면(외부 드래그) 허용하고 2차 방어에 맡긴다.
    /// 전부 거부 대상일 때만 타깃 비활성.
    static func canAcceptAny(sources: [URL], destination: URL) -> Bool {
        if sources.isEmpty { return true }
        return sources.contains { canAccept(source: $0, destination: destination) }
    }

    /// 드롭 델리게이트 결정 — 타입 게이트 통과 후 (수락·하이라이트) 진리표(최종 리뷰 fix wave).
    /// 수락은 언제나 true다: 유효 드롭은 수행하고, **무효 내부 드롭도 소비**해 상위 타깃(트리
    /// 루트 등)으로 폴스루하지 않게 한다(폴스루 시 항목이 조용히 루트로 이동 — I2). 소비된
    /// 무효 드롭은 handleFileDrop의 2차 필터가 조용한 무동작으로 만든다.
    /// - external(isInternal=false): 소스 미상 → 수락·하이라이트(draggingURLs 미참조 — C1 차단).
    /// - internal + 유효: 수락·하이라이트.
    /// - internal + 무효(자기/하위): 수락(소비)·하이라이트 없음(스프링로딩도 없음).
    static func dropDecision(isInternal: Bool, sources: [URL],
                             destination: URL) -> (accept: Bool, highlight: Bool) {
        guard isInternal else { return (accept: true, highlight: true) }
        return (accept: true, highlight: canAcceptAny(sources: sources, destination: destination))
    }
}
