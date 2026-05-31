import Foundation

public enum PostureKind: String, CaseIterable, Sendable {
    case neutral
    case headDown
    case headUp
    case turnedLeft
    case turnedRight
    case tiltedLeft
    case tiltedRight

    public var label: String {
        switch self {
        case .neutral:
            "neutral"
        case .headDown:
            "head down"
        case .headUp:
            "head up"
        case .turnedLeft:
            "turned left"
        case .turnedRight:
            "turned right"
        case .tiltedLeft:
            "tilted left"
        case .tiltedRight:
            "tilted right"
        }
    }

    public var groupLabel: String {
        switch self {
        case .neutral:
            "neutral"
        case .headDown, .headUp:
            "vertical"
        case .turnedLeft, .turnedRight:
            "turn"
        case .tiltedLeft, .tiltedRight:
            "tilt"
        }
    }
}

