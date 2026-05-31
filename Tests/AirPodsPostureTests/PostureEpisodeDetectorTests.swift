import XCTest
@testable import AirPodsPosture

final class PostureEpisodeDetectorTests: XCTestCase {
    func testEmitsEnteredSustainedAndRecoveredEvents() {
        let detector = PostureEpisodeDetector(
            configuration: PostureEpisodeDetectorConfiguration(
                minimumSustainedDuration: 2,
                recoveryDuration: 1,
                minimumConfidence: 0.7
            )
        )

        XCTAssertEqual(detector.observe(neutral(timestamp: 0)), [])

        let entered = detector.observe(headDown(timestamp: 1, heldDuration: 0))
        XCTAssertEqual(entered.map(\.phase), [.entered])
        XCTAssertEqual(entered.first?.posture, .headDown)

        XCTAssertEqual(detector.observe(headDown(timestamp: 2, heldDuration: 1)), [])

        let sustained = detector.observe(headDown(timestamp: 3.1, heldDuration: 2.1))
        XCTAssertEqual(sustained.map(\.phase), [.sustained])
        XCTAssertEqual(sustained.first?.duration ?? 0, 2.1, accuracy: 0.001)

        XCTAssertEqual(detector.observe(headDown(timestamp: 4, heldDuration: 3)), [])
        XCTAssertEqual(detector.observe(neutral(timestamp: 4.2)), [])

        let recovered = detector.observe(neutral(timestamp: 5.3))
        XCTAssertEqual(recovered.map(\.phase), [.recovered])
        XCTAssertEqual(recovered.first?.endedAt ?? 0, 4.2, accuracy: 0.001)
        XCTAssertEqual(recovered.first?.duration ?? 0, 3.2, accuracy: 0.001)
    }

    func testSwitchingPostureExitsPreviousAndEntersNext() {
        let detector = PostureEpisodeDetector(
            configuration: PostureEpisodeDetectorConfiguration(
                minimumSustainedDuration: 2,
                recoveryDuration: 1,
                minimumConfidence: 0.7
            )
        )

        _ = detector.observe(headDown(timestamp: 1, heldDuration: 0))
        let events = detector.observe(
            snapshot(
                kind: .turnedLeft,
                timestamp: 1.5,
                confidence: 0.86,
                offsetDegrees: 24,
                heldDuration: 0
            )
        )

        XCTAssertEqual(events.map(\.phase), [.exited, .entered])
        XCTAssertEqual(events.map(\.posture), [.headDown, .turnedLeft])
        XCTAssertEqual(events.first?.endedAt ?? 0, 1.5, accuracy: 0.001)
    }

    func testMinimumConfidenceGatesEpisodeStart() {
        let detector = PostureEpisodeDetector(
            configuration: PostureEpisodeDetectorConfiguration(
                minimumSustainedDuration: 1,
                recoveryDuration: 1,
                minimumConfidence: 0.8
            )
        )

        let weak = detector.observe(headDown(timestamp: 1, confidence: 0.72, heldDuration: 0))
        XCTAssertEqual(weak, [])

        let strong = detector.observe(headDown(timestamp: 2, confidence: 0.85, heldDuration: 0))
        XCTAssertEqual(strong.map(\.phase), [.entered])
    }

    private func headDown(
        timestamp: TimeInterval,
        confidence: Double = 0.84,
        heldDuration: TimeInterval
    ) -> PostureSnapshot {
        snapshot(
            kind: .headDown,
            timestamp: timestamp,
            confidence: confidence,
            offsetDegrees: 22,
            heldDuration: heldDuration
        )
    }

    private func neutral(timestamp: TimeInterval) -> PostureSnapshot {
        snapshot(
            kind: .neutral,
            timestamp: timestamp,
            confidence: 0.94,
            offsetDegrees: 2,
            heldDuration: 0
        )
    }

    private func snapshot(
        kind: PostureKind,
        timestamp: TimeInterval,
        confidence: Double,
        offsetDegrees: Double,
        heldDuration: TimeInterval
    ) -> PostureSnapshot {
        PostureSnapshot(
            kind: kind,
            confidence: confidence,
            offsetDegrees: offsetDegrees,
            heldDuration: heldDuration,
            timestamp: timestamp,
            debugSummary: "\(kind.label) test snapshot"
        )
    }
}
