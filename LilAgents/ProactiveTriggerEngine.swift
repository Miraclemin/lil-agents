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

    // MARK: - Event Handlers (called by ScreenObserver)

    func clipboardChanged(content: String) {
        guard canTrigger(type: "clipboard") else { return }
        guard let suggestion = makeClipboardSuggestion(content: content) else { return }
        fire(suggestion: suggestion)
    }

    func appSwitched(to appName: String) {
        // No immediate trigger — wait for the 3-min context check
    }

    func appContextAvailable(appName: String, content: AccessibleContent) {
        let key = "appContext_\(appName.lowercased())"
        guard canTrigger(type: key) else { return }
        guard let suggestion = makeAppContextSuggestion(appName: appName, content: content) else { return }
        fire(suggestion: suggestion)
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
        let lower = appName.lowercased()
        let title = content.windowTitle

        if lower.contains("xcode") || lower.contains("android studio") || lower.contains("cursor") {
            let titleLower = title.lowercased()
            if titleLower.contains("error") || titleLower.contains("failed") || titleLower.contains("warning") {
                return ProactiveSuggestion(
                    bubbleText: "遇到报错了？",
                    promptText: "我在用 \(appName) 开发，当前窗口提示 \"\(title)\"，帮我分析一下可能是什么问题，怎么解决",
                    typeKey: "appContext_\(lower)"
                )
            }
            return ProactiveSuggestion(
                bubbleText: "需要帮忙吗？",
                promptText: "我在用 \(appName) 开发，当前工作在 \"\(title)\"，有什么可以帮你的？",
                typeKey: "appContext_\(lower)"
            )
        }

        if lower.contains("mail") || lower.contains("outlook") || lower.contains("spark") {
            return ProactiveSuggestion(
                bubbleText: "帮你写邮件？",
                promptText: "我在写邮件，帮我起草一段专业、简洁的回复内容",
                typeKey: "appContext_\(lower)"
            )
        }

        if lower.contains("notion") || lower.contains("obsidian") || lower.contains("typora") || lower.contains("bear") {
            return ProactiveSuggestion(
                bubbleText: "帮你整理思路？",
                promptText: "我在写文档，标题是 \"\(title)\"，帮我梳理一下内容结构或者补充一些想法",
                typeKey: "appContext_\(lower)"
            )
        }

        if lower.contains("keynote") || lower.contains("powerpoint") || lower.contains("canva") {
            return ProactiveSuggestion(
                bubbleText: "要优化内容吗？",
                promptText: "我在做演示文稿 \"\(title)\"，帮我检查和优化文案，让表达更清晰",
                typeKey: "appContext_\(lower)"
            )
        }

        if lower.contains("terminal") || lower.contains("iterm") || lower.contains("warp") {
            return ProactiveSuggestion(
                bubbleText: "需要命令帮助？",
                promptText: "我在使用终端 \"\(title)\"，有什么命令或者操作需要帮忙吗？",
                typeKey: "appContext_\(lower)"
            )
        }

        return nil
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

    private func fire(suggestion: ProactiveSuggestion) {
        let now = Date()
        lastTriggerTime = now
        lastTriggerTypeTime[suggestion.typeKey] = now

        DispatchQueue.main.async { [weak self] in
            guard let controller = self?.controller else { return }
            // Pick first character that is visible, not in chat, and not already showing a suggestion
            let target = controller.characters.first {
                $0.isManuallyVisible && !$0.isIdleForPopover && $0.pendingProactiveSuggestion == nil
            }
            target?.showProactiveSuggestion(suggestion)
        }
    }
}
