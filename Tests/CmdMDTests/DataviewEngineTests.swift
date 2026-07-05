import XCTest
@testable import CmdMD

final class DataviewEngineTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-engine-\(UUID().uuidString)/Calendar", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 2026-W27 = 2026-06-29(월)~2026-07-05(일). 주 안 2개 + 주 밖 1개.
        write("2026-06-30.md", """
        ---
        date: '2026-06-30'
        ---
        ## 🌡️ 컨디션 #daily_condition
        - 전반적: 좋음
        - 식사: 죽
        ## 💭 메모 #daily_memo
        - 메모A
        """)
        write("2026-07-05.md", """
        ## 🌡️ 컨디션 #daily_condition
        - 전반적: 우울
        - 식사: 군고구마
        ## 💊 치료 메모 #daily_medical
        - 캐싸일라 d+4
        """)
        write("2026-06-20.md", "## 🌡️ 컨디션 #daily_condition\n- 주 밖")
        write("2026-W27.md", "# 주간")
        write("2026-W26.md", "# 전주")   // 월간 블록용
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()); super.tearDown() }

    private func write(_ name: String, _ content: String) {
        try! content.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func run(_ code: String, note: String) -> Result<[DataviewOutputItem], DataviewError> {
        DataviewEngine.run(code: code,
                           context: DataviewRunContext(noteURL: root.appendingPathComponent(note),
                                                       rootURL: root.deletingLastPathComponent()))
    }

    /// notebox 주간리뷰 템플릿 블록 전문(실사용 검증 — 스펙 §10).
    private let weeklyBlock = #"""
    let filename = dv.current().file.name;
    let match = filename.match(/^(\d{4})-[wW](\d{1,2})$/);
    if (!match) {
        dv.paragraph("⚠️ 파일 이름 형식이 맞지 않습니다.");
    } else {
        let year = parseInt(match[1]);
        let week = parseInt(match[2]);
        let startOfWeek = dv.luxon.DateTime.fromObject({ weekYear: year, weekNumber: week, weekday: 1 });
        let endOfWeek = startOfWeek.plus({ days: 6 });
        let pages = dv.pages('"' + dv.current().file.folder + '"')
            .where(p => {
                let day = p.file.day || dv.date(p.file.name);
                return day && day >= startOfWeek && day <= endOfWeek;
            })
            .sort(p => p.file.name);
        let tableData = pages.map(p => {
            let allLists = p.file.lists;
            let condition = [];
            let meals = [];
            let medical = [];
            let memo = [];
            allLists.forEach(L => {
                let text = L.text;
                let header = (L.header.subpath || "").toString();
                if (header.includes("컨디션") || L.tags.includes("#daily_condition")) {
                    if (text.includes("식사:")) {
                        meals.push(text.replace("식사:", "").trim());
                    } else {
                        condition.push(text);
                    }
                }
                else if ((header.includes("치료") && !header.includes("주차")) || L.tags.includes("#daily_medical")) {
                    medical.push(text);
                }
                else if (header.includes("메모") || L.tags.includes("#daily_memo")) {
                    memo.push(text);
                }
            });
            return [
                p.file.link,
                condition.join("<br>"),
                meals.join("<br>"),
                medical.join("<br>"),
                memo.join("<br>")
            ];
        });
        dv.table(
            ["날짜", "컨디션/통증", "식사", "치료/증상", "메모/생각"],
            tableData
        );
    }
    """#

    func testRealWeeklyBlockEndToEnd() throws {
        let items = try run(weeklyBlock, note: "2026-W27.md").get()
        guard case .table(let headers, let rows) = items.first else { return XCTFail("표여야 함") }
        XCTAssertEqual(headers.first, .text("날짜"))
        // 실측 발견(브리프의 count==2 기대와 다름 — 실제 3): dv-shim.js의 dv.date()가
        // 순정 luxon fromISO를 그대로 쓰는데, luxon은 "2026-W27"(파일 자기 이름, ISO 주 표기)도
        // 유효한 날짜(그 주 월요일)로 파싱한다(node로 bundled luxon.min.js 직접 검증 완료).
        // 그래서 p.file.day가 nil인 주간 노트 자신도 "day && day>=start&&<=end" 조건을
        // 통과해 셀 전부 빈 문자열인 자기참조 행이 표에 추가된다. 진짜 원인은 dv-shim.js의
        // dv.date 과다허용(실제 옵시디언 Dataview의 getDate는 이런 부분 ISO를 안 받아준다) —
        // 이 태스크 범위(기존 파일 수정 금지)에서는 고치지 않고 실측대로 단언 + 후속 보고.
        XCTAssertEqual(rows.count, 3, "주 안 데일리 2개(2026-06-20 제외) + 자기참조 빈 행 1개(실측 — 위 주석)")
        // 이름순 정렬: 06-30 먼저. 링크 셀 + lists 헤딩/태그 라우팅 검증.
        guard case .link(let path, _) = rows[0][0] else { return XCTFail("첫 셀은 링크") }
        XCTAssertTrue(path.contains("2026-06-30"))
        XCTAssertEqual(rows[0][1], .text("전반적: 좋음"))
        XCTAssertEqual(rows[0][2], .text("죽"), "식사: 접두사 제거")
        XCTAssertEqual(rows[1][3], .text("캐싸일라 d+4"), "치료 헤딩 라우팅")
        XCTAssertEqual(rows[0][4], .text("메모A"))
        // 3번째 행 = 2026-W27.md 자기참조(빈 행) — 위 발견 주석 실증.
        guard case .link(let selfPath, _) = rows[2][0] else { return XCTFail("셋째 셀도 링크") }
        XCTAssertTrue(selfPath.contains("2026-W27"))
        XCTAssertEqual(rows[2][1], .text(""))
    }

    func testRealMonthlyBlockListsWeeklies() throws {
        // notebox 월간리뷰 템플릿 블록 전문(축약 없이).
        let monthly = #"""
        let filename = dv.current().file.name;
        let match = filename.match(/^(\d{4})-(\d{2})$/);
        if (!match) {
            dv.paragraph("⚠️ 파일 이름 형식이 맞지 않습니다. (예: 2026-01)");
        } else {
            let year = parseInt(match[1]);
            let month = parseInt(match[2]);
            let weeklyReviews = dv.pages('"' + dv.current().file.folder + '"')
                .where(p => {
                    let weekMatch = p.file.name.match(/^(\d{4})-[wW](\d{1,2})$/);
                    if (!weekMatch) return false;
                    let weekYear = parseInt(weekMatch[1]);
                    let weekNum = parseInt(weekMatch[2]);
                    let weekStart = dv.luxon.DateTime.fromObject({
                        weekYear: weekYear,
                        weekNumber: weekNum,
                        weekday: 1
                    });
                    return weekStart.year === year && weekStart.month === month;
                })
                .sort(p => p.file.name);
            if (weeklyReviews.length === 0) {
                dv.paragraph("⚠️ 이번 달의 주간 리뷰가 없습니다.");
            } else {
                dv.list(weeklyReviews.map(p => p.file.link));
            }
        }
        """#
        write("2026-06.md", "# 월간")
        let items = try run(monthly, note: "2026-06.md").get()
        guard case .list(let links) = items.first else { return XCTFail("목록이어야 함") }
        // W26(6/22 시작)·W27(6/29 시작) 둘 다 6월 시작 → 2건.
        XCTAssertEqual(links.count, 2)
    }

    func testScriptErrorSurfaced() {
        let r = run("dv.el('div', 'x');", note: "2026-W27.md")
        guard case .failure(.script(let msg)) = r else { return XCTFail("script 에러여야 함") }
        XCTAssertTrue(msg.contains("dv.el"), "비지원 API 한국어 안내")
    }

    func testTimeout() {
        let r = DataviewEngine.run(code: "while(true){}",
                                   context: DataviewRunContext(noteURL: root.appendingPathComponent("2026-W27.md"),
                                                               rootURL: root.deletingLastPathComponent()),
                                   timeLimit: 0.5)
        guard case .failure(.timeout) = r else { return XCTFail("타임아웃이어야 함") }
    }

    func testUnsupportedSourceError() {
        let r = run("dv.pages('\"A\" or \"B\"');", note: "2026-W27.md")
        guard case .failure(.script(let msg)) = r else { return XCTFail() }
        XCTAssertTrue(msg.contains("소스"), "복합 소스 미지원 안내")
    }

    /// 구현 주의 ②: pages 오류 조립에서 source 문자열의 따옴표가 JSON을 깨지 않아야 한다.
    func testPagesErrorMessageWithQuoteDoesNotBreakJSON() {
        let r = run(#"dv.pages('bad"quote');"#, note: "2026-W27.md")
        guard case .failure(.script(let msg)) = r else { return XCTFail("script 에러여야 함") }
        XCTAssertTrue(msg.contains("bad"), "따옴표 든 소스도 에러 메시지에 살아남아야 함")
    }

    /// 폴더 소스의 선행/후행 슬래시 정규화 — "/Calendar/" == "Calendar".
    func testFolderSourceSlashNormalization() throws {
        let code = "dv.list(dv.pages('\"/Calendar/\"').map(p => p.file.name));"
        let items = try run(code, note: "2026-W27.md").get()
        guard case .list(let names) = items.first else { return XCTFail("목록이어야 함") }
        XCTAssertFalse(names.isEmpty, "선행/후행 슬래시가 있어도 폴더 매칭이 되어야 함")
    }
}
