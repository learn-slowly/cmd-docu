import Foundation
import PDFKit

/// 근거 파일에서 질의어 주변 문단(창)과 원본 위치를 뽑는다.
/// text 경로는 순수·결정적(테스트 대상), pdf/office는 기존 추출기를 재사용.
enum RagPassageExtractor {
    struct Passage: Equatable { let text: String; let location: RagLocation }

    /// 본문 문자열에서 질의어가 가장 많이 겹치는 줄의 문단을 반환(순수). 매치 없으면 앞 maxChars·줄 1.
    /// 첫 매치만 쓰면 문서 앞머리의 스치는 언급이 정답 문단을 밀어낸다(스모크 발견 2026-07-02)
    /// — 서로 다른 질의어 매치 수가 최대인 줄을 고르고, 동률이면 이른 줄(기존 동작 보존).
    static func passage(inText body: String, terms: [String], maxChars: Int = 1200) -> Passage {
        let cleanTerms = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                              .filter { !$0.isEmpty }
        let lower = body.lowercased()
        // 줄 단위로 매치 수를 세어 최다 매치 줄의 첫 매치 오프셋을 고른다.
        var best: Int? = nil
        var bestScore = 0
        var lineStart = 0
        for lineSub in lower.split(separator: "\n", omittingEmptySubsequences: false) {
            var score = 0
            var firstInLine: Int? = nil
            for term in cleanTerms {
                if let r = lineSub.range(of: term) {
                    score += 1
                    let inLine = lineSub.distance(from: lineSub.startIndex, to: r.lowerBound)
                    if firstInLine == nil || inLine < firstInLine! { firstInLine = inLine }
                }
            }
            if score > bestScore, let firstInLine {
                bestScore = score
                best = lineStart + firstInLine
            }
            lineStart += lineSub.count + 1   // +1 = 개행
        }
        guard let matchOff = best else {
            // 앞 maxChars 잘라 반환. 끝 공백·줄바꿈은 제거(자연 텍스트 경계).
            let prefix = String(body.prefix(maxChars)).trimmingCharacters(in: .whitespacesAndNewlines)
            return Passage(text: prefix, location: .line(1))
        }
        let chars = Array(body)
        // 매치 줄 번호 = 매치 앞의 개행 수 + 1.
        let line = chars[0..<matchOff].reduce(1) { $0 + ($1 == "\n" ? 1 : 0) }
        // 문단 경계: 앞뒤로 빈 줄("\n\n")을 찾는다.
        let paraStart = paragraphStart(chars, before: matchOff)
        let paraEnd = paragraphEnd(chars, from: matchOff)
        var paragraph = String(chars[paraStart..<paraEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        if paragraph.count > maxChars {
            paragraph = centeredWindow(String(chars[paraStart..<paraEnd]), around: matchOff - paraStart, maxChars: maxChars)
        }
        return Passage(text: paragraph, location: .line(line))
    }

    /// 종류별 근거 추출: text/md=줄, pdf=페이지, office=위치 unknown. 실패 시 nil.
    static func passage(for url: URL, terms: [String], kordoc: KordocService, maxChars: Int = 1200) async -> Passage? {
        let ext = url.pathExtension.lowercased()
        if DocumentKind.pdfExtensions.contains(ext) {
            return pdfPassage(url: url, terms: terms, maxChars: maxChars)
        }
        if DocumentKind.officeExtensions.contains(ext) {
            guard let body = await ContentExtractor.body(for: url, kordoc: kordoc) else { return nil }
            let p = passage(inText: body, terms: terms, maxChars: maxChars)
            return Passage(text: p.text, location: .unknown)   // 원본 위치 매핑 불가
        }
        guard let body = ContentExtractor.localBody(for: url) else { return nil }
        return passage(inText: body, terms: terms, maxChars: maxChars)
    }

    // MARK: - private

    private static func pdfPassage(url: URL, terms: [String], maxChars: Int) -> Passage? {
        guard let doc = PDFDocument(url: url) else { return nil }
        let cleanTerms = terms.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                              .filter { !$0.isEmpty }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let text = page.string else { continue }
            let lower = text.lowercased()
            if cleanTerms.contains(where: { lower.contains($0) }) {
                let p = passage(inText: text, terms: terms, maxChars: maxChars)
                return Passage(text: p.text, location: .page(i + 1))
            }
        }
        // 매치 없으면 1페이지 앞부분.
        if let first = doc.page(at: 0)?.string {
            return Passage(text: String(first.prefix(maxChars)), location: .page(1))
        }
        return nil
    }

    private static func paragraphStart(_ chars: [Character], before off: Int) -> Int {
        var i = off
        while i > 1 {
            if chars[i - 1] == "\n" && chars[i - 2] == "\n" { return i }
            i -= 1
        }
        return 0
    }

    private static func paragraphEnd(_ chars: [Character], from off: Int) -> Int {
        var i = off
        while i < chars.count - 1 {
            if chars[i] == "\n" && chars[i + 1] == "\n" { return i }
            i += 1
        }
        return chars.count
    }

    private static func centeredWindow(_ s: String, around off: Int, maxChars: Int) -> String {
        let chars = Array(s)
        let half = maxChars / 2
        let start = max(0, min(off - half, chars.count - maxChars))
        let end = min(chars.count, start + maxChars)
        return String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
