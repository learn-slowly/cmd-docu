import XCTest
@testable import CmdMD

/// 폴더 정리 배정 청크 분할 — 회귀(2026-07-05): Downloads 789개처럼 파일이 많으면
/// 배정 응답(파일당 JSON 1엔트리)이 파일 수에 비례해 길어져 claude CLI 120s 고정
/// 타임아웃을 구조적으로 초과("응답이 너무 오래 걸려 중단했습니다"). 청크 분할로
/// 요청당 출력을 상한한다. 스킴 제안은 출력이 버킷 몇 줄이라 무관(실증: 성공).
final class CleanupChunkingTests: XCTestCase {

    // MARK: 가짜 Claude — 호출 기록 + 요청된 청크의 파일들을 전부 배정해 돌려준다.

    private actor FakeClaude: ClaudeAsking {
        private(set) var calls: [(prompt: String, context: String)] = []
        /// 이 이름들엔 낮은 confidence를 부여(2차 재배정 유도).
        let lowConfidenceNames: Set<String>
        let bucketId: String

        init(bucketId: String, lowConfidenceNames: Set<String> = []) {
            self.bucketId = bucketId
            self.lowConfidenceNames = lowConfidenceNames
        }

        func ask(prompt: String, context: String) async throws -> String {
            calls.append((prompt, context))
            // context(indexedMetadataList)의 [i] 목록으로 인덱스 배정 JSON 생성
            // (실 응답 계약과 동일 — 파일명 반복 없이 i만).
            let items = Self.indexedItems(fromContext: context)
            let entries = items.map { item in
                let conf = lowConfidenceNames.contains(item.name) ? 0.3 : 0.9
                return "{\"i\":\(item.index),\"id\":\"\(bucketId)\",\"reason\":\"t\",\"confidence\":\(conf)}"
            }
            return "{\"assignments\":[\(entries.joined(separator: ","))]}"
        }

        func callCount() -> Int { calls.count }
        func contexts() -> [String] { calls.map(\.context) }

        /// indexedMetadataList 줄에서 (인덱스, 파일명) 추출("[i] 이름 | …" 형식 —
        /// 형식이 바뀌면 테스트가 알려준다).
        static func indexedItems(fromContext context: String) -> [(index: Int, name: String)] {
            context.split(separator: "\n").compactMap { line in
                guard line.hasPrefix("["),
                      let close = line.firstIndex(of: "]"),
                      let index = Int(line[line.index(after: line.startIndex)..<close]) else { return nil }
                let rest = line[line.index(close, offsetBy: 2)...]
                guard let name = rest.split(separator: " ").first.map(String.init) else { return nil }
                return (index, name)
            }
        }
    }

    private func makeMetas(_ count: Int, dir: URL) -> [FileMeta] {
        (0..<count).map { i in
            let name = String(format: "file_%03d.md", i)
            return FileMeta(url: dir.appendingPathComponent(name), name: name, ext: "md",
                            size: 100, createdAt: Date(timeIntervalSince1970: 0),
                            modifiedAt: Date(timeIntervalSince1970: 0))
        }
    }

    private let scheme: CleanupScheme = [
        CleanupBucket(id: "docs", name: "docs", hint: "문서", relativePath: "docs")
    ]

    // MARK: 순수 청크 분할

    func testChunkedSplitsPreservingOrder() {
        let items = Array(1...200)
        let chunks = CleanupPlanner.chunked(items, size: 80)
        XCTAssertEqual(chunks.map(\.count), [80, 80, 40])
        XCTAssertEqual(chunks.flatMap { $0 }, items, "순서 보존·유실 없음")
    }

    func testChunkedEdges() {
        XCTAssertEqual(CleanupPlanner.chunked([Int](), size: 80).count, 0, "빈 입력 → 빈 결과")
        XCTAssertEqual(CleanupPlanner.chunked([1, 2], size: 80), [[1, 2]], "size 이하 → 한 청크")
        XCTAssertEqual(CleanupPlanner.chunked([1, 2, 3], size: 1), [[1], [2], [3]])
    }

    // MARK: 배정 청크 호출

    /// 회귀 핵심: 200개 파일 배정이 한 방(1회 호출)이 아니라 청크(80)당 1회로 나뉘어야 한다.
    func testAssignSplitsIntoChunkedCalls() async throws {
        let dir = URL(fileURLWithPath: "/tmp/cleanup-chunk-test")
        let metas = makeMetas(200, dir: dir)
        let fake = FakeClaude(bucketId: "docs")
        let service = CleanupService(claude: fake, kordoc: KordocService())

        let assignments = try await service.assign(scheme: scheme, metas: metas)

        let count = await fake.callCount()
        XCTAssertEqual(count, 3, "200개·청크 80 → 1차 배정 3회 호출(80/80/40)")
        XCTAssertEqual(assignments.count, 200, "전 파일 배정 병합")
        XCTAssertEqual(assignments.map(\.fileURL), metas.map(\.url), "청크 병합이 원 순서 보존")

        // 각 청크 context에 그 청크 파일만 실렸는지(입력도 상한).
        let contexts = await fake.contexts()
        let sizes = contexts.map { FakeClaude.indexedItems(fromContext: $0).count }
        XCTAssertEqual(sizes, [80, 80, 40])
    }

    /// 진행 콜백: 청크마다 1회, (완료 순서, 전체 수) 전달.
    func testAssignReportsProgressPerChunk() async throws {
        let dir = URL(fileURLWithPath: "/tmp/cleanup-chunk-test")
        let metas = makeMetas(170, dir: dir)
        let fake = FakeClaude(bucketId: "docs")
        let service = CleanupService(claude: fake, kordoc: KordocService())

        let progress = ProgressRecorder()
        _ = try await service.assign(scheme: scheme, metas: metas) { done, total in
            Task { await progress.record(done: done, total: total) }
        }
        // 콜백 Task 착지 대기(콜백은 시작 전 호출이라 총 3회: 1/3, 2/3, 3/3).
        try await Task.sleep(nanoseconds: 200_000_000)
        let recorded = await progress.entries
        XCTAssertEqual(recorded.map(\.done), [1, 2, 3])
        XCTAssertEqual(Set(recorded.map(\.total)), [3])
    }

    private actor ProgressRecorder {
        var entries: [(done: Int, total: Int)] = []
        func record(done: Int, total: Int) { entries.append((done, total)) }
    }

    // MARK: 인덱스 기반 응답 파싱(출력 압축 — 긴 한글 파일명 반복 제거)

    /// i가 있으면 인덱스로 매칭(청크-로컬), 범위 밖 i는 버린다. name 폴백도 여전히 동작.
    func testParseAssignmentsIndexForm() {
        let dir = URL(fileURLWithPath: "/tmp/cleanup-chunk-test")
        let metas = makeMetas(3, dir: dir)
        let out = """
        {"assignments":[
          {"i":0,"id":"docs","reason":"a","confidence":0.9},
          {"i":2,"id":"docs","reason":"b","confidence":0.8},
          {"i":9,"id":"docs","reason":"범위밖","confidence":1.0},
          {"name":"file_001.md","id":"docs","reason":"이름폴백","confidence":0.7}
        ]}
        """
        let a = CleanupPlanner.parseAssignments(out, scheme: scheme, metadata: metas)
        XCTAssertEqual(a?.count, 3, "범위 밖 인덱스는 버림, i 2건+name 폴백 1건")
        XCTAssertEqual(a?[0].fileURL, metas[0].url)
        XCTAssertEqual(a?[1].fileURL, metas[2].url)
        XCTAssertEqual(a?[2].fileURL, metas[1].url, "name 폴백 매칭")
    }

    /// 배정 프롬프트가 인덱스 목록·i 응답 계약·reason 길이 제한을 담는다.
    func testAssignPromptUsesIndexContract() {
        let dir = URL(fileURLWithPath: "/tmp/cleanup-chunk-test")
        let p = CleanupPlanner.buildAssignPrompt(scheme: scheme, metadata: makeMetas(2, dir: dir))
        XCTAssertTrue(p.contains("[0] file_000.md"), "인덱스 목록")
        XCTAssertTrue(p.contains("\"i\":0"), "i 응답 계약")
        XCTAssertTrue(p.contains("15자 이내"), "reason 길이 제한")
    }
}
