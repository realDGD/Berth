import Foundation

/// Select a server-supported character locale without replacing its other locale categories.
enum RemoteLocale {
    static let probeScript = """
    charset=$(locale charmap 2>/dev/null) || exit 1
    installed=$(locale -a 2>/dev/null) || exit 1
    printf '%s\\n' '__BERTH_LOCALE_BEGIN__' "$charset" "${LC_ALL-}" "$installed" '__BERTH_LOCALE_END__'
    """

    static func characterLocale(from output: String) -> String? {
        let lines = output.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let begin = lines.firstIndex(of: "__BERTH_LOCALE_BEGIN__"),
              let end = lines[(begin + 1)...].firstIndex(of: "__BERTH_LOCALE_END__"),
              end > begin + 2 else { return nil }
        let charset = lines[begin + 1].lowercased().replacingOccurrences(of: "-", with: "")
        // LC_ALL takes precedence over LC_CTYPE; preserve an explicit server choice.
        guard !charset.isEmpty, charset != "utf8", lines[begin + 2].isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.@-")
        let candidates = lines[(begin + 3)..<end].filter { name in
            guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }),
                  let encoding = name.split(separator: ".", maxSplits: 1).dropFirst().first else { return false }
            return encoding.split(separator: "@", maxSplits: 1).first?
                .lowercased().replacingOccurrences(of: "-", with: "") == "utf8"
        }
        // Keep the exact spelling advertised by locale -a (e.g. C.utf8).
        return candidates.first { $0.lowercased().hasPrefix("c.") }
            ?? candidates.first { $0.lowercased().hasPrefix("en_us.") }
            ?? candidates.first
    }

    /// A failed or unavailable exec probe must not prevent opening a PTY.
    static func detect(
        timeout: Duration = .seconds(2),
        probe: @escaping @Sendable () async throws -> String
    ) async -> String? {
        // A task group waits for cancelled children. SSH channel creation can be waiting on
        // an event-loop future, so race via a stream instead of delaying the terminal on it.
        let (results, continuation) = AsyncStream<String?>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let probeTask = Task {
            let result: String?
            do { result = characterLocale(from: try await probe()) }
            catch { result = nil }
            continuation.yield(result)
            continuation.finish()
        }
        let timer = Task {
            do { try await Task.sleep(for: timeout) }
            catch { return }
            continuation.yield(nil)
            continuation.finish()
        }
        defer {
            probeTask.cancel()
            timer.cancel()
            continuation.finish()
        }
        var iterator = results.makeAsyncIterator()
        return await iterator.next() ?? nil
    }
}
