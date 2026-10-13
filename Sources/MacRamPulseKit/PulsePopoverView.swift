import Cocoa
import SwiftUI
import Darwin

// MARK: - Modern SwiftUI Popover Interface (v5.3)

struct PulsePopoverView: View {
    @ObservedObject var monitor: SystemMemoryMonitor

    var pressureBadgeText: String {
        switch monitor.stats.vmPressureLevel {
        case 4: return "🔴 압박 위험"
        case 2: return "🟡 스왑 활성"
        default: return "🟢 압박 없음 (\(monitor.stats.kernelFreeLevel)% 여유)"
        }
    }

    var pressureBadgeColor: Color {
        switch monitor.stats.vmPressureLevel {
        case 4: return .red
        case 2: return .orange
        default: return .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 1. Top Header Bar
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(LinearGradient(
                            colors: [Color.blue, Color.purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 34, height: 34)
                    Image(systemName: "memorychip.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 16, weight: .semibold))
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("MacRamPulse")
                            .font(.system(size: 15, weight: .bold))
                        Text("v5.3")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.2))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                        Text(pressureBadgeText)
                            .font(.system(size: 9.5, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(pressureBadgeColor.opacity(0.18))
                            .foregroundColor(pressureBadgeColor)
                            .cornerRadius(4)
                    }
                    Text(String(format: "%@ · 커널 직접 스캔 %.1fms", SystemMemoryMonitor.machineLabel, monitor.stats.scanDurationMs))
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: { monitor.refreshFull() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("즉시 새로고침")

                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("MacRamPulse 종료")
            }

            // 2. Always-Visible Hero Dual Cards (Physical RAM + SSD Swap)
            HStack(spacing: 10) {
                // Left Card: Physical RAM Breakdown
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("통합 메모리 (RAM)", systemImage: "cpu")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(monitor.stats.usedPercent)%")
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                            .foregroundColor(monitor.stats.usedPercent > 82 ? .red : .blue)
                    }

                    Text(String(format: "%.1f GB / %.0f GB", monitor.stats.usedGB, monitor.stats.totalGB))
                        .font(.system(size: 16, weight: .bold, design: .rounded))

                    // Multi-segment bar (Active + Wired + Compressed)
                    GeometryReader { geo in
                        let w = geo.size.width
                        let total = max(1.0, monitor.stats.totalGB)
                        let actW = w * CGFloat(min(1.0, monitor.stats.activeGB / total))
                        let wirW = w * CGFloat(min(1.0, monitor.stats.wiredGB / total))
                        let cmpW = w * CGFloat(min(1.0, monitor.stats.compressedGB / total))
                        HStack(spacing: 1) {
                            Rectangle().fill(Color.blue).frame(width: max(2, actW))
                            Rectangle().fill(Color.purple).frame(width: max(2, wirW))
                            Rectangle().fill(Color.orange).frame(width: max(2, cmpW))
                            Spacer(minLength: 0)
                        }
                        .frame(height: 7)
                        .background(Color.primary.opacity(0.08))
                        .cornerRadius(3.5)
                    }
                    .frame(height: 7)

                    HStack(spacing: 6) {
                        Text(String(format: "활성 %.1f · 고정 %.1f · 압축 %.1fG",
                                    monitor.stats.activeGB, monitor.stats.wiredGB, monitor.stats.compressedGB))
                            .font(.system(size: 9.5))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Spacer(minLength: 4)
                        Button("캐시 퍼지") {
                            monitor.purgePhysicalRAMCache()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(monitor.isBusy)
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(11)

                // Right Card: SSD Swap & Reclaim
                VStack(alignment: .leading, spacing: 6) {
                    let swapGB = monitor.stats.swapUsedMB / 1024.0
                    let swapTotalGB = max(0.5, monitor.stats.swapTotalMB / 1024.0)
                    HStack {
                        Label("SSD 스왑 (Swap)", systemImage: "internaldrive")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(swapGB > 6.0 ? "높음" : "안정")
                            .font(.system(size: 9.5, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(swapGB > 6.0 ? Color.orange.opacity(0.2) : Color.green.opacity(0.2))
                            .foregroundColor(swapGB > 6.0 ? .orange : .green)
                            .cornerRadius(4)
                    }

                    Text(String(format: "%.1f GB / %.1f GB", swapGB, swapTotalGB))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(swapGB > 6.0 ? .orange : .primary)

                    MeterBar(fraction: swapGB / swapTotalGB, color: swapGB > 6.0 ? .orange : .green)

                    HStack {
                        Text(String(format: "내장여유 %.0fGB", monitor.stats.internalFreeGB))
                            .font(.system(size: 9.5))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("유휴데몬 정리") {
                            monitor.reclaimIdleDaemonsNow()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.mini)
                        .disabled(monitor.isBusy)
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(11)
            }

            // 3. Main Segmented Tab Bar
            Picker("", selection: $monitor.mainTab) {
                ForEach(MainTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            // 4. Tab Content Area
            Group {
                switch monitor.mainTab {
                case .apps:
                    appsTabView
                case .autopilot:
                    autopilotTabView
                case .ssdBoost:
                    ssdBoostTabView
                }
            }

            // 5. Status Toast Footer
            if !monitor.lastActionMessage.isEmpty {
                HStack(spacing: 6) {
                    Text(monitor.lastActionMessage)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)
                        .help(monitor.lastActionMessage)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background((monitor.isToastWarning ? Color.orange : Color.green).opacity(0.12))
                .cornerRadius(8)
                .transition(.opacity)
            }
        }
        .padding(14)
        .frame(width: 460)
        .animation(.easeOut(duration: 0.2), value: monitor.lastActionMessage.isEmpty)
    }

    // MARK: - Tab 1: Apps Memory & Swap Breakdown (With Search & Safe 2-Step Kill)

    var appsTabView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Search & Sort Controls
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                    TextField("앱 또는 데몬 검색...", text: $monitor.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                    if !monitor.searchText.isEmpty {
                        Button(action: { monitor.searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(7)

                Picker("", selection: $monitor.sortMode) {
                    ForEach(SortMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 215)
                .controlSize(.small)
            }

            // Legend
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
            .foregroundColor(.secondary)

            ScrollView {
                VStack(spacing: 6) {
                    if monitor.filteredAndSortedGroups.isEmpty {
                        Text(monitor.hasNoSearchResults
                             ? "'\(monitor.searchText.trimmingCharacters(in: .whitespaces))'와(과) 일치하는 앱이 없습니다"
                             : "프로세스를 읽는 중…")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(monitor.filteredAndSortedGroups.prefix(15)) { group in
                        HStack(spacing: 10) {
                            Text(group.icon)
                                .font(.system(size: 18))
                                .frame(width: 26)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    Text(group.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .lineLimit(1)
                                    Text("\(group.processCount)개")
                                        .font(.system(size: 9.5, weight: .medium))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.primary.opacity(0.08))
                                        .cornerRadius(4)
                                    if group.isReclaimableDaemon {
                                        Text(group.showsIdleBadge ? "유휴 데몬" : "작업 중")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background((group.showsIdleBadge ? Color.orange : Color.blue).opacity(0.2))
                                            .foregroundColor(group.showsIdleBadge ? .orange : .blue)
                                            .cornerRadius(4)
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
                                                Rectangle()
                                                    .fill(Color.blue)
                                                    .frame(width: max(3, ramW))
                                            }
                                            if group.swapMB > 10 {
                                                Rectangle()
                                                    .fill(Color.orange)
                                                    .frame(width: max(3, swpW))
                                            }
                                            Spacer(minLength: 0)
                                        }
                                        .frame(height: 5)
                                        .background(Color.primary.opacity(0.06))
                                        .cornerRadius(2.5)
                                    }
                                    .frame(width: 96, height: 5)

                                    Text("RAM \(formatShort(group.rssMB)) · 스왑 \(formatShort(group.swapMB))")
                                        .font(.system(size: 10))
                                        .foregroundColor(group.swapMB > 1000 ? .orange : .secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 1) {
                                Text(formatMB(group.totalMB))
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                Text("총 점유")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                            .frame(width: 60, alignment: .trailing)

                            if group.isProtected {
                                Text("보호됨")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .frame(width: 56)
                            } else if monitor.confirmingGroupId == group.id {
                                Button("종료확인") {
                                    monitor.confirmTerminate(group)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                                .controlSize(.small)
                                .frame(width: 56)
                            } else {
                                Button(group.isReclaimableDaemon ? "회수" : "정리") {
                                    monitor.requestTerminate(group)
                                }
                                .help(group.isReclaimableDaemon
                                      ? "1분 이상 CPU를 쓰지 않은 데몬만 종료합니다 (작업 중인 빌드는 유지)"
                                      : "앱은 정상 종료(Quit)를 요청하고, 백그라운드 프로세스는 종료 신호를 보냅니다")
                                .buttonStyle(.bordered)
                                .tint(group.isReclaimableDaemon ? .orange : .primary)
                                .controlSize(.small)
                                .frame(width: 56)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(8)
                    }
                }
            }
            .frame(height: 265)
        }
    }

    // MARK: - Tab 2: Autonomous Autopilot & Activity Timeline

    var autopilotTabView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Stats Banner
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("누적 자동 회수 메모리")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f GB (%d회 자동 정리)", monitor.totalSavedMB / 1024.0, monitor.totalCleanCount))
                        .font(.system(size: 13.5, weight: .bold, design: .rounded))
                        .foregroundColor(.green)
                }
                Spacer()
                Button(action: { monitor.runAutoPatrol(manualTrigger: true) }) {
                    Label("지금 즉시 순찰", systemImage: "bolt.shield.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(10)
            .background(Color.green.opacity(0.08))
            .cornerRadius(10)

            // Rules Configuration Card
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

                Text("ℹ️ OpenClaw, Colima VM, Claude, Codex CLI 세션은 보호되며, 작업 중(CPU 사용)인 프로세스는 회수하지 않습니다.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(10)

            // Activity Timeline
            HStack {
                Text("📜 자동 관리 타임라인")
                    .font(.system(size: 11.5, weight: .bold))
                Spacer()
                Button("기록 비우기") {
                    monitor.clearLogs()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(monitor.autoLogs.enumerated()), id: \.offset) { _, log in
                        Text(log)
                            .font(.system(size: 10.5, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04))
                            .cornerRadius(6)
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
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(monitor.stats.internalUsedPct)%")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundColor(monitor.stats.internalUsedPct > 85 ? .orange : .green)
                    }
                    Text(String(format: "%.1f GB 여유", monitor.stats.internalFreeGB))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    MeterBar(fraction: Double(monitor.stats.internalUsedPct) / 100,
                             color: monitor.stats.internalUsedPct > 85 ? .orange : .green)
                }
                .padding(10)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(10)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("🚀 외장 SSD (캐시/I/O 분산)")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(monitor.stats.externalUsedPct)%")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundColor(.blue)
                    }
                    Text(String(format: "%.1f GB 여유", monitor.stats.externalFreeGB))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.blue)
                    MeterBar(fraction: Double(monitor.stats.externalUsedPct) / 100, color: .blue)
                }
                .padding(10)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(10)
            }

            HStack {
                Text("📦 대용량 개발/런타임 캐시 외장 분산 상태")
                    .font(.system(size: 11.5, weight: .bold))
                Spacer()
                Button("미사용 시뮬레이터 정리") {
                    monitor.cleanUnavailableSimulators()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(monitor.isBusy)
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(monitor.stats.offloadTargets) { target in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(target.title)
                                        .font(.system(size: 11.5, weight: .semibold))
                                    Text(target.estimatedSize)
                                        .font(.system(size: 9.5, weight: .bold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.primary.opacity(0.08))
                                        .cornerRadius(4)
                                }
                                Text(target.desc)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()

                            if target.exists {
                                Button(action: { monitor.revealInFinder(target.sourcePath) }) {
                                    Image(systemName: "folder")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Finder에서 위치 열기")
                            }

                            if target.isOffloaded {
                                Text("✅ 외장 분산됨")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundColor(.green)
                                    .frame(width: 82, alignment: .trailing)
                            } else if target.exists {
                                Button("외장 이전") {
                                    monitor.offloadToExternalSSD(target)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .frame(width: 82)
                                .disabled(monitor.isBusy)
                            } else {
                                Text("미생성")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .frame(width: 82, alignment: .trailing)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(8)
                    }
                }
            }
            .frame(height: 225)
        }
    }

    func formatShort(_ mb: Double) -> String {
        mb >= 1024.0 ? String(format: "%.1fG", mb / 1024.0) : String(format: "%.0fM", mb)
    }

    func formatMB(_ mb: Double) -> String {
        if mb >= 1024.0 {
            return String(format: "%.2fGB", mb / 1024.0)
        }
        return String(format: "%.0fMB", mb)
    }
}

/// Thin horizontal gauge. Drawn by hand (not ProgressView) so its tint also shows
/// when the popover's window is inactive.
struct MeterBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(color)
                .frame(width: max(2, geo.size.width * CGFloat(min(1.0, max(0, fraction)))))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.08))
                .cornerRadius(height / 2)
        }
        .frame(height: height)
    }
}
