import Foundation

/// Persists user preferences for the Smart Suggestions (proactive) feature.
class AppContextSettings {

    // MARK: - Context Timer

    private static let timerKey = "contextTimerDuration"

    /// Seconds to wait in the same app before checking context.
    static var timerDuration: TimeInterval {
        get {
            let v = UserDefaults.standard.double(forKey: timerKey)
            return v > 0 ? v : 15
        }
        set { UserDefaults.standard.set(newValue, forKey: timerKey) }
    }

    static let timerOptions: [(label: String, seconds: TimeInterval)] = [
        ("15 seconds", 15),
        ("30 seconds", 30),
        ("1 minute",   60),
        ("3 minutes",  180),
        ("5 minutes",  300)
    ]

    // MARK: - App Rules

    struct AppRule {
        let id: String
        let displayName: String
        let keywords: [String]
        /// Prompt templates: (bubbleText, promptTemplate).
        /// Use %app% for app name, %title% for window title.
        let suggestions: [(bubble: String, prompt: String)]
    }

    static let allRules: [AppRule] = [
        AppRule(
            id: "ide",
            displayName: "Xcode / Cursor / VS Code",
            keywords: ["xcode", "cursor", "visual studio code", "android studio"],
            suggestions: [
                ("遇到报错了？",  "我在用 %app% 开发，窗口提示 \"%title%\"，帮我分析可能是什么问题"),
                ("需要帮忙吗？",  "我在用 %app% 开发，当前工作在 \"%title%\"，有什么可以帮忙的？")
            ]
        ),
        AppRule(
            id: "email",
            displayName: "Mail / Outlook / Spark",
            keywords: ["mail", "邮件", "outlook", "spark"],
            suggestions: [
                ("帮你写邮件？", "我在写邮件，帮我起草一段专业、简洁的回复内容")
            ]
        ),
        AppRule(
            id: "notes",
            displayName: "Notion / Obsidian / Bear",
            keywords: ["notion", "obsidian", "typora", "bear", "备忘录"],
            suggestions: [
                ("帮你整理思路？", "我在写文档 \"%title%\"，帮我梳理内容结构或补充想法")
            ]
        ),
        AppRule(
            id: "slides",
            displayName: "Keynote / PowerPoint / Canva",
            keywords: ["keynote", "powerpoint", "canva"],
            suggestions: [
                ("要优化内容吗？", "我在做演示文稿 \"%title%\"，帮我优化文案，让表达更清晰")
            ]
        ),
        AppRule(
            id: "terminal",
            displayName: "Terminal / iTerm / Warp",
            keywords: ["terminal", "终端", "iterm", "warp"],
            suggestions: [
                ("需要命令帮助？", "我在使用终端 \"%title%\"，有什么命令或操作需要帮忙吗？")
            ]
        ),
        AppRule(
            id: "browser",
            displayName: "Safari / Chrome / Firefox / Arc",
            keywords: ["safari", "chrome", "firefox", "arc", "edge", "brave", "opera"],
            suggestions: [
                ("帮你解释这个？", "我在浏览器里看这个页面：\"%title%\"，帮我介绍一下这个主题或解答相关问题")
            ]
        )
    ]

    private static let enabledAppsKey = "contextEnabledApps"

    private static var enabledIds: [String] {
        UserDefaults.standard.stringArray(forKey: enabledAppsKey) ?? allRules.map { $0.id }
    }

    static func isRuleEnabled(_ id: String) -> Bool { enabledIds.contains(id) }

    static func setRuleEnabled(_ id: String, enabled: Bool) {
        var current = enabledIds
        if enabled { if !current.contains(id) { current.append(id) } }
        else        { current.removeAll { $0 == id } }
        UserDefaults.standard.set(current, forKey: enabledAppsKey)
    }

    /// Returns the matching enabled rule for `appName`, or nil if none match / all disabled.
    static func matchingRule(for appName: String) -> AppRule? {
        let lower = appName.lowercased()
        return allRules.first { rule in
            isRuleEnabled(rule.id) && rule.keywords.contains { lower.contains($0) }
        }
    }
}
