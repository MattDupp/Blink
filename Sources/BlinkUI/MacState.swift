import Foundation
import CoreAudio
import IOKit.ps

/// What the Mac is doing, read without asking for anything.
public enum MacState {

    /// The Mac runs on its battery.
    public static var onBattery: Bool {
        guard let type = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPMBatteryPowerKey
    }

    public static var lowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// Some app is using the microphone: most likely a call.
    ///
    /// This asks Core Audio whether the default input device is "running somewhere". It
    /// does not open the microphone, hears nothing, and needs no permission: the app
    /// never uses the microphone itself.
    public static var microphoneInUse: Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return false }
        var running = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}
