import Foundation
import Testing
@testable import MacRamPulseKit

private let nodePath = ["/opt/homebrew/bin/node", "/opt/homebrew/opt/node@24/bin/node", "/usr/local/bin/node"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

/// Runs against the live process table: spawns a real `node` child and finds it with libproc.
@Suite("ProcessScanner — live process table", .serialized, .enabled(if: nodePath != nil, "node not installed"))
struct ProcessScannerIntegrationTests {
    @Test("finds a spawned node child with ppid, argv, cwd and idle time")
    func findsSpawnedNode() throws {
        let marker = "mrp-scan-marker-\(UUID().uuidString.prefix(8))"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(marker)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: nodePath!)
        child.arguments = ["-e", "const b = Buffer.alloc(32e6, 1); setTimeout(() => {}, 30000) // \(marker)"]
        child.currentDirectoryURL = dir
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        Thread.sleep(forTimeInterval: 1.0)

        let scanner = ProcessScanner()
        let first = try #require(scanner.scan().first { $0.pid == child.processIdentifier })
        #expect(first.ppid == getpid())
        #expect(ProcessScanner.isNode(first.path))
        #expect(first.args.contains(marker))
        #expect(URL(fileURLWithPath: first.cwd).resolvingSymlinksInPath().path
                == dir.resolvingSymlinksInPath().path)
        #expect(first.footprintMB >= 30)
        #expect(first.idleSec == 0)                       // first sighting
        #expect(ProcessClassifier.classify(first)?.isProtected == true)

        Thread.sleep(forTimeInterval: 1.5)
        let second = try #require(scanner.scan().first { $0.pid == child.processIdentifier })
        #expect(second.idleSec >= 1.0)                    // sleeping node uses ~no CPU
    }

    @Test("never reports its own process and skips tiny processes")
    func skipsSelfAndTiny() throws {
        let tiny = Process()
        tiny.executableURL = URL(fileURLWithPath: "/bin/sleep")
        tiny.arguments = ["30"]
        try tiny.run()
        defer { tiny.terminate(); tiny.waitUntilExit() }
        let samples = ProcessScanner().scan()
        #expect(!samples.contains { $0.pid == getpid() })
        #expect(!samples.contains { $0.pid == tiny.processIdentifier })
        #expect(samples.count > 20)
    }
}
