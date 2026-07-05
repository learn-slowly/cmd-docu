import Foundation

/// dataviewjs 블록 1개(문서 내 등장 순서 id + 코드 원문).
struct DataviewBlock: Equatable {
    let id: Int
    let code: String
}

/// 마크다운에서 ```dataviewjs 펜스를 추출하고 그 자리를 호출자가 준 HTML로 치환한다(순수).
/// 렌더러의 코드 마스킹(maskCodeRegions)보다 먼저, 호출자(PreviewView)가 원문에 적용한다.
/// 다른 펜스(``` 등) 안에 든 예시는 건드리지 않도록 일반 펜스 상태도 함께 추적한다.
enum DataviewBlockExtractor {

    static func extract(_ markdown: String,
                        placeholderHTML: (Int) -> String) -> (markdown: String, blocks: [DataviewBlock]) {
        // CRLF 개행 문서를 LF로 정규화 — \r 잔존이 whitespaces trim 실패로 펜스 매치 차단함.
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var out: [String] = []
        var blocks: [DataviewBlock] = []
        var i = 0
        var insideOtherFence = false
        var otherFenceMarker = ""   // 열었던 펜스 문자열(백틱 3+개) — 같은 길이 이상으로 닫힘

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if insideOtherFence {
                out.append(line)
                if trimmed.hasPrefix(otherFenceMarker), trimmed.allSatisfy({ $0 == "`" }) {
                    insideOtherFence = false
                }
                i += 1
                continue
            }

            if trimmed == "```dataviewjs" {
                // 닫는 펜스 탐색 — 없으면(미종결) 원문 그대로 둔다.
                var j = i + 1
                var body: [String] = []
                var closed = false
                while j < lines.count {
                    if lines[j].trimmingCharacters(in: .whitespaces) == "```" { closed = true; break }
                    body.append(lines[j]); j += 1
                }
                if closed {
                    let id = blocks.count
                    blocks.append(DataviewBlock(id: id, code: body.joined(separator: "\n")))
                    out.append(placeholderHTML(id))
                    i = j + 1
                    continue
                }
            }

            // 일반 펜스 진입 감지(``` 3개 이상 + 언어 태그 여부 무관, dataviewjs 제외)
            if trimmed.hasPrefix("```"), trimmed != "```dataviewjs" {
                let backticks = trimmed.prefix(while: { $0 == "`" })
                if backticks.count >= 3 {
                    insideOtherFence = true
                    otherFenceMarker = String(backticks)
                }
            }
            out.append(line)
            i += 1
        }
        return (out.joined(separator: "\n"), blocks)
    }
}
