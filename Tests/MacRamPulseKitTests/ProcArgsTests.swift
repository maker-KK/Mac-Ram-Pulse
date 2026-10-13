import Darwin
import Testing
@testable import MacRamPulseKit

@Suite("ProcArgs — KERN_PROCARGS2 parsing")
struct ProcArgsTests {
    /// Builds a KERN_PROCARGS2-shaped buffer.
    func buffer(argc: Int32, exec: String, padding: Int, args: [String], env: [String] = []) -> [UInt8] {
        var b = withUnsafeBytes(of: argc.littleEndian) { Array($0) }
        b += Array(exec.utf8) + [0]
        b += [UInt8](repeating: 0, count: padding)
        for a in args + env { b += Array(a.utf8) + [0] }
        return b
    }

    @Test("returns argv joined by spaces, skipping exec path and padding")
    func parsesArgv() {
        let b = buffer(argc: 3, exec: "/opt/homebrew/bin/node", padding: 5,
                       args: ["node", "./server.mjs", "--stdio"])
        #expect(ProcArgs.parse(b, count: b.count) == "node ./server.mjs --stdio")
    }

    @Test("stops at argc and never leaks environment variables")
    func stopsAtArgc() {
        let b = buffer(argc: 2, exec: "/bin/node", padding: 1,
                       args: ["node", "x.mjs"], env: ["PRIVATE_ENV=hidden"])
        let parsed = ProcArgs.parse(b, count: b.count)
        #expect(parsed == "node x.mjs")
        #expect(!parsed.contains("PRIVATE_ENV"))
    }

    @Test("preserves empty arguments")
    func keepsEmptyArgument() {
        let b = buffer(argc: 3, exec: "/bin/node", padding: 1, args: ["node", "", "-e"])
        #expect(ProcArgs.parse(b, count: b.count) == "node  -e")
    }

    @Test("too-short or truncated buffers do not crash", arguments: [0, 2, 4, 9])
    func truncatedBuffer(count: Int) {
        let b = buffer(argc: 2, exec: "/bin/node", padding: 1, args: ["node", "long-argument"])
        _ = ProcArgs.parse(b, count: count)
    }

    @Test("count larger than the buffer is clamped")
    func countClamped() {
        let b = buffer(argc: 1, exec: "/bin/node", padding: 1, args: ["node"])
        #expect(ProcArgs.parse(b, count: b.count + 100) == "node")
    }
}
