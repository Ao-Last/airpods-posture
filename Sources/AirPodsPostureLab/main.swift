import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    AirPods Posture Lab

    Usage:
      airpods-posture-lab --simulate      Replay all gesture simulations
      airpods-posture-lab --simulate nod
      airpods-posture-lab --simulate shake
      airpods-posture-lab --simulate tilt-left
      airpods-posture-lab --simulate tilt-right

    Real AirPods headphone motion runs through the standard Xcode macOS app target:
      AirPodsPostureLab.xcodeproj -> AirPodsPostureLab
    """)
    exit(0)
}

if let simulateIndex = arguments.firstIndex(of: "--simulate") {
    let gestureName = arguments.dropFirst(simulateIndex + 1).first
    let gesture = gestureName.flatMap(SimulationGesture.init(rawValue:))

    if let gestureName, gesture == nil {
        print("Unknown simulation gesture: \(gestureName)")
        exit(64)
    }

    SimulationRunner().run(gesture: gesture)
    exit(0)
}

print("""
Real AirPods headphone motion now runs only through the standard Xcode macOS app target.

Open:
  AirPodsPostureLab.xcodeproj

Then run the AirPodsPostureLab scheme. For CLI-only recognizer smoke tests, use:
  swift run airpods-posture-lab --simulate
""")
