import AirPodsPostureCore
import Darwin
import Foundation

final class TerminalDashboard {
    private let lock = NSLock()
    private var lastRenderTime = 0.0
    private var lastStatus = "idle"

    func printLiveHeader() {
        print("""
        AirPods Posture Lab
        Hold your head naturally for the first half second so the lab can calibrate.
        Gestures: nod, shake, tilt left, tilt right. Press Control-C to stop.

        """)
    }

    func printSimulationHeader() {
        print("""
        AirPods Posture Lab - simulation
        Replaying synthetic posture gestures with the same recognizer and sounds.

        """)
    }

    func renderStatus(_ status: String) {
        lock.withLock {
            lastStatus = status
            print("\n\(status)")
        }
    }

    func renderCalibrationProgress(current: Int, target: Int) {
        lock.withLock {
            let progress = min(Double(current) / Double(target), 1)
            let filled = Int(progress * 18)
            let bar = String(repeating: "#", count: filled)
                + String(repeating: "-", count: max(0, 18 - filled))
            print("\rcalibrating [\(bar)]", terminator: "")
            fflush(stdout)
        }
    }

    func render(sample: PostureSample, event: GestureEvent?) {
        lock.withLock {
            if let event {
                print(
                    "\n\(event.kind.label.uppercased())  confidence \(percent(event.confidence))  "
                        + "amplitude \(degrees(event.amplitudeDegrees))  \(event.debugSummary)"
                )
            }

            guard sample.timestamp - lastRenderTime >= 0.06 || event != nil else {
                return
            }

            lastRenderTime = sample.timestamp
            let line = "yaw \(degrees(sample.yaw))  pitch \(degrees(sample.pitch))  roll \(degrees(sample.roll))  status \(lastStatus)"
            print("\r\(line.padding(toLength: 96, withPad: " ", startingAt: 0))", terminator: "")
            fflush(stdout)
        }
    }

    private func degrees(_ value: Double) -> String {
        String(format: "%+.1f deg", value)
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}
