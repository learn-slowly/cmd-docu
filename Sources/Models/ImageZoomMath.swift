import CoreGraphics

/// 이미지 뷰어 줌 수학(AppKit 비의존·순수). 배율 클램프·맞춤 계산·스텝·라벨·스크롤 휠 장치 판정.
/// ImageReaderView가 사용하며, 여기 로직만 단위 테스트한다.
enum ImageZoomMath {
    static let factor: CGFloat = 1.25
    /// 마우스 휠 한 틱당 배율 — 버튼/키보드 factor(1.25)보다 세밀.
    static let wheelFactor: CGFloat = 1.1
    static let minMagnification: CGFloat = 0.1
    static let maxMagnification: CGFloat = 16

    /// 배율을 [min, max]로 제한.
    static func clamp(_ m: CGFloat,
                      min lo: CGFloat = minMagnification,
                      max hi: CGFloat = maxMagnification) -> CGFloat {
        Swift.min(Swift.max(m, lo), hi)
    }

    /// 창에 맞춤 배율 — 축소만(작은 이미지는 100% 유지). 0/음수 크기는 1로 방어.
    static func fit(imageSize: CGSize, in viewSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return 1 }
        return Swift.min(viewSize.width / imageSize.width,
                         viewSize.height / imageSize.height, 1.0)
    }

    /// 한 스텝 확대(×factor) 후 클램프.
    static func stepIn(_ m: CGFloat) -> CGFloat { clamp(m * factor) }

    /// 한 스텝 축소(÷factor) 후 클램프.
    static func stepOut(_ m: CGFloat) -> CGFloat { clamp(m / factor) }

    /// 배율을 정수 퍼센트 문자열로("100%"). 반올림.
    static func percentLabel(_ m: CGFloat) -> String {
        "\(Int((m * 100).rounded()))%"
    }

    /// 스크롤 휠 이벤트를 줌으로 볼지 판정.
    /// - ⌘가 눌려 있으면 장치 무관 항상 줌.
    /// - 아니면 저정밀 델타(휠 마우스)만 줌, 정밀 델타(트랙패드/Magic Mouse)는 팬.
    static func shouldZoom(hasPreciseDeltas: Bool, commandHeld: Bool) -> Bool {
        commandHeld || !hasPreciseDeltas
    }
}
