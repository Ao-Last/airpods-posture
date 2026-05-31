import SwiftUI

struct ContentView: View {
    @ObservedObject var model: PostureLabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            axes
            posture
            gestures
            calibration
            controls
        }
        .padding(28)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("AirPods Posture Lab")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Spacer()
                Text(model.authorizationLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
                Text(model.sampleRateLabel)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
                Text(model.signalQualityLabel)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
            }

            Text(model.status)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(model.statusColor)

            ProgressView(value: model.calibrationProgress)
                .opacity(model.isCalibrated ? 0.35 : 1)
        }
    }

    private var axes: some View {
        HStack(spacing: 12) {
            AxisGauge(name: "Yaw", value: model.yaw, limit: 30, tint: .teal)
            AxisGauge(name: "Pitch", value: model.pitch, limit: 30, tint: .indigo)
            AxisGauge(name: "Roll", value: model.roll, limit: 30, tint: .orange)
        }
    }

    private var gestures: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Gestures")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                GestureTile(kind: .nod, title: "Nod", subtitle: "yes / confirm", model: model)
                GestureTile(kind: .shake, title: "Shake", subtitle: "no / cancel", model: model)
                GestureTile(kind: .tiltLeft, title: "Tilt Left", subtitle: "previous / left", model: model)
                GestureTile(kind: .tiltRight, title: "Tilt Right", subtitle: "next / right", model: model)
            }
        }
    }

    private var posture: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Posture")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                PostureStatusPanel(model: model)
                PostureMonitorTile(
                    title: "Low Head",
                    subtitle: "sustained downward angle",
                    systemImage: "arrow.down.circle.fill",
                    isActive: model.currentPosture == .headDown,
                    activeColor: .orange,
                    confidence: model.currentPosture == .headDown ? model.postureConfidence : 0
                )
                PostureMonitorTile(
                    title: "Turn",
                    subtitle: "left or right heading",
                    systemImage: "arrow.left.and.right.circle.fill",
                    isActive: model.currentPosture == .turnedLeft || model.currentPosture == .turnedRight,
                    activeColor: .teal,
                    confidence: model.currentPosture == .turnedLeft || model.currentPosture == .turnedRight ? model.postureConfidence : 0
                )
                PostureMonitorTile(
                    title: "Side Tilt",
                    subtitle: "ear toward shoulder",
                    systemImage: "arrow.counterclockwise.circle.fill",
                    isActive: model.currentPosture == .tiltedLeft || model.currentPosture == .tiltedRight,
                    activeColor: .indigo,
                    confidence: model.currentPosture == .tiltedLeft || model.currentPosture == .tiltedRight ? model.postureConfidence : 0
                )
            }
        }
    }

    private var calibration: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Calibration")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.calibrationProfileSummary)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                CalibrationButton(kind: .nod, title: "Nod", systemImage: "checkmark.circle.fill", model: model)
                CalibrationButton(kind: .shake, title: "Shake", systemImage: "xmark.circle.fill", model: model)
                CalibrationButton(kind: .tiltLeft, title: "Tilt Left", systemImage: "arrow.left.circle.fill", model: model)
                CalibrationButton(kind: .tiltRight, title: "Tilt Right", systemImage: "arrow.right.circle.fill", model: model)
            }

            if let recordingGesture = model.recordingGesture {
                HStack(spacing: 10) {
                    ProgressView(value: model.recordingProgress)
                    Text("Recording \(recordingGesture.label)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .trailing)
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                model.resetCalibration()
            } label: {
                Label("Recalibrate", systemImage: "scope")
            }
            .buttonStyle(.borderedProminent)

            Button {
                model.isRunning ? model.stop() : model.start()
            } label: {
                Label(model.isRunning ? "Stop" : "Start", systemImage: model.isRunning ? "stop.fill" : "play.fill")
            }

            Spacer()

            Text(model.lastDebugSummary)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct PostureStatusPanel: View {
    @ObservedObject var model: PostureLabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(color)
                Text(model.currentPosture.label.capitalized)
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                Text(model.postureHeldDurationLabel)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Text(String(format: "%.0f%%", model.postureConfidence * 100))
                Text(String(format: "%.1f deg", model.postureOffset))
                Text(model.currentPosture.groupLabel)
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)

            Text(model.postureDebugSummary)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(model.currentPosture == .neutral ? 0.25 : 0.65), lineWidth: 1)
        )
    }

    private var icon: String {
        switch model.currentPosture {
        case .neutral:
            "person.crop.circle.fill"
        case .headDown:
            "arrow.down.circle.fill"
        case .headUp:
            "arrow.up.circle.fill"
        case .turnedLeft:
            "arrow.left.circle.fill"
        case .turnedRight:
            "arrow.right.circle.fill"
        case .tiltedLeft, .tiltedRight:
            "arrow.counterclockwise.circle.fill"
        }
    }

    private var color: Color {
        switch model.currentPosture {
        case .neutral:
            .secondary
        case .headDown:
            .orange
        case .headUp:
            .yellow
        case .turnedLeft, .turnedRight:
            .teal
        case .tiltedLeft, .tiltedRight:
            .indigo
        }
    }
}

private struct PostureMonitorTile: View {
    var title: String
    var subtitle: String
    var systemImage: String
    var isActive: Bool
    var activeColor: Color
    var confidence: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Text(isActive ? String(format: "%.0f%%", confidence * 100) : "--")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isActive ? .white.opacity(0.82) : .secondary)
                .lineLimit(2)
        }
        .foregroundStyle(isActive ? .white : .primary)
        .padding(12)
        .frame(width: 132)
        .frame(minHeight: 108, alignment: .topLeading)
        .background(isActive ? activeColor : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.clear : Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

private struct CalibrationButton: View {
    var kind: GestureKind
    var title: String
    var systemImage: String
    @ObservedObject var model: PostureLabModel

    private var isRecording: Bool {
        model.recordingGesture == kind
    }

    var body: some View {
        Button {
            model.startRecording(kind)
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .accentColor : .secondary)
        .disabled(!model.isCalibrated || (model.recordingGesture != nil && !isRecording))
    }
}

private struct AxisGauge: View {
    var name: String
    var value: Double
    var limit: Double
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%+.1f deg", value))
                    .font(.system(size: 19, weight: .semibold, design: .monospaced))
            }

            GeometryReader { proxy in
                ZStack(alignment: .center) {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 10)
                    Rectangle()
                        .fill(.secondary.opacity(0.4))
                        .frame(width: 1, height: 24)

                    let normalized = min(max(value / limit, -1), 1)
                    Capsule()
                        .fill(tint.gradient)
                        .frame(width: max(6, abs(normalized) * proxy.size.width / 2), height: 10)
                        .offset(x: normalized * proxy.size.width / 4)
                }
            }
            .frame(height: 28)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        )
    }
}

private struct GestureTile: View {
    var kind: GestureKind
    var title: String
    var subtitle: String
    @ObservedObject var model: PostureLabModel

    private var isActive: Bool {
        model.lastGesture == kind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Text(isActive ? String(format: "%.0f%%", model.lastConfidence * 100) : "--")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
            }

            Text(title)
                .font(.system(size: 18, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(isActive ? .white : .primary)
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(isActive ? activeColor : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.clear : Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private var icon: String {
        switch kind {
        case .nod:
            "checkmark.circle.fill"
        case .shake:
            "xmark.circle.fill"
        case .tiltLeft:
            "arrow.left.circle.fill"
        case .tiltRight:
            "arrow.right.circle.fill"
        }
    }

    private var activeColor: Color {
        switch kind {
        case .nod:
            .green
        case .shake:
            .red
        case .tiltLeft:
            .blue
        case .tiltRight:
            .purple
        }
    }
}
