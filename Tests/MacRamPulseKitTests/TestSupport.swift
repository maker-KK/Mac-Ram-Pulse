import Darwin
@testable import MacRamPulseKit

/// Real-world executable paths observed on the Mac mini (2026-10-12).
enum Paths {
    static let codexAppServer = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    static let standaloneCodex = "/Users/me/.local/bin/codex.opencodex-real"
    static let chatGPT = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
    static let codexRenderer = "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/155.0.8059.40/Helpers/Codex (Renderer).app/Contents/MacOS/Codex (Renderer)"
    static let node = "/opt/homebrew/Cellar/node@24/24.16.0/bin/node"
    static let cuaNode = "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node"
    static let nodeRepl = "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl"
    static let claudeCode = "/Users/me/Library/Application Support/Claude/claude-code/2.1.295/9d6405864fdc/claude.app/Contents/MacOS/claude"
    static let claudeDesktop = "/Applications/Claude.app/Contents/MacOS/Claude"
    static let jbrJava = "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java"
    static let studio = "/Applications/Android Studio.app/Contents/MacOS/studio"
    static let xcode = "/Applications/Xcode.app/Contents/MacOS/Xcode"
    static let sourceKit = "/Applications/Xcode.app/Contents/SharedFrameworks/SourceKit.framework/Versions/A/XPCServices/SourceKitService.xpc/Contents/MacOS/SourceKitService"
    static let dart = "/Users/me/flutter/bin/cache/dart-sdk/bin/dartaotruntime"
    static let colimaVM = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
    static let limactl = "/opt/homebrew/bin/limactl"
    static let asideRenderer = "/Applications/Aside.app/Contents/Frameworks/Aside Framework.framework/Versions/1.0.928.1/Helpers/Aside Helper (Renderer).app/Contents/MacOS/Aside Helper (Renderer)"
    static let antigravity = "/Applications/Antigravity.app/Contents/MacOS/Electron"
    static let launchd = "/sbin/launchd"
    static let uv = "/opt/homebrew/bin/uv"
    static let uvPython = "/Users/me/.cache/uv/archive-v0/SXTaIWcl7HBGvlRS/bin/python"
    static let computerUse = "/Users/me/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
    static let antigravityLS = "/Applications/Antigravity.app/Contents/Resources/bin/language_server"
}

func sample(
    pid: pid_t,
    ppid: pid_t = 1,
    path: String,
    parent: String = "",
    grandparent: String = "",
    args: String = "",
    cwd: String = "",
    rssMB: Double = 50,
    footprintMB: Double = 100,
    ageSec: Int64 = 3600,
    idleSec: Double = 0
) -> ProcSample {
    ProcSample(
        pid: pid, ppid: ppid, path: path, parentPath: parent, grandparentPath: grandparent,
        args: args, cwd: cwd, rssMB: rssMB, footprintMB: footprintMB, ageSec: ageSec, idleSec: idleSec
    )
}

func group(
    _ name: String,
    pids: [pid_t],
    idlePids: [pid_t] = [],
    totalMB: Double = 1000,
    idleMB: Double = 0,
    isProtected: Bool = false,
    isReclaimable: Bool = false
) -> AppGroupMemory {
    AppGroupMemory(
        name: name, icon: "⚙️", rssMB: totalMB / 2, swapMB: totalMB / 2, totalMB: totalMB,
        processCount: pids.count, pids: pids, idlePids: idlePids, idleMB: idleMB,
        isProtected: isProtected, isReclaimableDaemon: isReclaimable
    )
}
