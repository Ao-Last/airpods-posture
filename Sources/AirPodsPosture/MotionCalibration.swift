import Foundation

public final class MotionCalibration: @unchecked Sendable {
    private let lock = NSLock()
    private var baseline: HeadsetQuaternion?

    public init() {}

    public var isCalibrated: Bool {
        lock.withLock {
            baseline != nil
        }
    }

    public func calibrate(with quaternion: HeadsetQuaternion) {
        lock.withLock {
            baseline = quaternion.normalized
        }
    }

    public func reset() {
        lock.withLock {
            baseline = nil
        }
    }

    public func sample(
        from quaternion: HeadsetQuaternion,
        timestamp: TimeInterval,
        rotationRateDegreesPerSecond: MotionVector = .zero,
        userAcceleration: MotionVector = .zero
    ) -> PostureSample? {
        lock.withLock {
            guard let baseline else {
                return nil
            }

            let relative = quaternion.normalized.relative(to: baseline)
            let euler = relative.eulerDegrees()

            return PostureSample(
                timestamp: timestamp,
                yaw: euler.yaw,
                pitch: euler.pitch,
                roll: euler.roll,
                rotationRateDegreesPerSecond: rotationRateDegreesPerSecond,
                userAcceleration: userAcceleration
            )
        }
    }
}
