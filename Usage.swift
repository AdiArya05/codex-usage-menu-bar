import AppKit
import SwiftUI

struct QuotaWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: TimeInterval?
    var remaining: Int { Int(max(0, min(100, (100 - usedPercent).rounded(.down)))) }
    var reset: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }
    var label: String {
        switch windowDurationMins {
        case 10080: "Weekly"
        case 1440: "Daily"
        case let n? where n >= 60 && n % 60 == 0: "\(n / 60)-hour"
        case let n?: "\(n)-minute"
        case nil: "Usage"
        }
    }
}

struct Bucket: Decodable {
    struct Credits: Decodable {
        let unlimited: Bool
        let balance: String?
    }
    let limitId: String?
    let limitName: String?
    let primary: QuotaWindow?
    let secondary: QuotaWindow?
    let credits: Credits?
    let planType: String?
    var windows: [QuotaWindow] { [primary, secondary].compactMap { $0 } }

    // The map and live notifications can omit one of the two quota windows.
    func fillingMissingWindows(from fallback: Bucket?) -> Bucket {
        guard let fallback else { return self }
        var merged = windows
        for window in fallback.windows where merged.count < 2 {
            if !merged.contains(where: { $0.windowDurationMins == window.windowDurationMins }) {
                merged.append(window)
            }
        }
        return Bucket(limitId: limitId ?? fallback.limitId, limitName: limitName ?? fallback.limitName,
                      primary: merged.first, secondary: merged.dropFirst().first,
                      credits: credits ?? fallback.credits, planType: planType ?? fallback.planType)
    }
}

struct EarnedResets: Decodable {
    struct Credit: Decodable {
        let expiresAt: TimeInterval?
        let status: String?
    }
    let availableCount: Int
    let credits: [Credit]?
}

struct Limits: Decodable {
    let rateLimits: Bucket
    let rateLimitsByLimitId: [String: Bucket]?
    let rateLimitResetCredits: EarnedResets?

    var buckets: [String: Bucket] {
        var result = rateLimitsByLimitId ?? [:]
        let key = rateLimits.limitId ?? "codex"
        result[key] = result[key]?.fillingMissingWindows(from: rateLimits) ?? rateLimits
        return result
    }
}

struct QuotaRow: Identifiable {
    let id: String
    let name: String
    let window: QuotaWindow

    var isCoreCodexWindow: Bool {
        id.hasPrefix("codex:") && [300, 10080].contains(window.windowDurationMins ?? 0)
    }

    static func dashboardRows(_ rows: [QuotaRow]) -> [QuotaRow] {
        let core = rows.filter(\.isCoreCodexWindow)
            .sorted { ($0.window.windowDurationMins ?? 0) < ($1.window.windowDurationMins ?? 0) }
        let extra = rows.filter { !$0.isCoreCodexWindow }
        let available = max(0, 3 - core.filter { $0.window.remaining > 0 }.count)
        let depleted = max(0, 2 - core.filter { $0.window.remaining == 0 }.count)
        return core + extra.filter { $0.window.remaining > 0 }.prefix(available)
            + extra.filter { $0.window.remaining == 0 }.prefix(depleted)
    }
}

func countdown(_ date: Date, now: Date) -> String {
    let seconds = date.timeIntervalSince(now)
    guard seconds > 0 else { return "Due now" }
    let minutes = Int(ceil(seconds / 60))
    if minutes < 60 { return "\(minutes)m" }
    if minutes < 1440 { return "\(minutes / 60)h \(minutes % 60)m" }
    return "\(minutes / 1440)d \((minutes % 1440) / 60)h"
}

@MainActor
final class Usage: ObservableObject {
    @Published private(set) var rows: [QuotaRow] = []
    @Published private(set) var resets: EarnedResets?
    @Published private(set) var credits: Bucket.Credits?
    @Published private(set) var account = "Personal"
    @Published private(set) var accountPlan: String?
    @Published private(set) var now = Date()
    @Published private(set) var lastSync: Date?
    @Published private(set) var nextSync: Date?
    @Published private(set) var error: String?
    @Published private(set) var syncing = false

    var onChange: (() -> Void)?
    @Published var expanded = false
    @Published var activity = CodexActivity.idle
    private var buckets: [String: Bucket] = [:]
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var generation = UUID()
    private var requestID = 0
    private var pendingID: Int?
    private var deadline: Date?
    private var updatesDuringRead: [String: Bucket] = [:]
    private var ready = false
    private var authURL: URL?
    private var authFingerprint: Date?
    private var timer: Timer?

    var headline: QuotaRow? {
        rows.first { $0.id.hasPrefix("codex:") } ?? rows.first
    }
    var missingPlusWindows: [String] {
        guard (buckets["codex"]?.planType ?? accountPlan) == "plus" else { return [] }
        let durations = Set(rows.filter(\.isCoreCodexWindow).compactMap { $0.window.windowDurationMins })
        return [(300, "5-hour"), (10080, "Weekly")].compactMap { durations.contains($0.0) ? nil : $0.1 }
    }

    var nextReset: Date? { rows.compactMap { $0.window.reset }.filter { $0 > now }.min() }
    var nextExpiry: Date? {
        resets?.credits?.filter { $0.status == nil || $0.status == "available" }
            .compactMap { $0.expiresAt.map(Date.init(timeIntervalSince1970:)) }
            .filter { $0 > now }.min()
    }

    func start() {
        let environment = ProcessInfo.processInfo.environment
        let home = environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex").path
        authURL = URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        authFingerprint = authDate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        refresh()
    }

    func refresh() {
        guard !syncing else { return }
        if process == nil { connect(); return }
        guard ready else { return }
        syncing = true
        updatesDuringRead.removeAll()
        deadline = Date().addingTimeInterval(12)
        requestID += 1
        pendingID = requestID
        send(["id": requestID, "method": "account/rateLimits/read"])
    }

    func wake() {
        disconnect()
        refresh()
    }

    func stop() {
        timer?.invalidate()
        disconnect()
    }

    private func authDate() -> Date? {
        guard let authURL else { return nil }
        return (try? authURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func tick() {
        now = Date()
        let fingerprint = authDate()
        if fingerprint != authFingerprint {
            authFingerprint = fingerprint
            clearAccount()
            wake()
        } else if let deadline, now >= deadline {
            disconnect()
            fail("Sync timed out")
        } else if let nextSync, now >= nextSync {
            refresh()
        }
        onChange?()
    }

    private func connect() {
        guard let executable = codexExecutable() else {
            fail("Codex CLI unavailable")
            return
        }
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        child.executableURL = executable
        child.arguments = ["app-server", "--listen", "stdio://"]
        child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        let token = UUID()
        generation = token
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                guard let self, self.generation == token, !data.isEmpty else { return }
                self.receive(data)
            }
        }
        child.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.disconnect()
                self.fail("Codex connection closed")
            }
        }
        do {
            try child.run()
            syncing = true
            deadline = Date().addingTimeInterval(12)
            send(["id": 0, "method": "initialize", "params": [
                "clientInfo": ["name": "codex_usage_bar", "version": "1.0"]
            ]])
        } catch {
            disconnect()
            fail("Couldn’t start Codex")
        }
    }

    private func disconnect() {
        generation = UUID()
        output?.readabilityHandler = nil
        try? input?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil
        input = nil
        output = nil
        buffer.removeAll()
        ready = false
        syncing = false
        pendingID = nil
        deadline = nil
        updatesDuringRead.removeAll()
    }

    private func send(_ message: [String: Any]) {
        do {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(10)
            try input?.write(contentsOf: data)
        } catch {
            disconnect()
            fail("Codex connection interrupted")
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end])
            buffer.removeSubrange(...end)
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            handle(message)
        }
    }

    private func decode<T: Decodable>(_ value: Any?, as type: T.Type) -> T? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func handle(_ message: [String: Any]) {
        let id = message["id"] as? Int
        if id == 0 {
            guard message["result"] != nil else {
                disconnect()
                fail("Codex handshake failed")
                return
            }
            ready = true
            syncing = false
            send(["method": "initialized"])
            send(["id": -1, "method": "account/read", "params": ["refreshToken": false]])
            refresh()
        } else if id == -1 {
            let result = message["result"] as? [String: Any]
            if let details = result?["account"] as? [String: Any] {
                account = details["email"] as? String ?? "Personal"
                accountPlan = details["planType"] as? String
            }
        } else if let id, id == pendingID {
            pendingID = nil
            deadline = nil
            syncing = false
            guard let limits = decode(message["result"], as: Limits.self) else {
                fail("Couldn’t read Codex usage")
                return
            }
            var updated = limits.buckets
            for (id, notification) in updatesDuringRead {
                updated[id] = notification.fillingMissingWindows(from: updated[id])
            }
            buckets = updated
            updatesDuringRead.removeAll()
            resets = limits.rateLimitResetCredits
            credits = buckets["codex"]?.credits ?? limits.rateLimits.credits
            lastSync = Date()
            error = nil
            nextSync = Date().addingTimeInterval(expanded ? 12 : 30)
            publishRows()
        } else if message["method"] as? String == "account/rateLimits/updated",
                  let params = message["params"] as? [String: Any],
                  let bucket = decode(params["rateLimits"], as: Bucket.self) {
            guard lastSync != nil else { return }
            let key = bucket.limitId ?? "codex"
            buckets[key] = bucket.fillingMissingWindows(from: buckets[key])
            if pendingID != nil {
                updatesDuringRead[key] = bucket.fillingMissingWindows(from: updatesDuringRead[key])
            }
            if key == "codex", let balance = bucket.credits { credits = balance }
            publishRows()
        } else if message["method"] as? String == "account/updated", ready {
            guard lastSync != nil else { return }
            clearAccount()
            pendingID = nil
            deadline = nil
            syncing = false
            send(["id": -1, "method": "account/read", "params": ["refreshToken": false]])
            refresh()
        }
    }

    private func publishRows() {
        rows = buckets.flatMap { key, bucket in
            bucket.windows.enumerated().map { index, window in
                let duration = window.windowDurationMins.map(String.init) ?? "unknown"
                let duplicate = bucket.windows.prefix(index).contains { $0.windowDurationMins == window.windowDurationMins }
                let rowID = duplicate ? "\(key):\(duration):\(index)" : "\(key):\(duration)"
                return QuotaRow(id: rowID, name: bucket.limitName ?? (key == "codex" ? "Codex" : key), window: window)
            }
        }.sorted { a, b in
            if a.window.remaining != b.window.remaining { return a.window.remaining < b.window.remaining }
            return a.id < b.id
        }
        onChange?()
    }

    private func clearAccount() {
        buckets.removeAll()
        rows = []
        resets = nil
        credits = nil
        lastSync = nil
        account = "Personal"
        accountPlan = nil
        updatesDuringRead.removeAll()
        onChange?()
    }

    private func fail(_ message: String) {
        error = message
        nextSync = Date().addingTimeInterval(15)
        onChange?()
    }
}
