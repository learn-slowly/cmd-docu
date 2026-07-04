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

    /// providers에 앱 전용 타입이 있으면 내부 드래그 — 창 레벨 "열기"·에디터 이미지 삽입이
    /// 이 판별로 내부 드래그를 무시한다(빗나간 드롭=조용한 무동작, 스펙 §4).
    static func isInternalDrag(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.cmdDocuDrag.identifier) }
    }

    /// 드래그 소스용 provider — 내부 페이로드(전체 목록, .ownProcess) + Finder 호환
    /// fileURL(드래그 항목 자신). ⚠️ SwiftUI .onDrag는 provider 1개 한계 —
    /// 아웃바운드 다중은 드래그 항목 1개만 전달된다(다중 내보내기는 ⌘C, 스펙 정정).
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
}
