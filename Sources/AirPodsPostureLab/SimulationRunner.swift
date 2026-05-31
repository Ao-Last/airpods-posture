import AirPodsPostureCore
import Foundation

enum SimulationGesture: String, CaseIterable {
    case nod
    case shake
    case tiltLeft = "tilt-left"
    case tiltRight = "tilt-right"
}

final class SimulationRunner {
    private let recognizer = PostureGestureRecognizer()
    private let dashboard = TerminalDashboard()
    private let sounds = SoundFeedback()

    func run(gesture: SimulationGesture?) {
        dashboard.printSimulationHeader()
        sounds.play(.armed)

        let gestures = gesture.map { [$0] } ?? SimulationGesture.allCases

        for gesture in gestures {
            recognizer.reset()
            dashboard.renderStatus("simulating \(gesture.rawValue)")
            sounds.play(.calibrated)

            for sample in samples(for: gesture) {
                let event = recognizer.observe(sample)
                dashboard.render(sample: sample, event: event)

                if let event {
                    sounds.play(.gesture(event.kind))
                }

                Thread.sleep(forTimeInterval: 0.02)
            }

            Thread.sleep(forTimeInterval: 0.45)
            print("")
        }

        sounds.stop()
    }

    private func samples(for gesture: SimulationGesture) -> [PostureSample] {
        let step = 0.04
        let values: [(yaw: Double, pitch: Double, roll: Double)]

        switch gesture {
        case .nod:
            values = [
                (0, 0, 0), (0.2, 0.1, -2), (0.4, 0.3, -6), (0.3, 0.3, -13),
                (0.1, 0.2, -5), (0.0, 0.1, 7), (0.1, 0.0, 12), (0.1, 0.0, 3),
                (0, 0, 0)
            ]
        case .shake:
            values = [
                (0, 0, 0), (-4, 0.1, 0), (-12, 0.3, 0.2), (-17, 0.1, 0.1),
                (-5, 0.1, 0.2), (9, 0.2, 0.2), (17, 0.1, 0.1), (5, 0, 0),
                (0, 0, 0)
            ]
        case .tiltLeft:
            values = [
                (0, 0, 0), (0, -4, 0), (0, -10, 0), (0, -18, 0),
                (0, -20, 0), (0, -21, 0), (0, -20, 0), (0, -21, 0),
                (0, -20, 0), (0, -19, 0), (0, -18, 0), (0, -5, 0),
                (0, 0, 0)
            ]
        case .tiltRight:
            values = [
                (0, 0, 0), (0, 4, 0), (0, 10, 0), (0, 18, 0),
                (0, 20, 0), (0, 21, 0), (0, 20, 0), (0, 21, 0),
                (0, 20, 0), (0, 19, 0), (0, 18, 0), (0, 5, 0),
                (0, 0, 0)
            ]
        }

        return values.enumerated().map { index, value in
            PostureSample(
                timestamp: Double(index) * step,
                yaw: value.yaw,
                pitch: value.pitch,
                roll: value.roll
            )
        }
    }
}
