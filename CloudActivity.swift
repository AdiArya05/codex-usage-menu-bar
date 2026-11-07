import Foundation

func codexExecutable() -> URL? {
    let candidates = [
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
    ] + (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":").map { "\($0)/codex" }
    return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
        .map { URL(fileURLWithPath: $0) }
}

/// Cloud tasks use a separate authenticated CLI feed from local Desktop turns.
/// Called only on the activity monitor's serial queue.
final class CloudActivity {
    private struct TaskPage: Decodable {
        struct Task: Decodable {
            let id: String
            let status: String
            let title: String?
        }

        let tasks: [Task]
    }

    private var pending: Set<String> = []
    private var pendingTitles: [String] = []
    private var lastSuccess: Date?
    private var nextPoll = Date.distantPast
    private var process: Process?
    private var lastOutcome: (signal: CodexSignal, expires: Date)?

    var working: Bool {
        guard let lastSuccess, Date().timeIntervalSince(lastSuccess) < 45 else { return false }
        return !pending.isEmpty
    }

    var workingTitles: [String] { working ? pendingTitles : [] }

    var outcome: CodexSignal? {
        guard let lastOutcome, lastOutcome.expires > Date() else { return nil }
        return lastOutcome.signal
    }

    func poll(on queue: DispatchQueue, didUpdate: @escaping () -> Void) {
        guard process == nil, nextPoll <= Date() else { return }
        nextPoll = Date().addingTimeInterval(20)
        guard let executable = codexExecutable() else { return }

        let child = Process()
        let output = Pipe()
        child.executableURL = executable
        child.arguments = ["cloud", "list", "--json", "--limit", "20"]
        child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice

        do {
            try child.run()
        } catch {
            return
        }
        process = child

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = try? output.fileHandleForReading.readToEnd()
            child.waitUntilExit()
            queue.async { [weak self] in
                guard let self, self.process === child else { return }
                self.process = nil
                guard child.terminationStatus == 0, let data,
                      let page = try? JSONDecoder().decode(TaskPage.self, from: data) else { return }
                self.update(page)
                didUpdate()
            }
        }
        queue.asyncAfter(deadline: .now() + 8) { [weak self, weak child] in
            guard let child, self?.process === child, child.isRunning else { return }
            child.terminate()
        }
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    private func update(_ page: TaskPage) {
        let now = Date()
        let changed = page.tasks.filter { pending.contains($0.id) }
        if changed.contains(where: { $0.status == "error" }) {
            lastOutcome = (.failed, now.addingTimeInterval(12))
        } else if changed.contains(where: { $0.status == "ready" || $0.status == "applied" }) {
            lastOutcome = (.finished, now.addingTimeInterval(6))
        }
        let pendingTasks = page.tasks.filter { $0.status == "pending" }
        pending = Set(pendingTasks.map(\.id))
        pendingTitles = pendingTasks.compactMap(\.title)
        lastSuccess = now
        nextPoll = now.addingTimeInterval(pending.isEmpty ? 20 : 5)
    }
}
