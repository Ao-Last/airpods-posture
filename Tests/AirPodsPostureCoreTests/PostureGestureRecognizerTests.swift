import XCTest
@testable import AirPodsPostureCore

final class PostureGestureRecognizerTests: XCTestCase {
    func testDetectsNodFromRollStroke() {
        let recognizer = PostureGestureRecognizer()
        let event = firstEvent(
            recognizer: recognizer,
            values: [
                (yaw: 0, pitch: 0, roll: 0),
                (yaw: 0.2, pitch: 0.1, roll: -2),
                (yaw: 0.3, pitch: 0.2, roll: -8),
                (yaw: 0.1, pitch: 0.2, roll: -14),
                (yaw: 0.0, pitch: 0.1, roll: -5),
                (yaw: 0.1, pitch: 0.0, roll: 7),
                (yaw: 0.1, pitch: 0.0, roll: 12),
                (yaw: 0.0, pitch: 0.0, roll: 3),
                (yaw: 0.0, pitch: 0, roll: 0.0)
            ]
        )

        XCTAssertEqual(event?.kind, .nod)
        XCTAssertGreaterThan(event?.confidence ?? 0, 0.70)
    }

    func testWaitsForBiphasicNodBeforeEmitting() {
        let recognizer = PostureGestureRecognizer()
        let firstHalf = [
            (yaw: 0.0, pitch: 0.0, roll: 0.0),
            (yaw: 0.2, pitch: 0.1, roll: -2.0),
            (yaw: 0.3, pitch: 0.2, roll: -8.0),
            (yaw: 0.1, pitch: 0.2, roll: -14.0),
            (yaw: 0.0, pitch: 0.1, roll: -5.0)
        ]

        XCTAssertNil(firstEvent(recognizer: recognizer, values: firstHalf))

        let event = firstEvent(
            recognizer: recognizer,
            startIndex: firstHalf.count,
            values: [
                (yaw: 0.1, pitch: 0.0, roll: 7),
                (yaw: 0.1, pitch: 0.0, roll: 12),
                (yaw: 0.0, pitch: 0.0, roll: 3),
                (yaw: 0.0, pitch: 0, roll: 0.0)
            ]
        )

        XCTAssertEqual(event?.kind, .nod)
    }

    func testDetectsShakeFromYawStroke() {
        let recognizer = PostureGestureRecognizer()
        let event = firstEvent(
            recognizer: recognizer,
            values: [
                (yaw: 0, pitch: 0, roll: 0),
                (yaw: -5, pitch: 0.1, roll: 0),
                (yaw: -13, pitch: 0.2, roll: 0.2),
                (yaw: -18, pitch: 0.1, roll: 0.1),
                (yaw: -4, pitch: 0.1, roll: 0.2),
                (yaw: 10, pitch: 0.2, roll: 0.2),
                (yaw: 18, pitch: 0.1, roll: 0.1),
                (yaw: 4, pitch: 0, roll: 0),
                (yaw: 0, pitch: 0, roll: 0)
            ]
        )

        XCTAssertEqual(event?.kind, .shake)
        XCTAssertGreaterThan(event?.confidence ?? 0, 0.75)
    }

    func testDetectsLeftTiltAfterHold() {
        let recognizer = PostureGestureRecognizer()
        let event = firstEvent(
            recognizer: recognizer,
            step: 0.05,
            values: [
                (yaw: 0, pitch: 0, roll: 0),
                (yaw: 0, pitch: -8, roll: 0),
                (yaw: 0, pitch: -17, roll: 0),
                (yaw: 0, pitch: -20, roll: 0),
                (yaw: 0, pitch: -21, roll: 0),
                (yaw: 0, pitch: -21, roll: 0),
                (yaw: 0, pitch: -20, roll: 0),
                (yaw: 0, pitch: -20, roll: 0),
                (yaw: 0, pitch: -18, roll: 0),
                (yaw: 0, pitch: -4, roll: 0)
            ]
        )

        XCTAssertEqual(event?.kind, .tiltLeft)
        XCTAssertGreaterThan(event?.confidence ?? 0, 0.65)
    }

    func testIgnoresSmallThinkingMotion() {
        let recognizer = PostureGestureRecognizer()
        let event = firstEvent(
            recognizer: recognizer,
            values: [
                (yaw: 0, pitch: 0, roll: 0),
                (yaw: 1, pitch: 0.5, roll: 0.2),
                (yaw: -1, pitch: -0.2, roll: 0.3),
                (yaw: 2, pitch: 1.0, roll: -0.2),
                (yaw: 1, pitch: 0.2, roll: 0.1),
                (yaw: 0, pitch: 0, roll: 0)
            ]
        )

        XCTAssertNil(event)
    }

    func testQuaternionBaselineProducesRelativeEulerAngles() {
        let baseline = HeadsetQuaternion.fromEulerDegrees(yaw: 10, pitch: 2, roll: -4)
        let moved = baseline * HeadsetQuaternion.fromEulerDegrees(yaw: 0, pitch: 15, roll: 0)
        let relative = moved.relative(to: baseline).eulerDegrees()

        XCTAssertEqual(relative.pitch, 15, accuracy: 0.01)
    }

    func testMotionVectorMapsRotationRateToPostureAxes() {
        let sample = PostureSample(
            timestamp: 0,
            yaw: 0,
            pitch: 0,
            roll: 0,
            rotationRateDegreesPerSecond: MotionVector(x: 10, y: 20, z: 30),
            userAcceleration: MotionVector(x: 0.1, y: 0.2, z: 0.2)
        )

        XCTAssertEqual(sample.angularVelocity(on: .roll), 10)
        XCTAssertEqual(sample.angularVelocity(on: .pitch), 20)
        XCTAssertEqual(sample.angularVelocity(on: .yaw), 30)
        XCTAssertEqual(sample.accelerationMagnitude, 0.3, accuracy: 0.001)
    }

    private func firstEvent(
        recognizer: PostureGestureRecognizer,
        step: TimeInterval = 0.04,
        startIndex: Int = 0,
        values: [(yaw: Double, pitch: Double, roll: Double)]
    ) -> GestureEvent? {
        for (index, value) in values.enumerated() {
            let event = recognizer.observe(
                PostureSample(
                    timestamp: Double(startIndex + index) * step,
                    yaw: value.yaw,
                    pitch: value.pitch,
                    roll: value.roll
                )
            )

            if let event {
                return event
            }
        }

        return nil
    }
}
