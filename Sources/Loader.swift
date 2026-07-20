import SwiftUI

// MARK: - Reusable loading primitives (shimmer skeleton + progress line)

/// Animated shimmer sweep, used as a skeleton placeholder while data loads.
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content.overlay(
            GeometryReader { geo in
                LinearGradient(
                    colors: [.clear, .white.opacity(0.18), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: geo.size.width * 1.4)
                .offset(x: phase * geo.size.width * 1.4)
                .blendMode(.plusLighter)
            }
            .mask(content)
            .allowsHitTesting(false)
        )
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

extension View {
    func shimmering(_ on: Bool = true) -> some View {
        on ? AnyView(modifier(Shimmer())) : AnyView(self)
    }
}

/// A neutral skeleton block sized like a real tile/chart, shown during a cold scan.
struct SkeletonBlock: View {
    var height: CGFloat = 60
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.white.opacity(0.06))
            .frame(height: height)
            .shimmering()
    }
}

/// Thin determinate/indeterminate progress line pinned to the top of the panel.
struct ScanProgressBar: View {
    let progress: ScanProgress
    @State private var sweep: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.08))
                if progress.total > 0 {
                    // determinate: fraction of files scanned
                    Rectangle().fill(Color.green)
                        .frame(width: geo.size.width * progress.fraction)
                        .animation(.easeOut(duration: 0.25), value: progress.fraction)
                } else {
                    // indeterminate: pre-count sweep
                    Rectangle().fill(Color.green.opacity(0.8))
                        .frame(width: geo.size.width * 0.3)
                        .offset(x: sweep * geo.size.width * 1.3 - geo.size.width * 0.3)
                        .onAppear {
                            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                                sweep = 1
                            }
                        }
                }
            }
        }
        .frame(height: 2)
    }
}
