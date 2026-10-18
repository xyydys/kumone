import Foundation
import Testing
@testable import KumoneCore

@Suite @MainActor struct ArtworkDiscRotationTests {
    private let t0 = Date(timeIntervalSince1970: 1000)

    @Test func speedChangeKeepsTheAngleReached() {
        let rotation = ArtworkDiscRotation()
        rotation.update(spinning: true, revolutionsPerMinute: 10, at: t0) // 60°/s
        let t1 = t0.addingTimeInterval(1)
        #expect(rotation.state.currentAngle(at: t1) == 60)

        rotation.update(spinning: true, revolutionsPerMinute: 5, at: t1) // 30°/s
        #expect(rotation.state.currentAngle(at: t1) == 60)
        #expect(rotation.state.currentAngle(at: t1.addingTimeInterval(2)) == 120)
    }

    @Test func pauseHoldsTheAngleAndResumeContinuesFromIt() {
        let rotation = ArtworkDiscRotation()
        rotation.update(spinning: true, revolutionsPerMinute: 10, at: t0)
        let paused = t0.addingTimeInterval(0.5)
        rotation.update(spinning: false, revolutionsPerMinute: 10, at: paused)
        #expect(!rotation.state.isAnimating)
        #expect(rotation.state.currentAngle(at: paused.addingTimeInterval(30)) == 30)

        let resumed = paused.addingTimeInterval(30)
        rotation.update(spinning: true, revolutionsPerMinute: 10, at: resumed)
        #expect(rotation.state.currentAngle(at: resumed.addingTimeInterval(1)) == 90)
    }

    /// Every rebuilt mini-player disc reports the same settings on appear;
    /// that must not re-anchor the clock.
    @Test func repeatingTheSameStateDoesNotReanchor() {
        let rotation = ArtworkDiscRotation()
        rotation.update(spinning: true, revolutionsPerMinute: 10, at: t0)
        let anchored = rotation.state
        rotation.update(spinning: true, revolutionsPerMinute: 10, at: t0.addingTimeInterval(5))
        #expect(rotation.state == anchored)
    }

    @Test func zeroSpeedNeverTurns() {
        let rotation = ArtworkDiscRotation()
        rotation.update(spinning: true, revolutionsPerMinute: 0, at: t0)
        #expect(rotation.state.currentAngle(at: t0.addingTimeInterval(10)) == 0)
    }
}
