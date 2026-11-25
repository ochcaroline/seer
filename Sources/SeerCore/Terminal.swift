import Foundation

/// Opens a PR in a new terminal window: tmux session `seer-<repo>-<n>` with the PR checked out, nvim in the first window and a spare shell in the second.
public enum Terminal: String, CaseIterable, Sendable {
    case ghostty = "Ghostty", kitty = "kitty", terminal = "Terminal"

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static func sessionName(_ repo: Repo, _ number: Int) -> String {
        "seer-\(repo.name)-\(number)".map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined()
    }

    /// Re-attaches when the session already exists; on any failure waits so the error stays readable.
    public static func script(dir: String, repo: Repo, number: Int) -> String {
        let name = sessionName(repo, number)
        let s = quote(name), exact = quote("=" + name), d = quote(dir)
        return "cd \(d) && gh pr checkout \(number) -R \(quote(repo.full))"
            + " && { tmux has-session -t \(exact) 2>/dev/null || { tmux new-session -d -s \(s) -c \(d) nvim && tmux new-window -d -t \(s) -c \(d); }; }"
            + " && exec tmux attach -t \(exact)"
            + " || { printf '\\nFailed. Press Enter to close. '; read _; }"
    }

    /// Runs through `shell -lc` so the user's PATH (brew, nvim, tmux) applies, as GUI apps don't inherit it.
    public func command(shell: String, script: String) -> (exe: String, args: [String]) {
        switch self {
        case .ghostty: return ("/usr/bin/open", ["-na", "Ghostty", "--args", "-e", shell, "-lc", script])
        case .kitty: return ("/usr/bin/open", ["-na", "kitty", "--args", shell, "-lc", script])
        case .terminal:
            let line = "\(Self.quote(shell)) -lc \(Self.quote(script))"
                .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return ("/usr/bin/osascript", ["-e", "tell application \"Terminal\" to activate",
                                           "-e", "tell application \"Terminal\" to do script \"\(line)\""])
        }
    }
}
