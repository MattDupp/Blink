import CoreAudio
import AudioToolbox

/// Whether the Mac's sound can be heard at all.
///
/// The setup's guide is a voice, for someone whose eyes are closed. Most office Macs are
/// muted. This asks the output the system is using (the speakers, headphones, a display)
/// whether it is muted or turned down to zero, so the window can say so before a session.
/// An output that cannot be asked (some displays and interfaces have no volume of their
/// own) is taken as audible: a warning that is wrong is worse than none.
public enum SoundOutput {

    public static var isMuted: Bool {
        guard let device = defaultOutput else { return false }
        if let muted: UInt32 = read(device, kAudioDevicePropertyMute), muted != 0 { return true }
        if let volume: Float32 = read(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume), volume <= 0.001 { return true }
        return false
    }

    private static var defaultOutput: AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func read<Value>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Value? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var size = UInt32(MemoryLayout<Value>.size)
        let value = UnsafeMutablePointer<Value>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }
}
