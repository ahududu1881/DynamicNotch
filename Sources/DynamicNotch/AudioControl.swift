import CoreAudio
import Foundation

/// Output volume, mute and output-device selection on top of CoreAudio.
final class AudioControl {
    static let shared = AudioControl()

    /// level 0...1, muted
    var onVolumeChange: ((Double, Bool) -> Void)?
    var onDefaultOutputChange: ((AudioOutput) -> Void)?
    /// Fires when audio devices appear or disappear (AirPods connecting, USB audio plugged in...).
    var onDeviceListChange: (() -> Void)?

    private let system = AudioObjectID(kAudioObjectSystemObject)
    private let virtualMainVolume: AudioObjectPropertySelector = 0x766D7663 // 'vmvc'
    private var listened: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var startedAt = Date()

    private func address(_ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    // MARK: Default device

    var defaultOutput: AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectGetPropertyData(system, &a, 0, nil, &size, &id)
        return id
    }

    func setDefaultOutput(_ id: AudioDeviceID) {
        var device = id
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var a = address(selector)
            AudioObjectSetPropertyData(system, &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &device)
        }
    }

    // MARK: Volume

    private func volumeAddresses(_ dev: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        let out = kAudioDevicePropertyScopeOutput
        let candidates = [
            address(virtualMainVolume, scope: out),
            address(kAudioDevicePropertyVolumeScalar, scope: out, element: kAudioObjectPropertyElementMain),
        ]
        for var c in candidates where AudioObjectHasProperty(dev, &c) { return [c] }
        let channels = [address(kAudioDevicePropertyVolumeScalar, scope: out, element: 1),
                        address(kAudioDevicePropertyVolumeScalar, scope: out, element: 2)]
        return channels.filter { var c = $0; return AudioObjectHasProperty(dev, &c) }
    }

    var canControlVolume: Bool {
        let dev = defaultOutput
        guard dev != 0 else { return false }
        return volumeAddresses(dev).contains { var a = $0; var settable: DarwinBoolean = false
            return AudioObjectIsPropertySettable(dev, &a, &settable) == noErr && settable.boolValue }
    }

    func volume() -> Double? {
        let dev = defaultOutput
        let addrs = volumeAddresses(dev)
        guard !addrs.isEmpty else { return nil }
        var sum = 0.0
        for var a in addrs {
            var v = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr else { return nil }
            sum += Double(v)
        }
        return sum / Double(addrs.count)
    }

    func setVolume(_ level: Double) {
        let dev = defaultOutput
        var v = Float32(min(max(level, 0), 1))
        for var a in volumeAddresses(dev) {
            AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
        if level > 0, isMuted { setMuted(false) }
    }

    // MARK: Mute

    private func muteAddresses(_ dev: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        let out = kAudioDevicePropertyScopeOutput
        let all = [address(kAudioDevicePropertyMute, scope: out),
                   address(kAudioDevicePropertyMute, scope: out, element: 1),
                   address(kAudioDevicePropertyMute, scope: out, element: 2)]
        return all.filter { var c = $0; return AudioObjectHasProperty(dev, &c) }
    }

    var isMuted: Bool {
        let dev = defaultOutput
        guard var a = muteAddresses(dev).first else { return false }
        var m = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &m)
        return m != 0
    }

    func setMuted(_ muted: Bool) {
        let dev = defaultOutput
        var m: UInt32 = muted ? 1 : 0
        for var a in muteAddresses(dev) {
            AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        }
    }

    // MARK: Devices

    func outputDevices() -> [AudioOutput] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        let current = defaultOutput
        return ids.compactMap { id in
            guard outputChannelCount(id) > 0, let name = deviceName(id), !name.hasPrefix("CADefaultDeviceAggregate") else { return nil }
            return AudioOutput(id: id, name: name, symbol: symbol(for: id, name: name), isDefault: id == current,
                               isBluetooth: isBluetooth(id))
        }
    }

    func currentOutputInfo() -> AudioOutput? {
        outputDevices().first(where: \.isDefault)
    }

    func isBluetooth(_ dev: AudioDeviceID) -> Bool {
        var a = address(kAudioDevicePropertyTransportType)
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &transport)
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private func outputChannelCount(_ dev: AudioDeviceID) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func deviceName(_ dev: AudioDeviceID) -> String? {
        var a = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private func symbol(for dev: AudioDeviceID, name: String) -> String {
        var a = address(kAudioDevicePropertyTransportType)
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &transport)
        if isBluetooth(dev) { return AccessoryInfo.model(name: name).symbolName }
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpods.max" }
        if lower.contains("airpods pro") { return "airpods.pro" }
        if lower.contains("airpods") { return "airpods" }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return lower.contains("headphone") ? "headphones" : "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeUSB: return "hifispeaker"
        default: return "speaker.wave.2"
        }
    }

    // MARK: Listeners

    func startListening() {
        startedAt = Date()
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.attachDeviceListeners()
            if Date().timeIntervalSince(self.startedAt) > 1.5, let info = self.currentOutputInfo() {
                self.onDefaultOutputChange?(info)
            }
        }
        AudioObjectAddPropertyListenerBlock(system, &a, .main, block)

        var list = address(kAudioHardwarePropertyDevices)
        let listBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onDeviceListChange?() }
        AudioObjectAddPropertyListenerBlock(system, &list, .main, listBlock)
        attachDeviceListeners()
    }

    private func attachDeviceListeners() {
        for (obj, addr, block) in listened {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(obj, &a, .main, block)
        }
        listened.removeAll()

        let dev = defaultOutput
        guard dev != 0 else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, Date().timeIntervalSince(self.startedAt) > 1.5, let level = self.volume() else { return }
            self.onVolumeChange?(level, self.isMuted)
        }
        for var a in volumeAddresses(dev) + muteAddresses(dev) {
            if AudioObjectAddPropertyListenerBlock(dev, &a, .main, block) == noErr {
                listened.append((dev, a, block))
            }
        }
    }
}
