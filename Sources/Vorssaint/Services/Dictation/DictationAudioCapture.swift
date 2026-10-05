// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Accelerate
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// Fork: records one dictation from a chosen microphone. Each buffer goes to
/// the recognizer as it arrives; the waveform bars and voice activity are
/// computed from the same buffers. Voice is measured against the room's own
/// noise floor, so a quiet voice on a noisy microphone still counts.
///
/// Recording goes through a capture session opened on that microphone
/// alone. AVAudioEngine opened the system's default input first and switched
/// afterwards: with AirPods as the default, every start woke their call
/// profile, the route change stopped the engine, and a webcam chosen above
/// them never delivered a buffer.
final class DictationAudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// The recognizer's feed, on the capture queue.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Waveform bars, on the main queue.
    var onLevels: (([Float]) -> Void)?

    /// The lowest level that can count as voice, whatever the floor.
    var minimumVoiceLevel: Float = 0.006

    /// Every microphone arrives as mono 32-bit float at this rate.
    static let sampleRate: Double = 48_000

    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "com.vorssaint.dictation.capture", qos: .userInitiated)
    private var spectrum: SpectrumAnalyzer?
    private let lock = NSLock()
    private var active = false
    private var ring: [Float] = []
    private var noiseFloor: Float = 0
    private var lastVoice: CFTimeInterval = 0
    private var buffers = 0

    private(set) var format: AVAudioFormat?

    /// When voice was last heard above the floor.
    var lastVoiceTime: CFTimeInterval { lock.withLock { lastVoice } }
    /// Audio buffers heard this session; none means the microphone never spoke.
    var buffersReceived: Int { lock.withLock { buffers } }

    enum Failure: LocalizedError {
        case noInput
        var errorDescription: String? { "No microphone is available." }
    }

    /// `deviceUID` nil records from the system's default input.
    func start(deviceUID: String?) throws {
        stop()
        guard let device = deviceUID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio)
        else { throw Failure.noInput }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw Failure.noInput
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false)
        spectrum = SpectrumAnalyzer(configuration: .dictation, sampleRate: Self.sampleRate)
        lock.withLock {
            ring.removeAll(keepingCapacity: true)
            noiseFloor = 0
            lastVoice = CACurrentMediaTime()
            buffers = 0
            active = true
        }
        self.session = session
        // Starting a session waits on the device; it never holds up the shortcut.
        queue.async { session.startRunning() }
    }

    func stop() {
        lock.withLock { active = false }
        guard let session else { return }
        self.session = nil
        queue.async { session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard lock.withLock({ active }), let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        process(buffer)
    }

    /// The sample buffer's audio as a PCM buffer in its own format.
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { buffers += 1 }
        onBuffer?(buffer)
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(count))
        let now = CACurrentMediaTime()
        lock.lock()
        ring.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        let keep = SpectrumConfiguration.dictation.inputLength
        if ring.count > keep { ring.removeFirst(ring.count - keep) }
        let window = ring
        // The floor drops at once to anything quieter and creeps up slowly,
        // so a sentence never raises it but a fan that starts does.
        if noiseFloor == 0 || rms < noiseFloor { noiseFloor = rms } else { noiseFloor += (rms - noiseFloor) * 0.004 }
        if rms > DictationSupport.voiceThreshold(floor: noiseFloor, minimum: minimumVoiceLevel) { lastVoice = now }
        lock.unlock()
        guard let bars = spectrum?.process(window) else { return }
        DispatchQueue.main.async { [weak self] in self?.onLevels?(bars) }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID = uid as CFString
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }
}

/// Fork: the microphones Core Audio knows about, for dictation's picker and
/// for checking which ranked device is connected.
enum DictationAudioDevices {
    struct Device: Identifiable, Hashable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    static func inputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(uid: uid, name: name)
        }
    }

    static func hasInput(uid: String) -> Bool {
        DictationAudioCapture.deviceID(forUID: uid).map(hasInput) ?? false
    }

    static func name(forUID uid: String) -> String? {
        DictationAudioCapture.deviceID(forUID: uid).flatMap { string($0, kAudioObjectPropertyName) }
    }

    static func defaultInputName() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return string(device, kAudioObjectPropertyName)
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
