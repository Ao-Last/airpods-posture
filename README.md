# AirPods Posture

[中文说明](README.zh-CN.md)

AirPods Posture turns AirPods headphone motion into a reusable posture and gesture stream.

It is not a downstream productivity app. The repo owns two focused surfaces:

1. `AirPodsPosture`: a Swift package that turns head motion into posture snapshots, gesture events, and signal-quality state.
2. `AirPods Posture Lab`: a macOS SwiftUI debug app for real-device testing, calibration, and interaction tuning.

The long-term idea is simple: downstream apps should consume posture and gesture streams instead of copying raw CoreMotion handling.

```text
AirPods motion
  -> neutral calibration
  -> signal guard
  -> cleaned motion sample
  -> posture stream + gesture events
  -> downstream app or debug feedback
```

## Status

This project is early and experimental, but the core boundary is intentional:

- The library has no dependency on `CoreMotion`.
- The debug app converts `CMDeviceMotion` into library-owned `HeadMotionFrame` values.
- Gesture recognition uses motion segmentation plus DTW-style template matching.
- Posture detection is a sustained-state detector over cleaned motion samples.

Hardware support depends on Apple's `CMHeadphoneMotionManager` and the AirPods model / OS support available on the user's device.

## Package

Add the Swift package:

```swift
.package(url: "https://github.com/Ao-Last/airpods-posture.git", branch: "main")
```

Then depend on the product:

```swift
.product(name: "AirPodsPosture", package: "airpods-posture")
```

Import the module:

```swift
import AirPodsPosture
```

The main public API is `AirPodsPosturePipeline`.

```swift
let pipeline = AirPodsPosturePipeline()

let output = pipeline.observe(
    HeadMotionFrame(
        timestamp: timestamp,
        quaternion: headsetQuaternion,
        rotationRateDegreesPerSecond: rotationRate,
        userAcceleration: acceleration
    )
)

switch output {
case .accepted(let sample, let posture, let gesture, let signalQuality):
    print(sample.yaw, sample.pitch, sample.roll)
    print(posture.kind, posture.confidence)
    print(gesture?.kind as Any)
    print(signalQuality.state)

case .calibrating(let progress, _):
    print("calibrating", progress)

case .calibrated:
    print("ready")

case .reset(_, let signalQuality), .dropped(_, let signalQuality):
    print(signalQuality.debugSummary)
}
```

Core types:

- `HeadMotionFrame`: timestamp, headset quaternion, rotation rate, and user acceleration.
- `AirPodsPosturePipeline`: neutral calibration, signal guarding, posture detection, and gesture recognition.
- `PostureSample`: cleaned yaw / pitch / roll plus angular velocity and acceleration.
- `PostureSnapshot`: sustained posture stream.
- `GestureEvent`: discrete gesture event stream.
- `MotionSignalQuality`: stable / recovering / gap / spike state for Bluetooth resilience and diagnostics.

## Postures

Current postures:

- `neutral`: calibrated resting head position.
- `head_down`: sustained downward head angle, useful for low-head or "phone neck" detection.
- `head_up`: sustained upward head angle.
- `turned_left` / `turned_right`: sustained yaw away from center.
- `tilted_left` / `tilted_right`: sustained side tilt, ear toward shoulder.

Default axis assumptions are based on current real-device observations:

- yaw: left / right turning. Positive yaw maps to left turn, negative yaw maps to right turn.
- roll: up / down nodding, also the default vertical posture axis.
- pitch: side tilt.

These signs are defaults, not universal truth. AirPods fit, ear shape, and OS attitude conventions can vary, so downstream apps should keep calibration and user testing in the loop.

## Gestures

Current gestures:

- `nod`: roll stroke, intended for yes / confirm.
- `shake`: yaw stroke, intended for no / cancel.
- `tilt_left`: held pitch to the left, intended for previous / left.
- `tilt_right`: held pitch to the right, intended for next / right.

Dynamic gestures use:

1. relative attitude, rotation rate, and user acceleration;
2. angular-velocity motion segmentation, so the recognizer waits for a whole nod or shake;
3. DTW-style template matching;
4. physical evidence such as amplitude, dominant axis, reversal count, return-to-neutral, angular speed, and acceleration;
5. optional personal templates learned from the Lab recording UI.

Gestures are not derived from posture labels. Posture and gesture recognition both consume the same cleaned motion stream. Posture can later be used as context or gating for downstream interaction.

## Debug App

`AirPods Posture Lab` is the first-party debugging UI.

It shows:

- live yaw / pitch / roll;
- sample rate and signal quality;
- current posture, confidence, offset, and held duration;
- latest gesture, confidence, amplitude, and debug notes;
- calibration controls for nod, shake, left tilt, and right tilt.

It also plays matched audio feedback so movement has an immediate confirmation loop. Directional postures use hard equal-power stereo panning in the Lab: left turn / tilt cues play almost entirely in the left channel, right turn / tilt cues play almost entirely in the right channel, and cue strength follows posture offset, angular speed, and acceleration. These cues fire from motion onset before the sustained posture state commits, because the audio cue is part of the input surface, not decoration.

Run the real AirPods debug app through Xcode:

1. Open `AirPodsPostureLab.xcodeproj`.
2. Select the `AirPodsPostureLab` scheme.
3. Run it from Xcode.

Using Xcode lets the normal macOS app bundle, Info.plist, signing, privacy prompt, and lifecycle paths handle `CMHeadphoneMotionManager` correctly.

## CLI Simulation

The SwiftPM executable is only a recognizer simulation and smoke-test harness. It does not request real AirPods motion permission.

```bash
swift run airpods-posture-lab --simulate
swift run airpods-posture-lab --simulate nod
swift run airpods-posture-lab --simulate shake
swift run airpods-posture-lab --simulate tilt-left
swift run airpods-posture-lab --simulate tilt-right
```

## Tests

```bash
swift test
```

The tests cover:

- public pipeline calibration and stream output;
- signal-gap reset behavior;
- sustained posture detection;
- nod, shake, and held tilt recognition;
- whole-gesture segmentation;
- small-motion rejection;
- quaternion baseline conversion;
- motion-vector axis mapping.

## Project Layout

```text
Sources/AirPodsPosture/        Reusable Swift package
AirPodsPostureLab/             macOS SwiftUI debug app
Sources/AirPodsPostureLab/     CLI simulation harness
Tests/AirPodsPostureTests/     Package tests
```

## Roadmap

- Record real AirPods traces for neutral work, low-head posture, reading posture, deliberate nod, deliberate shake, and side tilts.
- Add explicit posture calibration for head down / head up and left / right turn.
- Add trace export so threshold and template changes can be evaluated offline.
- Tune false-positive rate before adding more downstream interactions.
- Add an armed/listening state for apps that only want gestures inside an interaction window.

## License

MIT
