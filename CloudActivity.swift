import Foundation
import Security

func codexExecutable() -> URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let applicationDirectories = ["/Applications", "\(home)/Applications"]
    let appNames = ["ChatGPT.app", "Codex.app"]
    let bundledExecutables = [
        "codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "codex-cli/bin/codex",
        "codex"
    ]
    for directory in applicationDirectories {
        for app in appNames {
            let bundle = "\(directory)/\(app)"
            for executable in bundledExecutables {
                if let trusted = trustedCodexExecutable(
                    at: "\(bundle)/Contents/Resources/\(executable)", under: bundle
                ) {
                    return trusted
                }
            }
        }
    }
    for prefix in ["/opt/homebrew", "/usr/local"] {
        if let trusted = trustedCodexExecutable(at: "\(prefix)/bin/codex", under: prefix) {
            return trusted
        }
    }
    return nil
}

func trustedCodexExecutable(at path: String, under installation: String) -> URL? {
    guard path.hasPrefix("/"), installation.hasPrefix("/"),
          FileManager.default.isExecutableFile(atPath: path) else { return nil }
    let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    guard executable.path.hasPrefix(installation + "/") else { return nil }

    let openAIRequirement = #"anchor apple generic and identifier "codex" and certificate leaf[subject.OU] = "2DC432GLL2""#
    var requirement: SecRequirement?
    var code: SecStaticCode?
    guard SecRequirementCreateWithString(openAIRequirement as CFString, [], &requirement) == errSecSuccess,
          let requirement,
          SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
          let code,
          SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                                     requirement) == errSecSuccess else { return nil }
    return executable
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
    private var pendingChats: [WorkingChat] = []
    private var lastSuccess: Date?
    private var nextPoll = Date.distantPast
    private var process: Process?
    private var lastOutcome: (signal: CodexSignal, expires: Date)?

    var working: Bool {
        guard let lastSuccess, Date().timeIntervalSince(lastSuccess) < 45 else { return false }
        return !pending.isEmpty
    }

    var workingChats: [WorkingChat] { working ? pendingChats : [] }

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
        pendingChats = pendingTasks.map { WorkingChat(id: "cloud:\($0.id)", title: $0.title) }
        lastSuccess = now
        nextPoll = now.addingTimeInterval(pending.isEmpty ? 20 : 5)
    }
}
