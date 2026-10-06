import AudioToolbox
import CoreAudio
import Foundation

/// Thin wrappers around the Core Audio property API.
enum CoreAudioHelpers {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default fallback: T) -> T {
        var address = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = fallback
        let status = withUnsafeMutableBytes(of: &value) { buffer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!)
        }
        return status == noErr ? value : fallback
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of _: T.Type) -> [T] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return [] }
        let typed = pointer.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: count))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var address = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static var defaultOutputDevice: AudioDeviceID {
        value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID(kAudioObjectUnknown))
    }

    static var defaultInputDevice: AudioDeviceID {
        value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, default: AudioDeviceID(kAudioObjectUnknown))
    }

    static func uid(of device: AudioDeviceID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    static func name(of device: AudioDeviceID) -> String? {
        string(device, kAudioObjectPropertyName)
    }

    static func device(withUID uid: String) -> AudioDeviceID? {
        allDevices.first { self.uid(of: $0) == uid }
    }

    static var allDevices: [AudioDeviceID] {
        array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, of: AudioDeviceID.self)
    }

    static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    /// The Core Audio object of a running process, or `kAudioObjectUnknown` if it has none.
    static func processObject(for pid: pid_t) -> AudioObjectID {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr ? object : AudioObjectID(kAudioObjectUnknown)
    }

    static var processObjects: [AudioObjectID] {
        array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
    }

    static func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = address(kAudioTapPropertyFormat)
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &description)
        return status == noErr ? description : nil
    }
}

/// A microphone the user can pick in Settings.
public struct AudioInputDevice: Hashable, Identifiable, Sendable {
    public var id: String { uid }
    public var uid: String
    public var name: String
}

/// A process that uses audio right now, as Core Audio reports it.
public struct AudioProcess: Hashable, Sendable {
    public var pid: pid_t
    public var bundleID: String
    public var isRunningInput: Bool
    public var isRunningOutput: Bool
}

public enum AudioSystem {
    public static func inputDevices() -> [AudioInputDevice] {
        CoreAudioHelpers.allDevices
            .filter { CoreAudioHelpers.hasInput($0) }
            .compactMap { device in
                guard let uid = CoreAudioHelpers.uid(of: device), let name = CoreAudioHelpers.name(of: device) else { return nil }
                // Aggregate devices the app creates for itself are private and never listed, but other tools' are.
                if name.hasPrefix("CADefaultDeviceAggregate") { return nil }
                return AudioInputDevice(uid: uid, name: name)
            }
    }

    public static var defaultInputName: String? {
        CoreAudioHelpers.name(of: CoreAudioHelpers.defaultInputDevice)
    }

    /// Every process Core Audio knows about with its current input and output state.
    public static func processes() -> [AudioProcess] {
        CoreAudioHelpers.processObjects.compactMap { object in
            let pid: pid_t = CoreAudioHelpers.value(object, kAudioProcessPropertyPID, default: -1)
            guard pid > 0 else { return nil }
            let bundleID = CoreAudioHelpers.string(object, kAudioProcessPropertyBundleID) ?? ""
            let input: UInt32 = CoreAudioHelpers.value(object, kAudioProcessPropertyIsRunningInput, default: 0)
            let output: UInt32 = CoreAudioHelpers.value(object, kAudioProcessPropertyIsRunningOutput, default: 0)
            return AudioProcess(pid: pid, bundleID: bundleID, isRunningInput: input != 0, isRunningOutput: output != 0)
        }
    }
}
