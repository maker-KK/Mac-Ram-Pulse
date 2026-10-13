import Foundation

/// Which running processes make it unsafe to move a cache folder to the external SSD.
/// Moving a folder that a process has open (Gradle daemon, emulator, npx-launched server…)
/// can corrupt the cache or crash that process.
enum OffloadSafety {
    struct Users {
        /// Exact executable names (last path component, case-insensitive).
        var executables: Set<String> = []
        /// Substrings of the lowercased executable path.
        var pathParts: [String] = []
    }

    static let users: [String: Users] = [
        "gradle": Users(executables: ["java"], pathParts: ["android studio.app/contents/jbr"]),
        "android": Users(executables: ["adb", "emulator", "qemu-system-aarch64"],
                         pathParts: ["android studio.app/contents/macos/studio"]),
        "xcode-derived": Users(executables: ["xcode", "xcodebuild", "sourcekitservice", "swift-frontend"]),
        "cache-uv": Users(executables: ["uv", "uvx"]),
        "npm": Users(executables: ["npm", "npx"]),
    ]

    /// Names of processes that block moving `target`, deduplicated, in scan order.
    static func blockers(for target: OffloadTarget, in samples: [ProcSample]) -> [String] {
        let folder = target.sourcePath.lowercased() + "/"
        let known = users[target.id] ?? Users()
        var names: [String] = []
        for s in samples {
            let path = s.path.lowercased()
            let exe = (s.path as NSString).lastPathComponent
            let usesFolder = path.hasPrefix(folder) || s.args.lowercased().contains(folder)
            let isKnownUser = known.executables.contains(exe.lowercased()) || known.pathParts.contains { path.contains($0) }
            if (usesFolder || isKnownUser) && !names.contains(exe) {
                names.append(exe)
            }
        }
        return names
    }
}
