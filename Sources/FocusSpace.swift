import SwiftUI
import AppKit

// MARK: - Focus space — calm, meditative modes for when many agents leave you scattered.
//
// Three modes, no scores, no failure states:
//   • Breathe — a box / 4-7-8 breathing pacer to slow down and reset.
//   • Drift   — a slow ambient field to rest your eyes on while agents work.
//   • Focus   — one agent at a time, big and quiet, so a busy fleet stops overwhelming.
//
// Animations are pure functions of time and only run while the window is on screen.

enum FocusMode: String, CaseIterable, Identifiable {
    case breathe = "Breathe"
    case drift = "Drift"
    case focus = "Focus"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .breathe: "wind"
        case .drift: "sparkles"
        case .focus: "scope"
        }
    }
}

@MainActor
final class FocusState: ObservableObject {
    @Published var visible = false
    /// Breathing session anchor. Kept here (not @State) so monitor-driven
    /// re-renders can never silently restart the session.
    @Published var breatheStart = Date()
    func restartBreathe() { breatheStart = Date() }
}

struct BreathPattern: Identifiable {
    let id: String
    let subtitle: String
    // phases: label, duration seconds, start openness (0..1), end openness
    let phases: [(label: String, dur: Double, from: Double, to: Double)]
    var cycle: Double { phases.reduce(0) { $0 + $1.dur } }

    static let box = BreathPattern(
        id: "Box", subtitle: "4 · 4 · 4 · 4",
        phases: [("Breathe in", 4, 0.32, 1), ("Hold", 4, 1, 1),
                 ("Breathe out", 4, 1, 0.32), ("Hold", 4, 0.32, 0.32)])
    static let relax = BreathPattern(
        id: "Relax", subtitle: "4 · 7 · 8",
        phases: [("Breathe in", 4, 0.32, 1), ("Hold", 7, 1, 1),
                 ("Breathe out", 8, 1, 0.32)])
    static let all = [box, relax]

    /// Returns (label, openness 0..1, phase progress 0..1) at time t.
    func sample(_ t: Double) -> (String, Double, Double) {
        var x = t.truncatingRemainder(dividingBy: cycle)
        for p in phases {
            if x < p.dur {
                let prog = x / p.dur
                let eased = prog * prog * (3 - 2 * prog)   // smoothstep for calm motion
                return (p.label, p.from + (p.to - p.from) * eased, prog)
            }
            x -= p.dur
        }
        return (phases[0].label, phases[0].from, 0)
    }
}

struct FocusView: View {
    @ObservedObject var monitor: AgentMonitor
    @ObservedObject var state: FocusState
    @State private var mode: FocusMode = .breathe
    @State private var pattern = BreathPattern.box
    @State private var targetBreaths = 6
    @State private var focusIdx = 0

    var body: some View {
        VStack(spacing: 0) {
            switcher
            Group {
                switch mode {
                case .breathe: BreathePacer(pattern: pattern, target: targetBreaths,
                                            working: monitor.workingCount, attention: monitor.attentionCount,
                                            running: state.visible,
                                            start: state.breatheStart, onRestart: state.restartBreathe)
                case .drift: DriftField(running: state.visible)
                case .focus: FocusOne(monitor: monitor, idx: $focusIdx)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: mode) { _, m in if m == .breathe { state.restartBreathe() } }
            .onChange(of: pattern.id) { _, _ in state.restartBreathe() }
            .onChange(of: targetBreaths) { _, _ in state.restartBreathe() }
            if mode == .breathe { breatheControls }
        }
        .background(Color(red: 0.03, green: 0.04, blue: 0.05))
        .preferredColorScheme(.dark)
    }

    private var switcher: some View {
        HStack(spacing: 6) {
            ForEach(FocusMode.allCases) { m in
                Button { withAnimation(.easeInOut(duration: 0.25)) { mode = m } } label: {
                    Label(m.rawValue, systemImage: m.icon)
                        .font(.system(size: 11, weight: mode == m ? .semibold : .regular))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(mode == m ? .white.opacity(0.12) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(mode == m ? .white : .secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var breatheControls: some View {
        HStack(spacing: 6) {
            ForEach(BreathPattern.all) { p in
                Button { pattern = p } label: {
                    VStack(spacing: 0) {
                        Text(p.id).font(.system(size: 10, weight: .semibold))
                        Text(p.subtitle).font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(pattern.id == p.id ? .white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .foregroundStyle(pattern.id == p.id ? .white : .secondary)
            }
            Divider().frame(height: 22).opacity(0.3)
            ForEach([3, 6, 10], id: \.self) { n in
                Button { targetBreaths = n } label: {
                    Text("\(n)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .frame(minWidth: 22)
                        .padding(.vertical, 6)
                        .background(targetBreaths == n ? .white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .foregroundStyle(targetBreaths == n ? .white : .secondary)
            }
            Text("breaths").font(.system(size: 9)).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }
}

// MARK: Breathe

struct BreathePacer: View {
    let pattern: BreathPattern
    let target: Int            // breaths to complete
    let working: Int
    let attention: Int
    let running: Bool
    let start: Date            // session anchor, owned by FocusState
    let onRestart: () -> Void

    private let calm = Color(red: 0.35, green: 0.78, blue: 0.72)   // soft teal
    private let alert = Color(red: 0.95, green: 0.62, blue: 0.30)  // soft amber
    private var total: Double { Double(target) * pattern.cycle }

    var body: some View {
        if running {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { tl in
                content(elapsed: max(0, tl.date.timeIntervalSince(start)))
            }
        } else {
            content(elapsed: 0)
        }
    }

    @ViewBuilder private func content(elapsed: Double) -> some View {
        if total > 0 && elapsed >= total {
            completeView
        } else {
            breathingView(elapsed: elapsed)
        }
    }

    private func breathingView(elapsed: Double) -> some View {
        let (label, open, _) = pattern.sample(elapsed)
        let tint = attention > 0 ? alert : calm
        let fraction = total > 0 ? min(1, elapsed / total) : 0
        let breathsDone = min(target, Int(elapsed / pattern.cycle))
        let remaining = max(0, total - elapsed)
        return ZStack {
            GeometryReader { geo in
                let d = min(geo.size.width, geo.size.height)
                let ringR = d * 0.42
                let r = d * (0.12 + open * 0.24)
                ZStack {
                    // breathing radial glow
                    Circle().fill(tint.opacity(0.10 + 0.10 * open))
                        .frame(width: r * 3.2, height: r * 3.2).blur(radius: 40)
                    // fixed progress ring — the "how far along" gauge
                    Circle().stroke(.white.opacity(0.08), lineWidth: 4)
                        .frame(width: ringR * 2, height: ringR * 2)
                    Circle().trim(from: 0, to: fraction)
                        .stroke(tint.opacity(0.9), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: ringR * 2, height: ringR * 2)
                    // the breathing orb
                    Circle().fill(tint.opacity(0.20)).frame(width: r * 2, height: r * 2)
                    Circle().stroke(tint.opacity(0.85), lineWidth: 2).frame(width: r * 2, height: r * 2)
                }
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            VStack(spacing: 6) {
                Text(label).font(.system(size: 20, weight: .light, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9)).contentTransition(.opacity)
                if attention > 0 {
                    Text("\(attention) agent\(attention > 1 ? "s" : "") waiting — finish this breath first")
                        .font(.system(size: 10)).foregroundStyle(alert.opacity(0.9))
                } else {
                    Text(pattern.subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            // Live agent status at the top — watch your fleet finish while you breathe.
            VStack {
                agentStatus
                Spacer()
                // Progress readout, tucked at the bottom so it never fights the orb.
                HStack(spacing: 6) {
                    Text("\(breathsDone) / \(target) breaths")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(timeStr(remaining)) left")
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            }
        }
    }

    /// The at-a-glance "are my agents still going?" banner — shared with the Games
    /// window so the indicator reads identically everywhere.
    private var agentStatus: some View {
        AgentStatusPill(working: working, attention: attention).padding(.top, 8)
    }

    private var completeView: some View {
        VStack(spacing: 12) {
            agentStatus
            Spacer().frame(height: 4)
            ZStack {
                Circle().stroke(calm.opacity(0.85), lineWidth: 4).frame(width: 96, height: 96)
                Image(systemName: "checkmark").font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(calm)
            }
            Text("Done").font(.system(size: 22, weight: .light, design: .rounded))
            Text("\(target) breaths · \(timeStr(total))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button(action: onRestart) {
                Label("Start again", systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(.white.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    private func timeStr(_ s: Double) -> String {
        let sec = Int(s.rounded())
        return String(format: "%d:%02d", sec / 60, sec % 60)
    }
}

// MARK: Drift

struct DriftField: View {
    let running: Bool
    private let count = 46

    var body: some View {
        if running {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { tl in
                canvas(t: tl.date.timeIntervalSinceReferenceDate)
            }
        } else {
            canvas(t: 0)
        }
    }

    private func canvas(t: Double) -> some View {
        Canvas { ctx, size in
            let golden = 2.399963
            for i in 0..<count {
                let ph = Double(i) * golden
                // very slow, low-amplitude wander — restful, not busy
                let x = size.width * (0.5 + 0.42 * sin(t * 0.05 + ph))
                let y = size.height * (0.5 + 0.42 * cos(t * 0.037 + ph * 1.3))
                let tw = 0.4 + 0.6 * (0.5 + 0.5 * sin(t * 0.6 + ph))   // gentle twinkle
                let r = 1.5 + 2.0 * (Double(i % 5) / 5.0)
                ctx.fill(Path(ellipseIn: CGRect(x: x - r * 2.5, y: y - r * 2.5, width: r * 5, height: r * 5)),
                         with: .color(Color(red: 0.5, green: 0.8, blue: 0.85).opacity(0.05 * tw)))
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                         with: .color(Color(red: 0.7, green: 0.9, blue: 0.95).opacity(0.5 * tw)))
            }
        }
    }
}

// MARK: Focus one agent

struct FocusOne: View {
    @ObservedObject var monitor: AgentMonitor
    @Binding var idx: Int

    // Prioritise what needs you, then active work, then anything recent.
    private var ordered: [AgentSession] {
        let attn = monitor.sessions.filter { $0.state == .attention }
        let work = monitor.sessions.filter { $0.state == .working }
        let rest = monitor.sessions.filter { $0.state != .attention && $0.state != .working }
        return attn + work + rest
    }

    var body: some View {
        let list = ordered
        VStack(spacing: 16) {
            if list.isEmpty {
                Text("No sessions to focus on.").foregroundStyle(.secondary)
            } else {
                let s = list[max(0, min(idx, list.count - 1))]
                Text("ONE THING AT A TIME").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Circle().fill(color(s)).frame(width: 9, height: 9)
                        Text(s.project).font(.system(size: 22, weight: .semibold))
                    }
                    Text(s.state.rawValue).font(.system(size: 12)).foregroundStyle(color(s))
                    if let m = s.model {
                        Text(m.replacingOccurrences(of: "claude-", with: ""))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if let attn = s.attentionMessage {
                        Text(attn).font(.system(size: 13)).foregroundStyle(.orange)
                            .multilineTextAlignment(.center).padding(.horizontal, 24)
                    } else if !s.lastSnippet.isEmpty {
                        Text(s.lastSnippet).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center).lineLimit(4).padding(.horizontal, 24)
                    }
                }
                .padding(24)
                .frame(maxWidth: 420)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))

                HStack(spacing: 14) {
                    Button { idx = (idx - 1 + list.count) % list.count } label: {
                        Image(systemName: "chevron.left.circle").font(.system(size: 22))
                    }.buttonStyle(.plain)
                    Text("\(min(idx, list.count - 1) + 1) / \(list.count)")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Button { idx = (idx + 1) % list.count } label: {
                        Image(systemName: "chevron.right.circle").font(.system(size: 22))
                    }.buttonStyle(.plain)
                    Button { Jump.openInTerminal(s.cwd) } label: {
                        Label("Open", systemImage: "terminal").font(.system(size: 11))
                    }.buttonStyle(.plain).padding(.leading, 8)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private func color(_ s: AgentSession) -> Color {
        switch s.state {
        case .working: .green
        case .attention: .orange
        case .idle: .yellow.opacity(0.8)
        case .finished: .gray
        }
    }
}

// MARK: Controller

@MainActor
final class FocusController {
    private var window: NSWindow?
    private let monitor: AgentMonitor
    private let state = FocusState()

    init(monitor: AgentMonitor) { self.monitor = monitor }

    func toggle() {
        if let w = window, w.isVisible {
            state.visible = false; w.orderOut(nil); return
        }
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 460),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            w.title = "Focus"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.backgroundColor = NSColor(red: 0.03, green: 0.04, blue: 0.05, alpha: 1)
            w.delegate = windowDelegate
            w.contentView = NSHostingView(rootView: FocusView(monitor: monitor, state: state))
            w.center()
            window = w
        }
        state.restartBreathe()   // fresh breathing session each time you open Focus
        state.visible = true
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private lazy var windowDelegate = FocusWindowDelegate { [weak self] in self?.state.visible = false }
}

final class FocusWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}
