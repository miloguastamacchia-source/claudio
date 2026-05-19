import AppKit
import WebKit

private let loginUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

private let allowedDomains: Set<String> = [
    "claude.ai",
    "platform.claude.com",  // navigated to after login to capture sessionKeyLC
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
    private var onSuccess: ((_ sessionKey: String, _ orgId: String) -> Void)?
    private var onCancel: (() -> Void)?
    private var validationRetries = 0
    private let maxValidationRetries = 5
    private var capturedSessionKey: String = ""
    private var capturedConsoleOrgId: String = ""
    private var capturedPlatformCookies: String = ""
    private var awaitingSessionKeyLC = false

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

    private func pollCookies() {
        guard let wv = webView else { return }
        wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, !self.awaitingSessionKeyLC else { return }
            // Phase 1: looking for sessionKey on claude.ai
            for cookie in cookies {
                if cookie.name == "sessionKey", cookie.domain.contains("claude.ai"), !cookie.value.isEmpty {
                    self.capturedSessionKey = cookie.value
                    self.stopPolling()
                    // Navigate to platform.claude.com — Phase 2 is handled in webView(_:didFinish:)
                    self.awaitingSessionKeyLC = true
                    if let url = URL(string: "https://platform.claude.com") {
                        self.webView?.load(URLRequest(url: url))
                    }
                    // Timeout: if platform.claude.com never fully loads
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                        guard let self, self.awaitingSessionKeyLC else { return }
                        self.awaitingSessionKeyLC = false
                        self.handleSessionKey(self.capturedSessionKey, sessionKeyLC: "")
                    }
                    return
                }
            }
        }
    }

    private func handleSessionKey(_ key: String, sessionKeyLC: String) {
        // Capture on main thread before dispatching to background
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
            // Use org ID captured via WebView JS (has full cookie context); fall back to URLSession
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
        onCancel?()
    }

    func close() {
        stopPolling()
        NotificationCenter.default.removeObserver(self)
        window?.close()
        window = nil
        webView = nil
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard awaitingSessionKeyLC, webView.url?.host == "platform.claude.com" else { return }
        awaitingSessionKeyLC = false  // prevent timeout from double-firing

        // Use JS inside the WebView to fetch the org list — it has the complete cookie context
        // so no domain filtering or URLSession auth issues. The missing `return` was the bug
        // that killed this approach in v1.15; callAsyncJavaScript needs an explicit return.
        let js = """
        const r = await fetch('/api/organizations');
        const d = await r.json();
        return JSON.stringify(d);
        """
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { [weak self] jsResult in
            guard let self else { return }

            if case .success(let val) = jsResult,
               let str = val as? String, !str.isEmpty,
               let data = str.data(using: .utf8),
               let orgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for org in orgs {
                    if let uuid = org["uuid"] as? String,
                       (org["billing_type"] as? String) == "prepaid" {
                        self.capturedConsoleOrgId = uuid
                        break
                    }
                }
            }

            // Capture cookies for persistent storage (background refresh calls)
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let sessionKeyLC = cookies.first { $0.name == "sessionKeyLC" && !$0.value.isEmpty }?.value ?? ""

                // Deduplicate by name, preferring platform.claude.com domain cookies.
                // Exclude third-party and short-lived Cloudflare cookies.
                let sorted = cookies.sorted { a, _ in
                    let d = a.domain
                    return d == "platform.claude.com" || d == ".platform.claude.com"
                }
                var seen = Set<String>()
                var parts: [String] = []
                for c in sorted {
                    let d = c.domain
                    guard d.contains("claude") else { continue }           // skip google etc.
                    guard !c.name.hasPrefix("__cf") && c.name != "cf_clearance" && c.name != "_cfuvid" else { continue }
                    if seen.insert(c.name).inserted {
                        parts.append("\(c.name)=\(c.value)")
                    }
                }
                if !sessionKeyLC.isEmpty && !seen.contains("sessionKeyLC") {
                    parts.append("sessionKeyLC=\(sessionKeyLC)")
                }
                self.capturedPlatformCookies = parts.joined(separator: "; ")
                self.handleSessionKey(self.capturedSessionKey, sessionKeyLC: sessionKeyLC)
            }
        }
    }

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
