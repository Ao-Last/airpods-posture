import XCTest
@testable import AirPodsPosture

final class PosturePipelineTests: XCTestCase {
    func testPipelineCalibratesAndEmitsSustainedPosture() {
        let pipeline = AirPodsPosturePipeline(
            configuration: AirPodsPosturePipelineConfiguration(requiredCalibrationSamples: 2)
        )
        let baseline = HeadsetQuaternion.fromEulerDegrees(yaw: 0, pitch: 0, roll: 0)

        guard case .calibrating(let progress, _) = pipeline.observe(frame(timestamp: 0, quaternion: baseline)) else {
            return XCTFail("expected calibration progress")
        }
        XCTAssertEqual(progress, 0.5, accuracy: 0.001)

        guard case .calibrated = pipeline.observe(frame(timestamp: 0.04, quaternion: baseline)) else {
            return XCTFail("expected calibration completion")
        }

        var latestPosture: PostureSnapshot?
        for index in 0..<18 {
            let timestamp = 0.08 + Double(index) * 0.04
            let moved = baseline * HeadsetQuaternion.fromEulerDegrees(yaw: 0, pitch: 0, roll: -20)
            if case .accepted(let sample, let posture, _, let quality) = pipeline.observe(
                frame(timestamp: timestamp, quaternion: moved)
            ) {
                XCTAssertEqual(sample.roll, -20, accuracy: 0.1)
                XCTAssertEqual(quality.state, .stable)
                latestPosture = posture
            }
        }

        XCTAssertEqual(latestPosture?.kind, .headDown)
        XCTAssertGreaterThan(latestPosture?.confidence ?? 0, 0.7)
    }

    func testPipelineResetsRecognitionOnSignalGap() {
        let pipeline = AirPodsPosturePipeline(
            configuration: AirPodsPosturePipelineConfiguration(requiredCalibrationSamples: 1)
        )
        let baseline = HeadsetQuaternion.fromEulerDegrees(yaw: 0, pitch: 0, roll: 0)

        _ = pipeline.observe(frame(timestamp: 0, quaternion: baseline))
        _ = pipeline.observe(frame(timestamp: 0.04, quaternion: baseline))

        let gapOutput = pipeline.observe(frame(timestamp: 0.35, quaternion: baseline))
        guard case .reset(_, let quality) = gapOutput else {
            return XCTFail("expected signal gap reset")
        }

        XCTAssertEqual(quality.state, .gap)
    }

    func testPipelineLearnsGestureConfiguration() {
        let pipeline = AirPodsPosturePipeline()
        let samples = [
            PostureSample(timestamp: 0.00, yaw: 0, pitch: 0, roll: 0),
            PostureSample(timestamp: 0.04, yaw: 0, pitch: 0, roll: -4),
            PostureSample(timestamp: 0.08, yaw: 0, pitch: 0, roll: -12),
            PostureSample(timestamp: 0.12, yaw: 0, pitch: 0, roll: -18),
            PostureSample(timestamp: 0.16, yaw: 0, pitch: 0, roll: -6),
            PostureSample(timestamp: 0.20, yaw: 0, pitch: 0, roll: 8),
            PostureSample(timestamp: 0.24, yaw: 0, pitch: 0, roll: 18),
            PostureSample(timestamp: 0.28, yaw: 0, pitch: 0, roll: 4),
            PostureSample(timestamp: 0.32, yaw: 0, pitch: 0, roll: 0)
        ]

        let result = pipeline.learnGesture(kind: .nod, samples: samples)

        XCTAssertEqual(result?.configuration.nodAxis, .roll)
        XCTAssertEqual(pipeline.recognizerConfiguration.nodAxis, .roll)
        XCTAssertEqual(result?.summary.contains("nod -> roll"), true)
    }

    private func frame(timestamp: TimeInterval, quaternion: HeadsetQuaternion) -> HeadMotionFrame {
        HeadMotionFrame(
            timestamp: timestamp,
            quaternion: quaternion,
            rotationRateDegreesPerSecond: .zero,
            userAcceleration: .zero
        )
    }
}
