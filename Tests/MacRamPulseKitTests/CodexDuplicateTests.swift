import Darwin
import Testing
@testable import MacRamPulseKit

@Suite("ProcessClassifier.idleCodexDuplicates — opt-in Rule 5")
struct CodexDuplicateTests {
    let hour = 3600.0
    let codexPid: pid_t = 500

    func mcp(_ pid: pid_t, args: String = "node ./server.mjs", cwd: String = "/Users/me/.codex/code-review-plugin",
             ageSec: Int64, idleSec: Double, parent: String = Paths.codexAppServer, ppid: pid_t? = nil) -> ProcSample {
        sample(pid: pid, ppid: ppid ?? codexPid, path: Paths.cuaNode, parent: parent,
               args: args, cwd: cwd, ageSec: ageSec, idleSec: idleSec)
    }

    func pids(_ s: [ProcSample]) -> Set<pid_t> { Set(s.map(\.pid)) }

    @Test("keeps the newest of each identical set and reclaims idle older ones")
    func keepsNewest() {
        let samples = [
            mcp(1, ageSec: 100, idleSec: 2 * hour),        // newest — kept even though idle
            mcp(2, ageSec: 20_000, idleSec: 2 * hour),
            mcp(3, ageSec: 30_000, idleSec: 2 * hour),
        ]
        #expect(pids(ProcessClassifier.idleCodexDuplicates(samples, minIdleSec: hour)) == [2, 3])
    }

    @Test("same argv in different cwd are different servers")
    func cwdDistinguishesServers() {
        let samples = [
            mcp(1, cwd: "/a", ageSec: 100, idleSec: 2 * hour),
            mcp(2, cwd: "/b", ageSec: 20_000, idleSec: 2 * hour),
        ]
        #expect(ProcessClassifier.idleCodexDuplicates(samples, minIdleSec: hour).isEmpty)
    }

    @Test("recently active duplicates are kept")
    func activeDuplicateKept() {
        let samples = [mcp(1, ageSec: 100, idleSec: 0), mcp(2, ageSec: 20_000, idleSec: 60)]
        #expect(ProcessClassifier.idleCodexDuplicates(samples, minIdleSec: hour).isEmpty)
    }

    @Test("a busy child keeps its idle npm-exec parent alive")
    func busyChildProtectsSubtree() {
        let samples = [
            mcp(1, args: "npm exec rea-agents mcp", ageSec: 100, idleSec: 2 * hour),
            mcp(2, args: "npm exec rea-agents mcp", ageSec: 20_000, idleSec: 2 * hour),
            sample(pid: 20, ppid: 2, path: Paths.node, parent: Paths.node, idleSec: 5),
        ]
        #expect(ProcessClassifier.idleCodexDuplicates(samples, minIdleSec: hour).isEmpty)
    }

    @Test("an idle subtree is reclaimed together")
    func idleSubtreeReclaimedTogether() {
        let samples = [
            mcp(1, args: "npm exec rea-agents mcp", ageSec: 100, idleSec: 2 * hour),
            mcp(2, args: "npm exec rea-agents mcp", ageSec: 20_000, idleSec: 2 * hour),
            sample(pid: 20, ppid: 2, path: Paths.node, parent: Paths.node, idleSec: 2 * hour),
            sample(pid: 21, ppid: 20, path: Paths.node, parent: Paths.node, idleSec: 2 * hour),
        ]
        #expect(pids(ProcessClassifier.idleCodexDuplicates(samples, minIdleSec: hour)) == [2, 20, 21])
    }

    @Test("MCP servers of the protected standalone Codex CLI are never reclaimed")
    func standaloneCodexChildrenProtected() {
        let samples = [
            mcp(1, ageSec: 100, idleSec: 2 * hour, parent: Paths.standaloneCodex, ppid: 900),
            mcp(2, ageSec: 20_000, idleSec: 2 * hour, parent: Paths.standaloneCodex, ppid: 900),
        ]
        #expect(ProcessClassifier.idleCodexDuplicates(samples, minIdleSec: hour).isEmpty)
    }

    @Test("servers with unreadable cwd are not treated as duplicates")
    func unknownCwdNotDeduplicated() {
        let samples = [
            mcp(1, cwd: "", ageSec: 100, idleSec: 2 * hour),
            mcp(2, cwd: "", ageSec: 20_000, idleSec: 2 * hour),
        ]
        #expect(ProcessClassifier.idleCodexDuplicates(samples, minIdleSec: hour).isEmpty)
    }

    /// pid reuse between reads can make a snapshot's parent links loop; the walk must terminate.
    @Test("parent-link cycles in a snapshot do not hang or crash")
    func cycleTerminates() {
        let samples = [
            mcp(1, ageSec: 100, idleSec: 2 * hour),
            mcp(2, ageSec: 20_000, idleSec: 2 * hour),
            // the Codex app-server pid now looks like a child of the duplicate (pid reuse)
            sample(pid: codexPid, ppid: 2, path: Paths.codexAppServer, parent: Paths.cuaNode, idleSec: 2 * hour),
        ]
        let victims = pids(ProcessClassifier.idleCodexDuplicates(samples, minIdleSec: hour))
        #expect(!victims.contains(codexPid))   // never the Codex app-server itself
        #expect(!victims.contains(1))          // never the newest server
    }

    @Test("only node processes are pulled in as descendants")
    func onlyNodeDescendants() {
        let samples = [
            mcp(1, ageSec: 100, idleSec: 2 * hour),
            mcp(2, ageSec: 20_000, idleSec: 2 * hour),
            sample(pid: 30, ppid: 2, path: "/usr/bin/caffeinate", parent: Paths.cuaNode, idleSec: 2 * hour),
        ]
        #expect(pids(ProcessClassifier.idleCodexDuplicates(samples, minIdleSec: hour)) == [2])
    }
}
