import SwiftUI

// MARK: - Agent Swarm — an ambient firefly pane, one mote per live agent.
//
// Each running agent is a soft green light drifting on a lazy orbit. Each agent
// waiting on you (permission prompt) is an orange mote that blinks. When nothing
// is running the pane collapses and the animation loop is torn out of the view
// tree entirely — so it costs ~0% CPU when idle, matching the app's promise.
//
// Motion is a pure function of time (phase-offset trig): no per-frame state, so
// it resumes cleanly after a pause and is deterministic.

struct AgentSwarm: View {
    @ObservedObject var monitor: AgentMonitor
    var onTap: () -> Void
    var onBreathe: () -> Void = {}
    var onPlay: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var working: Int { monitor.workingCount }
    private var attention: Int { monitor.attentionCount }
    /// Only animate when there's something to show AND a surface is visible —
    /// off-screen display links are the classic hidden CPU cost.
    private var active: Bool { (working > 0 || attention > 0) && monitor.panelVisible }

    var body: some View {
        Group {
            if active {
                swarm
                    .frame(height: 54)
                    .frame(maxWidth: .infinity)
                    .background(
                        attention > 0
                            ? Color.orange.opacity(0.06)
                            : Color.green.opacity(0.03)
                    )
                    .overlay(alignment: .leading) { caption }
                    .overlay(alignment: .trailing) { actionButtons }
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
                    .help("\(working) working · \(attention) needs you — tap to open Sessions")
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.35), value: active)
    }

    @ViewBuilder private var swarm: some View {
        if active && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { tl in
                Canvas { ctx, size in
                    draw(ctx, size, t: tl.date.timeIntervalSinceReferenceDate)
                }
            }
        } else {
            // Idle or Reduce Motion: a single static frame, no display link → 0% CPU.
            Canvas { ctx, size in draw(ctx, size, t: 0, still: true) }
        }
    }

    private var caption: some View {
        HStack(spacing: 5) {
            if working > 0 {
                Text("\(working) working").foregroundStyle(.green)
            }
            if attention > 0 {
                Text("\(attention) needs you").foregroundStyle(.orange)
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.leading, 12)
        .shadow(color: .black.opacity(0.6), radius: 3)
    }

    /// Two off-ramps while agents work: calm down, or take a real break with a game.
    private var actionButtons: some View {
        HStack(spacing: 6) {
            pill("Breathe", icon: "wind", action: onBreathe)
                .help("Focus space — breathe, drift, or focus on one agent")
            pill("Play", icon: "gamecontroller", action: onPlay)
                .help("Games — 2048, Memory, Minesweeper")
        }
        .padding(.trailing, 12)
    }

    private func pill(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, t: Double, still: Bool = false) {
        let cx = size.width / 2, cy = size.height / 2
        let golden = 2.399963

        // Green working motes on lazy orbits, spread by the golden angle.
        for i in 0..<working {
            let ph = Double(i) * golden
            let ax: Double = still ? 0 : sin(t * 0.6 + ph) * min(cx - 12, 220)
            let ay: Double = still ? 0 : cos(t * 0.47 + ph * 1.3) * (cy - 10)
            let bright = still ? 0.7 : 0.6 + 0.4 * sin(t * 1.7 + ph)
            mote(ctx, x: cx + ax, y: cy + ay, hue: .green, brightness: bright, scale: 1)
        }

        // Orange attention motes: blink hard to pull the eye.
        for j in 0..<attention {
            let ph = Double(j) * golden + 0.7
            let ax: Double = still ? Double(j - attention / 2) * 22 : sin(t * 0.4 + ph) * min(cx - 16, 200)
            let ay: Double = still ? 0 : cos(t * 0.33 + ph) * (cy - 12)
            let blink = still ? 1.0 : 0.35 + 0.65 * abs(sin(t * .pi * 1.2 + ph))
            mote(ctx, x: cx + ax, y: cy + ay, hue: .orange, brightness: blink, scale: 1.25)
        }
    }

    private func mote(_ ctx: GraphicsContext, x: Double, y: Double, hue: Color, brightness: Double, scale: Double) {
        let b = max(0, min(1, brightness))
        let haloR = 9.0 * scale
        let coreR = 3.0 * scale
        ctx.fill(Path(ellipseIn: CGRect(x: x - haloR, y: y - haloR, width: haloR * 2, height: haloR * 2)),
                 with: .color(hue.opacity(0.18 * b)))
        ctx.fill(Path(ellipseIn: CGRect(x: x - coreR, y: y - coreR, width: coreR * 2, height: coreR * 2)),
                 with: .color(hue.opacity(0.55 + 0.45 * b)))
    }
}
