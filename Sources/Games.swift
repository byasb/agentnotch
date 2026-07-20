import SwiftUI
import AppKit

// MARK: - Game space — three calm, turn-based games for a mental breather while
// agents run. No reflexes, no timers, no failure spirals: 2048, Memory, Minesweeper.

enum GameKind: String, CaseIterable, Identifiable {
    case g2048 = "2048"
    case memory = "Memory"
    case mines = "Minesweeper"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .g2048: "square.grid.2x2"
        case .memory: "rectangle.grid.3x2"
        case .mines: "flag"
        }
    }
}

/// Shared "are my agents still going?" indicator — used in the Focus/Breathe
/// screen and the Games window so you can keep half an eye on the fleet.
struct AgentStatusPill: View {
    let working: Int
    let attention: Int
    private let calm = Color(red: 0.35, green: 0.78, blue: 0.72)
    private let alert = Color(red: 0.95, green: 0.62, blue: 0.30)

    var body: some View {
        let allDone = working == 0 && attention == 0
        return HStack(spacing: 8) {
            if allDone {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(calm)
                Text("All agents done").foregroundStyle(calm)
            } else {
                if working > 0 {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text("\(working) working").foregroundStyle(.green)
                }
                if attention > 0 {
                    if working > 0 { Text("·").foregroundStyle(.tertiary) }
                    Image(systemName: "bell.fill").font(.system(size: 9)).foregroundStyle(alert)
                    Text("\(attention) need you").foregroundStyle(alert)
                }
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.white.opacity(0.05), in: Capsule())
        .animation(.easeInOut(duration: 0.3), value: allDone)
    }
}

struct GamesView: View {
    @ObservedObject var monitor: AgentMonitor
    @State private var kind: GameKind = .g2048
    @StateObject private var g2048 = Game2048()
    @StateObject private var memory = MemoryGame()
    @StateObject private var mines = MinesGame()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(GameKind.allCases) { k in
                    Button { kind = k } label: {
                        Label(k.rawValue, systemImage: k.icon)
                            .font(.system(size: 11, weight: kind == k ? .semibold : .regular))
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(kind == k ? .white.opacity(0.12) : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(kind == k ? .white : .secondary)
                }
                Spacer()
                Button {
                    switch kind {
                    case .g2048: g2048.reset()
                    case .memory: memory.reset()
                    case .mines: mines.reset()
                    }
                } label: {
                    Label("New", systemImage: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            // Live agent status — glance up mid-game to see the fleet finish.
            HStack {
                AgentStatusPill(working: monitor.workingCount, attention: monitor.attentionCount)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            Divider().opacity(0.2)
            Group {
                switch kind {
                case .g2048: Game2048View(game: g2048)
                case .memory: MemoryView(game: memory)
                case .mines: MinesView(game: mines)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(red: 0.04, green: 0.05, blue: 0.06))
        .preferredColorScheme(.dark)
        .onAppear {
            if g2048.grid.flatMap({ $0 }).allSatisfy({ $0 == 0 }) { g2048.reset() }
            if memory.cards.isEmpty { memory.reset() }
            if mines.grid.isEmpty { mines.reset() }
        }
    }
}

// MARK: 2048

@MainActor
final class Game2048: ObservableObject {
    @Published var grid = Array(repeating: Array(repeating: 0, count: 4), count: 4)
    @Published var score = 0
    @Published var won = false
    @Published var over = false

    init() { reset() }

    func reset() {
        grid = Array(repeating: Array(repeating: 0, count: 4), count: 4)
        score = 0; won = false; over = false
        spawn(); spawn()
    }

    private func spawn() {
        let empties = (0..<4).flatMap { r in (0..<4).compactMap { c in grid[r][c] == 0 ? (r, c) : nil } }
        guard let (r, c) = empties.randomElement() else { return }
        grid[r][c] = Int.random(in: 0..<10) == 0 ? 4 : 2
    }

    // Slide+merge one row leftward.
    private func slide(_ row: [Int]) -> ([Int], Int) {
        let t = row.filter { $0 != 0 }
        var out: [Int] = []; var gained = 0; var i = 0
        while i < t.count {
            if i + 1 < t.count && t[i] == t[i + 1] {
                out.append(t[i] * 2); gained += t[i] * 2; i += 2
            } else { out.append(t[i]); i += 1 }
        }
        while out.count < 4 { out.append(0) }
        return (out, gained)
    }

    func move(_ dir: MoveDir) {
        var g = grid
        // orient so the move is "left"
        switch dir {
        case .left: break
        case .right: g = g.map { $0.reversed() }
        case .up: g = transpose(g)
        case .down: g = transpose(g).map { $0.reversed() }
        }
        var gained = 0
        g = g.map { row in let (n, gd) = slide(row); gained += gd; return n }
        // orient back
        switch dir {
        case .left: break
        case .right: g = g.map { $0.reversed() }
        case .up: g = transpose(g)
        case .down: g = transpose(g.map { $0.reversed() })
        }
        if g != grid {
            grid = g; score += gained
            if grid.flatMap({ $0 }).contains(2048) { won = true }
            spawn()
            over = !anyMoves()
        }
    }

    private func transpose(_ m: [[Int]]) -> [[Int]] {
        (0..<4).map { c in (0..<4).map { r in m[r][c] } }
    }

    private func anyMoves() -> Bool {
        for r in 0..<4 { for c in 0..<4 {
            if grid[r][c] == 0 { return true }
            if c + 1 < 4 && grid[r][c] == grid[r][c + 1] { return true }
            if r + 1 < 4 && grid[r][c] == grid[r + 1][c] { return true }
        } }
        return false
    }
}

enum MoveDir { case up, down, left, right }

struct Game2048View: View {
    @ObservedObject var game: Game2048

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Score \(game.score)").font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                if game.won { Text("You hit 2048! ").font(.system(size: 11)).foregroundStyle(.green) }
                else if game.over { Text("No moves left").font(.system(size: 11)).foregroundStyle(.orange) }
            }
            .padding(.horizontal, 4)
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                let gap = 8.0
                let cell = (side - gap * 5) / 4
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05))
                    ForEach(0..<4, id: \.self) { r in
                        ForEach(0..<4, id: \.self) { c in
                            let v = game.grid[r][c]
                            RoundedRectangle(cornerRadius: 8)
                                .fill(tile(v))
                                .overlay(Text(v == 0 ? "" : "\(v)")
                                    .font(.system(size: v >= 1024 ? 20 : 24, weight: .bold, design: .rounded))
                                    .foregroundStyle(v <= 4 ? .white.opacity(0.85) : .black.opacity(0.8)))
                                .frame(width: cell, height: cell)
                                .position(x: gap + cell / 2 + Double(c) * (cell + gap),
                                          y: gap + cell / 2 + Double(r) * (cell + gap))
                        }
                    }
                }
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text("Arrow keys to move").font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { game.move(.left); return .handled }
        .onKeyPress(.rightArrow) { game.move(.right); return .handled }
        .onKeyPress(.upArrow) { game.move(.up); return .handled }
        .onKeyPress(.downArrow) { game.move(.down); return .handled }
    }

    private func tile(_ v: Int) -> Color {
        switch v {
        case 0: return .white.opacity(0.04)
        case 2: return Color(red: 0.36, green: 0.42, blue: 0.5)
        case 4: return Color(red: 0.30, green: 0.5, blue: 0.55)
        case 8: return Color(red: 0.36, green: 0.72, blue: 0.66)
        case 16: return Color(red: 0.45, green: 0.78, blue: 0.55)
        case 32: return Color(red: 0.7, green: 0.8, blue: 0.42)
        case 64: return Color(red: 0.92, green: 0.78, blue: 0.35)
        case 128: return Color(red: 0.95, green: 0.66, blue: 0.32)
        case 256: return Color(red: 0.96, green: 0.55, blue: 0.3)
        case 512: return Color(red: 0.96, green: 0.44, blue: 0.36)
        default: return Color(red: 0.95, green: 0.35, blue: 0.45)
        }
    }
}

// MARK: Memory

@MainActor
final class MemoryGame: ObservableObject {
    struct Card: Identifiable { let id: Int; let symbol: String; var up = false; var matched = false }
    @Published var cards: [Card] = []
    @Published var moves = 0
    private var busy = false
    private let symbols = ["leaf.fill", "flame.fill", "bolt.fill", "heart.fill",
                           "star.fill", "moon.fill", "cloud.fill", "drop.fill"]

    init() { reset() }

    var won: Bool { !cards.isEmpty && cards.allSatisfy { $0.matched } }

    func reset() {
        let deck = (symbols + symbols).shuffled()
        cards = deck.enumerated().map { Card(id: $0.offset, symbol: $0.element) }
        moves = 0; busy = false
    }

    func flip(_ id: Int) {
        guard !busy, let i = cards.firstIndex(where: { $0.id == id }),
              !cards[i].up, !cards[i].matched else { return }
        cards[i].up = true
        let up = cards.filter { $0.up && !$0.matched }
        if up.count == 2 {
            moves += 1
            busy = true
            if up[0].symbol == up[1].symbol {
                for j in cards.indices where cards[j].up && !cards[j].matched { cards[j].matched = true }
                busy = false
            } else {
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    for j in cards.indices where !cards[j].matched { cards[j].up = false }
                    busy = false
                }
            }
        }
    }
}

struct MemoryView: View {
    @ObservedObject var game: MemoryGame
    private let cols = 4

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Moves \(game.moves)").font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                if game.won { Text("Solved! ").font(.system(size: 11)).foregroundStyle(.green) }
            }
            .padding(.horizontal, 4)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: cols), spacing: 8) {
                ForEach(game.cards) { card in
                    Button { game.flip(card.id) } label: {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(card.matched ? Color.green.opacity(0.18)
                                  : card.up ? Color.white.opacity(0.12) : Color.white.opacity(0.05))
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                if card.up || card.matched {
                                    Image(systemName: card.symbol)
                                        .font(.system(size: 22))
                                        .foregroundStyle(card.matched ? .green : .white)
                                } else {
                                    Image(systemName: "questionmark")
                                        .font(.system(size: 16)).foregroundStyle(.secondary.opacity(0.4))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Match all pairs").font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(14)
    }
}

// MARK: Minesweeper

@MainActor
final class MinesGame: ObservableObject {
    struct Cell { var mine = false; var revealed = false; var flagged = false; var adj = 0 }
    @Published var grid: [[Cell]] = []
    @Published var over = false
    @Published var won = false
    @Published var flags = 0
    let rows = 9, cols = 9, mineCount = 10
    private var placed = false

    init() { reset() }

    func reset() {
        grid = Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
        over = false; won = false; flags = 0; placed = false
    }

    private func place(avoid ar: Int, _ ac: Int) {
        var spots = (0..<rows).flatMap { r in (0..<cols).map { c in (r, c) } }
            .filter { !($0.0 == ar && $0.1 == ac) }
        spots.shuffle()
        for (r, c) in spots.prefix(mineCount) { grid[r][c].mine = true }
        for r in 0..<rows { for c in 0..<cols {
            grid[r][c].adj = neighbors(r, c).filter { grid[$0.0][$0.1].mine }.count
        } }
        placed = true
    }

    private func neighbors(_ r: Int, _ c: Int) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for dr in -1...1 { for dc in -1...1 where !(dr == 0 && dc == 0) {
            let nr = r + dr, nc = c + dc
            if nr >= 0, nr < rows, nc >= 0, nc < cols { out.append((nr, nc)) }
        } }
        return out
    }

    func reveal(_ r: Int, _ c: Int) {
        guard !over, !won, !grid[r][c].revealed, !grid[r][c].flagged else { return }
        if !placed { place(avoid: r, c) }
        flood(r, c)
        if grid[r][c].mine {
            over = true
            for rr in 0..<rows { for cc in 0..<cols where grid[rr][cc].mine { grid[rr][cc].revealed = true } }
        }
        checkWin()
    }

    private func flood(_ r: Int, _ c: Int) {
        guard !grid[r][c].revealed, !grid[r][c].flagged else { return }
        grid[r][c].revealed = true
        if grid[r][c].mine { return }
        if grid[r][c].adj == 0 {
            for (nr, nc) in neighbors(r, c) where !grid[nr][nc].revealed { flood(nr, nc) }
        }
    }

    func toggleFlag(_ r: Int, _ c: Int) {
        guard !over, !won, !grid[r][c].revealed else { return }
        grid[r][c].flagged.toggle()
        flags += grid[r][c].flagged ? 1 : -1
    }

    private func checkWin() {
        let safe = grid.flatMap { $0 }.filter { !$0.mine }
        if safe.allSatisfy({ $0.revealed }) { won = true }
    }
}

struct MinesView: View {
    @ObservedObject var game: MinesGame

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label("\(game.mineCount - game.flags)", systemImage: "flag.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                if game.won { Text("Cleared! ").font(.system(size: 11)).foregroundStyle(.green) }
                else if game.over { Text("Boom ").font(.system(size: 11)).foregroundStyle(.red) }
            }
            .padding(.horizontal, 4)
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                let cell = side / Double(game.cols)
                if game.grid.count == game.rows {
                    VStack(spacing: 2) {
                        ForEach(0..<game.rows, id: \.self) { r in
                            HStack(spacing: 2) {
                                ForEach(0..<game.cols, id: \.self) { c in
                                    cellView(game.grid[r][c], r: r, c: c)
                                        .frame(width: cell - 2, height: cell - 2)
                                }
                            }
                        }
                    }
                    .frame(width: side, height: side)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Text("Click to reveal · right-click to flag").font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(14)
    }

    @ViewBuilder
    private func cellView(_ cell: MinesGame.Cell, r: Int, c: Int) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(cell.revealed ? Color.white.opacity(0.04) : Color.white.opacity(0.12))
            .overlay {
                if cell.flagged && !cell.revealed {
                    Image(systemName: "flag.fill").font(.system(size: 11)).foregroundStyle(.orange)
                } else if cell.revealed {
                    if cell.mine {
                        Image(systemName: "burst.fill").font(.system(size: 12)).foregroundStyle(.red)
                    } else if cell.adj > 0 {
                        Text("\(cell.adj)").font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(numColor(cell.adj))
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { game.reveal(r, c) }
            .simultaneousGesture(TapGesture().modifiers(.control).onEnded { game.toggleFlag(r, c) })
            .contextMenu { Button("Flag / Unflag") { game.toggleFlag(r, c) } }
    }

    private func numColor(_ n: Int) -> Color {
        switch n {
        case 1: .cyan
        case 2: .green
        case 3: .orange
        case 4: .purple
        default: .red
        }
    }
}

// MARK: Controller

@MainActor
final class GamesController {
    private var window: NSWindow?
    private let monitor: AgentMonitor
    init(monitor: AgentMonitor) { self.monitor = monitor }
    func toggle() {
        if let w = window, w.isVisible { w.orderOut(nil); return }
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            w.title = "Games"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.backgroundColor = NSColor(red: 0.04, green: 0.05, blue: 0.06, alpha: 1)
            w.contentView = NSHostingView(rootView: GamesView(monitor: monitor))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
