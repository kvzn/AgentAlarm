public enum AgentNames {
    public static let supported = ["claude", "codex", "gemini", "opencode"]

    public static func displayName(for agent: String) -> String {
        switch agent {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "gemini": return "Gemini CLI"
        case "opencode": return "OpenCode"
        default: return agent
        }
    }
}
