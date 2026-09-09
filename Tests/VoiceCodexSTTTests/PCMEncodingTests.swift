import AVFoundation
import Foundation
import XCTest
@testable import VoiceCodex

final class PCMEncodingTests: XCTestCase {
    func testCommonDeviceFormatsPreserveDurationAndSignal() throws {
        for rate in [16_000.0, 44_100.0, 48_000.0] {
            for channels in [1, 2] {
                for interleaved in [false, true] {
                    let frames = Int(rate * 0.02)
                    let buffer = makeBuffer(rate: rate, channels: channels, frames: frames, interleaved: interleaved)
                    fill(buffer) { frame, _ in Float(sin(Double(frame) / rate * 440 * 2 * .pi)) * 0.5 }
                    let (pcm, level) = try XCTUnwrap(SpeechMicrophone.encode(buffer))
                    // 20 ms at 16 kHz, 16 bit, mono is 640 bytes.
                    XCTAssertEqual(pcm.count, 640, "\(rate) Hz / \(channels) ch / interleaved=\(interleaved)")
                    XCTAssertGreaterThan(level, 0.5)
                    XCTAssertTrue(pcm.contains { $0 != 0 })
                }
            }
        }
    }

    func testStereoChannelsAreAveraged() throws {
        let buffer = makeBuffer(rate: 16_000, channels: 2, frames: 320)
        fill(buffer) { _, channel in channel == 0 ? 0.5 : -0.5 }
        let (pcm, level) = try XCTUnwrap(SpeechMicrophone.encode(buffer))
        XCTAssertEqual(level, 0)
        XCTAssertTrue(pcm.allSatisfy { $0 == 0 })
    }

    func testSamplesAreClampedAndEncodedLittleEndian() throws {
        let samples: [Float] = [-2, -1, 0, 1, 2]
        let buffer = makeBuffer(rate: 16_000, channels: 1, frames: samples.count)
        fill(buffer) { frame, _ in samples[frame] }
        let (pcm, _) = try XCTUnwrap(SpeechMicrophone.encode(buffer))
        let integers = stride(from: 0, to: pcm.count, by: 2).map {
            Int16(bitPattern: UInt16(pcm[$0]) | (UInt16(pcm[$0 + 1]) << 8))
        }
        XCTAssertEqual(integers, [-32767, -32767, 0, 32767, 32767])
    }

    func testEmptyBufferIsRejected() {
        let buffer = makeBuffer(rate: 48_000, channels: 1, frames: 32)
        buffer.frameLength = 0
        XCTAssertNil(SpeechMicrophone.encode(buffer))
    }

    private func makeBuffer(rate: Double, channels: Int, frames: Int,
                            interleaved: Bool = false) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: AVAudioChannelCount(channels), interleaved: interleaved)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    private func fill(_ buffer: AVAudioPCMBuffer, value: (Int, Int) -> Float) {
        let channels = Int(buffer.format.channelCount)
        let data = buffer.floatChannelData!
        for frame in 0..<Int(buffer.frameLength) {
            for channel in 0..<channels {
                if buffer.format.isInterleaved { data[0][frame * channels + channel] = value(frame, channel) }
                else { data[channel][frame] = value(frame, channel) }
            }
        }
    }
}
