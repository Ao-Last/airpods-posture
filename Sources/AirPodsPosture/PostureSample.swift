import Foundation

public struct MotionVector: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = MotionVector(x: 0, y: 0, z: 0)

    public var magnitude: Double {
        sqrt(x * x + y * y + z * z)
    }

    public func value(on axis: PostureAxis) -> Double {
        switch axis {
        case .yaw:
            z
        case .pitch:
            y
        case .roll:
            x
        }
    }

    public func interpolated(toward next: MotionVector, alpha: Double) -> MotionVector {
        MotionVector(
            x: x + (next.x - x) * alpha,
            y: y + (next.y - y) * alpha,
            z: z + (next.z - z) * alpha
        )
    }
}

public struct PostureSample: Equatable, Sendable {
    public var timestamp: TimeInterval
    public var yaw: Double
    public var pitch: Double
    public var roll: Double
    public var rotationRateDegreesPerSecond: MotionVector
    public var userAcceleration: MotionVector

    public init(
        timestamp: TimeInterval,
        yaw: Double,
        pitch: Double,
        roll: Double,
        rotationRateDegreesPerSecond: MotionVector = .zero,
        userAcceleration: MotionVector = .zero
    ) {
        self.timestamp = timestamp
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.rotationRateDegreesPerSecond = rotationRateDegreesPerSecond
        self.userAcceleration = userAcceleration
    }

    public func value(on axis: PostureAxis) -> Double {
        switch axis {
        case .yaw:
            yaw
        case .pitch:
            pitch
        case .roll:
            roll
        }
    }

    public func angularVelocity(on axis: PostureAxis) -> Double {
        rotationRateDegreesPerSecond.value(on: axis)
    }

    public var angularSpeed: Double {
        rotationRateDegreesPerSecond.magnitude
    }

    public var accelerationMagnitude: Double {
        userAcceleration.magnitude
    }
}
