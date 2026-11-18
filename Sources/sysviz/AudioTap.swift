import Foundation
import CoreAudio

struct VizError: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

/// Захват системного звука через Core Audio Tap (macOS 14.2+).
/// Драйверы и переключение выхода не нужны.
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let lock = NSLock()
    private var samples: [Float] = []
    private let keepCount: Int
    private(set) var sampleRate: Double = 48_000

    init(keepCount: Int) {
        self.keepCount = keepCount
    }

    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            throw VizError("AudioHardwareCreateProcessTap вернул \(status). Нужен macOS 14.2+.")
        }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &format)
        guard status == noErr else {
            throw VizError("Не удалось прочитать формат тапа: \(status)")
        }
        guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw VizError("Формат тапа не float32, неподдерживаемый вариант")
        }

        sampleRate = format.mSampleRate
        let channels = max(Int(format.mChannelsPerFrame), 1)
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        let outputUID = try defaultOutputDeviceUID()
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "sysviz",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString
                ]
            ]
        ]

        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard status == noErr else {
            throw VizError("Не удалось создать aggregate device: \(status)")
        }

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { [weak self] _, input, _, _, _ in
            self?.consume(input, channels: channels, nonInterleaved: nonInterleaved)
        }
        guard status == noErr else {
            throw VizError("AudioDeviceCreateIOProcIDWithBlock вернул \(status)")
        }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            throw VizError("AudioDeviceStart вернул \(status)")
        }
    }

    /// Последние `count` моно-сэмплов. Если данных мало, дополняем нулями.
    func latest(count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        if samples.count >= count {
            return Array(samples.suffix(count))
        }
        return [Float](repeating: 0, count: count - samples.count) + samples
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private func consume(_ input: UnsafePointer<AudioBufferList>, channels: Int, nonInterleaved: Bool) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var mono: [Float] = []

        if nonInterleaved {
            // Каждый буфер — отдельный канал.
            guard list.count > 0 else { return }
            let frames = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
            mono = [Float](repeating: 0, count: frames)
            for buffer in list {
                guard let raw = buffer.mData else { continue }
                let data = raw.assumingMemoryBound(to: Float.self)
                let available = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                for i in 0..<available {
                    mono[i] += data[i]
                }
            }
            let scale = 1 / Float(list.count)
            for i in 0..<frames {
                mono[i] *= scale
            }
        } else {
            // Чередующиеся сэмплы: L R L R ...
            guard let first = list.first, let raw = first.mData else { return }
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let data = raw.assumingMemoryBound(to: Float.self)
            mono = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels {
                    sum += data[i * channels + c]
                }
                mono[i] = sum / Float(channels)
            }
        }

        lock.lock()
        samples.append(contentsOf: mono)
        if samples.count > keepCount {
            samples.removeFirst(samples.count - keepCount)
        }
        lock.unlock()
    }

    private func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr else {
            throw VizError("Не удалось получить устройство вывода: \(status)")
        }

        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr else {
            throw VizError("Не удалось получить UID устройства вывода: \(status)")
        }
        return uid as String
    }
}
