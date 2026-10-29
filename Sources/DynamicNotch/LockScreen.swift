import AppKit
import SwiftUI

/// Reports the screen locking and unlocking.
final class LockScreenMonitor {
    var onChange: ((Bool) -> Void)?
    private(set) var isLocked = false
    private var observers: [NSObjectProtocol] = []

    func start() {
        isLocked = Self.currentlyLocked()
        let center = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                guard let self, self.isLocked != locked else { return }
                self.isLocked = locked
                self.onChange?(locked)
            })
        }
    }

    static func currentlyLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}

/// The few private SkyLight calls that put a window above the lock screen. Every symbol is looked up at run time;
/// when one is missing (a macOS update renamed it) the notch simply is not drawn on the lock screen.
struct SkyLightSpaces {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CreateSpace = @convention(c) (Int32, Int32, UnsafeRawPointer?) -> UInt64
    private typealias SetLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias SpaceList = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32
    private typealias DestroySpace = @convention(c) (Int32, UInt64) -> Int32

    private let connection: Int32
    private let create: CreateSpace
    private let setLevel: SetLevel
    private let show: SpaceList
    private let hide: SpaceList
    private let add: AddWindows
    private let destroy: DestroySpace

    init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let main = dlsym(handle, "SLSMainConnectionID"), let create = dlsym(handle, "SLSSpaceCreate"),
              let level = dlsym(handle, "SLSSpaceSetAbsoluteLevel"), let show = dlsym(handle, "SLSShowSpaces"),
              let hide = dlsym(handle, "SLSHideSpaces"), let add = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces"),
              let destroy = dlsym(handle, "SLSSpaceDestroy")
        else { return nil }
        connection = unsafeBitCast(main, to: MainConnection.self)()
        self.create = unsafeBitCast(create, to: CreateSpace.self)
        setLevel = unsafeBitCast(level, to: SetLevel.self)
        self.show = unsafeBitCast(show, to: SpaceList.self)
        self.hide = unsafeBitCast(hide, to: SpaceList.self)
        self.add = unsafeBitCast(add, to: AddWindows.self)
        self.destroy = unsafeBitCast(destroy, to: DestroySpace.self)
    }

    /// A new space that sits above everything, the lock screen included.
    func makeTopSpace() -> UInt64 {
        let space = create(connection, 1, nil)
        _ = setLevel(connection, space, 2_147_483_647)
        return space
    }

    func place(window number: Int, in space: UInt64) {
        _ = add(connection, space, [number] as CFArray, 7)
        _ = show(connection, [space] as CFArray)
    }

    func remove(_ space: UInt64) {
        _ = hide(connection, [space] as CFArray)
        _ = destroy(connection, space)
    }
}

/// Draws the notch on the lock screen: a second panel that shares the model and lives in a top-level space
/// for as long as the screen is locked.
@MainActor
final class LockScreenPresenter {
    private let sky = SkyLightSpaces()
    private var panel: NotchPanel?
    private var space: UInt64 = 0

    var isAvailable: Bool { sky != nil }

    func show(model: NotchModel, frame: NSRect) {
        guard let sky else { return }
        hide()
        let panel = NotchPanel(frame: frame)
        let host = NSHostingView(rootView: NotchRootView(model: model))
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        space = sky.makeTopSpace()
        sky.place(window: panel.windowNumber, in: space)
        self.panel = panel
    }

    func hide() {
        guard let panel else { return }
        sky?.remove(space)
        panel.orderOut(nil)
        panel.close()
        self.panel = nil
        space = 0
    }
}
