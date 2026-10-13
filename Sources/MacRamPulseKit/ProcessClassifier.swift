import Foundation
import Darwin

// MARK: - Process Grouping Rules

struct GroupInfo {
    let name: String
    let icon: String
    var isProtected = false
    var isReclaimable = false
}

enum ProcessClassifier {
    static let claude = GroupInfo(name: "Claude", icon: "🧠", isProtected: true)
    static let standaloneCodex = GroupInfo(name: "Codex CLI (독립 세션)", icon: "⌨️", isProtected: true)
    static let codexChildren = GroupInfo(name: "Codex MCP·REPL 하위 서버", icon: "🧩")

    /// Which Codex process hosts a process tree.
    enum CodexHost { case chatGPTApp, standalone }

    static func classify(_ s: ProcSample) -> GroupInfo? {
        let lower = s.path.lowercased()
        let parent = s.parentPath.lowercased()

        if lower.contains("android studio.app/contents/jbr") {
            return GroupInfo(name: "Android Studio (Java/Gradle 데몬)", icon: "☕", isReclaimable: true)
        }
        if lower.contains("dartaotruntime") || lower.contains("flutter_tester") {
            return GroupInfo(name: "Flutter / Dart 런타임 데몬", icon: "🎯", isReclaimable: true)
        }
        if let host = codexAncestor(of: s) {
            return host == .standalone ? standaloneCodex : codexChildren
        }
        if ProcessScanner.isNode(s.path) {
            if s.args.lowercased().contains("openclaw") {
                return GroupInfo(name: "OpenClaw 게이트웨이", icon: "🦞", isProtected: true)
            }
            if parent.contains("claude") || s.grandparentPath.lowercased().contains("claude") { return claude }
            return GroupInfo(name: "Node.js (기타 MCP/개발 서버)", icon: "🟢", isProtected: true)
        }
        if codexHost(of: s.path) == .standalone { return standaloneCodex }
        if lower.contains("/chatgpt.app/") || lower.contains("/codex") {
            return GroupInfo(name: "ChatGPT & Codex 앱", icon: "🤖")
        }
        if lower.contains("google chrome") { return GroupInfo(name: "Google Chrome", icon: "🌐") }
        if lower.contains("/aside.app/") { return GroupInfo(name: "Aside", icon: "🎙️") }
        if lower.contains("/antigravity.app/") {
            return GroupInfo(name: "Antigravity (현재 실행중)", icon: "🚀", isProtected: true)
        }
        if lower.contains("claude") { return claude }
        if lower.contains("/notion.app/") { return GroupInfo(name: "Notion", icon: "📝") }
        if isLinuxVM(lower) { return GroupInfo(name: "Colima / Linux VM", icon: "🐳", isProtected: true) }
        if lower.contains("splashtop") { return GroupInfo(name: "Splashtop Streamer", icon: "🖥️") }
        if lower.contains("/obsidian.app/") { return GroupInfo(name: "Obsidian", icon: "💎") }
        if lower.contains("webkit") || lower.contains("/safari.app/") { return GroupInfo(name: "Safari / WebKit", icon: "🧭") }
        if let appRange = s.path.range(of: ".app/") {
            let prefix = s.path[..<appRange.lowerBound]
            let name = prefix.lastIndex(of: "/").map { String(prefix[prefix.index(after: $0)...]) } ?? String(prefix)
            return GroupInfo(name: name, icon: "📦")
        }
        return nil
    }

    static func isLinuxVM(_ lowerPath: String) -> Bool {
        let exe = (lowerPath as NSString).lastPathComponent
        return lowerPath.contains("virtualization.virtualmachine") || exe == "colima" || exe == "limactl"
    }

    static func codexHost(of path: String) -> CodexHost? {
        let lower = path.lowercased()
        if lower.contains("/.local/bin/codex") || lower.contains("/.codex/packages/") { return .standalone }
        if lower.contains("/codex") { return .chatGPTApp }
        return nil
    }

    private static func isRelay(_ path: String) -> Bool {
        ProcessScanner.isNode(path) || path.lowercased().hasSuffix("/node_repl")
    }

    /// Codex spawns a full set of MCP servers (and CUA node_repl kernels) per chat thread and keeps
    /// them alive. Matches direct children and grandchildren behind `npm exec` / `node_repl`.
    static func codexAncestor(of s: ProcSample) -> CodexHost? {
        guard isRelay(s.path) else { return nil }
        if let host = codexHost(of: s.parentPath) { return host }
        if isRelay(s.parentPath), let host = codexHost(of: s.grandparentPath) { return host }
        return nil
    }

    /// Duplicate ChatGPT-Codex MCP servers (same parent + cwd + argv), keeping the newest of each set.
    /// A server only counts as idle if its whole `node` subtree is idle; the subtree is returned with it.
    /// Servers of the standalone (protected) Codex CLI and servers with an unknown cwd are never touched.
    static func idleCodexDuplicates(_ samples: [ProcSample], minIdleSec: Double) -> [ProcSample] {
        let nodeChildren = Dictionary(grouping: samples.filter { ProcessScanner.isNode($0.path) }) { $0.ppid }
        let servers = samples.filter {
            ProcessScanner.isNode($0.path) && !$0.cwd.isEmpty && codexHost(of: $0.parentPath) == .chatGPTApp
        }
        let roots = Dictionary(grouping: servers) { "\($0.ppid)|\($0.cwd)|\($0.args)" }.values.flatMap { set -> [ProcSample] in
            guard set.count > 1, let newest = set.min(by: { $0.ageSec < $1.ageSec }) else { return [] }
            return set.filter { $0.pid != newest.pid }
        }
        let keepers = Set(servers.map(\.pid)).subtracting(roots.map(\.pid))

        func subtree(_ root: ProcSample) -> [ProcSample] {
            var out: [ProcSample] = []
            var seen = Set<pid_t>()
            var stack = [root]
            while let s = stack.popLast() {
                guard seen.insert(s.pid).inserted else { continue }   // snapshot may contain pid-reuse cycles
                out.append(s)
                stack += nodeChildren[s.pid] ?? []
            }
            return out
        }

        var victims: [pid_t: ProcSample] = [:]
        for tree in roots.map(subtree)
        where tree.allSatisfy({ $0.idleSec >= minIdleSec && !keepers.contains($0.pid) }) {
            tree.forEach { victims[$0.pid] = $0 }
        }
        return Array(victims.values)
    }
}
