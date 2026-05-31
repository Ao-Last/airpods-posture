# Directional Impact Events

This note sketches a core event stream for fast, physical, collision-like head motion feedback.

The motivating interaction is not "play a posture sound". It is closer to a small ball moving inside a four-sided box. The user's head is the ball. Left, right, up, and down are soft virtual walls. When motion reaches a wall with enough intent, the system emits an impact event. The Lab can sonify that event as a short collision, but the event itself should be useful to any downstream app.

## Why This Is Separate

`PostureSnapshot`, `GestureEvent`, and directional impacts should remain distinct streams:

- `PostureSnapshot`: sustained state. It should be stable and intentionally delayed by hold thresholds.
- `GestureEvent`: symbolic motion recognition. It can wait for enough evidence to classify a nod, shake, or learned gesture.
- `DirectionalImpactEvent`: low-latency boundary contact. It should fire early when the user clearly pushes toward a direction.

This separation matters because audio feedback must feel immediate, while posture detection must feel trustworthy.

## Related Work

Head gesture recognition work commonly combines activity detection with a recognition layer such as DTW or a classifier. Li and Hu's 2024 head-gesture paper uses IMU data, activity detection, and DTW to identify complete head movements, and explicitly treats endpoint detection parameters such as angular velocity threshold, minimum movement duration, and filtering window length as important recognition controls: <https://www.mdpi.com/2313-433X/10/5/123>.

Other IMU gesture work uses accelerometer and gyroscope features such as min/max amplitude, standard deviation, correlation, and signal energy over causal windows: <https://www.mdpi.com/2076-3417/10/12/4213>. Real-time nod/shake work also shows that Euler angle sequences can be recognized on device, but it is still gesture recognition rather than immediate contact feedback: <https://arxiv.org/abs/1806.04776>.

The impact stream should borrow the activity/onset and energy ideas, but it should not wait for a whole gesture template. It is a lower-level physical event.

## Core Problem

Physical walls have fixed positions. Head movement does not.

Different users have different comfortable ranges. Even the same user will produce different amplitudes depending on context, fatigue, AirPods fit, and intent. A fixed "left wall at 18 degrees" is too brittle:

- small intentional movements may never hit the wall;
- large casual movements may hit too often;
- fast movements may deserve earlier feedback than slow posture drift;
- Bluetooth jitter and fit changes can cause false contacts.

So the wall must be adaptive. It should behave like a soft boundary learned from recent neutral-relative motion, not like a fixed angle.

## Proposed Event Shape

```swift
public enum DirectionalImpactDirection: String, CaseIterable, Sendable {
    case left
    case right
    case up
    case down
}

public struct DirectionalImpactEvent: Equatable, Sendable {
    public var direction: DirectionalImpactDirection
    public var timestamp: TimeInterval
    public var axis: PostureAxis
    public var offsetDegrees: Double
    public var velocityDegreesPerSecond: Double
    public var accelerationMagnitude: Double
    public var intensity: Double
    public var boundaryDegrees: Double
    public var phase: DirectionalImpactPhase
}

public enum DirectionalImpactPhase: String, Sendable {
    case contact
    case repeatContact
}
```

Initial pipeline output shape:

```swift
case accepted(
    sample: PostureSample,
    posture: PostureSnapshot,
    gesture: GestureEvent?,
    impact: DirectionalImpactEvent?,
    signalQuality: MotionSignalQuality
)
```

This is a breaking API change, so we may instead introduce a new output case or add a secondary observer API if we want compatibility.

## Detection Model

The detector should maintain one state machine per direction.

For each accepted `PostureSample`, compute directional candidates:

- left/right from signed yaw;
- up/down from signed roll initially, matching current vertical posture assumptions;
- possibly side tilt from pitch later, or expose six directions if we want turn and tilt to be separate.

Each candidate has:

- `offset`: absolute neutral-relative angle for that direction;
- `velocity`: signed angular velocity on the relevant axis;
- `acceleration`: user acceleration magnitude;
- `energy`: short causal window energy from angle delta, angular velocity, and acceleration;
- `adaptiveBoundary`: a slowly learned boundary for that direction.

An impact fires when most of these are true:

- the offset crosses a soft boundary or a lower onset boundary with high velocity;
- velocity points toward the wall;
- short-window energy is above a motion floor;
- the direction is armed, meaning it has released enough since the last contact;
- signal quality is stable or recovering, not gap/spike.

## Adaptive Boundaries

Each direction should maintain a boundary estimate:

```text
boundary = clamp(
  percentile(recentPeakOffsets, 70%) * boundaryScale,
  minBoundary,
  maxBoundary
)
```

Suggested starting values:

- yaw left/right min boundary: 8 deg;
- yaw left/right max boundary: 28 deg;
- vertical min boundary: 10 deg;
- vertical max boundary: 30 deg;
- boundary scale: 0.65 to 0.8;
- update peaks only after a completed movement or release, not continuously during contact.

This makes the wall track the user's actual movement range without making every tiny twitch a wall hit.

## State Machine

Each direction has:

- `armed`: ready to fire;
- `contact`: fired and waiting for release;
- `cooldown`: short refractory period to prevent flutter;
- `lastImpactTimestamp`;
- `lastPeakOffset`;
- `recentPeakOffsets`.

Transitions:

```text
armed
  -> contact
     when offset/velocity/energy indicate boundary contact

contact
  -> cooldown
     when velocity reverses, offset stops growing, or opposite direction becomes dominant

cooldown
  -> armed
     when offset falls below release boundary or enough time passes
```

Use hysteresis:

```text
contactBoundary = adaptiveBoundary
releaseBoundary = adaptiveBoundary * 0.45
```

This is the key to the ping-pong-ball feel. A wall hit is not "currently turned left"; it is "I crossed into left boundary contact from a released state".

## Intensity

Impact intensity should be normalized to `0...1`:

```text
angleScore = saturate((offset - releaseBoundary) / (contactBoundary - releaseBoundary))
velocityScore = saturate(abs(velocity) / velocityReference)
accelScore = saturate(accelerationMagnitude / accelerationReference)
energyScore = saturate(shortWindowEnergy / energyReference)

intensity = weightedSum(
  angleScore: 0.35,
  velocityScore: 0.35,
  accelScore: 0.20,
  energyScore: 0.10
)
```

Slow posture drift can cross a boundary, but should produce a small or no impact. Fast intentional movement can hit earlier with a stronger event.

## Rapid Shake Behavior

Rapid left/right shaking should produce alternating impact events:

```text
left contact  -> left impact
release/cross -> right contact -> right impact
release/cross -> left contact  -> left impact
```

The detector should not emit repeated left impacts while still held against the left wall. It should re-arm left only after release or meaningful opposite movement.

## Lab Audio Model

The Lab should not use a single replacing cue player for impacts.

Impact audio should behave like game one-shots:

- no `stop()` when a new impact arrives;
- allow short polyphonic overlap;
- cap active voices, e.g. 4 voices;
- use a very short transient plus decay;
- pan by direction;
- scale gain and brightness by intensity.

This prevents rapid left/right contacts from cutting each other off. The sound should become a sequence of impacts, not a sequence of interrupted beeps.

## Implementation Plan

1. Add `DirectionalImpactEvent` and `DirectionalImpactDetector` to `AirPodsPosture`.
2. Feed the detector from the same cleaned `PostureSample` used by posture and gesture recognition.
3. Add optional impact output to `AirPodsPosturePipeline`.
4. Update Lab to consume impact events for sound instead of deriving sound directly from samples.
5. Replace Lab impact playback with a polyphonic one-shot sound engine.
6. Keep the current posture UI unchanged so we can compare stable posture and low-latency impact timing side by side.

## Open Questions

- Should turn and tilt both map to left/right, or should we eventually expose six directions: turn-left, turn-right, tilt-left, tilt-right, up, down?
- Should adaptive boundaries be per session only, or persisted per user/device?
- Should downstream apps receive impact events during gesture recording, or should recording mode suppress them?
- Should impact events be exposed as part of `AirPodsPosturePipelineOutput`, or through a separate detector that apps compose themselves?
