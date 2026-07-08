import XCTest
@testable import CmdMD

final class ImageZoomMathTests: XCTestCase {
    func testFitConstrainedByWidth() {
        // 800x100 이미지를 400x400 뷰에 → 폭 제약 400/800 = 0.5
        let m = ImageZoomMath.fit(imageSize: CGSize(width: 800, height: 100),
                                  in: CGSize(width: 400, height: 400))
        XCTAssertEqual(m, 0.5, accuracy: 0.0001)
    }

    func testFitConstrainedByHeight() {
        let m = ImageZoomMath.fit(imageSize: CGSize(width: 100, height: 800),
                                  in: CGSize(width: 400, height: 400))
        XCTAssertEqual(m, 0.5, accuracy: 0.0001)
    }

    func testFitSmallImageCapsAtOne() {
        // 뷰보다 작은 이미지는 100% 유지(확대 안 함).
        let m = ImageZoomMath.fit(imageSize: CGSize(width: 50, height: 50),
                                  in: CGSize(width: 400, height: 400))
        XCTAssertEqual(m, 1.0, accuracy: 0.0001)
    }

    func testFitZeroSizeDefendsToOne() {
        XCTAssertEqual(ImageZoomMath.fit(imageSize: .zero,
                                         in: CGSize(width: 400, height: 400)), 1.0)
        XCTAssertEqual(ImageZoomMath.fit(imageSize: CGSize(width: 100, height: 100),
                                         in: .zero), 1.0)
    }

    func testClampBounds() {
        XCTAssertEqual(ImageZoomMath.clamp(0.01), ImageZoomMath.minMagnification, accuracy: 0.0001)
        XCTAssertEqual(ImageZoomMath.clamp(100), ImageZoomMath.maxMagnification, accuracy: 0.0001)
        XCTAssertEqual(ImageZoomMath.clamp(2), 2, accuracy: 0.0001)
    }

    func testStepInOut() {
        XCTAssertEqual(ImageZoomMath.stepIn(1.0), 1.25, accuracy: 0.0001)
        XCTAssertEqual(ImageZoomMath.stepOut(1.0), 0.8, accuracy: 0.0001)
    }

    func testStepClampsAtBounds() {
        XCTAssertEqual(ImageZoomMath.stepIn(ImageZoomMath.maxMagnification),
                       ImageZoomMath.maxMagnification, accuracy: 0.0001)
        XCTAssertEqual(ImageZoomMath.stepOut(ImageZoomMath.minMagnification),
                       ImageZoomMath.minMagnification, accuracy: 0.0001)
    }

    func testPercentLabel() {
        XCTAssertEqual(ImageZoomMath.percentLabel(1.0), "100%")
        XCTAssertEqual(ImageZoomMath.percentLabel(0.5), "50%")
        XCTAssertEqual(ImageZoomMath.percentLabel(1.5), "150%")
        XCTAssertEqual(ImageZoomMath.percentLabel(0.333), "33%")
    }

    func testShouldZoomTruthTable() {
        // 휠 마우스(저정밀) → 줌
        XCTAssertTrue(ImageZoomMath.shouldZoom(hasPreciseDeltas: false, commandHeld: false))
        XCTAssertTrue(ImageZoomMath.shouldZoom(hasPreciseDeltas: false, commandHeld: true))
        // 트랙패드(정밀) → 팬
        XCTAssertFalse(ImageZoomMath.shouldZoom(hasPreciseDeltas: true, commandHeld: false))
        // ⌘ 누르면 장치 무관 줌
        XCTAssertTrue(ImageZoomMath.shouldZoom(hasPreciseDeltas: true, commandHeld: true))
    }
}
