import Foundation

/// A long-running ChatGPT whose Codex engine has grown large enough that a restart is worth it.
struct CodexAdvice: Equatable {
    let mainPid: pid_t        // ChatGPT main process
    let uptimeHours: Double
    let engineMB: Double      // Codex app-server footprint
    let treeMB: Double        // whole ChatGPT process tree (what a restart gives back, at most)
    let childCount: Int       // processes under the Codex engine
}

enum CodexHealth {
    /// The engine grew from ~3.5GB to 10.7GB in 2.5 days on the author's Mac mini (2026-10-12 → 10-14).
    static let engineWarnMB = 6 * 1024.0
    static let treeWarnMB = 16 * 1024.0

    static func assess(_ samples: [ProcSample]) -> CodexAdvice? {
        guard let main = samples.first(where: { $0.path.hasSuffix("/ChatGPT.app/Contents/MacOS/ChatGPT") }) else {
            return nil
        }
        let children = Dictionary(grouping: samples) { $0.ppid }
        func descendants(of pid: pid_t) -> [ProcSample] {
            var out: [ProcSample] = []
            var seen: Set<pid_t> = [pid]
            var stack = children[pid] ?? []
            while let s = stack.popLast() {
                guard seen.insert(s.pid).inserted else { continue }
                out.append(s)
                stack += children[s.pid] ?? []
            }
            return out
        }
        let tree = [main] + descendants(of: main.pid)
        let engine = tree.first { $0.ppid == main.pid && ProcessClassifier.codexHost(of: $0.path) == .chatGPTApp }
        let engineMB = engine?.footprintMB ?? 0
        let treeMB = tree.reduce(0) { $0 + $1.footprintMB }
        guard engineMB >= engineWarnMB || treeMB >= treeWarnMB else { return nil }
        return CodexAdvice(
            mainPid: main.pid,
            uptimeHours: Double(main.ageSec) / 3600,
            engineMB: engineMB,
            treeMB: treeMB,
            childCount: engine.map { descendants(of: $0.pid).count } ?? 0
        )
    }
}
