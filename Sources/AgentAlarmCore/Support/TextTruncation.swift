public enum TextTruncation {
    /// 按字素截断，超出时追加"…"。
    public static func truncate(_ text: String, to maxGraphemes: Int) -> String {
        guard text.count > maxGraphemes else { return text }
        return String(text.prefix(maxGraphemes)) + "…"
    }

    /// 取第一行非空文本并去掉首尾空白。
    public static func firstLine(_ text: String) -> String {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}
