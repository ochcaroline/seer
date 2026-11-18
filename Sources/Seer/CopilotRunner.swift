import Foundation

final class CopilotRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    /// Runs Copilot with `dir` (created if needed) as its working directory, the only place its file tools can see.
    func run(_ prompt: String, model: String, in dir: URL) -> String {
        let home = NSHomeDirectory()
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.npm-global/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        guard let path = dirs.map({ $0 + "/copilot" }).first(where: FileManager.default.isExecutableFile) else {
            return "Copilot CLI was not found. Install it and run `copilot login`."
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = [
            "--prompt", prompt,
            "--silent",
            "--model", model,
            "--available-tools", "view,grep,glob",
            "--allow-tool", "view",
            "--allow-tool", "grep",
            "--allow-tool", "glob",
            "--deny-tool", "shell",
            "--deny-tool", "write",
        ]
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch { return "Could not create Copilot's working directory \(dir.path): \(error.localizedDescription)" }
        p.currentDirectoryURL = dir
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        lock.lock()
        process = p
        lock.unlock()
        defer {
            lock.lock()
            process = nil
            lock.unlock()
        }
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let response = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard p.terminationReason == .exit, p.terminationStatus == 0 else {
                return "Copilot failed (exit status \(p.terminationStatus))." + (response.isEmpty ? "" : "\n\n" + response)
            }
            return response.isEmpty ? "Copilot returned no response." : response
        } catch { return "Could not start Copilot: \(error.localizedDescription)" }
    }

    func cancel() {
        lock.lock()
        process?.terminate()
        lock.unlock()
    }
}
