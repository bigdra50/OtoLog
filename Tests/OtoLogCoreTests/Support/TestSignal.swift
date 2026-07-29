import AVFAudio
import Foundation

/// テスト用 PCM 生成。
enum TestSignal {
    static func sine(format: AVAudioFormat, seconds: Double, frequency: Double = 440) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            fatalError("failed to allocate PCM buffer")
        }
        buffer.frameLength = frames
        let omega = 2 * Double.pi * frequency / format.sampleRate
        for channel in 0..<Int(format.channelCount) {
            guard let data = buffer.floatChannelData?[channel] else { continue }
            for frame in 0..<Int(frames) {
                data[frame] = Float(sin(omega * Double(frame)) * 0.5)
            }
        }
        return buffer
    }
}
