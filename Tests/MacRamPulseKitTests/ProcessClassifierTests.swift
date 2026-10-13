import Darwin
import Testing
@testable import MacRamPulseKit

@Suite("ProcessClassifier — app grouping & protection")
struct ProcessClassifierTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let label: String
        let path: String
        var parent = ""
        var grandparent = ""
        var args = ""
        let group: String?
        var isProtected = false
        var isReclaimable = false
        var testDescription: String { label }
    }

    static let cases: [Case] = [
        Case(label: "Android Studio JBR java is a reclaimable build daemon",
             path: Paths.jbrJava, group: "Android Studio (Java/Gradle 데몬)", isReclaimable: true),
        Case(label: "dartaotruntime is a reclaimable build daemon",
             path: Paths.dart, group: "Flutter / Dart 런타임 데몬", isReclaimable: true),
        Case(label: "OpenClaw gateway node (by argv) is protected",
             path: Paths.node, parent: Paths.launchd,
             args: "node --max-old-space-size=8192 /opt/homebrew/lib/node_modules/openclaw/dist/index.js gateway",
             group: "OpenClaw 게이트웨이", isProtected: true),
        Case(label: "Claude Code MCP node child belongs to protected Claude",
             path: Paths.node, parent: Paths.claudeCode, group: "Claude", isProtected: true),
        Case(label: "npm-exec grandchild of Claude Code belongs to protected Claude",
             path: Paths.node, parent: Paths.node, grandparent: Paths.claudeCode, group: "Claude", isProtected: true),
        Case(label: "Codex app-server MCP child goes to Codex children group",
             path: Paths.cuaNode, parent: Paths.codexAppServer, args: "node ./server.mjs",
             group: "Codex MCP·REPL 하위 서버"),
        Case(label: "npm-exec grandchild of Codex app-server goes to Codex children",
             path: Paths.node, parent: Paths.node, grandparent: Paths.codexAppServer,
             group: "Codex MCP·REPL 하위 서버"),
        Case(label: "CUA node_repl goes to Codex children",
             path: Paths.nodeRepl, parent: Paths.codexAppServer, group: "Codex MCP·REPL 하위 서버"),
        Case(label: "standalone Codex CLI is protected",
             path: Paths.standaloneCodex, parent: Paths.launchd, group: "Codex CLI (독립 세션)", isProtected: true),
        Case(label: "MCP child of the standalone Codex CLI stays protected with its session",
             path: Paths.node, parent: Paths.standaloneCodex, group: "Codex CLI (독립 세션)", isProtected: true),
        Case(label: "npm-exec grandchild of the standalone Codex CLI stays protected",
             path: Paths.node, parent: Paths.node, grandparent: Paths.standaloneCodex,
             group: "Codex CLI (독립 세션)", isProtected: true),
        Case(label: "ChatGPT renderer is closable",
             path: Paths.codexRenderer, group: "ChatGPT & Codex 앱"),
        Case(label: "other node servers are protected",
             path: Paths.node, parent: Paths.launchd, args: "node serve/build/main.js",
             group: "Node.js (기타 MCP/개발 서버)", isProtected: true),
        Case(label: "Colima Virtualization VM is protected",
             path: Paths.colimaVM, group: "Colima / Linux VM", isProtected: true),
        Case(label: "limactl host agent is protected with Colima",
             path: Paths.limactl, group: "Colima / Linux VM", isProtected: true),
        Case(label: "Claude desktop is protected",
             path: Paths.claudeDesktop, group: "Claude", isProtected: true),
        Case(label: "Antigravity app is protected",
             path: Paths.antigravity, group: "Antigravity (현재 실행중)", isProtected: true),
        Case(label: "Aside renderer groups into Aside",
             path: Paths.asideRenderer, group: "Aside"),
        Case(label: "nested helper app is grouped by its outer .app",
             path: "/Applications/Foo.app/Contents/Frameworks/Foo Helper.app/Contents/MacOS/Foo Helper",
             group: "Foo"),
        Case(label: "non-app system daemon is not grouped",
             path: "/usr/libexec/trustd", group: nil),
        // Over-matching regressions: substring rules must not capture unrelated apps.
        Case(label: "MacRamPulse working copy inside the Antigravity folder is not 'Antigravity'",
             path: "/Volumes/ExternalSSD/Antigravity/MacRamPulse.app/Contents/MacOS/MacRamPulse",
             group: "MacRamPulse"),
        Case(label: "an app whose name contains 'lima' (Climate) is not the Colima VM",
             path: "/Applications/Climate Lab.app/Contents/MacOS/Climate Lab", group: "Climate Lab"),
        Case(label: "an app whose name contains 'aside' is not Aside",
             path: "/Applications/Asides Journal.app/Contents/MacOS/Asides Journal", group: "Asides Journal"),
    ]

    @Test("classifies real-world processes", arguments: cases)
    func classifies(_ c: Case) {
        let info = ProcessClassifier.classify(
            sample(pid: 100, path: c.path, parent: c.parent, grandparent: c.grandparent, args: c.args)
        )
        #expect(info?.name == c.group)
        #expect((info?.isProtected ?? false) == c.isProtected)
        #expect((info?.isReclaimable ?? false) == c.isReclaimable)
    }
}
