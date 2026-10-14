import Cocoa
import SwiftUI
import Darwin

// MARK: - Popover (v5.7, Liquid Glass)

struct PulsePopoverView: View {
    @ObservedObject var monitor: SystemMemoryMonitor

    private var comfortColor: Color { PulseStyle.color(monitor.comfort.level) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ComfortHeroCard(reading: monitor.comfort, usedPct: monitor.stats.usedPercent,
                            swapGB: monitor.stats.swapUsedMB / 1024, animate: monitor.menuBarAnimation)
            memoryCards

            Picker("", selection: $monitor.mainTab) {
                ForEach(MainTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch monitor.mainTab {
                case .apps: appsTabView
                case .autopilot: autopilotTabView
                case .ssdBoost: ssdBoostTabView
                }
            }

            if !monitor.lastActionMessage.isEmpty {
                toast
            }
        }
        .padding(14)
        .frame(width: 460)
        .background(stateWash)
        .animation(.easeOut(duration: 0.2), value: monitor.lastActionMessage.isEmpty)
    }

    /// A faint tint in the state's colour behind everything, so the whole popover "feels" the word.
    private var stateWash: some View {
        RadialGradient(colors: [comfortColor.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
            .animation(.easeInOut(duration: 0.6), value: monitor.comfort.level)
            .allowsHitTesting(false)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [Color.blue, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 32, height: 32)
                    .shadow(color: .purple.opacity(0.25), radius: 6, y: 2)
                Image(systemName: "memorychip.fill")
                    .foregroundStyle(.white)
                    .font(.system(size: 15, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("MacRamPulse")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Chip(text: "v5.7", color: .blue, size: 9)
                }
                Text(String(format: "커널 직접 스캔 · %.1fms · 서브프로세스 0개", monitor.stats.scanDurationMs))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            headerButtons
        }
    }

    @ViewBuilder
    private var headerButtons: some View {
        let buttons = HStack(spacing: 6) {
            Button(action: { monitor.refreshFull() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .glassButton()
            .help("즉시 새로고침")

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .glassButton()
            .help("MacRamPulse 종료")
        }
        .controlSize(.small)
        if #available(macOS 26, *), PulseStyle.glassEnabled {
            GlassEffectContainer(spacing: 6) { buttons }
        } else {
            buttons
        }
    }

    // MARK: RAM & swap cards

    private var memoryCards: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("통합 메모리", systemImage: "cpu")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(monitor.stats.usedPercent)%")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(monitor.stats.usedPercent > 82 ? Color.red : Color.blue)
                }

                Text(String(format: "%.1f GB / %.0f GB", monitor.stats.usedGB, monitor.stats.totalGB))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .monospacedDigit()

                // Multi-segment bar (Active + Wired + Compressed)
                GeometryReader { geo in
                    let w = geo.size.width
                    let total = max(1.0, monitor.stats.totalGB)
                    let actW = w * CGFloat(min(1.0, monitor.stats.activeGB / total))
                    let wirW = w * CGFloat(min(1.0, monitor.stats.wiredGB / total))
                    let cmpW = w * CGFloat(min(1.0, monitor.stats.compressedGB / total))
                    HStack(spacing: 1.5) {
                        Rectangle().fill(Color.blue).frame(width: max(2, actW))
                        Rectangle().fill(Color.purple).frame(width: max(2, wirW))
                        Rectangle().fill(Color.orange).frame(width: max(2, cmpW))
                        Spacer(minLength: 0)
                    }
                    .frame(height: 8)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Capsule())
                }
                .frame(height: 8)

                HStack(spacing: 6) {
                    Text(String(format: "활성 %.1f · 고정 %.1f · 압축 %.1fG",
                                monitor.stats.activeGB, monitor.stats.wiredGB, monitor.stats.compressedGB))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 4)
                    Button("캐시 퍼지") { monitor.purgePhysicalRAMCache() }
                        .glassButton()
                        .controlSize(.mini)
                        .disabled(monitor.isBusy)
                }
            }
            .padding(10)
            .glassCard()

            VStack(alignment: .leading, spacing: 6) {
                let swapGB = monitor.stats.swapUsedMB / 1024.0
                let swapTotalGB = max(0.5, monitor.stats.swapTotalMB / 1024.0)
                let label = ComfortAssessor.swapLabel(swapGB: swapGB, ramGB: monitor.stats.totalGB)
                let heavy = ComfortAssessor.swapPoints(swapGB: swapGB, ramGB: monitor.stats.totalGB) >= 12
                HStack {
                    Label("SSD 스왑", systemImage: "internaldrive")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Chip(text: label, color: heavy ? .orange : .green)
                }

                Text(String(format: "%.1f GB / %.1f GB", swapGB, swapTotalGB))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(heavy ? Color.orange : Color.primary)

                MeterBar(fraction: swapGB / swapTotalGB, color: heavy ? .orange : .green)

                HStack {
                    Text(String(format: "내장 여유 %.0f GB", monitor.stats.internalFreeGB))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("유휴 데몬 정리") { monitor.reclaimIdleDaemonsNow() }
                        .glassButton(prominent: true, tint: .orange)
                        .controlSize(.mini)
                        .disabled(monitor.isBusy)
                }
            }
            .padding(10)
            .glassCard()
        }
    }

    private var toast: some View {
        HStack(spacing: 6) {
            Image(systemName: monitor.isToastWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(monitor.isToastWarning ? Color.orange : Color.green)
            Text(monitor.lastActionMessage)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .help(monitor.lastActionMessage)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassCard(PulseStyle.rowRadius, tint: monitor.isToastWarning ? .orange : .green)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Tab 1: Apps Memory & Swap Breakdown (With Search & Safe 2-Step Kill)

    var appsTabView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let advice = monitor.stats.codexAdvice {
                chatGPTAdviceCard(advice)
            }

            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                    TextField("앱 또는 데몬 검색...", text: $monitor.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                    if !monitor.searchText.isEmpty {
                        Button(action: { monitor.searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: Capsule())

                Picker("", selection: $monitor.sortMode) {
                    ForEach(SortMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 215)
                .controlSize(.small)
            }

            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle().fill(Color.blue).frame(width: 6, height: 6)
                    Text("물리 RAM (칩 상주)")
                }
                HStack(spacing: 4) {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                    Text("스왑/압축 (SSD/압축 점유)")
                }
                Spacer()
                Text("총 \(monitor.filteredAndSortedGroups.count)개 앱 그룹")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 6) {
                    if monitor.filteredAndSortedGroups.isEmpty {
                        Text(monitor.hasNoSearchResults
                             ? "'\(monitor.searchText.trimmingCharacters(in: .whitespaces))'와(과) 일치하는 앱이 없습니다"
                             : "프로세스를 읽는 중…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(monitor.visibleGroups) { group in
                        appRow(group)
                    }
                }
            }
            .frame(height: 265)

            if monitor.hiddenGroupCount > 0 {
                Text("외 \(monitor.hiddenGroupCount)개 앱은 검색으로 찾을 수 있어요")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func appRow(_ group: AppGroupMemory) -> some View {
        HStack(spacing: 10) {
            Text(group.icon)
                .font(.system(size: 18))
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(group.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Chip(text: "\(group.processCount)개")
                    if group.isReclaimableDaemon {
                        Chip(text: group.showsIdleBadge ? "유휴 데몬" : "작업 중", color: group.showsIdleBadge ? .orange : .blue, size: 9)
                    }
                }

                // Proportional Dual Bar (Blue = RAM, Orange = Swap)
                HStack(spacing: 8) {
                    GeometryReader { geo in
                        // 6GB reference scale; larger groups shrink to fit so the bar never overflows
                        let scale = geo.size.width / CGFloat(max(6000.0, group.rssMB + group.swapMB))
                        let ramW = CGFloat(group.rssMB) * scale
                        let swpW = CGFloat(group.swapMB) * scale
                        HStack(spacing: 1) {
                            if group.rssMB > 0 {
                                Rectangle().fill(Color.blue).frame(width: max(3, ramW))
                            }
                            if group.swapMB > 10 {
                                Rectangle().fill(Color.orange).frame(width: max(3, swpW))
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(height: 5)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Capsule())
                    }
                    .frame(width: 96, height: 5)

                    Text("RAM \(formatShort(group.rssMB)) · 스왑 \(formatShort(group.swapMB))")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(group.swapMB > 1000 ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text(formatMB(group.totalMB))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("총 점유")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 60, alignment: .trailing)

            if group.isProtected {
                Label("보호됨", systemImage: "lock.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 56)
            } else if monitor.confirmingGroupId == group.id {
                Button("종료확인") { monitor.confirmTerminate(group) }
                    .glassButton(prominent: true, tint: .red)
                    .controlSize(.small)
                    .frame(width: 56)
            } else {
                Button(group.isReclaimableDaemon ? "회수" : "정리") { monitor.requestTerminate(group) }
                    .help(group.isReclaimableDaemon
                          ? "1분 이상 CPU를 쓰지 않은 데몬만 종료합니다 (작업 중인 빌드는 유지)"
                          : "앱은 정상 종료(Quit)를 요청하고, 백그라운드 프로세스는 종료 신호를 보냅니다")
                    .glassButton(tint: group.isReclaimableDaemon ? .orange : nil)
                    .controlSize(.small)
                    .frame(width: 56)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentRow()
    }

    // MARK: - Tab 2: Autonomous Autopilot & Activity Timeline

    var autopilotTabView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("누적 자동 회수 메모리")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f GB · %d회 자동 정리", monitor.totalSavedMB / 1024.0, monitor.totalCleanCount))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.green)
                }
                Spacer()
                Button(action: { monitor.runAutoPatrol(manualTrigger: true) }) {
                    Label("지금 즉시 순찰", systemImage: "bolt.shield.fill")
                }
                .glassButton(prominent: true, tint: .green)
                .controlSize(.small)
            }
            .padding(10)
            .glassCard(tint: .green)

            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $monitor.autoGuardEnabled) {
                    Text("🤖 3분 주기 백그라운드 무인 자동 순찰 (LaunchAgent 상주)")
                        .font(.system(size: 11.5, weight: .bold))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Divider()

                Toggle(isOn: $monitor.cleanOrphanedIDEDaemons) {
                    Text("종료된 IDE(Android Studio / Xcode / Flutter)의 고아 빌드 데몬 회수 (10분 이상 CPU 유휴일 때만)")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)

                Toggle(isOn: $monitor.trimBloatedRenderers) {
                    Text("단일 백그라운드 렌더러 2.0GB 초과 비정상 누수 시 자동 리프레시")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)

                Toggle(isOn: $monitor.cleanCodexDuplicateMCPs) {
                    Text("Codex 스레드별 중복 MCP 서버 중 60분 이상 유휴인 오래된 것 회수 (최신 1세트 유지)")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Codex는 채팅 스레드마다 MCP 서버를 새로 띄우고 종료하지 않습니다. 오래된 스레드를 다시 열면 해당 MCP 도구가 재시작될 때까지 실패할 수 있습니다.")

                Divider()

                HStack(spacing: 8) {
                    Text("메뉴바 표시")
                        .font(.system(size: 11, weight: .semibold))
                    Picker("", selection: $monitor.menuBarMode) {
                        ForEach(MenuBarMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                    .controlSize(.small)
                    Toggle("움직이는 아이콘", isOn: $monitor.menuBarAnimation)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(.system(size: 11))
                }

                Text("ℹ️ OpenClaw, Colima VM, Claude, Codex CLI 세션은 보호되며, 작업 중(CPU 사용)인 프로세스는 회수하지 않습니다.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .padding(10)
            .contentRow(PulseStyle.cardRadius)

            HStack {
                Text("📜 자동 관리 타임라인")
                    .font(.system(size: 11.5, weight: .bold))
                Spacer()
                Button("기록 비우기") { monitor.clearLogs() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(monitor.autoLogs.enumerated()), id: \.offset) { _, log in
                        Text(log)
                            .font(.system(size: 10.5, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentRow(8)
                    }
                }
            }
            .frame(height: 145)
        }
    }

    // MARK: - Tab 3: Dual-SSD Buffer & Cache Offload

    var ssdBoostTabView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("🏠 내장 SSD (OS 스왑 버퍼)")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(monitor.stats.internalUsedPct)%")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundStyle(monitor.stats.internalUsedPct > 85 ? Color.orange : Color.green)
                    }
                    Text(String(format: "%.1f GB 여유", monitor.stats.internalFreeGB))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    MeterBar(fraction: Double(monitor.stats.internalUsedPct) / 100,
                             color: monitor.stats.internalUsedPct > 85 ? .orange : .green)
                }
                .padding(10)
                .glassCard()

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("🚀 외장 SSD (캐시/I/O 분산)")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(monitor.stats.externalMounted ? "\(monitor.stats.externalUsedPct)%" : "—")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.blue)
                    }
                    Text(monitor.stats.externalMounted
                         ? String(format: "%.1f GB 여유", monitor.stats.externalFreeGB)
                         : "연결 안 됨")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(monitor.stats.externalMounted ? Color.blue : Color.secondary)
                    MeterBar(fraction: Double(monitor.stats.externalUsedPct) / 100, color: .blue)
                }
                .padding(10)
                .glassCard()
            }

            HStack {
                Text("📦 대용량 개발/런타임 캐시 외장 분산 상태")
                    .font(.system(size: 11.5, weight: .bold))
                Spacer()
                Button("미사용 시뮬레이터 정리") { monitor.cleanUnavailableSimulators() }
                    .glassButton()
                    .controlSize(.mini)
                    .disabled(monitor.isBusy)
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(monitor.stats.offloadTargets) { target in
                        offloadRow(target)
                    }
                }
            }
            .frame(height: 225)
        }
    }

    private func offloadRow(_ target: OffloadTarget) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(target.title)
                        .font(.system(size: 11.5, weight: .semibold))
                    Chip(text: target.estimatedSize)
                }
                Text(target.desc)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()

            if target.exists {
                Button(action: { monitor.revealInFinder(target.sourcePath) }) {
                    Image(systemName: "folder")
                }
                .glassButton()
                .controlSize(.small)
                .help("Finder에서 위치 열기")
            }

            if target.isOffloaded {
                Label("외장 분산됨", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.green)
                    .frame(width: 92, alignment: .trailing)
            } else if target.exists {
                Button(monitor.stats.externalMounted ? "외장 이전" : "SSD 없음") { monitor.offloadToExternalSSD(target) }
                    .glassButton(prominent: true)
                    .controlSize(.small)
                    .frame(width: 92)
                    .disabled(monitor.isBusy || !monitor.stats.externalMounted)
            } else {
                Text("미생성")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentRow()
    }

    /// Plain-language card: what is wrong, what a restart gives back, one button.
    func chatGPTAdviceCard(_ advice: CodexAdvice) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text("🤖").font(.system(size: 22))
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "ChatGPT가 메모리를 %.0fGB 쓰고 있어요", advice.treeMB / 1024))
                    .font(.system(size: 12, weight: .bold))
                Text(String(format: "%@ 켜져 있어서 쌓였어요. 다시 시작하면 대부분 돌아와요 (대화는 그대로).",
                            Self.uptimeText(advice.uptimeHours)))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if monitor.confirmingRestart {
                Button("확인") { monitor.confirmChatGPTRestart() }
                    .glassButton(prominent: true, tint: .orange)
                    .controlSize(.small)
                    .help("ChatGPT를 정상 종료한 뒤 다시 엽니다. 진행 중인 Codex 작업은 멈춰요.")
            } else {
                Button("다시 시작") { monitor.requestChatGPTRestart() }
                    .glassButton()
                    .controlSize(.small)
                    .disabled(monitor.isBusy)
            }
        }
        .padding(10)
        .glassCard(tint: .orange)
    }

    static func uptimeText(_ hours: Double) -> String {
        if hours >= 48 { return String(format: "%.0f일 넘게", floor(hours / 24)) }
        if hours >= 1 { return String(format: "%.0f시간째", hours) }
        return String(format: "%.0f분째", max(1, (hours * 60).rounded()))
    }

    /// Switches to GB at 1023.5MB so a value never renders as "1024M".
    func formatShort(_ mb: Double) -> String {
        mb >= 1023.5 ? String(format: "%.1fG", mb / 1024.0) : String(format: "%.0fM", mb)
    }

    func formatMB(_ mb: Double) -> String {
        if mb >= 1023.5 {
            return String(format: "%.2fGB", mb / 1024.0)
        }
        return String(format: "%.0fMB", mb)
    }
}
