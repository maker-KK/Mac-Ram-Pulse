import Darwin
import Foundation
import Testing
@testable import MacRamPulseKit

/// v5.5: Codex leaves a full tool set (node MCP servers, `uv` Python MCP servers, Computer Use
/// clients, node_repl) running for every chat thread, and its engine grows over days.
@Suite("Codex care — wider duplicate cleanup")
struct CodexDuplicateWideningTests {
    let hour = 3600.0
    let engine: pid_t = 500

    func child(_ pid: pid_t, _ path: String, args: String, age: Int64, idle: Double = 7200,
               cwd: String = "/Users/me/projects/app", parent: String = Paths.codexAppServer, ppid: pid_t? = nil) -> ProcSample {
        sample(pid: pid, ppid: ppid ?? engine, path: path, parent: parent, args: args, cwd: cwd, ageSec: age, idleSec: idle)
    }

    func pids(_ s: [ProcSample]) -> Set<pid_t> { Set(s.map(\.pid)) }

    static let unityArgs = "uv tool uvx --from mcpforunityserver==10.3.0 mcp-for-unity --transport stdio"

    @Test("duplicate uv (Python MCP) servers are reclaimed with their Python child")
    func uvWithPythonChild() {
        let s = [
            child(1, Paths.uv, args: Self.unityArgs, age: 100),
            child(2, Paths.uv, args: Self.unityArgs, age: 9000),
            sample(pid: 20, ppid: 2, path: Paths.uvPython, parent: Paths.uv, args: "python mcp-for-unity", idleSec: 7200),
        ]
        #expect(pids(ProcessClassifier.idleCodexDuplicates(s, minIdleSec: hour)) == [2, 20])
    }

    @Test("a busy Python child keeps its uv parent alive")
    func busyPythonProtectsUv() {
        let s = [
            child(1, Paths.uv, args: Self.unityArgs, age: 100),
            child(2, Paths.uv, args: Self.unityArgs, age: 9000),
            sample(pid: 20, ppid: 2, path: Paths.uvPython, parent: Paths.uv, idleSec: 3),
        ]
        #expect(ProcessClassifier.idleCodexDuplicates(s, minIdleSec: hour).isEmpty)
    }

    @Test("duplicate Computer Use clients are reclaimed, newest kept")
    func computerUseClients() {
        let s = [
            child(1, Paths.computerUse, args: "SkyComputerUseClient mcp", age: 100),
            child(2, Paths.computerUse, args: "SkyComputerUseClient mcp", age: 5000),
            child(3, Paths.computerUse, args: "SkyComputerUseClient mcp", age: 9000),
        ]
        #expect(pids(ProcessClassifier.idleCodexDuplicates(s, minIdleSec: hour)) == [2, 3])
    }

    @Test("duplicate node_repl sessions are reclaimed with their kernels")
    func nodeReplWithKernels() {
        let s = [
            child(1, Paths.nodeRepl, args: "node_repl", age: 100),
            child(2, Paths.nodeRepl, args: "node_repl", age: 9000),
            sample(pid: 21, ppid: 2, path: Paths.node, parent: Paths.nodeRepl, args: "node kernel.js", idleSec: 7200),
        ]
        #expect(pids(ProcessClassifier.idleCodexDuplicates(s, minIdleSec: hour)) == [2, 21])
    }

    @Test("tool processes of the protected standalone Codex CLI are never touched")
    func standaloneUntouched() {
        let s = [
            child(1, Paths.uv, args: Self.unityArgs, age: 100, parent: Paths.standaloneCodex, ppid: 900),
            child(2, Paths.uv, args: Self.unityArgs, age: 9000, parent: Paths.standaloneCodex, ppid: 900),
        ]
        #expect(ProcessClassifier.idleCodexDuplicates(s, minIdleSec: hour).isEmpty)
    }

    @Test("uv servers started by other apps (Antigravity) are never touched")
    func otherAppsUvUntouched() {
        let s = [
            child(1, Paths.uv, args: Self.unityArgs, age: 100, parent: Paths.antigravityLS, ppid: 700),
            child(2, Paths.uv, args: Self.unityArgs, age: 9000, parent: Paths.antigravityLS, ppid: 700),
        ]
        #expect(ProcessClassifier.idleCodexDuplicates(s, minIdleSec: hour).isEmpty)
    }

    /// The Computer Use client lives under ".../computer-use/Codex Computer Use.app/...", whose path
    /// contains "/Codex" — it must not be mistaken for the Codex engine itself.
    @Test("the Computer Use client is not mistaken for the Codex engine")
    func computerUseIsNotAnEngine() {
        #expect(ProcessClassifier.codexHost(of: Paths.computerUse) == nil)
        #expect(ProcessClassifier.codexHost(of: Paths.codexAppServer) == .chatGPTApp)
        #expect(ProcessClassifier.codexHost(of: Paths.standaloneCodex) == .standalone)
        #expect(ProcessClassifier.codexHost(of: Paths.codexRenderer) == nil)
        let s = [
            sample(pid: 1, ppid: 40, path: Paths.node, parent: Paths.computerUse, args: "node a", cwd: "/x", ageSec: 100, idleSec: 9000),
            sample(pid: 2, ppid: 40, path: Paths.node, parent: Paths.computerUse, args: "node a", cwd: "/x", ageSec: 9000, idleSec: 9000),
        ]
        #expect(ProcessClassifier.idleCodexDuplicates(s, minIdleSec: hour).isEmpty)
    }

    @Test("Codex tool processes of every kind are grouped as Codex children", arguments: [
        (Paths.uv, Paths.codexAppServer, "", "Codex MCP·REPL 하위 서버"),
        (Paths.uvPython, Paths.uv, Paths.codexAppServer, "Codex MCP·REPL 하위 서버"),
        (Paths.computerUse, Paths.codexAppServer, "", "Codex MCP·REPL 하위 서버"),
        (Paths.uv, Paths.standaloneCodex, "", "Codex CLI (독립 세션)"),
        (Paths.uvPython, Paths.uv, Paths.standaloneCodex, "Codex CLI (독립 세션)"),
    ])
    func grouping(path: String, parent: String, grandparent: String, group: String) {
        let info = ProcessClassifier.classify(sample(pid: 1, path: path, parent: parent, grandparent: grandparent))
        #expect(info?.name == group)
    }

    @Test("Antigravity's uv/Python is not grouped as Codex")
    func antigravityUvNotCodex() {
        let uv = ProcessClassifier.classify(sample(pid: 1, path: Paths.uv, parent: Paths.antigravityLS))
        let py = ProcessClassifier.classify(sample(pid: 2, path: Paths.uvPython, parent: Paths.uv, grandparent: Paths.antigravityLS))
        #expect(uv?.name != "Codex MCP·REPL 하위 서버")
        #expect(py?.name != "Codex MCP·REPL 하위 서버")
    }
}

@Suite("Codex care — restart advice")
struct CodexHealthTests {
    let gb = 1024.0

    /// A ChatGPT tree: main app, renderer, Codex engine and `kids` tool processes.
    func tree(engineGB: Double, kids: Int = 3, kidGB: Double = 0.2, uptimeH: Double = 58) -> [ProcSample] {
        let age = Int64(uptimeH * 3600)
        var s = [
            sample(pid: 100, ppid: 1, path: Paths.chatGPT, parent: Paths.launchd, footprintMB: 0.6 * gb, ageSec: age),
            sample(pid: 101, ppid: 100, path: Paths.codexRenderer, parent: Paths.chatGPT, footprintMB: 3 * gb, ageSec: age),
            sample(pid: 102, ppid: 100, path: Paths.codexAppServer, parent: Paths.chatGPT, footprintMB: engineGB * gb, ageSec: age),
        ]
        s += (0..<kids).map { i in
            sample(pid: pid_t(200 + i), ppid: 102, path: Paths.node, parent: Paths.codexAppServer, footprintMB: kidGB * gb, ageSec: 3600)
        }
        return s
    }

    @Test("no ChatGPT running → no advice")
    func noChatGPT() {
        #expect(CodexHealth.assess([sample(pid: 1, path: Paths.claudeDesktop)]) == nil)
    }

    @Test("a fresh, small ChatGPT → no advice")
    func healthy() {
        #expect(CodexHealth.assess(tree(engineGB: 1.0, uptimeH: 2)) == nil)
    }

    @Test("a large Codex engine → advice with uptime, engine and whole-tree size")
    func largeEngine() throws {
        let advice = try #require(CodexHealth.assess(tree(engineGB: 10.7, kids: 5, kidGB: 0.2)))
        #expect(advice.mainPid == 100)
        #expect(abs(advice.uptimeHours - 58) < 0.01)
        #expect(abs(advice.engineMB - 10.7 * gb) < 1)
        #expect(abs(advice.treeMB - (0.6 + 3 + 10.7 + 1.0) * gb) < 1)
        #expect(advice.childCount == 5)
    }

    @Test("a huge tree with a modest engine (piled-up tools) → advice")
    func hugeTree() {
        #expect(CodexHealth.assess(tree(engineGB: 3, kids: 80, kidGB: 0.2)) != nil)
    }

    @Test("a large standalone Codex CLI is not ChatGPT and gets no restart advice")
    func standaloneIgnored() {
        let s = [sample(pid: 1, ppid: 1, path: Paths.standaloneCodex, parent: Paths.launchd, footprintMB: 20 * gb)]
        #expect(CodexHealth.assess(s) == nil)
    }
}

@Suite("Codex care — restart flow", .serialized)
@MainActor
struct ChatGPTRestartFlowTests {
    func wait(_ seconds: Double) async throws { try await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    func monitor(_ spy: Spy, advice: Bool = true) -> SystemMemoryMonitor {
        let m = spy.makeMonitor()
        if advice {
            m.stats.codexAdvice = CodexAdvice(mainPid: 100, uptimeHours: 58, engineMB: 10_900, treeMB: 31_000, childCount: 160)
        }
        return m
    }

    @Test("first tap arms, second tap restarts ChatGPT once")
    func twoStepRestart() async throws {
        let spy = Spy()
        let m = monitor(spy)
        m.requestChatGPTRestart()
        #expect(m.confirmingRestart)
        #expect(spy.restartCalls.isEmpty)
        m.confirmChatGPTRestart()
        m.confirmChatGPTRestart()
        for _ in 0..<50 where m.isBusy || spy.restartCalls.isEmpty { try await wait(0.02) }
        try await wait(0.05)
        #expect(spy.restartCalls == [100])
        #expect(m.lastActionMessage.hasPrefix("✅"))
        #expect(m.autoLogs.first?.contains("ChatGPT") == true)
    }

    @Test("if ChatGPT refuses to quit, the user is told")
    func refused() async throws {
        let spy = Spy()
        spy.restartResult = false
        let m = monitor(spy)
        m.requestChatGPTRestart()
        m.confirmChatGPTRestart()
        for _ in 0..<50 where spy.restartCalls.isEmpty || m.isBusy { try await wait(0.02) }
        try await wait(0.05)
        #expect(m.lastActionMessage.hasPrefix("⚠️"))
    }

    @Test("confirming without arming does nothing")
    func confirmWithoutArm() async throws {
        let spy = Spy()
        let m = monitor(spy)
        m.confirmChatGPTRestart()
        try await wait(0.1)
        #expect(spy.restartCalls.isEmpty)
    }

    @Test("the armed restart expires")
    func restartArmExpires() async throws {
        let spy = Spy()
        spy.confirmTimeout = 0.1
        let m = monitor(spy)
        m.requestChatGPTRestart()
        try await wait(0.25)
        #expect(!m.confirmingRestart)
    }

    @Test("without advice the restart button does nothing")
    func noAdviceNoRestart() async throws {
        let spy = Spy()
        let m = monitor(spy, advice: false)
        m.requestChatGPTRestart()
        m.confirmChatGPTRestart()
        try await wait(0.1)
        #expect(!m.confirmingRestart)
        #expect(spy.restartCalls.isEmpty)
    }

    @Test("a full refresh publishes the advice from the scan")
    func refreshPublishesAdvice() async throws {
        let spy = Spy()
        spy.scanResult = CodexHealthTests().tree(engineGB: 10.7)
        let m = spy.makeMonitor()
        m.refreshFull()
        for _ in 0..<50 where m.stats.codexAdvice == nil { try await wait(0.02) }
        #expect(m.stats.codexAdvice?.mainPid == 100)
    }

    /// The patrol leaves one log line per ChatGPT run, not one every 3 minutes.
    @Test("the patrol logs the advice once per ChatGPT run")
    func patrolLogsOncePerRun() async throws {
        let spy = Spy()
        spy.scanResult = CodexHealthTests().tree(engineGB: 10.7)
        let m = spy.makeMonitor()
        let before = m.autoLogs.count
        for _ in 0..<3 {
            m.runAutoPatrol(manualTrigger: false)
            try await wait(0.15)
        }
        #expect(m.autoLogs.filter { $0.contains("재시작 권장") }.count == 1)
        #expect(m.autoLogs.count == before + 1)
    }
}

@Suite("Codex care — card wording")
@MainActor
struct ChatGPTAdviceWordingTests {
    @Test("uptime is said in plain words", arguments: [(5.0, "5시간째"), (30.0, "30시간째"), (58.0, "2일 넘게"), (100.0, "4일 넘게")])
    func uptimeText(hours: Double, text: String) {
        #expect(PulsePopoverView.uptimeText(hours) == text)
    }
}
