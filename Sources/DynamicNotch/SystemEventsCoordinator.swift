import AppKit

/// Turns volume / brightness / media keys and device changes into notch HUDs,
/// and swallows the key events so macOS does not draw its own toast.
@MainActor
final class SystemEventsCoordinator {
    private let controller: NotchController
    private let audio = AudioControl.shared
    private let brightness = BrightnessControl.shared
    private let interceptor = SystemKeyInterceptor()
    private let power = PowerMonitor()
    private var trustTimer: Timer?
    var plugins: PluginManager?

    private let settings = Settings.shared
    private let hotkeys = HotkeyMonitor()
    private var watchdog: Timer?

    var interceptEnabled: Bool { settings.interceptSystemHUD }

    var hasAccessibility: Bool { AXIsProcessTrusted() }
    var tapRunning: Bool { interceptor.isRunning }

    init(controller: NotchController) { self.controller = controller }

    private var model: NotchModel { controller.model }

    func start() {
        interceptor.handler = { [weak self] key, down, isRepeat, flags in
            self?.handle(key: key, down: down, isRepeat: isRepeat, flags: flags) ?? false
        }
        installTapWhenTrusted(prompt: true)

        audio.onVolumeChange = { [weak self] level, muted in
            guard let self else { return }
            self.plugins?.emit("volume", ["level": level, "muted": muted])
            let kind = HUDKind.volume(level: level, muted: muted)
            guard self.controller.canShow(kind) else { return }
            self.model.showHUD(kind)
        }
        audio.onDefaultOutputChange = { [weak self] output in
            guard let self else { return }
            self.model.setOutputs(self.audio.outputDevices())
            guard self.settings.showOutputToasts, self.controller.canShow(.output(name: "", symbol: "")) else { return }
            // A Bluetooth device that was just connected is announced by the accessory toast instead.
            if output.isBluetooth, !self.knownBluetooth.values.contains(output.name) || self.connectedRecently(output.name) { return }
            self.model.showHUD(.output(name: output.name, symbol: output.symbol), duration: 2.2)
        }
        knownBluetooth = Dictionary(uniqueKeysWithValues: audio.outputDevices().filter(\.isBluetooth).map { ($0.id, $0.name) })
        audio.onDeviceListChange = { [weak self] in self?.scheduleDeviceDiff() }
        audio.startListening()

        model.onOutputsRequested = { [weak self] in self?.refreshOutputs() }
        model.onSelectOutput = { [weak self] output in
            self?.audio.setDefaultOutput(output.id)
            self?.refreshOutputs()
        }
        refreshOutputs()

        power.onEvent = { [weak self] kind in
            if case .power(let percent, let charging, let plugged) = kind {
                self?.plugins?.emit("battery", ["percent": percent, "charging": charging, "plugged": plugged])
            }
            guard let self, !self.controller.isSuspended, self.settings.showBatteryToasts else { return }
            if case .power(_, _, let plugged) = kind, !plugged { self.model.showHUD(kind, duration: 6) }
            else { self.model.showHUD(kind, duration: 3.4) }
        }
        power.start()

        // Swiping / scrolling over the notch changes the volume.
        controller.onScrollVolume = { [weak self] delta in self?.nudgeVolume(by: delta) }

        hotkeys.handler = { [weak self] action in self?.perform(action) }
        hotkeys.start()

        // The event tap can be switched off by the system (timeouts, permission changes, wake): keep it alive.
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.interceptor.ensureEnabled() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interceptor.ensureEnabled(); self?.refreshOutputs() }
        }
    }

    // MARK: Bluetooth accessories

    private var knownBluetooth: [UInt32: String] = [:]
    private var connectedAt: [String: Date] = [:]
    private var deviceDiffTask: Task<Void, Never>?
    private var lastAccessory: String?

    private func connectedRecently(_ name: String) -> Bool {
        connectedAt[name].map { Date().timeIntervalSince($0) < 5 } ?? false
    }

    /// Device lists change in bursts while AirPods connect; look once things settle.
    private func scheduleDeviceDiff() {
        deviceDiffTask?.cancel()
        deviceDiffTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.diffBluetoothDevices()
        }
    }

    private func diffBluetoothDevices() {
        let current = Dictionary(uniqueKeysWithValues: audio.outputDevices().filter(\.isBluetooth).map { ($0.id, $0.name) })
        let added = current.filter { knownBluetooth[$0.key] == nil }.map(\.value)
        let removed = knownBluetooth.filter { current[$0.key] == nil }.map(\.value)
        knownBluetooth = current
        model.setOutputs(audio.outputDevices())
        for name in added { announceAccessory(name, connected: true) }
        for name in removed { announceAccessory(name, connected: false) }
    }

    private func announceAccessory(_ name: String, connected: Bool) {
        if connected { connectedAt[name] = Date() }
        let display = AccessoryInfo.displayName(name)
        plugins?.emit("accessory", ["name": display, "connected": connected, "model": String(describing: AccessoryInfo.model(name: name))])
        let kind = HUDKind.accessory(name: display, model: AccessoryInfo.model(name: name), connected: connected, battery: nil)
        guard settings.showAccessoryToasts, controller.canShow(kind) else { return }
        lastAccessory = name
        model.showHUD(kind, duration: connected ? 4.2 : 2.8)
        guard connected else { return }

        // Model and battery come from system_profiler a moment later; fill them in place.
        BluetoothInfo.fetch(matching: name) { [weak self] info in
            guard let info else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.lastAccessory == name else { return }
                    self.model.updateHUD(channel: "accessory",
                                         to: .accessory(name: display, model: AccessoryInfo.model(name: name, productID: info.productID),
                                                        connected: true, battery: info.battery))
                }
            }
        }
    }

    // MARK: Actions shared by keys, scroll and hotkeys

    private func nudgeVolume(by delta: Double) {
        guard audio.canControlVolume, delta.isFinite, delta != 0 else { return }
        let target = min(max((audio.volume() ?? 0) + delta, 0), 1)
        audio.setVolume(target)
        model.showHUD(.volume(level: target, muted: audio.isMuted))
    }

    private func perform(_ action: HotkeyAction) {
        guard !controller.userDisabled else { return }
        switch action {
        case .playPause: model.onCommand?(.toggle)
        case .next: model.onCommand?(.next)
        case .previous: model.onCommand?(.previous)
        case .volumeUp: nudgeVolume(by: 1.0 / 16)
        case .volumeDown: nudgeVolume(by: -1.0 / 16)
        case .togglePlayer: if !controller.isSuspended { model.expanded ? model.collapse() : model.expand() }
        }
    }

    func requestAccessibility() {
        installTapWhenTrusted(prompt: true)
    }

    private func refreshOutputs() {
        model.setOutputs(audio.outputDevices())
        model.volume = audio.volume() ?? model.volume
    }

    private func installTapWhenTrusted(prompt: Bool) {
        if interceptor.isRunning { return }
        let options = ["AXTrustedCheckOptionPrompt" as CFString: prompt] as CFDictionary
        if AXIsProcessTrustedWithOptions(options), interceptor.start() { trustTimer?.invalidate(); return }
        // Keep checking so the tap comes alive right after the user grants the permission.
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if AXIsProcessTrusted(), self.interceptor.start() { self.trustTimer?.invalidate() }
            }
        }
    }

    // MARK: Keys

    private func handle(key: SystemKey, down: Bool, isRepeat: Bool, flags: NSEvent.ModifierFlags) -> Bool {
        // Switched off by the user: leave every key to macOS. (In full screen volume and brightness still go to the notch.)
        guard !controller.userDisabled else { return false }

        let fine = flags.contains(.shift) && flags.contains(.option)
        let step = fine ? 1.0 / 64 : 1.0 / 16

        switch key {
        case .soundUp, .soundDown:
            guard interceptEnabled, audio.canControlVolume, controller.canShow(.volume(level: 0, muted: false)) else { return false }
            if down {
                let current = audio.volume() ?? 0
                let snapped = (current / step).rounded() * step
                let target = snapped + (key == .soundUp ? step : -step)
                audio.setVolume(target)
                model.showHUD(.volume(level: min(max(target, 0), 1), muted: audio.isMuted))
            }
            return true

        case .mute:
            guard interceptEnabled, audio.canControlVolume, controller.canShow(.volume(level: 0, muted: false)) else { return false }
            if down, !isRepeat {
                audio.setMuted(!audio.isMuted)
                model.showHUD(.volume(level: audio.volume() ?? 0, muted: audio.isMuted))
            }
            return true

        case .brightnessUp, .brightnessDown:
            guard interceptEnabled, brightness.isAvailable, brightness.pointerOnBuiltIn, controller.canShow(.brightness(level: 0)),
                  let current = brightness.level() else { return false }
            if down {
                let snapped = (current / step).rounded() * step
                let target = min(max(snapped + (key == .brightnessUp ? step : -step), 0), 1)
                brightness.set(target)
                plugins?.emit("brightness", ["level": target])
                model.showHUD(.brightness(level: target))
            }
            return true

        case .play, .next, .previous, .fast, .rewind:
            // The system keeps handling these; we only announce them.
            if down, !isRepeat, settings.showMediaKeyToasts, controller.canShow(.mediaKey(symbol: "", title: "")) {
                let symbol: String, label: String
                switch key {
                case .play: symbol = model.media?.isPlaying == true ? "pause.fill" : "play.fill"; label = L("Oynat / Duraklat", "Play / Pause")
                case .next, .fast: symbol = "forward.fill"; label = L("Sonraki", "Next")
                default: symbol = "backward.fill"; label = L("Önceki", "Previous")
                }
                model.showHUD(.mediaKey(symbol: symbol, title: model.media?.title ?? label), duration: 1.4)
            }
            return false
        }
    }
}
