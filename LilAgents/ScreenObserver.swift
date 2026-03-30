import AppKit
import ApplicationServices

// MARK: - Accessible Content

struct AccessibleContent {
    var appName: String = ""
    var windowTitle: String = ""
    var selectedText: String = ""
    /// Best-effort visible/typed text from the focused element (e.g. terminal buffer,
    /// source editor). Populated only when selectedText is empty.
    var visibleText: String = ""

    /// Returns selectedText if non-empty, otherwise visibleText.
    var bestAvailableText: String {
        selectedText.isEmpty ? visibleText : selectedText
    }
}

// MARK: - ScreenObserver

/// Layer 1: System event monitoring (clipboard, app switches) — zero API cost.
/// Layer 2: Accessibility API text extraction — also zero API cost.
class ScreenObserver {
    weak var engine: ProactiveTriggerEngine?

    private var clipboardChangeCount: Int = 0
    private var clipboardTimer: Timer?
    private var lastActiveApp: String = ""
    private var appContextTimer: Timer?

    // MARK: - Accessibility Permissions

    /// Requests accessibility permission from macOS if not already granted.
    /// Shows the system prompt once; subsequent calls are no-ops.
    static func requestAccessibilityPermissionIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Start / Stop

    func start() {
        clipboardChangeCount = NSPasteboard.general.changeCount

        // Poll clipboard every 1.5 s — lightweight, changeCount comparison only
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    func stop() {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        appContextTimer?.invalidate()
        appContextTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Layer 1: Clipboard

    private func checkClipboard() {
        let current = NSPasteboard.general.changeCount
        guard current != clipboardChangeCount else { return }
        clipboardChangeCount = current

        // Image in clipboard (screenshot or copied image) — check before text
        if NSImage(pasteboard: NSPasteboard.general) != nil {
            engine?.clipboardImageChanged()
            return
        }

        guard let raw = NSPasteboard.general.string(forType: .string) else { return }
        let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.count > 15 else { return }

        engine?.clipboardChanged(content: content)
    }

    // MARK: - Layer 1: App Switch

    @objc private func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let name = app.localizedName,
              name != lastActiveApp else { return }

        lastActiveApp = name
        appContextTimer?.invalidate()
        appContextTimer = nil

        engine?.appSwitched(to: name)

        // After 15 seconds in the same app, do a context check (free via Accessibility API)
        let capturedName = name
        appContextTimer = Timer.scheduledTimer(withTimeInterval: AppContextSettings.timerDuration, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            guard let current = NSWorkspace.shared.frontmostApplication,
                  current.localizedName == capturedName else { return }

            let baseContent = self.getAccessibleContent()
            let isBrowser = AppContextSettings.matchingRule(for: capturedName)?.id == "browser"

            if isBrowser {
                // AppleScript is blocking — run on background thread
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self = self else { return }
                    let pageText = self.browserPageText(for: capturedName)
                    var content = baseContent
                    if let t = pageText { content.visibleText = t }
                    DispatchQueue.main.async {
                        self.engine?.appContextAvailable(appName: capturedName, content: content)
                    }
                }
            } else {
                self.engine?.appContextAvailable(appName: capturedName, content: baseContent)
            }
        }
    }

    // MARK: - Layer 2: Accessibility API

    func getAccessibleContent() -> AccessibleContent {
        var result = AccessibleContent()
        guard Self.hasAccessibilityPermission else { return result }
        guard let app = NSWorkspace.shared.frontmostApplication else { return result }

        result.appName = app.localizedName ?? ""
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // Window title — try three sources in order:
        // 1. Focused window (may be a panel with no title in complex apps like Xcode)
        // 2. Main window (the primary document window)
        // 3. First window in the windows list
        result.windowTitle = axWindowTitle(axApp, kAXFocusedWindowAttribute)
            ?? axWindowTitle(axApp, kAXMainWindowAttribute)
            ?? axWindowTitleFromList(axApp)
            ?? ""

        // Selected text and visible content from the focused element
        var elementRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &elementRef) == .success,
           let elementRef = elementRef {
            let axElement = elementRef as! AXUIElement

            var selRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axElement, kAXSelectedTextAttribute as CFString, &selRef) == .success {
                result.selectedText = (selRef as? String) ?? ""
            }

            // When nothing is selected, try the focused element's value first,
            // then fall back to a tree search for any visible text area.
            if result.selectedText.isEmpty {
                var valRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &valRef) == .success,
                   let raw = valRef as? String, !raw.isEmpty {
                    result.visibleText = String(raw.suffix(2000))
                } else {
                    // Focused element has no value — walk the window's AX tree to find
                    // the first text area (handles Xcode where focus is on a toolbar, etc.)
                    var winRef: CFTypeRef?
                    let winAttr = kAXFocusedWindowAttribute
                    if AXUIElementCopyAttributeValue(axApp, winAttr as CFString, &winRef) == .success,
                       let winRef = winRef {
                        let axWin = winRef as! AXUIElement
                        if let text = axTextAreaValue(in: axWin, maxDepth: 8) {
                            result.visibleText = String(text.suffix(2000))
                        }
                    }
                }
            }
        }

        return result
    }

    func getSelectedText() -> String {
        getAccessibleContent().selectedText
    }

    // MARK: - AX Helpers

    private func axWindowTitle(_ axApp: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, attribute as CFString, &ref) == .success,
              let ref = ref else { return nil }
        let axWin = ref as! AXUIElement
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &titleRef) == .success,
              let t = titleRef as? String, !t.isEmpty else { return nil }
        return t
    }

    /// Depth-first search for the first AXTextArea (or any element with a non-trivial
    /// string value) inside `root`. Returns the text value or nil.
    /// Skips subtrees deeper than `maxDepth` to stay fast.
    private func axTextAreaValue(in root: AXUIElement, maxDepth: Int) -> String? {
        guard maxDepth > 0 else { return nil }

        // Check this node's role and value
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(root, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""

        if role == kAXTextAreaRole || role == kAXTextFieldRole || role == "AXCodeEditor" {
            var valRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(root, kAXValueAttribute as CFString, &valRef) == .success,
               let text = valRef as? String, text.count > 30 {
                return text
            }
        }

        // Recurse into children via raw CF iteration (avoids bridging pitfalls)
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let childrenRef = childrenRef else { return nil }
        let cfArr = childrenRef as! CFArray
        let count = CFArrayGetCount(cfArr)
        for i in 0..<count {
            guard let rawPtr = CFArrayGetValueAtIndex(cfArr, i) else { continue }
            let child = Unmanaged<AXUIElement>.fromOpaque(rawPtr).takeUnretainedValue()
            if let found = axTextAreaValue(in: child, maxDepth: maxDepth - 1) {
                return found
            }
        }
        return nil
    }

    private func axWindowTitleFromList(_ axApp: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let ref = ref else { return nil }
        // CFArray does NOT bridge directly to [AXUIElement] — must use raw CF iteration
        let cfArr = ref as! CFArray
        let count = CFArrayGetCount(cfArr)
        for i in 0..<count {
            guard let rawPtr = CFArrayGetValueAtIndex(cfArr, i) else { continue }
            let axWin = Unmanaged<AXUIElement>.fromOpaque(rawPtr).takeUnretainedValue()
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &titleRef) == .success,
               let t = titleRef as? String, !t.isEmpty {
                return t
            }
        }
        return nil
    }

    // MARK: - Browser Page Content (AppleScript)

    /// Returns the URL of the active tab in the frontmost browser window.
    /// Safe to call from a background thread (spawns osascript as a child process).
    func browserPageText(for appName: String) -> String? {
        let lower = appName.lowercased()

        let script: String
        if lower.contains("safari") {
            script = """
                tell application "Safari"
                    if (count of windows) > 0 then
                        return URL of current tab of front window
                    end if
                end tell
            """
        } else if lower.contains("chrome") {
            script = """
                tell application "Google Chrome"
                    if (count of windows) > 0 then
                        return URL of active tab of first window
                    end if
                end tell
            """
        } else if lower.contains("arc") {
            script = """
                tell application "Arc"
                    if (count of windows) > 0 then
                        return URL of active tab of first window
                    end if
                end tell
            """
        } else if lower.contains("firefox") {
            script = """
                tell application "Firefox"
                    if (count of windows) > 0 then
                        return URL of active tab of first window
                    end if
                end tell
            """
        } else {
            return nil
        }

        guard let url = runOsascript(script) else { return nil }
        return "页面地址：\(url)"
    }

    private func runOsascript(_ source: String) -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", source]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError  = errPipe
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            NSLog("[LilAgents] osascript launch failed: \(error)")
            return nil
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        if let errText = String(data: errData, encoding: .utf8), !errText.isEmpty {
            NSLog("[LilAgents] osascript error: \(errText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        NSLog("[LilAgents] osascript output (\(text.count) chars): \(text.prefix(200))")
        return text.isEmpty ? nil : text
    }

    // MARK: - Diagnostic

    /// Directly tests browser page content fetch and shows result.
    func showBrowserDiagnostic() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            showAlert("Browser Diagnostic", "No frontmost application found.")
            return
        }
        let name = app.localizedName ?? "unknown"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = self.browserPageText(for: name) ?? "(nil — see Console.app for [LilAgents] logs)"
            DispatchQueue.main.async {
                self.showAlert("Browser Diagnostic — \(name)",
                               "Page text (\(result.count) chars):\n\n\(result.prefix(500))")
            }
        }
    }

    private func showAlert(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    /// Call from menu to show current AX status in an alert.
    func showDiagnostic() {
        let hasPerm = Self.hasAccessibilityPermission
        var lines: [String] = ["AX Permission: \(hasPerm ? "✅ granted" : "❌ NOT granted")"]

        if hasPerm, let app = NSWorkspace.shared.frontmostApplication {
            lines.append("Frontmost app: \(app.localizedName ?? "?")")
            let axApp = AXUIElementCreateApplication(app.processIdentifier)

            let focused  = axWindowTitle(axApp, kAXFocusedWindowAttribute) ?? "(none)"
            let main     = axWindowTitle(axApp, kAXMainWindowAttribute)    ?? "(none)"
            let fromList = axWindowTitleFromList(axApp)                     ?? "(none)"
            lines.append("Focused window title : \(focused)")
            lines.append("Main window title    : \(main)")
            lines.append("Window list title    : \(fromList)")

            // Focused element value (first 200 chars)
            var elemRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &elemRef) == .success,
               let elemRef = elemRef {
                let axEl = elemRef as! AXUIElement
                var valRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axEl, kAXValueAttribute as CFString, &valRef) == .success,
                   let v = valRef as? String {
                    lines.append("Focused element value: \(String(v.prefix(200)))")
                } else {
                    lines.append("Focused element value: (none / not readable)")
                }
            }
        }

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "AX Diagnostic"
            alert.informativeText = lines.joined(separator: "\n")
            alert.addButton(withTitle: "OK")
            if !Self.hasAccessibilityPermission {
                alert.addButton(withTitle: "Open System Settings")
            }
            let resp = alert.runModal()
            if resp == .alertSecondButtonReturn {
                Self.requestAccessibilityPermissionIfNeeded()
            }
        }
    }
}
