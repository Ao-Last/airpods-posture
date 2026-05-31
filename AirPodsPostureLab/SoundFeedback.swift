import AVFoundation
import Foundation

enum SoundCue {
    case armed
    case calibrated
    case connected
    case disconnected
    case error
    case gesture(GestureKind)
}

final class SoundFeedback: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let renderQueue = DispatchQueue(label: "dev.airpods-posture.lab.app.sound")
    private let playbackLock = NSLock()
    private let sampleRate = 48_000.0
    private var isEnabled = true
    private var playbackGeneration = 0
    private lazy var format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 2,
        interleaved: false
    )!

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
        } catch {
            isEnabled = false
        }
    }

    func play(_ cue: SoundCue) {
        guard isEnabled else {
            return
        }

        let generation = playbackLock.withLock {
            playbackGeneration += 1
            return playbackGeneration
        }

        renderQueue.async { [weak self] in
            self?.schedule(cue, generation: generation)
        }
    }

    private func schedule(_ cue: SoundCue, generation: Int) {
        guard playbackLock.withLock({ playbackGeneration == generation }) else {
            return
        }

        let segments = cue.segments
        let totalDuration = segments.reduce(0) { $0 + $1.duration }
        let totalFrames = AVAudioFrameCount(max(1, Int(totalDuration * sampleRate)))

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames),
              let channels = buffer.floatChannelData else {
            return
        }

        buffer.frameLength = totalFrames
        for channelIndex in 0..<Int(format.channelCount) {
            channels[channelIndex].update(repeating: 0, count: Int(totalFrames))
        }

        var frameOffset = 0
        for segment in segments {
            let frameCount = max(1, Int(segment.duration * sampleRate))
            for localFrame in 0..<frameCount where frameOffset + localFrame < Int(totalFrames) {
                let progress = Double(localFrame) / Double(max(1, frameCount - 1))
                let frequency = segment.startFrequency
                    + (segment.endFrequency - segment.startFrequency) * progress
                let phase = 2 * Double.pi * frequency * Double(localFrame) / sampleRate
                let envelope = envelope(progress)
                let sample = sin(phase) * segment.gain * envelope
                let leftGain = sqrt((1 - segment.pan) * 0.5)
                let rightGain = sqrt((1 + segment.pan) * 0.5)
                let frame = frameOffset + localFrame

                channels[0][frame] += Float(sample * leftGain)
                channels[1][frame] += Float(sample * rightGain)
            }

            frameOffset += frameCount
        }

        guard playbackLock.withLock({ playbackGeneration == generation }) else {
            return
        }

        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        player.play()
    }

    private func envelope(_ progress: Double) -> Double {
        let attack = min(progress / 0.16, 1)
        let release = min((1 - progress) / 0.18, 1)
        return max(0, min(attack, release))
    }
}

private struct ToneSegment {
    var startFrequency: Double
    var endFrequency: Double
    var duration: TimeInterval
    var pan: Double
    var gain: Double
}

private extension SoundCue {
    var segments: [ToneSegment] {
        switch self {
        case .armed:
            [
                ToneSegment(startFrequency: 420, endFrequency: 520, duration: 0.08, pan: 0, gain: 0.12),
                ToneSegment(startFrequency: 640, endFrequency: 760, duration: 0.09, pan: 0, gain: 0.12)
            ]
        case .calibrated:
            [
                ToneSegment(startFrequency: 520, endFrequency: 520, duration: 0.07, pan: -0.2, gain: 0.10),
                ToneSegment(startFrequency: 700, endFrequency: 760, duration: 0.10, pan: 0.2, gain: 0.12)
            ]
        case .connected:
            [
                ToneSegment(startFrequency: 540, endFrequency: 720, duration: 0.12, pan: 0, gain: 0.11)
            ]
        case .disconnected:
            [
                ToneSegment(startFrequency: 360, endFrequency: 260, duration: 0.14, pan: 0, gain: 0.10)
            ]
        case .error:
            [
                ToneSegment(startFrequency: 180, endFrequency: 160, duration: 0.11, pan: 0, gain: 0.13)
            ]
        case .gesture(.nod):
            [
                ToneSegment(startFrequency: 660, endFrequency: 760, duration: 0.07, pan: 0, gain: 0.14),
                ToneSegment(startFrequency: 860, endFrequency: 980, duration: 0.09, pan: 0, gain: 0.15)
            ]
        case .gesture(.shake):
            [
                ToneSegment(startFrequency: 380, endFrequency: 300, duration: 0.08, pan: -0.45, gain: 0.13),
                ToneSegment(startFrequency: 300, endFrequency: 240, duration: 0.08, pan: 0.45, gain: 0.13)
            ]
        case .gesture(.tiltLeft):
            [
                ToneSegment(startFrequency: 620, endFrequency: 700, duration: 0.10, pan: -0.92, gain: 0.15)
            ]
        case .gesture(.tiltRight):
            [
                ToneSegment(startFrequency: 620, endFrequency: 700, duration: 0.10, pan: 0.92, gain: 0.15)
            ]
        }
    }
}
