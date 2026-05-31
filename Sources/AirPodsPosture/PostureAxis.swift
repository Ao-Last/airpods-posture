import Foundation

public enum PostureAxis: String, CaseIterable, Sendable {
    case yaw
    case pitch
    case roll

    public var label: String {
        rawValue
    }
}
