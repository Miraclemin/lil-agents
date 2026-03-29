import Foundation
import AppKit

// MARK: - ProactiveSuggestion

struct ProactiveSuggestion {
    /// Short question shown in the proactive bubble above the character.
    let bubbleText: String
    /// Full prompt that gets sent to Claude when the user accepts.
    let promptText: String
    /// Identifier used for per-type cooldown tracking.
    let typeKey: String
}

// MARK: - ProactiveTriggerEngine

/// Layer 3: Decision logic — turns raw events from ScreenObserver into ProactiveSuggestions.
/// All decisions are made locally; Claude is only called when the user accepts a suggestion.
class ProactiveTriggerEngine {
    weak var controller: LilAgentsController?

    // Cooldown: 10 s between any trigger; 30 s per trigger type
    private var lastTriggerTime: Date = .distantPast
    private var lastTriggerTypeTime: [String: Date] = [:]
    private let globalCooldown: TimeInterval  = 10
    private let typeCooldown:   TimeInterval  = 30

    // Round-robin index for proactive triggers
    private var lastProactiveIndex: Int = 0

    // MARK: - Event Handlers (called by ScreenObserver)

    func clipboardChanged(content: String) {
        // No cooldown for clipboard — every copy that matches a rule fires immediately.
        guard let suggestion = makeClipboardSuggestion(content: content) else { return }
        fire(suggestion: suggestion, allowReplace: true)
    }

    func clipboardImageChanged() {
        let suggestion = ProactiveSuggestion(
            bubbleText: "截图了？帮你看看",
            promptText: "我刚截了一张图，描述一下截图里有什么内容，或者告诉我你想问什么，我来帮你分析",
            typeKey: "clipboard_image"
        )
        fire(suggestion: suggestion, allowReplace: true)
    }

    func appSwitched(to appName: String) {
        // No immediate trigger — wait for the 3-min context check
    }

    func appContextAvailable(appName: String, content: AccessibleContent) {
        let key = "appContext_\(appName.lowercased())"
        guard canTrigger(type: key) else { return }
        guard let suggestion = makeAppContextSuggestion(appName: appName, content: content) else { return }
        fire(suggestion: suggestion, allowReplace: false)
    }

    // MARK: - Clipboard Suggestions

    private func makeClipboardSuggestion(content: String) -> ProactiveSuggestion? {
        // Skip file paths and very short single-word copies
        guard !content.hasPrefix("/"), content.contains(" ") || content.count > 60 else { return nil }

        let charCount = content.count
        let wordCount = content.split(separator: " ").count

        let hasChineseChars = content.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value) || (0x3040...0x30FF).contains($0.value)
        }
        let looksEnglish = content.range(of: "[a-zA-Z]{3,}", options: .regularExpression) != nil

        // 1. Long text (any language) → summarize. Check FIRST so long English
        //    text doesn't fall into the translation branch below.
        if wordCount > 80 || charCount > 400 {
            return ProactiveSuggestion(
                bubbleText: "帮你总结？",
                promptText: "帮我用几句话总结这段内容的核心要点：\n\n\(content)",
                typeKey: "clipboard"
            )
        }

        // 2. Code snippet → explain
        let codeIndicators = ["{", "}", "=>", "func ", "def ", "class ", "import ", "var ", "let ", "const "]
        let looksLikeCode = codeIndicators.contains { content.contains($0) } && charCount > 40
        if looksLikeCode {
            return ProactiveSuggestion(
                bubbleText: "解释这段代码？",
                promptText: "帮我解释这段代码在做什么：\n\n```\n\(content)\n```",
                typeKey: "clipboard"
            )
        }

        // 3. Short English text → translate
        if looksEnglish && !hasChineseChars && charCount > 30 {
            return ProactiveSuggestion(
                bubbleText: "翻译一下？",
                promptText: "帮我翻译这段文字（保持原意，用中文）：\n\n\(content)",
                typeKey: "clipboard"
            )
        }

        return nil
    }

    // MARK: - App Context Suggestions

    private func makeAppContextSuggestion(appName: String, content: AccessibleContent) -> ProactiveSuggestion? {
        guard let rule = AppContextSettings.matchingRule(for: appName) else { return nil }
        let lower = appName.lowercased()
        let title = content.windowTitle
        let text  = content.bestAvailableText  // selected text, or visible element text

        func expand(_ template: String) -> String {
            var result = template
                .replacingOccurrences(of: "%app%", with: appName)
                .replacingOccurrences(of: "%title%", with: title)
            if !text.isEmpty {
                result += "\n\n当前内容：\n```\n\(text)\n```"
            }
            return result
        }

        // Terminal: if there's visible text, offer a "explain / help" suggestion
        if rule.id == "terminal" && !text.isEmpty {
            return ProactiveSuggestion(
                bubbleText: "需要命令帮助？",
                promptText: "我在终端里执行了以下内容，帮我解释或提供建议：\n```\n\(text)\n```",
                typeKey: "appContext_\(lower)"
            )
        }

        // IDE: prefer error-specific suggestion if window title or visible text signals an error
        if rule.id == "ide" && rule.suggestions.count >= 2 {
            let titleLower = title.lowercased()
            let textLower  = text.lowercased()
            let hasError = ["error", "failed", "warning"].contains {
                titleLower.contains($0) || textLower.contains($0)
            }
            if hasError {
                let s = rule.suggestions[0]
                return ProactiveSuggestion(bubbleText: s.bubble, promptText: expand(s.prompt), typeKey: "appContext_\(lower)")
            }
            let s = rule.suggestions[1]
            return ProactiveSuggestion(bubbleText: s.bubble, promptText: expand(s.prompt), typeKey: "appContext_\(lower)")
        }

        // Browser: skip if the window title is empty or equals the app name
        // (means no page is loaded / new-tab page)
        if rule.id == "browser" {
            let cleanTitle = title
                .replacingOccurrences(of: "— Safari", with: "")
                .replacingOccurrences(of: "- Google Chrome", with: "")
                .replacingOccurrences(of: "— Mozilla Firefox", with: "")
                .replacingOccurrences(of: "- Microsoft Edge", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !cleanTitle.isEmpty,
                  cleanTitle.lowercased() != appName.lowercased() else { return nil }

            // If we have actual page text, build a richer prompt
            if !text.isEmpty {
                let truncated = String(text.prefix(2000))
                return ProactiveSuggestion(
                    bubbleText: "帮你解释这个？",
                    promptText: "我在浏览器里看这个页面：「\(cleanTitle)」\n\n以下是页面的主要内容：\n\n\(truncated)\n\n请帮我解释关键内容，或者我有问题可以直接问你",
                    typeKey: "appContext_\(lower)"
                )
            }

            // No page text — fall back to title-only suggestion
            let s = rule.suggestions[0]
            return ProactiveSuggestion(bubbleText: s.bubble, promptText: expand(s.prompt), typeKey: "appContext_\(lower)")
        }

        let s = rule.suggestions[0]
        return ProactiveSuggestion(bubbleText: s.bubble, promptText: expand(s.prompt), typeKey: "appContext_\(lower)")
    }

    // MARK: - Cooldown

    private func canTrigger(type: String) -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastTriggerTime) >= globalCooldown else { return false }
        if let last = lastTriggerTypeTime[type],
           now.timeIntervalSince(last) < typeCooldown { return false }
        return true
    }

    // MARK: - Fire

    /// - parameter allowReplace: When true the suggestion replaces any existing
    ///   bubble that hasn't been acted on yet (used for clipboard events).
    private func fire(suggestion: ProactiveSuggestion, allowReplace: Bool) {
        let now = Date()
        lastTriggerTime = now
        lastTriggerTypeTime[suggestion.typeKey] = now

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let controller = self.controller else { return }
            let eligible = controller.characters.filter { $0.window.isVisible && $0.isManuallyVisible && !$0.isIdleForPopover }
            guard !eligible.isEmpty else { return }

            // Round-robin: pick the next character in rotation
            let idx = self.lastProactiveIndex % eligible.count
            self.lastProactiveIndex = (idx + 1) % eligible.count
            let candidate = eligible[idx]

            let target: WalkerCharacter?
            if candidate.pendingProactiveSuggestion == nil {
                target = candidate
            } else if allowReplace {
                target = candidate
            } else {
                // Candidate is busy and we can't replace — try others
                target = eligible.first { $0.pendingProactiveSuggestion == nil }
            }
            target?.showProactiveSuggestion(suggestion)
        }
    }
}
