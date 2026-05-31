# AirPods Posture

[English](README.md)

AirPods Posture 把 AirPods 的头部运动数据转换成可复用的 posture / gesture stream。

这个 repo 不是一个下游效率工具，也不是某个具体应用。它只聚焦两个部分：

1. `AirPodsPosture`：Swift package，把头部运动转换成姿态快照、手势事件和信号质量状态。
2. `AirPods Posture Lab`：macOS SwiftUI 调试应用，用来做真机测试、校准和交互体验调试。

长期边界很清楚：下游应用应该消费这个包输出的 posture / gesture stream，而不是自己复制一套 CoreMotion 实时处理逻辑。

```text
AirPods motion
  -> neutral calibration
  -> signal guard
  -> cleaned motion sample
  -> posture stream + gesture events
  -> downstream app or debug feedback
```

## 当前状态

项目还处在早期实验阶段，但核心边界已经稳定：

- library 不依赖 `CoreMotion`。
- 调试 app 负责把 `CMDeviceMotion` 转换成库定义的 `HeadMotionFrame`。
- gesture 识别使用 motion segmentation 加 DTW-style template matching。
- posture 识别是在 cleaned motion sample 上做持续状态检测。

硬件支持取决于 Apple 的 `CMHeadphoneMotionManager`，以及用户设备上的 AirPods 型号和系统支持情况。

## Package

添加 Swift package：

```swift
.package(url: "https://github.com/Ao-Last/airpods-posture.git", branch: "main")
```

依赖 product：

```swift
.product(name: "AirPodsPosture", package: "airpods-posture")
```

导入模块：

```swift
import AirPodsPosture
```

主要公开 API 是 `AirPodsPosturePipeline`。

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
case .accepted(let sample, let posture, let gesture, let episodeEvents, let signalQuality):
    print(sample.yaw, sample.pitch, sample.roll)
    print(posture.kind, posture.confidence)
    print(gesture?.kind as Any)
    print(episodeEvents.map(\.phase))
    print(signalQuality.state)

case .calibrating(let progress, _):
    print("calibrating", progress)

case .calibrated:
    print("ready")

case .reset(_, let signalQuality), .dropped(_, let signalQuality):
    print(signalQuality.debugSummary)
}
```

核心类型：

- `HeadMotionFrame`：时间戳、耳机四元数、角速度和用户加速度。
- `AirPodsPosturePipeline`：中立姿态校准、信号保护、姿态检测和手势识别。
- `PostureSample`：清洗后的 yaw / pitch / roll，以及角速度和加速度。
- `PostureSnapshot`：持续姿态流。
- `PostureEpisodeEvent`：从 posture 时间状态派生出来的 entered / sustained / recovered / exited 事件流。
- `GestureEvent`：离散手势事件流。
- `MotionSignalQuality`：stable / recovering / gap / spike，用于蓝牙信号恢复和 UI 诊断。

设计笔记：

- [Directional impact events](docs/directional-impact-events.md)：一个低延迟事件流设计，用来表达类似小球撞击 left / right / up / down 边界的身体反馈。它和稳定 posture、语义 gesture 分离。

## Postures

当前支持的姿态：

- `neutral`：校准后的自然头部位置。
- `head_down`：持续低头，可用于低头族或颈部姿态提醒。
- `head_up`：持续抬头。
- `turned_left` / `turned_right`：相对中心的持续左右转头。
- `tilted_left` / `tilted_right`：头向肩膀方向的侧倾。

当前默认轴假设来自真机观察：

- yaw：左右转头。正 yaw 映射为左转，负 yaw 映射为右转。
- roll：上下点头，也是默认的垂直姿态轴。
- pitch：侧倾。

这些符号只是默认值，不是永恒真理。AirPods 的佩戴方式、耳型、系统姿态约定都可能带来差异，所以后续应用应该保留校准和用户测试。

## Posture Episodes

`PostureEpisodeDetector` 会把稳定姿态快照转换成可复用的时间事件：

- `entered`：进入某个非 neutral 姿态。
- `sustained`：该姿态已经持续超过 `minimumSustainedDuration`。
- `recovered`：用户已经回到 neutral 并保持了 `recoveryDuration`。
- `exited`：当前姿态被另一个非 neutral 姿态替换。

这一层适合低实时性应用，比如低头提醒。Core package 只报告 episode 语义；下游应用仍然负责通知权限、cooldown、统计、设置和产品文案。如果下游想自己做算法，也可以完全忽略这一层，直接消费 `PostureSnapshot` 或 `PostureSample`。

## Gestures

当前支持的手势：

- `nod`：roll stroke，用于 yes / confirm。
- `shake`：yaw stroke，用于 no / cancel。
- `tilt_left`：保持向左侧倾，用于 previous / left。
- `tilt_right`：保持向右侧倾，用于 next / right。

动态手势识别使用：

1. relative attitude、rotation rate 和 user acceleration；
2. 基于角速度的 motion segmentation，等待完整 nod / shake，而不是半个动作就触发；
3. DTW-style template matching；
4. 幅度、主轴、反转次数、回中、角速度和加速度等物理证据；
5. Lab 录制 UI 学到的个人模板。

gesture 不是从 posture label 推导出来的。posture 和 gesture 都消费同一条 cleaned motion stream。未来 posture 可以作为下游交互的上下文或 gating 条件。

## Debug App

`AirPods Posture Lab` 是第一方调试 UI。

它会显示：

- 实时 yaw / pitch / roll；
- sample rate 和 signal quality；
- 当前姿态、置信度、偏移量和持续时间；
- 最近手势、置信度、幅度和 debug 信息；
- nod、shake、left tilt、right tilt 的校准录制控件。

它也会播放与动作匹配的音效，让身体动作有即时确认反馈。Lab 里的方向姿态使用更硬的 equal-power stereo panning：向左转头 / 侧倾几乎只播放左声道，向右转头 / 侧倾几乎只播放右声道，并且音效强度会跟随姿态偏移、角速度和加速度变化。这些音效会在 motion onset 阶段提前触发，而不是等 sustained posture 状态确认后才触发，因为这里的音效是输入表面的一部分，不是装饰。

真机 AirPods 调试请通过 Xcode 运行：

1. 打开 `AirPodsPostureLab.xcodeproj`。
2. 选择 `AirPodsPostureLab` scheme。
3. 从 Xcode 运行。

这样可以让 macOS app bundle、Info.plist、签名、隐私提示和 app 生命周期都走标准路径，正确使用 `CMHeadphoneMotionManager`。

## CLI Simulation

SwiftPM executable 只是 recognizer simulation 和 smoke test harness。它不会请求真实 AirPods motion 权限。

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

测试覆盖：

- public pipeline 校准和 stream 输出；
- signal gap reset；
- 持续姿态检测；
- nod、shake 和 held tilt 识别；
- 完整手势分段；
- 小动作拒绝；
- quaternion baseline 转换；
- motion vector 轴映射。

## Project Layout

```text
Sources/AirPodsPosture/        可复用 Swift package
AirPodsPostureLab/             macOS SwiftUI 调试应用
Sources/AirPodsPostureLab/     CLI simulation harness
Tests/AirPodsPostureTests/     Package tests
```

## Roadmap

- 录制真实 AirPods traces：自然工作、低头、阅读姿态、nod、shake 和侧倾。
- 添加 head down / head up 和 left / right turn 的显式姿态校准。
- 添加 trace export，方便离线评估阈值和模板变化。
- 先调 false-positive rate，再增加更多下游交互。
- 增加 armed/listening state，让应用只在交互窗口内接受 gesture。

## License

MIT
