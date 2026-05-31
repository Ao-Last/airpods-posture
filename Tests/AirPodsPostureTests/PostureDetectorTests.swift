import XCTest
@testable import AirPodsPosture

final class PostureDetectorTests: XCTestCase {
    func testDetectsSustainedHeadDown() {
        let detector = PostureDetector()
        let snapshots = samples(
            start: 0,
            step: 0.1,
            values: Array(repeating: (yaw: 0.0, pitch: 0.0, roll: -19.0), count: 8)
        ).map { detector.observe($0) }

        XCTAssertEqual(snapshots.last?.kind, .headDown)
        XCTAssertGreaterThan(snapshots.last?.heldDuration ?? 0, 0.5)
        XCTAssertGreaterThan(snapshots.last?.confidence ?? 0, 0.7)
    }

    func testIgnoresBriefHeadDownGlance() {
        let detector = PostureDetector()
        let values = [
            (yaw: 0.0, pitch: 0.0, roll: 0.0),
            (yaw: 0.0, pitch: 0.0, roll: -20.0),
            (yaw: 0.0, pitch: 0.0, roll: -21.0),
            (yaw: 0.0, pitch: 0.0, roll: -4.0),
            (yaw: 0.0, pitch: 0.0, roll: 0.0)
        ]
        let snapshots = samples(start: 0, step: 0.1, values: values).map { detector.observe($0) }

        XCTAssertEqual(snapshots.last?.kind, .neutral)
    }

    func testDetectsSustainedSideTilt() {
        let detector = PostureDetector()
        let snapshots = samples(
            start: 0,
            step: 0.1,
            values: Array(repeating: (yaw: 0.0, pitch: -18.0, roll: 0.0), count: 8)
        ).map { detector.observe($0) }

        XCTAssertEqual(snapshots.last?.kind, .tiltedLeft)
    }

    func testDetectsSustainedRightTurnFromNegativeYaw() {
        let detector = PostureDetector()
        let snapshots = samples(
            start: 0,
            step: 0.1,
            values: Array(repeating: (yaw: -23.0, pitch: 0.0, roll: 0.0), count: 8)
        ).map { detector.observe($0) }

        XCTAssertEqual(snapshots.last?.kind, .turnedRight)
    }

    func testDetectsSustainedLeftTurnFromPositiveYaw() {
        let detector = PostureDetector()
        let snapshots = samples(
            start: 0,
            step: 0.1,
            values: Array(repeating: (yaw: 23.0, pitch: 0.0, roll: 0.0), count: 8)
        ).map { detector.observe($0) }

        XCTAssertEqual(snapshots.last?.kind, .turnedLeft)
    }

    private func samples(
        start: TimeInterval,
        step: TimeInterval,
        values: [(yaw: Double, pitch: Double, roll: Double)]
    ) -> [PostureSample] {
        values.enumerated().map { index, value in
            PostureSample(
                timestamp: start + Double(index) * step,
                yaw: value.yaw,
                pitch: value.pitch,
                roll: value.roll
            )
        }
    }
}
