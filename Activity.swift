import Foundation
import Network
import SQLite3

enum CodexActivity: String {
    case idle = "Idle"
    case working = "Working"
    case needsInput = "Needs your input"
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

    private let home: URL
    private let questions: PendingQuestions
    private var hasPendingQuestions = false
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
            self.disconnect()
        }
    }

    private func poll() {
        if let pending = questions.poll(), pending != hasPendingQuestions {
            hasPendingQuestions = pending
            publishActivity()
        }
        guard connection != nil else {
            let socket = home.appendingPathComponent("ipc/ipc.sock").path
            guard FileManager.default.fileExists(atPath: socket) else { return }
            connect(socket)
            return
        }
        guard clientID != nil, let turns = activeTurns() else { return }
        for (thread, subscription) in followed where turns[thread] != subscription.turnID {
            unfollow(thread)
        }
        for (thread, turn) in turns {
            if let subscription = followed[thread],
               subscription.owner != nil || Date().timeIntervalSince(subscription.requestedAt) < 10 {
                continue
            }
            followed[thread] = FollowedTurn(turnID: turn, requestedAt: Date())
            sendFollowing(thread, true)
        }
        publishActivity()
    }

    private func activeTurns() -> [String: String]? {
        let lockDirectory = home.appendingPathComponent("thread-writer-locks")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: lockDirectory.path)) ?? []
        let ids = files.filter { $0.hasSuffix(".lock") }
            .map { String($0.dropLast(5)) }
            .filter { UUID(uuidString: $0) != nil }
        guard !ids.isEmpty else { return [:] }

        var database: OpaquePointer?
        let path = home.appendingPathComponent("thread_history_1.sqlite").path
        let result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        guard result == SQLITE_OK else { return nil }

        var statement: OpaquePointer?
        let sql = """
            SELECT turn_id, status FROM thread_turns
            WHERE thread_id = ? ORDER BY rollout_ordinal DESC LIMIT 1
            """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        var turns: [String: String] = [:]
        for id in ids {
            let result = id.withCString { identifier in
                sqlite3_bind_text(statement, 1, identifier, -1, nil)
                let result = sqlite3_step(statement)
                if result == SQLITE_ROW,
                   let status = sqlite3_column_text(statement, 1), String(cString: status) == "inProgress",
                   let turn = sqlite3_column_text(statement, 0) {
                    turns[id] = String(cString: turn)
                }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                return result
            }
            guard result == SQLITE_ROW || result == SQLITE_DONE else { return nil }
        }
        return turns
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
            // Large history snapshots are irrelevant to the activity indicator.
            if length > 16 * 1024 * 1024 {
                buffer.removeFirst(4)
                skipBytes = length
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
        publishActivity()
    }

    private func publishActivity() {
        let active = followed.values.filter { $0.status["type"] as? String == "active" }
        let waiting = hasPendingQuestions || active.contains {
            let flags = $0.status["activeFlags"] as? [String] ?? []
            return flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput")
        }
        let next: CodexActivity = waiting ? .needsInput : active.isEmpty ? .idle : .working
        guard next != activity else { return }
        activity = next
        DispatchQueue.main.async { [onChange] in onChange(next) }
    }
}
