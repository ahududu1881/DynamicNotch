import XCTest
import SwiftUI
@testable import DynamicNotch

/// Complex situations: several things want the notch at once.
@MainActor
final class ArbitrationTests: XCTestCase {
    private let lowBattery = HUDKind.power(percent: 20, charging: false, plugged: false)
    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    func testBatteryWarningDuringTouchIDWaitsAndTouchIDSuccessIsNeverDelayed() async {
        let m = NotchModel(geometry: .fallback)
        m.showHUD(.touchID(.waiting), duration: 30)
        m.showHUD(lowBattery, duration: 0.6)
        XCTAssertEqual(m.presentation, .hud(.touchID(.waiting)), "the battery warning must not push the Touch ID dialog aside")
        XCTAssertEqual(m.queuedHUDCount, 1)

        m.showHUD(.touchID(.success), duration: 0.5)
        XCTAssertEqual(m.presentation, .hud(.touchID(.success)), "the success animation shows right away")

        await sleep(1.1)   // success is over; the battery warning takes its turn
        XCTAssertEqual(m.presentation, .hud(lowBattery))
    }

    func testTouchIDPreemptsABatteryWarningWhichThenResumes() async {
        let m = NotchModel(geometry: .fallback)
        m.showHUD(lowBattery, duration: 5)
        m.showHUD(.touchID(.waiting), duration: 30)
        XCTAssertEqual(m.presentation, .hud(.touchID(.waiting)))
        XCTAssertEqual(m.queuedHUDCount, 1, "the interrupted warning is kept")

        m.showHUD(.touchID(.success), duration: 0.4)
        await sleep(1.0)
        XCTAssertEqual(m.presentation, .hud(lowBattery))
    }

    func testCancelledTouchIDLetsQueuedItemsContinue() async {
        let m = NotchModel(geometry: .fallback)
        m.showHUD(.touchID(.waiting), duration: 30)
        m.showHUD(lowBattery, duration: 5)
        m.dismissHUD(channel: "touchid")
        await sleep(0.6)
        XCTAssertEqual(m.presentation, .hud(lowBattery))
    }

    func testTouchIDWaitingIsNeverQueuedBehindSomethingElse() {
        let m = NotchModel(geometry: .fallback)
        m.showHUD(lowBattery, duration: 5)
        m.showHUD(.notification(bundleID: "x", app: "A", title: "t", body: "b"), duration: 5, id: "n")
        m.showHUD(.touchID(.waiting), duration: 30)
        XCTAssertEqual(m.presentation, .hud(.touchID(.waiting)))
    }

    func testSecondCriticalItemDoesNotReplaceTheFirst() {
        let m = NotchModel(geometry: .fallback)
        m.showHUD(.power(percent: 10, charging: false, plugged: false), duration: 5)
        m.showHUD(.touchID(.waiting), duration: 30)     // immediate
        m.showHUD(.power(percent: 5, charging: false, plugged: false), duration: 5)   // same channel as the queued one
        XCTAssertEqual(m.presentation, .hud(.touchID(.waiting)))
        XCTAssertEqual(m.queuedHUDCount, 1, "same-channel warnings collapse into one queued entry")
    }

    func testBatteryAndNotificationCardsAreTallAndNeverInline() {
        let np = NowPlaying(source: .spotify, title: "t", artist: "", album: "", duration: 10, position: 0, positionDate: Date(), isPlaying: true)
        for kind in [lowBattery, HUDKind.notification(bundleID: "x", app: "A", title: "t", body: "b")] {
            let m = NotchModel(geometry: .fallback)
            m.setMedia(np, artwork: nil)
            m.expand()
            m.showHUD(kind, duration: 5, id: "x")
            XCTAssertEqual(m.presentation, .hud(kind), "cards replace the player instead of an invisible inline row")
            XCTAssertNil(m.inlineHUD)
            XCTAssertEqual(m.bodySize.width, NotchModel.notificationWidth)
            XCTAssertEqual(m.bodySize.height, NotchGeometry.fallback.notchHeight + kind.cardHeight)
        }
    }

    func testTappingTheBatteryCardOpensBatterySettings() {
        let m = NotchModel(geometry: .fallback)
        var opened = false
        m.onOpenBatterySettings = { opened = true }
        m.showHUD(lowBattery, duration: 5)
        m.primaryClick()
        XCTAssertTrue(opened)
        XCTAssertEqual(m.presentation, .idle)
    }

    func testVolumeStillShowsOverTheBatteryWarningButTheWarningResumes() async {
        let m = NotchModel(geometry: .fallback)
        m.showHUD(lowBattery, duration: 3)
        m.showHUD(.volume(level: 0.5, muted: false), duration: 0.4)
        XCTAssertEqual(m.presentation, .hud(.volume(level: 0.5, muted: false)))
        await sleep(1.0)
        XCTAssertEqual(m.presentation, .hud(lowBattery))
    }

    func testRandomStormNeverBreaksInvariants() async {
        let m = NotchModel(geometry: .fallback)
        let kinds: [HUDKind] = [lowBattery, .touchID(.waiting), .touchID(.success), .volume(level: 0.3, muted: false),
                                .brightness(level: 0.6), .accessory(name: "AirPods", model: .airpods, connected: true, battery: nil),
                                .focus(name: "Work", symbol: "moon.fill", tint: "#0A84FF", on: true),
                                .notification(bundleID: "a", app: "A", title: "t", body: "b"),
                                .custom(symbol: "star", text: "x", level: nil, tint: nil)]
        for i in 0..<400 {
            m.showHUD(kinds[i % kinds.count], duration: Double.random(in: 0.3...1.0), id: i % 3 == 0 ? "id\(i % 5)" : nil)
            if i % 9 == 0 { m.dismissHUD(channel: "touchid") }
            if i % 13 == 0 { m.reset() }
            XCTAssertLessThanOrEqual(m.queuedHUDCount, NotchModel.maxQueuedHUDs)
            XCTAssertTrue(m.bodySize.width.isFinite && m.bodySize.height.isFinite)
        }
        await sleep(12)   // everything drains
        XCTAssertEqual(m.queuedHUDCount, 0)
        XCTAssertEqual(m.presentation, .idle)
    }
}

@MainActor
final class PowerCardSnapshotTests: XCTestCase {
    func testRenderBatteryCards() throws {
        guard let out = ProcessInfo.processInfo.environment["POWERCARD_SNAPSHOT"] else { return }
        func card(_ p: Int, _ c: Bool, _ plugged: Bool) -> some View {
            PowerCard(percent: p, charging: c, plugged: plugged)
                .frame(width: 372 - 44, height: 56)
                .padding(.vertical, 12).padding(.horizontal, 22)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        }
        let sheet = VStack(spacing: 8) { card(20, false, false); card(5, false, false); card(78, true, true); card(60, false, false) }
            .padding(10).background(Color(white: 0.2))
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: out))
    }
}

@MainActor
final class RippleSnapshotTests: XCTestCase {
    func testRenderRippleFrames() throws {
        guard let out = ProcessInfo.processInfo.environment["RIPPLE_SNAPSHOT"] else { return }
        let red = Color(red: 1.0, green: 0.27, blue: 0.30)
        let phases: [Double] = [0, 0.15, 0.3, 0.45, 0.6, 0.75, 0.9]
        let sheet = HStack(spacing: 8) {
            ForEach(phases, id: \.self) { p in
                BatteryCapsuleBody(percent: 20, tint: red, charging: false, ripples: [p, (p + 0.5).truncatingRemainder(dividingBy: 1)])
                    .padding(10).background(Color.black).clipShape(RoundedRectangle(cornerRadius: 22))
            }
        }
        .padding(10).background(Color(white: 0.2))
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: out))
    }
}
