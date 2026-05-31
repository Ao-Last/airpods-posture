import Foundation

public struct HeadsetQuaternion: Equatable, Sendable {
    public var w: Double
    public var x: Double
    public var y: Double
    public var z: Double

    public init(w: Double, x: Double, y: Double, z: Double) {
        self.w = w
        self.x = x
        self.y = y
        self.z = z
    }

    public var normalized: HeadsetQuaternion {
        let length = sqrt(w * w + x * x + y * y + z * z)
        guard length > 0 else {
            return HeadsetQuaternion(w: 1, x: 0, y: 0, z: 0)
        }

        return HeadsetQuaternion(
            w: w / length,
            x: x / length,
            y: y / length,
            z: z / length
        )
    }

    public var inverse: HeadsetQuaternion {
        let squaredLength = w * w + x * x + y * y + z * z
        guard squaredLength > 0 else {
            return HeadsetQuaternion(w: 1, x: 0, y: 0, z: 0)
        }

        return HeadsetQuaternion(
            w: w / squaredLength,
            x: -x / squaredLength,
            y: -y / squaredLength,
            z: -z / squaredLength
        )
    }

    public static func * (lhs: HeadsetQuaternion, rhs: HeadsetQuaternion) -> HeadsetQuaternion {
        HeadsetQuaternion(
            w: lhs.w * rhs.w - lhs.x * rhs.x - lhs.y * rhs.y - lhs.z * rhs.z,
            x: lhs.w * rhs.x + lhs.x * rhs.w + lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.w * rhs.y - lhs.x * rhs.z + lhs.y * rhs.w + lhs.z * rhs.x,
            z: lhs.w * rhs.z + lhs.x * rhs.y - lhs.y * rhs.x + lhs.z * rhs.w
        )
    }

    public func relative(to baseline: HeadsetQuaternion) -> HeadsetQuaternion {
        (baseline.inverse * self).normalized
    }

    public static func average(_ quaternions: [HeadsetQuaternion]) -> HeadsetQuaternion? {
        guard let first = quaternions.first?.normalized else {
            return nil
        }

        var sum = HeadsetQuaternion(w: 0, x: 0, y: 0, z: 0)
        for quaternion in quaternions {
            let normalized = quaternion.normalized
            let dot = first.w * normalized.w
                + first.x * normalized.x
                + first.y * normalized.y
                + first.z * normalized.z
            let multiplier = dot < 0 ? -1.0 : 1.0

            sum.w += normalized.w * multiplier
            sum.x += normalized.x * multiplier
            sum.y += normalized.y * multiplier
            sum.z += normalized.z * multiplier
        }

        return sum.normalized
    }

    public static func fromEulerDegrees(yaw: Double, pitch: Double, roll: Double) -> HeadsetQuaternion {
        let yaw = yaw * .pi / 180
        let pitch = pitch * .pi / 180
        let roll = roll * .pi / 180

        let cy = cos(yaw * 0.5)
        let sy = sin(yaw * 0.5)
        let cp = cos(pitch * 0.5)
        let sp = sin(pitch * 0.5)
        let cr = cos(roll * 0.5)
        let sr = sin(roll * 0.5)

        return HeadsetQuaternion(
            w: cr * cp * cy + sr * sp * sy,
            x: sr * cp * cy - cr * sp * sy,
            y: cr * sp * cy + sr * cp * sy,
            z: cr * cp * sy - sr * sp * cy
        ).normalized
    }

    public func eulerDegrees() -> (yaw: Double, pitch: Double, roll: Double) {
        let q = normalized

        let sinRollCosPitch = 2 * (q.w * q.x + q.y * q.z)
        let cosRollCosPitch = 1 - 2 * (q.x * q.x + q.y * q.y)
        let roll = atan2(sinRollCosPitch, cosRollCosPitch)

        let sinPitch = 2 * (q.w * q.y - q.z * q.x)
        let pitch: Double
        if abs(sinPitch) >= 1 {
            pitch = sinPitch.sign == .minus ? -.pi / 2 : .pi / 2
        } else {
            pitch = asin(sinPitch)
        }

        let sinYawCosPitch = 2 * (q.w * q.z + q.x * q.y)
        let cosYawCosPitch = 1 - 2 * (q.y * q.y + q.z * q.z)
        let yaw = atan2(sinYawCosPitch, cosYawCosPitch)

        return (
            yaw: yaw * 180 / .pi,
            pitch: pitch * 180 / .pi,
            roll: roll * 180 / .pi
        )
    }
}
