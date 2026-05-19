import Foundation
import Security
import os

let log = Logger(subsystem: "com.claudio.app", category: "general")

// MARK: - Data model

struct UsageData {
    var sessionPct: Double = 0
    var sessionReset: TimeInterval = 0
    var weeklyPct: Double = 0
    var weeklyReset: TimeInterval = 0
    var routineUsed: Int = 0
    var routineLimit: Int = 5
    var overagePct: Double = 0
    var overageReset: TimeInterval = 0
    var extraDollars: Double = 0
    var extraEnabled: Bool = false
    var creditRemaining: Double = 0
    var creditTotal: Double = 0
}

enum UsageResult {
    case success(UsageData)
    case needsLogin
    case error(String)
}

// MARK: - Keychain (Claudio-owned)

private let keychainService = "claudio"
private let keychainAccount = "session"

private func keychainSave(service: String, account: String, data: Data) -> Bool {
    keychainDelete(service: service, account: account)
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecValueData as String: data,
    ]
    return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
}

private func keychainLoad(service: String, account: String) -> Data? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
    return item as? Data
}

@discardableResult
private func keychainDelete(service: String, account: String) -> Bool {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]
    return SecItemDelete(query as CFDictionary) == errSecSuccess
}

// MARK: - Session storage

struct Session {
    let sessionKey: String
    let orgId: String
    var consoleOrgId: String = ""
}

func loadSession() -> Session? {
    guard let data = keychainLoad(service: keychainService, account: keychainAccount),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
          let key = dict["sessionKey"], let org = dict["orgId"]
    else { return nil }
    return Session(sessionKey: key, orgId: org, consoleOrgId: dict["consoleOrgId"] ?? "")
}

func saveSession(_ session: Session) {
    let dict: [String: String] = [
        "sessionKey": session.sessionKey,
        "orgId": session.orgId,
        "consoleOrgId": session.consoleOrgId,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: dict) {
        if !keychainSave(service: keychainService, account: keychainAccount, data: data) {
            log.error("Failed to save session to keychain")
        }
    }
}

func clearSession() {
    keychainDelete(service: keychainService, account: keychainAccount)
}

// MARK: - Usage snapshot persistence

private let snapshotKey = "lastUsageSnapshot"
private let snapshotTimeKey = "lastUsageSnapshotTime"

func saveSnapshot(_ data: UsageData) {
    let dict: [String: Any] = [
        "sessionPct": data.sessionPct, "sessionReset": data.sessionReset,
        "weeklyPct": data.weeklyPct, "weeklyReset": data.weeklyReset,
        "routineUsed": data.routineUsed, "routineLimit": data.routineLimit,
        "overagePct": data.overagePct, "overageReset": data.overageReset,
        "extraDollars": data.extraDollars, "extraEnabled": data.extraEnabled,
        "creditRemaining": data.creditRemaining, "creditTotal": data.creditTotal,
    ]
    UserDefaults.standard.set(dict, forKey: snapshotKey)
    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: snapshotTimeKey)
}

func loadSnapshot() -> (UsageData, TimeInterval)? {
    guard let dict = UserDefaults.standard.dictionary(forKey: snapshotKey) else { return nil }
    let ts = UserDefaults.standard.double(forKey: snapshotTimeKey)
    guard ts > 0 else { return nil }
    let data = UsageData(
        sessionPct: dict["sessionPct"] as? Double ?? 0,
        sessionReset: dict["sessionReset"] as? Double ?? 0,
        weeklyPct: dict["weeklyPct"] as? Double ?? 0,
        weeklyReset: dict["weeklyReset"] as? Double ?? 0,
        routineUsed: dict["routineUsed"] as? Int ?? 0,
        routineLimit: dict["routineLimit"] as? Int ?? 5,
        overagePct: dict["overagePct"] as? Double ?? 0,
        overageReset: dict["overageReset"] as? Double ?? 0,
        extraDollars: dict["extraDollars"] as? Double ?? 0,
        extraEnabled: dict["extraEnabled"] as? Bool ?? false,
        creditRemaining: dict["creditRemaining"] as? Double ?? 0,
        creditTotal: dict["creditTotal"] as? Double ?? 0
    )
    return (data, ts)
}

func clearSnapshot() {
    UserDefaults.standard.removeObject(forKey: snapshotKey)
    UserDefaults.standard.removeObject(forKey: snapshotTimeKey)
}

// MARK: - API

private let browserHeaders: [String: String] = [
    "accept": "*/*",
    "accept-language": "en-US,en;q=0.9",
    "content-type": "application/json",
    "anthropic-client-platform": "web_claude_ai",
    "anthropic-client-version": "1.0.0",
    "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36",
    "origin": "https://claude.ai",
    "referer": "https://claude.ai/settings/usage",
    "sec-fetch-dest": "empty",
    "sec-fetch-mode": "cors",
    "sec-fetch-site": "same-origin",
]

private enum ApiResult {
    case success(Any)
    case authFailure
    case networkError(String)
}

private func apiRequest(path: String, sessionKey: String, baseURL: String = "https://claude.ai") -> ApiResult {
    guard let url = URL(string: "\(baseURL)\(path)") else { return .networkError("Bad URL") }
    var req = URLRequest(url: url, timeoutInterval: 15)
    for (k, v) in browserHeaders { req.setValue(v, forHTTPHeaderField: k) }
    req.setValue(baseURL, forHTTPHeaderField: "origin")
    req.setValue("\(baseURL)/", forHTTPHeaderField: "referer")
    // platform.claude.com uses "sessionKeyLC"; claude.ai uses "sessionKey"
    let cookieName = baseURL.contains("platform.claude.com") ? "sessionKeyLC" : "sessionKey"
    req.setValue("\(cookieName)=\(sessionKey)", forHTTPHeaderField: "Cookie")

    var result: ApiResult = .networkError("Request timed out")
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, resp, error in
        defer { sem.signal() }
        if let error {
            result = .networkError(error.localizedDescription)
            return
        }
        guard let http = resp as? HTTPURLResponse else {
            result = .networkError("No response")
            return
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            log.warning("Auth failure (\(http.statusCode)) on \(path)")
            result = .authFailure
            return
        }
        guard (200...299).contains(http.statusCode) else {
            result = .networkError("HTTP \(http.statusCode)")
            return
        }
        guard let data else {
            result = .networkError("No data")
            return
        }
        if let prefix = String(data: data.prefix(5), encoding: .utf8),
           prefix.hasPrefix("<!DOC") || prefix.hasPrefix("<html") {
            result = .authFailure
            return
        }
        if let json = try? JSONSerialization.jsonObject(with: data) {
            result = .success(json)
        } else {
            result = .networkError("Invalid JSON")
        }
    }.resume()
    sem.wait()
    return result
}

private func apiRequestDict(path: String, sessionKey: String, baseURL: String = "https://claude.ai") -> ApiResult {
    let result = apiRequest(path: path, sessionKey: sessionKey, baseURL: baseURL)
    switch result {
    case .success(let json):
        if let dict = json as? [String: Any] {
            return .success(dict)
        }
        return .networkError("Unexpected response format")
    default:
        return result
    }
}

func validateAndGetOrg(sessionKey: String) -> String? {
    guard case .success(let json) = apiRequest(path: "/api/organizations", sessionKey: sessionKey),
          let arr = json as? [[String: Any]],
          let first = arr.first,
          let uuid = first["uuid"] as? String
    else { return nil }
    return uuid
}

func validateAndGetConsoleOrg(sessionKey: String, excludingOrgId: String) -> String? {
    guard case .success(let json) = apiRequest(path: "/api/organizations", sessionKey: sessionKey, baseURL: "https://platform.claude.com"),
          let arr = json as? [[String: Any]]
    else { return nil }
    // platform.claude.com returns multiple orgs including the claude.ai org —
    // skip that one and return the first platform-specific org ID.
    for org in arr {
        if let uuid = org["uuid"] as? String, uuid != excludingOrgId {
            return uuid
        }
    }
    return nil
}

// MARK: - Fetch usage

private func fetchUsageSessionKey(session: Session) -> UsageResult {
    // Resolve console org ID — fetch and cache if missing or if it incorrectly matches
    // the claude.ai org ID (which platform.claude.com also returns but is the wrong one).
    var session = session
    if session.consoleOrgId.isEmpty || session.consoleOrgId == session.orgId {
        if let cid = validateAndGetConsoleOrg(sessionKey: session.sessionKey, excludingOrgId: session.orgId) {
            session.consoleOrgId = cid
            saveSession(session)
        }
    }

    let group = DispatchGroup()
    var usageResult: ApiResult = .networkError("Not started")
    var overageResult: ApiResult = .networkError("Not started")
    var routineResult: ApiResult = .networkError("Not started")
    var creditsResult: ApiResult = .networkError("Not started")

    group.enter()
    DispatchQueue.global().async {
        usageResult = apiRequestDict(path: "/api/organizations/\(session.orgId)/usage", sessionKey: session.sessionKey)
        group.leave()
    }

    group.enter()
    DispatchQueue.global().async {
        overageResult = apiRequestDict(path: "/api/organizations/\(session.orgId)/overage_spend_limit", sessionKey: session.sessionKey)
        group.leave()
    }

    group.enter()
    DispatchQueue.global().async {
        routineResult = apiRequestDict(path: "/api/organizations/\(session.orgId)/run-budget", sessionKey: session.sessionKey)
        group.leave()
    }

    group.enter()
    DispatchQueue.global().async {
        if !session.consoleOrgId.isEmpty {
            creditsResult = apiRequestDict(
                path: "/api/organizations/\(session.consoleOrgId)/prepaid/credits",
                sessionKey: session.sessionKey,
                baseURL: "https://platform.claude.com"
            )
        }
        group.leave()
    }

    group.wait()

    if case .authFailure = usageResult { return .needsLogin }
    if case .authFailure = overageResult { return .needsLogin }

    guard case .success(let usageJson) = usageResult,
          let usage = usageJson as? [String: Any] else {
        if case .networkError(let msg) = usageResult {
            return .error(msg)
        }
        return .error("Failed to fetch usage")
    }

    let ov: [String: Any]
    if case .success(let overageJson) = overageResult, let dict = overageJson as? [String: Any] {
        ov = dict
    } else {
        ov = [:]
    }

    // run-budget returns used/limit as strings
    var routineUsed = 0
    var routineLimit = 5
    if case .success(let routineJson) = routineResult, let rb = routineJson as? [String: Any] {
        routineUsed = Int(rb["used"] as? String ?? "0") ?? 0
        routineLimit = Int(rb["limit"] as? String ?? "5") ?? 5
    }

    // prepaid credits — response is the credits object directly:
    // { "amount": <cents>, "last_paid_purchase_cents": <cents>, "pending_invoice_amount_cents": <cents|null>, ... }
    var creditRemaining: Double = 0
    var creditTotal: Double = 0

    if case .success(let creditsJson) = creditsResult,
       let cr = creditsJson as? [String: Any] {
        func cents(_ key: String) -> Int {
            if let n = cr[key] as? Int    { return n }
            if let d = cr[key] as? Double { return Int(d) }
            return 0
        }
        let gross   = cents("amount")
        let pending = cents("pending_invoice_amount_cents")
        creditRemaining = Double(gross - pending) / 100
        creditTotal     = Double(cents("last_paid_purchase_cents")) / 100
    }

    let usedCents = (ov["used_credits"] as? Int) ?? 0

    return .success(UsageData(
        sessionPct: pct(usage["five_hour"] as? [String: Any]),
        sessionReset: rst(usage["five_hour"] as? [String: Any]),
        weeklyPct: pct(usage["seven_day"] as? [String: Any]),
        weeklyReset: rst(usage["seven_day"] as? [String: Any]),
        routineUsed: routineUsed,
        routineLimit: routineLimit,
        overagePct: (ov["utilization"] as? Double) ?? 0,
        overageReset: nextMonthTs(),
        extraDollars: Double(usedCents) / 100,
        extraEnabled: (ov["is_enabled"] as? Bool) ?? false,
        creditRemaining: creditRemaining,
        creditTotal: creditTotal
    ))
}

func fetchUsage() -> UsageResult {
    guard let session = loadSession() else { return .needsLogin }
    let result = fetchUsageSessionKey(session: session)
    if case .success(let data) = result {
        log.info("Fetched usage via session key")
        saveSnapshot(data)
    }
    if case .needsLogin = result {
        log.info("Session expired, clearing")
        clearSession()
    }
    return result
}

// MARK: - Helpers

private func parseISO(_ str: String?) -> TimeInterval {
    guard let str, !str.isEmpty else { return 0 }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: str) { return d.timeIntervalSince1970 }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: str)?.timeIntervalSince1970 ?? 0
}

private func pct(_ block: [String: Any]?) -> Double {
    (block?["utilization"] as? Double) ?? 0
}

private func rst(_ block: [String: Any]?) -> TimeInterval {
    parseISO(block?["resets_at"] as? String)
}

private func nextMonthTs() -> TimeInterval {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let now = Date()
    var comps = cal.dateComponents([.year, .month], from: now)
    comps.month! += 1
    if comps.month! > 12 { comps.month = 1; comps.year! += 1 }
    comps.day = 1
    return cal.date(from: comps)?.timeIntervalSince1970 ?? 0
}

func elapsedPct(resetTs: TimeInterval, windowSecs: TimeInterval) -> Double {
    guard resetTs > 0 else { return 50.0 }
    let elapsed = Date().timeIntervalSince1970 - (resetTs - windowSecs)
    return max(0, min(100, elapsed / windowSecs * 100))
}

func fmtAgo(_ ts: TimeInterval) -> String {
    guard ts > 0 else { return "—" }
    let secs = Int(Date().timeIntervalSince1970 - ts)
    if secs < 60 { return "just now" }
    let mins = secs / 60
    if mins < 60 { return mins == 1 ? "1 min ago" : "\(mins) mins ago" }
    let hrs = mins / 60
    return hrs == 1 ? "1h ago" : "\(hrs)h ago"
}

func fmtReset(_ ts: TimeInterval) -> String {
    guard ts > 0 else { return "?" }
    let d = ts - Date().timeIntervalSince1970
    if d <= 0 { return "now" }
    let h = Int(d) / 3600
    let m = (Int(d) % 3600) / 60
    if h >= 24 { return "\(h / 24)d \(h % 24)h" }
    return h > 0 ? "\(h)h \(m)m" : "\(m)m"
}
