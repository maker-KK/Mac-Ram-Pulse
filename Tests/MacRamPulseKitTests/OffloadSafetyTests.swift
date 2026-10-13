import Darwin
import Testing
@testable import MacRamPulseKit

@Suite("OffloadSafety — what blocks 외장 이전")
struct OffloadSafetyTests {
    func target(_ id: String, _ path: String) -> OffloadTarget {
        OffloadTarget(id: id, title: id, desc: "", sourcePath: path, offloadName: id,
                      estimatedSize: "", isOffloaded: false, exists: true)
    }

    @Test("exact tool names block their own cache only")
    func exactNames() {
        let uv = target("cache-uv", "/Users/me/.cache/uv")
        #expect(OffloadSafety.blockers(for: uv, in: [sample(pid: 1, path: "/opt/homebrew/bin/uv")]) == ["uv"])
        #expect(OffloadSafety.blockers(for: uv, in: [sample(pid: 1, path: "/usr/libexec/uvcassistant")]).isEmpty)
        #expect(OffloadSafety.blockers(for: uv, in: [sample(pid: 1, path: "/opt/homebrew/bin/npm")]).isEmpty)
    }

    @Test("a sibling folder with the same prefix is not 'inside' the cache")
    func siblingFolderIgnored() {
        let npm = target("npm", "/Users/me/.npm")
        let s = sample(pid: 1, path: Paths.node, args: "node /Users/me/.npmrc-tools/cli.js")
        #expect(OffloadSafety.blockers(for: npm, in: [s]).isEmpty)
    }

    @Test("processes running from inside the folder block it, case-insensitively")
    func insideFolderBlocks() {
        let derived = target("xcode-derived", "/Users/me/Library/Developer/Xcode/DerivedData")
        let s = sample(pid: 1, path: "/Users/me/Library/Developer/Xcode/DerivedData/App-abc/Build/Products/Debug/App.app/Contents/MacOS/App")
        #expect(OffloadSafety.blockers(for: derived, in: [s]) == ["App"])
    }

    @Test("blockers are deduplicated and keep scan order")
    func dedup() {
        let gradle = target("gradle", "/Users/me/.gradle")
        let s = [sample(pid: 1, path: Paths.jbrJava), sample(pid: 2, path: Paths.jbrJava), sample(pid: 3, path: Paths.studio)]
        #expect(OffloadSafety.blockers(for: gradle, in: s) == ["java"])
    }
}
