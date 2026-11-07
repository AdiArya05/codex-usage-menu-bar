import Foundation
import SQLite3

/// Tracks question cards that can remain answerable after their Codex turn finishes.
final class PendingQuestions {
    private struct Question: Hashable {
        let messageID: String
        let index: Int
    }

    private let home: URL
    private var cursor: Int64 = 0
    private var pending: [String: [Question: String]] = [:]

    init(home: URL) {
        self.home = home
    }

    func poll() -> Bool? {
        let history = home.appendingPathComponent("thread_history_1.sqlite").path
        var database: OpaquePointer?
        let result = sqlite3_open_v2(history, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        guard result == SQLITE_OK else { return nil }

        // Pin the upper bound so rows written during the scan are picked up next time.
        var endStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT coalesce(max(rowid), 0) FROM thread_items", -1, &endStatement, nil) == SQLITE_OK else { return nil }
        let endResult = sqlite3_step(endStatement)
        let end = sqlite3_column_int64(endStatement, 0)
        sqlite3_finalize(endStatement)
        guard endResult == SQLITE_ROW else { return nil }
        if end < cursor {
            cursor = 0
            pending.removeAll()
        }
        guard end > cursor else { return hasCurrentQuestions(in: database) }

        let query = """
            SELECT rowid, thread_id, item_type, item_id, turn_id,
                   CASE WHEN item_type = 'agentMessage' THEN json_array_length(item_json, '$.questions') END,
                   CASE WHEN item_type = 'userMessage' AND item_json LIKE '%<send_user_message_question_reply>%'
                        THEN item_json END
            FROM thread_items
            WHERE rowid > ? AND rowid <= ? AND (
                item_type = 'userMessage' OR
                (item_type = 'agentMessage' AND json_array_length(item_json, '$.questions') > 0)
            )
            ORDER BY rowid
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, cursor)
        sqlite3_bind_int64(statement, 2, end)

        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW,
                  let thread = sqlite3_column_text(statement, 1),
                  let type = sqlite3_column_text(statement, 2) else { return nil }
            let threadID = String(cString: thread)
            if String(cString: type) == "agentMessage",
               let item = sqlite3_column_text(statement, 3), let turn = sqlite3_column_text(statement, 4) {
                let messageID = String(cString: item)
                let turnID = String(cString: turn)
                let count = Int(sqlite3_column_int(statement, 5))
                for index in 0..<count {
                    pending[threadID, default: [:]][Question(messageID: messageID, index: index)] = turnID
                }
            } else if pending[threadID] != nil {
                if let raw = sqlite3_column_text(statement, 6), let answers = replies(in: String(cString: raw)) {
                    for answer in answers { pending[threadID]?.removeValue(forKey: answer) }
                    if pending[threadID]?.isEmpty == true { pending.removeValue(forKey: threadID) }
                } else {
                    // A new ordinary prompt moves the chat past its old questions.
                    pending.removeValue(forKey: threadID)
                }
            }
            cursor = sqlite3_column_int64(statement, 0)
        }
        cursor = end
        return hasCurrentQuestions(in: database)
    }

    private func replies(in item: String) -> Set<Question>? {
        guard let item = (try? JSONSerialization.jsonObject(with: Data(item.utf8))) as? [String: Any],
              let content = item["content"] as? [[String: Any]] else { return nil }
        let message = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let close = "</send_user_message_question_reply>"
        guard message.hasSuffix(close),
              let start = message.range(of: "<send_user_message_question_reply>", options: .backwards) else { return nil }
        let payload = message[start.upperBound..<message.index(message.endIndex, offsetBy: -close.count)]
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) else { return nil }
        let answers = (parsed as? [[String: Any]]) ?? (parsed as? [String: Any]).map { [$0] } ?? []
        return Set(answers.compactMap { answer in
            guard let rawID = answer["questionItemId"] as? String,
                  let id = (try? JSONSerialization.jsonObject(with: Data(rawID.utf8))) as? [Any],
                  id.count == 3, id[0] as? String == "request_user_input_async",
                  let messageID = id[1] as? String, let index = id[2] as? Int else { return nil }
            return Question(messageID: messageID, index: index)
        })
    }

    private func hasCurrentQuestions(in history: OpaquePointer?) -> Bool? {
        guard !pending.isEmpty else { return false }
        var database: OpaquePointer?
        let state = home.appendingPathComponent("state_5.sqlite").path
        let result = sqlite3_open_v2(state, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        guard result == SQLITE_OK else { return nil }

        var latestTurn: OpaquePointer?
        let latest = """
            SELECT turn_id, status, completed_at FROM thread_turns
            WHERE thread_id = ? ORDER BY rollout_ordinal DESC LIMIT 1
            """
        guard sqlite3_prepare_v2(history, latest, -1, &latestTurn, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(latestTurn) }

        var statement: OpaquePointer?
        let query = "SELECT 1 FROM threads WHERE id = ? AND archived = 0"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let cutoff = Date().addingTimeInterval(-10 * 60).timeIntervalSince1970
        for (thread, questions) in pending {
            let relevant = thread.withCString {
                sqlite3_bind_text(latestTurn, 1, $0, -1, nil)
                defer {
                    sqlite3_reset(latestTurn)
                    sqlite3_clear_bindings(latestTurn)
                }
                guard sqlite3_step(latestTurn) == SQLITE_ROW,
                      let turn = sqlite3_column_text(latestTurn, 0),
                      let status = sqlite3_column_text(latestTurn, 1),
                      questions.values.contains(String(cString: turn)) else { return false }
                let state = String(cString: status)
                return state == "inProgress" || (state == "completed" && sqlite3_column_double(latestTurn, 2) >= cutoff)
            }
            guard relevant else { continue }
            let result = thread.withCString {
                sqlite3_bind_text(statement, 1, $0, -1, nil)
                let result = sqlite3_step(statement)
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                return result
            }
            if result == SQLITE_ROW { return true }
            guard result == SQLITE_DONE else { return nil }
        }
        return false
    }
}
