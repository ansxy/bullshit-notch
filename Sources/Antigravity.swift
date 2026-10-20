import Foundation

/// Live Antigravity conversations (agy CLI, and the app if it uses the same layout).
///
/// A running conversation holds an exclusive flock on `<root>/presence/<conversation-id>.lock`;
/// its transcript is `<root>/brain/<id>/.system_generated/logs/transcript.jsonl`.
/// ponytail: undocumented Antigravity file layout; if it changes upstream these rows just disappear.
final class AntigravitySessions {
    private let roots = ["antigravity-cli", "antigravity"].map {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini").appendingPathComponent($0)
    }

    /// The agy process holding a conversation's lock, and its working directory.
    private struct Owner { let pid: Int32; let cwd: String }
    private var owners: [String: Owner] = [:]  // conversation id -> owner

    /// What we've pulled out of one transcript so far.
    private struct Parsed {
        var offset: UInt64 = 0
        var usage: [Int: (Int, Int)] = [:]  // by step_index
        var status = "idle"
        var lastStep: Date?
        var total: (input: Int, output: Int) { usage.values.reduce((0, 0)) { ($0.0 + $1.0, $0.1 + $1.1) } }
    }
    private var parsed: [URL: Parsed] = [:]

    private let iso = ISO8601DateFormatter()
    private let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func refresh() -> [(agent: Agent, tokens: (input: Int, output: Int))] {
        var result: [(agent: Agent, tokens: (input: Int, output: Int))] = []
        var live: Set<String> = []
        var liveURLs: Set<URL> = []
        for root in roots {
            let presence = root.appendingPathComponent("presence")
            let locks = (try? FileManager.default.contentsOfDirectory(
                at: presence, includingPropertiesForKeys: [.creationDateKey])) ?? []
            for lock in locks where lock.pathExtension == "lock" && isHeld(lock) {
                let id = lock.deletingPathExtension().lastPathComponent
                guard let owner = owner(of: lock, id: id) else { continue }
                live.insert(id)
                let transcript = root.appendingPathComponent("brain").appendingPathComponent(id)
                    .appendingPathComponent(".system_generated/logs/transcript.jsonl")
                liveURLs.insert(transcript)
                var p = parse(transcript)
                // ponytail: if the transcript has been silent for 10 min, assume we misread a final step and call it idle.
                if p.status == "busy", let last = p.lastStep, last.timeIntervalSinceNow < -600 { p.status = "idle" }
                let created = (try? lock.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
                let agent = Agent(harness: .antigravity, pid: owner.pid, sessionId: id, cwd: owner.cwd, name: nil,
                                  status: p.status, startedAt: created.timeIntervalSince1970 * 1000,
                                  statusUpdatedAt: p.lastStep.map { $0.timeIntervalSince1970 * 1000 })
                result.append((agent, p.total))
            }
        }
        owners = owners.filter { live.contains($0.key) }
        parsed = parsed.filter { liveURLs.contains($0.key) }
        return result
    }

    /// True if some process holds the lock, i.e. the conversation is open.
    private func isHeld(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return true
    }

    /// Looks up (once per conversation) which agy process holds the lock and where it runs.
    private func owner(of lock: URL, id: String) -> Owner? {
        if let cached = owners[id], kill(cached.pid, 0) == 0 { return cached }
        let pidText = shell("/usr/sbin/lsof", ["-t", lock.path]).split(separator: "\n").first ?? ""
        guard let pid = Int32(pidText.trimmingCharacters(in: .whitespaces)) else { return nil }
        let cwd = shell("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"])
            .split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let owner = Owner(pid: pid, cwd: cwd)
        owners[id] = owner
        return owner
    }

    /// Reads only the bytes appended to a transcript since the last call.
    private func parse(_ url: URL) -> Parsed {
        var entry = parsed[url] ?? Parsed()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return entry }
        defer { try? handle.close() }
        try? handle.seek(toOffset: entry.offset)
        let data = (try? handle.readToEnd()) ?? Data()
        // Only consume complete lines; a half-written last line is picked up next poll.
        if let end = data.lastIndex(of: UInt8(ascii: "\n")) {
            autoreleasepool {
                for line in data[..<end].split(separator: UInt8(ascii: "\n")) {
                    read(line, into: &entry)
                }
            }
            entry.offset += UInt64(end - data.startIndex + 1)
        }
        parsed[url] = entry
        return entry
    }

    private func read(_ line: Data.SubSequence, into entry: inout Parsed) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let type = obj["type"] as? String ?? ""
        let stepStatus = (obj["status"] as? String ?? "").uppercased()
        if let text = obj["created_at"] as? String,
           let date = iso.date(from: text) ?? isoFractional.date(from: text) {
            entry.lastStep = date
        }

        // Latest step decides the status: a model reply with no tool calls hands control back to you.
        if stepStatus.contains("WAIT") {
            entry.status = "waiting"
        } else if stepStatus.contains("ERROR") || stepStatus.contains("CANCEL") {
            entry.status = "idle"
        } else if type == "PLANNER_RESPONSE" {
            let calls = obj["tool_calls"] as? [Any] ?? []
            entry.status = calls.isEmpty ? "idle" : "busy"
        } else {
            entry.status = "busy"  // user input or a tool result: the model is up next
        }

        guard type == "PLANNER_RESPONSE" else { return }
        let int = { (k: String) in obj[k] as? Int ?? 0 }
        let key = obj["step_index"] as? Int ?? entry.usage.count
        entry.usage[key] = (
            int("input_tokens") + int("cache_creation_tokens") + int("cache_write_tokens") + int("cache_read_tokens") / 10,
            int("output_tokens"))
    }
}
