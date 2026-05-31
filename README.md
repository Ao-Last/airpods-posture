# AirPods Posture Lab

AirPods Posture Lab is a focused prototype for one question:

> Can AirPods headphone motion become a reliable, pleasant body-input layer?

This repo intentionally does not start with downstream agent integrations. The first milestone is the posture loop itself:

```text
AirPods motion -> neutral calibration -> signal guard -> cleaned motion stream -> posture stream + gesture events -> feedback
```

## Current Postures

The app now treats sustained posture as the primary product surface. Gestures are still useful, but they sit on top of a cleaner posture stream.

- `neutral`: calibrated resting head position.
- `head_down`: sustained downward head angle, useful for "phone neck" / low-head detection.
- `head_up`: sustained upward head angle.
- `turned_left` / `turned_right`: sustained yaw away from center.
- `tilted_left` / `tilted_right`: sustained side tilt, ear toward shoulder.

Default axis assumptions are based on current real-device observations:

- yaw: left / right turning.
- roll: up / down nodding, also the default vertical posture axis.
- pitch: side tilt.

These assumptions are intentionally visible in the UI and should be learned from calibration traces over time rather than treated as universal hardware truth.

## Current Gestures

- `nod`: roll stroke, intended for yes / confirm.
- `shake`: yaw stroke, intended for no / cancel.
- `tilt_left`: held pitch to the left, intended for previous / left.
- `tilt_right`: held pitch to the right, intended for next / right.

The app shows live yaw / pitch / roll, motion sample rate, signal quality, sustained posture, recognized gesture, confidence, amplitude, and recognizer debug notes.

Gesture recognition now uses a more standard motion-recognition shape:

1. Carry all available CoreMotion signals into the cleaned sample: relative attitude, rotation rate, and user acceleration.
2. Segment dynamic head motion with angular velocity, so the recognizer waits for a whole nod / shake instead of firing on the first half of the movement.
3. Classify nod / shake with DTW-style template matching plus physical evidence: amplitude, dominant axis, reversal count, return-to-neutral, angular speed, and acceleration.
4. Let user gesture recordings teach personal templates and thresholds, because AirPods fit and head motion style vary between people.

## UX Principle

The audio cue is part of the input surface, not decoration.

- Armed / calibrated: short rising tones.
- Nod: centered, upward confirmation cue.
- Shake: short left-right descending rejection cue.
- Tilt left: left-panned cue.
- Tilt right: right-panned cue.

That makes the loop feel physical: move head, hear matched confirmation, trust the input.

## Run

For real AirPods motion, use the standard Xcode macOS app target:

1. Open `AirPodsPostureLab.xcodeproj`.
2. Select the `AirPodsPostureLab` scheme.
3. Run it from Xcode.

This lets Xcode handle the app bundle, Info.plist, signing, privacy prompts, and app lifecycle normally. On launch, hold your head naturally for the first half second. The app averages the initial samples into a neutral baseline.

After neutral calibration, use the calibration buttons to record your own nod, shake, left tilt, and right tilt traces. Each recording teaches the recognizer which axis and threshold best match your AirPods fit and head movement.
Nod and shake recordings also become personal motion templates for DTW matching.

The command-line executable is only for recognizer simulation and smoke tests. It does not request real AirPods motion permission.

```bash
swift run airpods-posture-lab --simulate
```

To run without AirPods:

```bash
swift run airpods-posture-lab --simulate
swift run airpods-posture-lab --simulate nod
swift run airpods-posture-lab --simulate shake
swift run airpods-posture-lab --simulate tilt-left
swift run airpods-posture-lab --simulate tilt-right
```

## Test

```bash
swift test
```

The tests cover sustained posture detection, nod, shake, whole-gesture segmentation, held left tilt, small-motion rejection, quaternion baseline conversion, and motion vector axis mapping.

## Implementation Notes

- `AirPodsPostureCore` contains posture detection and gesture recognition, and can be tuned without a live device.
- `AirPodsPostureLab.xcodeproj` contains the standard macOS SwiftUI app that uses `CMHeadphoneMotionManager`.
- The SwiftPM executable is a simulation harness only.
- The signal guard drops obvious timestamp gaps and motion spikes before data reaches posture or gesture recognition. Bluetooth can still be imperfect, but broken segments should not become fake postures or gestures.
- Posture detection is a sustained-state detector. Gesture detection is not derived from posture labels; it uses the same cleaned motion stream and can use posture later as context or gating.
- Direction signs are defaults, not truth. Real AirPods fit, ear shape, and OS attitude conventions can vary enough that posture and gesture mappings should remain calibratable.

## What To Tune Next

1. Record real AirPods traces for neutral work, low-head posture, reading posture, deliberate nod, deliberate shake, and side tilts.
2. Tune posture thresholds using false-positive rate first, then comfort.
3. Add explicit posture calibration for head down / head up in addition to gesture calibration.
4. Add an "armed window" state so downstream gesture events only count while the posture layer is listening.
