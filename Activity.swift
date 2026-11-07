import Darwin
import Foundation
import Network
import SQLite3

enum CodexSignal: String {
    case needsInput = "Needs your input"
    case finished = "Finished"
    case failed = "Turn failed"
}

struct CodexActivity: Equatable {
    let working: Bool
    let signal: CodexSignal?
    var workingChatTitles: [String] = []

    static let idle = CodexActivity(working: false, signal: nil)

    var label: String {
        signal?.rawValue ?? (working ? "Working" : "Idle")
    }
}

// The desktop's local follower stream supplies live status. The history index
// discovers active turns so idle conversations do not need a subscription.
final class ActivityMonitor {
    private struct FollowedTurn {
        let turnID: String
        let requestedAt: Date
        var owner: String?
        var status: [String: Any] = [:]
    }

    private var localTurns: [String: String] = [:]
    private let home: URL
    private let questions: PendingQuestions
    private let cloud = CloudActivity()
    private var hasPendingQuestions = false
    private let startedAt = Date()
    private var recentOutcome: CodexSignal?
    private let onChange: (CodexActivity) -> Void
    private let queue = DispatchQueue(label: "CodexUsage.Activity", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var connection: NWConnection?
    private var clientID: String?
    private var followed: [String: FollowedTurn] = [:]
    private var buffer = Data()
    private var skipBytes = 0
    private var activity = CodexActivity.idle

    init(onChange: @escaping (CodexActivity) -> Void) {
        let path = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        home = URL(fileURLWithPath: path)
        questions = PendingQuestions(home: home)
        self.onChange = onChange
    }

    func start() {
        queue.async { [self] in
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.cloud.stop()
            self.disconnect()
        }
    }

    private func poll() {
        cloud.poll(on: queue) { [weak self] in self?.publishActivity() }
        if let pending = questions.poll() { hasPendingQuestions = pending }
        recentOutcome = readRecentOutcome()
        if let turns = activeTurns() { localTurns = turns }
        defer { publishActivity() }
        guard connection != nil else {
            let socket = home.appendingPathComponent("ipc/ipc.sock").path
            guard FileManager.default.fileExists(atPath: socket) else { return }
            connect(socket)
            return
        }
        guard clientID != nil else { return }
        for (thread, subscription) in followed where localTurns[thread] != subscription.turnID {
            unfollow(thread)
        }
        for (thread, turn) in localTurns {
            if let subscription = followed[thread],
               subscription.owner != nil || Date().timeIntervalSince(subscription.requestedAt) < 10 {
                continue
            }
            followed[thread] = FollowedTurn(turnID: turn, requestedAt: Date())
            sendFollowing(thread, true)
        }
    }

    private func readRecentOutcome() -> CodexSignal? {
        let path = home.appendingPathComponent("thread_history_1.sqlite").path
        var database: OpaquePointer?
        let result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        guard result == SQLITE_OK else { return nil }

        let query = """
            SELECT status FROM thread_turns
            WHERE (status = 'completed' AND completed_at >= ?)
               OR (status = 'failed' AND completed_at >= ?)
            ORDER BY (status = 'failed') DESC, completed_at DESC LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let now = Date()
        let firstNewTurn = ceil(startedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 1, max(firstNewTurn, now.timeIntervalSince1970 - 6))
        sqlite3_bind_double(statement, 2, max(firstNewTurn, now.timeIntervalSince1970 - 12))
        guard sqlite3_step(statement) == SQLITE_ROW, let status = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: status) == "failed" ? .failed : .finished
    }

    private func activeTurns() -> [String: String]? {
        var database: OpaquePointer?
        let path = home.appendingPathComponent("thread_history_1.sqlite").path
        let result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        guard result == SQLITE_OK else { return nil }

        var statement: OpaquePointer?
        let sql = """
            SELECT t.thread_id, t.turn_id, coalesce(
                (SELECT i.created_at_ms / 1000.0 FROM thread_items i
                 WHERE i.thread_id = t.thread_id AND i.turn_id = t.turn_id
                 ORDER BY i.rollout_ordinal DESC LIMIT 1), t.started_at, 0)
            FROM thread_turns t
            WHERE t.status = 'inProgress'
              AND NOT EXISTS (
                SELECT 1 FROM thread_turns later
                WHERE later.thread_id = t.thread_id AND later.rollout_ordinal > t.rollout_ordinal
              )
            """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        var turns: [String: String] = [:]
        let recentCutoff = Date().addingTimeInterval(-45).timeIntervalSince1970
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return turns }
            guard result == SQLITE_ROW, let thread = sqlite3_column_text(statement, 0),
                  let turn = sqlite3_column_text(statement, 1) else { return nil }

            let threadID = String(cString: thread)
            let turnID = String(cString: turn)
            let observed = followed[threadID].map {
                $0.turnID == turnID && $0.status["type"] as? String == "active"
            } ?? false
            let recent = sqlite3_column_double(statement, 2) >= recentCutoff
            if observed || recent || hasLiveWriter(threadID) {
                turns[threadID] = turnID
            }
        }
    }

    private func hasLiveWriter(_ thread: String) -> Bool {
        guard UUID(uuidString: thread) != nil else { return false }
        let path = home.appendingPathComponent("thread-writer-locks").appendingPathComponent("\(thread).lock").path
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        // A lock file can survive a crash. A shared, nonblocking probe
        // distinguishes a live exclusive writer from a leftover file.
        defer { close(descriptor) }
        return flock(descriptor, LOCK_SH | LOCK_NB) == -1 && errno == EWOULDBLOCK
    }

    private func connect(_ socket: String) {
        let connection = NWConnection(to: .unix(path: socket), using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.connection === connection else { return }
            switch state {
            case .ready:
                self.send([
                    "type": "request", "requestId": UUID().uuidString,
                    "method": "initialize", "version": 0,
                    "params": ["clientType": "codex-usage-menu-bar"]
                ])
                self.receive(connection)
            case .failed, .waiting, .cancelled:
                self.disconnect()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func disconnect() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        clientID = nil
        followed.removeAll()
        buffer.removeAll()
        skipBytes = 0
        publishActivity()
    }

    private func sendFollowing(_ thread: String, _ enabled: Bool) {
        guard let clientID else { return }
        send([
            "type": "broadcast", "method": "thread-stream-following-changed",
            "sourceClientId": clientID, "version": 1,
            "params": ["hostId": "local", "conversationId": thread, "following": enabled]
        ])
    }

    private func unfollow(_ thread: String) {
        followed.removeValue(forKey: thread)
        sendFollowing(thread, false)
    }

    private func send(_ value: [String: Any]) {
        guard let payload = try? JSONSerialization.data(withJSONObject: value) else { return }
        var length = UInt32(payload.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        connection?.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection, self.connection === connection else { return }
            if let data { self.readFrames(data) }
            if complete || error != nil {
                self.disconnect()
            } else {
                self.receive(connection)
            }
        }
    }

    private func readFrames(_ data: Data) {
        buffer.append(data)
        while true {
            if skipBytes > 0 {
                let count = min(skipBytes, buffer.count)
                buffer.removeFirst(count)
                skipBytes -= count
                if skipBytes > 0 { return }
            }
            guard buffer.count >= 4 else { return }
            let length = buffer.prefix(4).enumerated().reduce(0) {
                $0 | (Int($1.element) << (8 * $1.offset))
            }
            if length > 16 * 1024 * 1024 {
                // Codex sends the runtime status near the front of a paginated
                // snapshot. Read that metadata and drain the history in chunks.
                let prefixLimit = 64 * 1024
                guard buffer.count >= 4 + prefixLimit else { return }
                let prefix = buffer.dropFirst(4).prefix(prefixLimit)
                let snapshot = readSnapshotStatus(prefix)
                buffer.removeFirst(4)
                skipBytes = length
                if let snapshot { handle(snapshot) }
                continue
            }
            guard buffer.count >= 4 + length else { return }
            let payload = buffer.dropFirst(4).prefix(length)
            buffer.removeFirst(4 + length)
            if let value = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                handle(value)
            }
        }
    }

    private func readSnapshotStatus(_ prefix: Data) -> [String: Any]? {
        let key = Data(#","threadRuntimeStatus":{"#.utf8)
        guard let field = prefix.range(of: key),
              let end = prefix[field.upperBound...].firstIndex(of: UInt8(ascii: "}")) else { return nil }

        // Close conversationState, change, params and the envelope. Parsing the
        // truncated object also verifies the field was at the expected depth.
        var metadata = Data(prefix[...end])
        metadata.append(contentsOf: "}}}}".utf8)
        guard let message = (try? JSONSerialization.jsonObject(with: metadata)) as? [String: Any],
              message["method"] as? String == "thread-stream-state-changed",
              let params = message["params"] as? [String: Any],
              let change = params["change"] as? [String: Any],
              change["type"] as? String == "snapshot",
              let state = change["conversationState"] as? [String: Any],
              state["threadRuntimeStatus"] is [String: Any] else { return nil }
        return message
    }

    private func handle(_ value: [String: Any]) {
        switch value["method"] as? String {
        case "initialize":
            clientID = (value["result"] as? [String: Any])?["clientId"] as? String
            if clientID == nil { disconnect() } else { poll() }
        case "client-status-changed":
            guard let params = value["params"] as? [String: Any],
                  params["status"] as? String == "disconnected",
                  let owner = params["clientId"] as? String else { return }
            followed = followed.filter { $0.value.owner != owner }
            publishActivity()
        case "thread-stream-state-changed":
            handleThreadChange(value)
        default: break
        }
    }

    private func handleThreadChange(_ value: [String: Any]) {
        guard let params = value["params"] as? [String: Any],
              params["hostId"] as? String == "local",
              let thread = params["conversationId"] as? String,
              var subscription = followed[thread],
              let owner = value["sourceClientId"] as? String,
              let change = params["change"] as? [String: Any] else { return }

        let previousType = subscription.status["type"] as? String
        let previousFlags = subscription.status["activeFlags"] as? [String]
        if change["type"] as? String == "snapshot" {
            let conversation = change["conversationState"] as? [String: Any]
            subscription.status = conversation?["threadRuntimeStatus"] as? [String: Any] ?? [:]
            subscription.owner = owner
        } else if change["type"] as? String == "patches", subscription.owner == owner,
                  let patches = change["patches"] as? [[String: Any]] {
            for patch in patches {
                guard let path = patch["path"] as? [Any], path.first as? String == "threadRuntimeStatus" else { continue }
                if path.count == 1 {
                    subscription.status = patch["value"] as? [String: Any] ?? [:]
                } else if let field = path[1] as? String {
                    if path.count == 2 {
                        subscription.status[field] = patch["value"]
                    } else if field == "activeFlags", let index = path[2] as? Int {
                        var flags = subscription.status[field] as? [String] ?? []
                        switch patch["op"] as? String {
                        case "add" where (0...flags.count).contains(index):
                            if let flag = patch["value"] as? String { flags.insert(flag, at: index) }
                        case "replace" where flags.indices.contains(index):
                            if let flag = patch["value"] as? String { flags[index] = flag }
                        case "remove" where flags.indices.contains(index):
                            flags.remove(at: index)
                        default: break
                        }
                        subscription.status[field] = flags
                    }
                }
            }
        }
        followed[thread] = subscription
        if previousType != subscription.status["type"] as? String
            || previousFlags != subscription.status["activeFlags"] as? [String] {
            publishActivity()
        }
    }

    private func workingChatTitles(for threads: Set<String>) -> [String] {
        guard !threads.isEmpty else { return [] }
        var database: OpaquePointer?
        let path = home.appendingPathComponent("state_5.sqlite").path
        let result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        guard result == SQLITE_OK else { return [] }

        var statement: OpaquePointer?
        let sql = "SELECT substr(coalesce(nullif(name, ''), title), 1, 200) FROM threads WHERE id = ?"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        return threads.compactMap { thread in
            thread.withCString { id -> String? in
                sqlite3_bind_text(statement, 1, id, -1, nil)
                defer {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                }
                guard sqlite3_step(statement) == SQLITE_ROW,
                      let title = sqlite3_column_text(statement, 0) else { return nil }
                return String(cString: title)
            }
        }
    }

    private func publishActivity() {
        let active = followed.filter { $0.value.status["type"] as? String == "active" }
        let waitingTurns = active.filter {
            let flags = $0.value.status["activeFlags"] as? [String] ?? []
            return flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput")
        }
        let waiting = hasPendingQuestions || !waitingTurns.isEmpty
        let unobserved = localTurns.filter { thread, turn in
            guard let subscription = followed[thread], subscription.turnID == turn else { return true }
            return subscription.status["type"] == nil
        }
        let running = Set(active.keys).subtracting(waitingTurns.keys).union(unobserved.keys)
        let names = workingChatTitles(for: running) + cloud.workingTitles
        let titles = Set(names.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }).sorted()
        let outcomes = [recentOutcome, cloud.outcome]
        let outcome: CodexSignal? = outcomes.contains(.failed) ? .failed : outcomes.compactMap { $0 }.first
        let next = CodexActivity(working: !running.isEmpty || cloud.working,
                                 signal: waiting ? .needsInput : outcome,
                                 workingChatTitles: titles)
        guard next != activity else { return }
        activity = next
        DispatchQueue.main.async { [onChange] in onChange(next) }
    }
}
