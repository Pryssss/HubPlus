import Foundation

/// Minimal synchronous process runner. Used for short, fast commands (git).
enum Shell {
    /// Run an executable and return trimmed stdout, or nil on launch failure /
    /// non-zero exit. Reads to EOF before waiting, which is safe for the small
    /// outputs we use it for.
    @discardableResult
    static func run(_ launchPath: String, _ args: [String], cwd: String? = nil) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
