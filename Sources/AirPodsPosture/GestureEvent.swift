import Foundation

public enum GestureKind: String, CaseIterable, Sendable {
    case nod
    case shake
    case tiltLeft = "tilt_left"
    case tiltRight = "tilt_right"

    public var label: String {
        switch self {
        case .nod:
            "nod"
        case .shake:
            "shake"
        case .tiltLeft:
            "tilt left"
        case .tiltRight:
            "tilt right"
        }
    }
}

public struct GestureEvent: Equatable, Sendable {
    public var kind: GestureKind
    public var confidence: Double
    public var amplitudeDegrees: Double
    public var duration: TimeInterval
    public var timestamp: TimeInterval
    public var debugSummary: String

    public init(
        kind: GestureKind,
        confidence: Double,
        amplitudeDegrees: Double,
        duration: TimeInterval,
        timestamp: TimeInterval,
        debugSummary: String
    ) {
        self.kind = kind
        self.confidence = confidence
        self.amplitudeDegrees = amplitudeDegrees
        self.duration = duration
        self.timestamp = timestamp
        self.debugSummary = debugSummary
    }
}
