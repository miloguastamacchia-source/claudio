import AppKit
import WebKit

private let loginUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

private let allowedDomains: Set<String> = [
    "claude.ai",
    "platform.claude.com",      // Phase 2: capture platform sessionKey
    "console.anthropic.com",    // Phase 2: platform.claude.com/login may redirect here
    "accounts.google.com",
    "accounts.google.co.jp",
    "accounts.google.com.hk",
    "www.google.com",
    "appleid.apple.com",
    "login.microsoftonline.com",
    "github.com",
    "challenges.cloudflare.com",
]

class LoginWindow: NSObject, WKNavigationDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var cookieTimer: Timer?
    private var platformTimer: Timer?       // Phase 2: polls for platform.claude.com sessionKey
    private var onSuccess: ((_ sessionKey: String, _ orgId: String) -> Void)?
    private var onCancel: (() -> Void)?
    private var validationRetries = 0
    private let maxValidationRetries = 5
    private var capturedSessionKey: String = ""
    private var capturedConsoleOrgId: String = ""
    private var capturedPlatformCookies: String = ""
    private var awaitingPlatformSession = false

    init(onSuccess: @escaping (String, String) -> Void, onCancel: (() -> Void)? = nil) {
        self.onSuccess = onSuccess
        self.onCancel = onCancel
        super.init()
    }

    func show() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        let frame = NSRect(x: 0, y: 0, width: 480, height: 700)
        let wv = WKWebView(frame: frame, configuration: config)
        wv.customUserAgent = loginUserAgent
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        self.webView = wv

        let win = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Log in to Claude"
        win.contentView = wv
        win.center()
        win.isReleasedWhenClosed = false
        self.window = win

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: win
        )

        if let url = URL(string: "https://claude.ai/login") {
            wv.load(URLRequest(url: url))
        }

        // Add Edit menu so Cmd+V paste works in the WKWebView
        if NSApp.mainMenu?.item(withTitle: "Edit") == nil {
            let editMenu = NSMenu(title: "Edit")
            editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
            let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
            editMenuItem.submenu = editMenu
            NSApp.mainMenu = NSMenu()
            NSApp.mainMenu?.addItem(editMenuItem)
        }

        win.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        cookieTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollCookies()
        }
    }

    // MARK: - Phase 1: poll for claude.ai sessionKey

    private func pollCookies() {
        guard let wv = webView else { return }
        wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, !self.awaitingPlatformSession else { return }
            for cookie in cookies {
                if cookie.name == "sessionKey", cookie.domain.contains("claude.ai"), !cookie.value.isEmpty {
                    self.capturedSessionKey = cookie.value
                    self.stopPolling()
                    self.awaitingPlatformSession = true
                    // Navigate to platform.claude.com/login to establish a console session.
                    // If SSO is available it will complete automatically; otherwise the user
                    // sees the console login page and can authenticate manually.
                    self.window?.title = "Log in to Anthropic Console (for API credits)"
                    if let url = URL(string: "https://platform.claude.com/login") {
                        self.webView?.load(URLRequest(url: url))
                    }
                    // Poll for the platform sessionKey
                    self.startPlatformPolling()
                    return
                }
            }
        }
    }

    // MARK: - Phase 2: poll for platform.claude.com sessionKey (set by SSO after page loads)

    private func startPlatformPolling() {
        var attempts = 0
        // Poll every 500 ms for up to 60 s (120 attempts).
        // If platform.claude.com SSO auto-completes this fires quickly; if the user must
        // log in manually they have up to 60 s before we time out and proceed anyway.
        platformTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            attempts += 1
            self.webView?.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, self.awaitingPlatformSession else { return }

                var platformKey: HTTPCookie? = nil
                for c in cookies where c.name == "sessionKey" {
                    let onPlatform = c.domain == "platform.claude.com" || c.domain == ".platform.claude.com"
                        || c.domain == "console.anthropic.com" || c.domain == ".console.anthropic.com"
                    if onPlatform && !c.value.isEmpty && c.value != self.capturedSessionKey {
                        platformKey = c
                        break
                    }
                }

                let done = platformKey != nil || attempts >= 120
                guard done else { return }

                self.platformTimer?.invalidate()
                self.platformTimer = nil
                self.awaitingPlatformSession = false

                if platformKey != nil {
                    log.info("Platform login complete (attempt \(attempts))")
                } else {
                    log.warning("Platform login timed out after 60 s — proceeding without platform sessionKey")
                }
                self.capturePlatformCookiesAndFinish(from: cookies)
            }
        }
    }

    // MARK: - Build platformCookies and fetch consoleOrgId

    private func capturePlatformCookiesAndFinish(from cookies: [HTTPCookie]) {
        let sessionKeyLC = cookies.first { $0.name == "sessionKeyLC" && !$0.value.isEmpty }?.value ?? ""

        // Deduplicate: platform.claude.com / console.anthropic.com cookies take priority.
        // Exclude sessionKey ONLY from the claude.ai domain — the platform sessionKey IS kept.
        let isConsoleDomain = { (d: String) -> Bool in
            d == "platform.claude.com" || d == ".platform.claude.com"
            || d == "console.anthropic.com" || d == ".console.anthropic.com"
        }
        let prioritised = cookies.sorted { a, b in
            isConsoleDomain(a.domain) && !isConsoleDomain(b.domain)
        }
        var seen = Set<String>()
        var parts: [String] = []
        for c in prioritised {
            let d = c.domain
            guard d.contains("claude") || d.contains("anthropic") else { continue }
            // Skip claude.ai's sessionKey — it must not be sent to platform.claude.com.
            // The platform/console sessionKey (same name, different value/domain) IS kept.
            if c.name == "sessionKey" && (d == "claude.ai" || d == ".claude.ai") { continue }
            if seen.insert(c.name).inserted {
                parts.append("\(c.name)=\(c.value)")
            }
        }
        if !sessionKeyLC.isEmpty && !seen.contains("sessionKeyLC") {
            parts.append("sessionKeyLC=\(sessionKeyLC)")
        }
        capturedPlatformCookies = parts.joined(separator: "; ")

        // Fetch org list via URLSession to find the prepaid consoleOrgId
        guard let url = URL(string: "https://platform.claude.com/api/organizations") else {
            handleSessionKey(capturedSessionKey, sessionKeyLC: sessionKeyLC)
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpShouldHandleCookies = false
        req.setValue(capturedPlatformCookies, forHTTPHeaderField: "Cookie")
        req.setValue("https://platform.claude.com", forHTTPHeaderField: "Origin")
        req.setValue("https://platform.claude.com/", forHTTPHeaderField: "Referer")
        req.setValue(loginUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            var consoleOrgId = ""
            if let data,
               let orgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for org in orgs {
                    if let uuid = org["uuid"] as? String,
                       (org["billing_type"] as? String) == "prepaid" {
                        consoleOrgId = uuid
                        break
                    }
                }
            }
            DispatchQueue.main.async {
                self.capturedConsoleOrgId = consoleOrgId
                self.handleSessionKey(self.capturedSessionKey, sessionKeyLC: sessionKeyLC)
            }
        }.resume()
    }

    // MARK: - Finalise login

    private func handleSessionKey(_ key: String, sessionKeyLC: String) {
        let preloadedConsoleOrgId = capturedConsoleOrgId
        let preloadedPlatformCookies = capturedPlatformCookies
        DispatchQueue.global().async { [weak self] in
            guard let orgId = validateAndGetOrg(sessionKey: key) else {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.validationRetries += 1
                    if self.validationRetries >= self.maxValidationRetries {
                        self.stopPolling()
                        let alert = NSAlert()
                        alert.messageText = "Login Failed"
                        alert.informativeText = "Could not validate your session. Please try again."
                        alert.alertStyle = .warning
                        alert.runModal()
                        self.close()
                        self.onCancel?()
                    } else {
                        self.startPolling()
                    }
                }
                return
            }
            let consoleOrgId = preloadedConsoleOrgId.isEmpty
                ? (validateAndGetConsoleOrg(sessionKey: key, sessionKeyLC: sessionKeyLC, excludingOrgId: orgId) ?? "")
                : preloadedConsoleOrgId
            saveSession(Session(sessionKey: key, orgId: orgId, consoleOrgId: consoleOrgId,
                               sessionKeyLC: sessionKeyLC, platformCookies: preloadedPlatformCookies))
            DispatchQueue.main.async {
                self?.close()
                self?.onSuccess?(key, orgId)
            }
        }
    }

    // MARK: - Timer helpers

    private func startPolling() {
        cookieTimer?.invalidate()
        cookieTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollCookies()
        }
    }

    private func stopPolling() {
        cookieTimer?.invalidate()
        cookieTimer = nil
    }

    @objc private func windowWillClose(_ notification: Notification) {
        stopPolling()
        platformTimer?.invalidate()
        platformTimer = nil
        onCancel?()
    }

    func close() {
        stopPolling()
        platformTimer?.invalidate()
        platformTimer = nil
        NotificationCenter.default.removeObserver(self)
        window?.close()
        window = nil
        webView = nil
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let host = navigationAction.request.url?.host else {
            decisionHandler(.allow)
            return
        }
        let allowed = allowedDomains.contains { host == $0 || host.hasSuffix(".\($0)") }
        if !allowed { log.info("Blocked navigation to: \(host)") }
        decisionHandler(allowed ? .allow : .cancel)
    }
}
