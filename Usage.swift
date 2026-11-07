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
    var windows: [QuotaWindow] { [primary, secondary].compactMap { $0 } }
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
}

struct QuotaRow: Identifiable {
    let id: String
    let name: String
    let window: QuotaWindow
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
    @Published private(set) var now = Date()
    @Published private(set) var lastSync: Date?
    @Published private(set) var nextSync: Date?
    @Published private(set) var error: String?
    @Published private(set) var syncing = false

    var onChange: (() -> Void)?
    var expanded = false
    private var buckets: [String: Bucket] = [:]
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var generation = UUID()
    private var requestID = 0
    private var pendingID: Int?
    private var deadline: Date?
    private var readStarted: Date?
    private var eventTimes: [String: Date] = [:]
    private var ready = false
    private var authURL: URL?
    private var authFingerprint: Date?
    private var timer: Timer?

    var headline: QuotaRow? {
        rows.first { $0.id.hasPrefix("codex:") } ?? rows.first
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
        readStarted = Date()
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
        eventTimes.removeAll()
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
            }
        } else if let id, id == pendingID {
            pendingID = nil
            deadline = nil
            syncing = false
            guard let limits = decode(message["result"], as: Limits.self) else {
                fail("Couldn’t read Codex usage")
                return
            }
            var updated = limits.rateLimitsByLimitId ?? [:]
            let key = limits.rateLimits.limitId ?? "codex"
            if updated[key] == nil { updated[key] = limits.rateLimits }
            if let readStarted {
                for (id, time) in eventTimes where time >= readStarted {
                    updated[id] = buckets[id] ?? updated[id]
                }
            }
            buckets = updated
            eventTimes.removeAll()
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
            buckets[key] = bucket
            eventTimes[key] = Date()
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
                QuotaRow(id: "\(key):\(index)", name: bucket.limitName ?? (key == "codex" ? "Codex" : key), window: window)
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
        onChange?()
    }

    private func fail(_ message: String) {
        error = message
        nextSync = Date().addingTimeInterval(15)
        onChange?()
    }
}
