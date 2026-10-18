import SwiftUI

/// Shared rotation clock for the mini player's artwork disc.
///
/// The iOS 26 tab accessory rebuilds its content on tab switches (#46), and
/// the bar swaps between its expanded and inline layouts; keeping the angle
/// here lets each rebuilt disc continue from where the last one was instead
/// of snapping back to 0°.
@MainActor
final class ArtworkDiscRotation: ObservableObject {
    static let shared = ArtworkDiscRotation()

    @Published private(set) var state = RecordRotationState()

    /// Re-anchors the clock on a play/pause or speed change. The angle reached
    /// so far is kept, so the disc never jumps.
    func update(spinning: Bool, revolutionsPerMinute: Double, at date: Date = Date()) {
        let degreesPerSecond = max(revolutionsPerMinute, 0) * 6
        guard state.isAnimating != spinning || state.degreesPerSecond != degreesPerSecond else { return }
        let angle = state.currentAngle(at: date).truncatingRemainder(dividingBy: 360)
        var next = RecordRotationState(degreesPerSecond: degreesPerSecond)
        next.reset(to: angle)
        if spinning { next.start(at: date) }
        state = next
    }
}

/// Circular album artwork that turns like a record while music plays and
/// rests at its current angle when paused.
struct SpinningArtworkDisc: View {
    let url: URL?
    let diameter: CGFloat
    let isPlaying: Bool
    /// Zero keeps the disc still.
    let revolutionsPerMinute: Double
    @ObservedObject var rotation: ArtworkDiscRotation

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var spins: Bool {
        isPlaying && revolutionsPerMinute > 0 && !reduceMotion
    }

    var body: some View {
        // 60 fps is smooth for a disc this small and spares ProMotion
        // displays from running at 120 Hz just for the mini player.
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !rotation.state.isAnimating)) { context in
            CachedAsyncImage(url: url)
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .rotationEffect(.degrees(rotation.state.currentAngle(at: context.date)))
        }
        .frame(width: diameter, height: diameter)
        .overlay {
            Circle()
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
        .onAppear(perform: syncRotation)
        .onChange(of: spins) { _ in syncRotation() }
        .onChange(of: revolutionsPerMinute) { _ in syncRotation() }
    }

    private func syncRotation() {
        rotation.update(spinning: spins, revolutionsPerMinute: revolutionsPerMinute)
    }
}
