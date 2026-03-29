import Foundation

/// Stores the user-configured persona that gets injected into Claude's system prompt.
class PersonaConfig {
    private static let nameKey        = "personaName"
    private static let descriptionKey = "personaDescription"

    static var name: String {
        get { UserDefaults.standard.string(forKey: nameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: nameKey) }
    }

    static var personalityDescription: String {
        get { UserDefaults.standard.string(forKey: descriptionKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: descriptionKey) }
    }

    /// Returns the full system prompt string to pass to Claude, or nil if no persona is set.
    static var systemPromptString: String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = personalityDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty || !d.isEmpty else { return nil }

        var parts: [String] = []
        if !n.isEmpty { parts.append("你的名字是\(n)。") }
        if !d.isEmpty { parts.append("你的性格特点：\(d)。") }
        parts.append("你是用户的桌面AI伴侣，陪在用户Mac屏幕的下方。用自然、口语化的语气和用户交流，不需要过于正式。除非用户需要，否则回答要简洁。")

        return parts.joined(separator: " ")
    }

    static var isConfigured: Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = personalityDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return !n.isEmpty || !d.isEmpty
    }
}
