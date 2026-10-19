import CoreAudio
import Foundation

struct AudioDeviceInfo: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
}

/// CoreAudio のデバイス列挙・属性取得の薄いラッパ。
enum AudioDevices {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func all() -> [AudioDeviceInfo] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(info)
    }

    static func info(_ id: AudioDeviceID) -> AudioDeviceInfo? {
        guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        return AudioDeviceInfo(
            id: id, uid: uid, name: name,
            inputChannels: channels(id, scope: kAudioObjectPropertyScopeInput),
            outputChannels: channels(id, scope: kAudioObjectPropertyScopeOutput)
        )
    }

    static func find(uid: String) -> AudioDeviceInfo? {
        all().first { $0.uid == uid }
    }

    static func defaultDevice(input: Bool) -> AudioDeviceInfo? {
        var addr = address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return info(id)
    }

    static func nominalRate(_ id: AudioDeviceID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    /// デバイス固有の遅延（latency + safety offset + buffer）をフレーム数で返す。
    static func latencyFrames(_ id: AudioDeviceID, input: Bool) -> UInt32 {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        func u32(_ selector: AudioObjectPropertySelector) -> UInt32 {
            var addr = address(selector, scope: scope)
            var v = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v)
            return v
        }
        return u32(kAudioDevicePropertyLatency) + u32(kAudioDevicePropertySafetyOffset) + u32(kAudioDevicePropertyBufferFrameSize)
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref) == noErr else { return nil }
        return ref?.takeRetainedValue() as String?
    }

    private static func channels(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
