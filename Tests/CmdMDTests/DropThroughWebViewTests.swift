import XCTest
import WebKit
@testable import CmdMD

/// F2 후속: 프리뷰 WKWebView가 파일 드래그를 삼키지 않도록 드래그 목적지 등록을 영구 해제.
/// registerForDraggedTypes를 no-op으로 덮었으므로, 재등록 시도 후에도 등록 타입이 비어 있어야 한다.
final class DropThroughWebViewTests: XCTestCase {

    @MainActor
    func testRegisteredDraggedTypesStayEmptyAfterRegister() {
        let webView = DropThroughWebView(frame: .zero, configuration: WKWebViewConfiguration())
        // WebKit이 navigation/load 시점에 하는 재등록을 흉내 — no-op override로 무효화되어야 함.
        webView.registerForDraggedTypes([.fileURL, .string])
        XCTAssertTrue(webView.registeredDraggedTypes.isEmpty,
                      "DropThroughWebView는 재등록 후에도 드래그 목적지 타입이 비어 있어야 함")
    }
}
