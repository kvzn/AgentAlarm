import Testing
@testable import AgentAlarmCore

@Suite struct TextTruncationTests {
    @Test func shortTextUnchanged() {
        #expect(TextTruncation.truncate("你好", to: 40) == "你好")
    }
    @Test func longTextCutAtGraphemeWithEllipsis() {
        let text = String(repeating: "字", count: 50)
        let cut = TextTruncation.truncate(text, to: 40)
        #expect(cut.count == 41)
        #expect(cut.hasSuffix("…"))
    }
    @Test func combinedEmojiNotSplit() {
        let flag = "👨‍👩‍👧"
        let text = "ab" + flag + "cd"
        #expect(TextTruncation.truncate(text, to: 3) == "ab" + flag + "…")
    }
    @Test func firstLineTrimsWhitespace() {
        #expect(TextTruncation.firstLine("  第一行 \n第二行") == "第一行")
        #expect(TextTruncation.firstLine("\n\n只有一行") == "只有一行")
    }
    @Test func jsonAccessHelpers() {
        let dict: [String: Any] = ["a": "x", "b": ["c": 1], "d": [1, 2], "e": true]
        #expect(dict.string("a") == "x")
        #expect(dict.string("zz") == nil)
        #expect(dict.dictionary("b")?["c"] as? Int == 1)
        #expect(dict.array("d")?.count == 2)
        #expect(dict.bool("e") == true)
    }
}
