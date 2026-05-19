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

        // After the page finishes loading, the WebView's cookie store has ALL cookies set by
        // platform.claude.com (sessionKeyLC, anthropic-device-id, __ssid, etc.).
        // We build a full cookie header from the store and use it for a URLSession request —
        // this mirrors what the browser sends and gets past platform.claude.com's auth.
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }

            let sessionKeyLC = cookies.first { $0.name == "sessionKeyLC" && !$0.value.isEmpty }?.value ?? ""

            // Build cookie header for platform.claude.com.
            // Include platform.claude.com domain AND .claude.com (shared parent) cookies.
            // Exclude .claude.ai cookies to avoid duplicates (e.g. anthropic-device-id).
            var cookieParts = cookies
                .filter { c in
                    let d = c.domain
                    return d == "platform.claude.com" || d == ".platform.claude.com"
                        || d == ".claude.com"
                }
                .map { "\($0.name)=\($0.value)" }
            // Always include sessionKeyLC explicitly — its domain may vary
            if !sessionKeyLC.isEmpty, !cookieParts.contains(where: { $0.hasPrefix("sessionKeyLC=") }) {
                cookieParts.append("sessionKeyLC=\(sessionKeyLC)")
            }
            self.capturedPlatformCookies = cookieParts.joined(separator: "; ")

            guard let url = URL(string: "https://platform.claude.com/api/organizations") else {
                self.handleSessionKey(self.capturedSessionKey, sessionKeyLC: sessionKeyLC)
                return
            }
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            req.setValue("https://platform.claude.com", forHTTPHeaderField: "origin")
            req.setValue("https://platform.claude.com/", forHTTPHeaderField: "referer")
            req.setValue(loginUserAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            URLSession.shared.dataTask(with: req) { data, _, _ in
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
