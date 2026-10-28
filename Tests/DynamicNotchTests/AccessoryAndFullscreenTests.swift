import XCTest
import SwiftUI
@testable import DynamicNotch

final class AccessoryTests: XCTestCase {
    private let profiler = try! JSONSerialization.data(withJSONObject: [
        "SPBluetoothDataType": [[
            "device_connected": [
                ["Ahmet Can’s AirPods Pro": ["device_productID": "0x200E", "device_batteryLevelLeft": "80%", "device_batteryLevelRight": "78%", "device_batteryLevelCase": "55%"]],
                ["AirPods Max": ["device_productID": "0x200A", "device_batteryLevelMain": "64 %"]],
                ["LOGI M240": ["device_minorType": "Mouse"]],
            ],
            "device_not_connected": [["iPhone": [:]]],
        ]]
    ])

    func testParsesBatteryOfEarbudsAndHeadphones() {
        let pro = BluetoothInfo.parse(profiler, matching: "Ahmet Can’s AirPods Pro")
        XCTAssertEqual(pro?.productID, "0x200E")
        XCTAssertEqual(pro?.battery, AccessoryBattery(left: 80, right: 78, box: 55, main: nil))
        XCTAssertEqual(BluetoothInfo.parse(profiler, matching: "airpods max")?.battery, AccessoryBattery(left: nil, right: nil, box: nil, main: 64))
        XCTAssertNil(BluetoothInfo.parse(profiler, matching: "LOGI M240")?.battery)
    }

    func testNotConnectedOrGarbageGivesNil() {
        XCTAssertNil(BluetoothInfo.parse(profiler, matching: "iPhone"))
        XCTAssertNil(BluetoothInfo.parse(Data(), matching: "x"))
        XCTAssertNil(BluetoothInfo.parse(Data("{}".utf8), matching: "x"))
        XCTAssertNil(BluetoothInfo.parse(Data("[1]".utf8), matching: "x"))
    }

    func testModelSymbolsByProductIDAndName() {
        XCTAssertEqual(AccessoryInfo.symbol(name: "Renamed", productID: "0x200E"), "airpods.pro")
        XCTAssertEqual(AccessoryInfo.symbol(name: "Renamed", productID: "0x200a"), "airpods.max")
        XCTAssertEqual(AccessoryInfo.symbol(name: "Ali's AirPods Max"), "airpods.max")
        XCTAssertEqual(AccessoryInfo.symbol(name: "AirPods Pro"), "airpods.pro")
        XCTAssertEqual(AccessoryInfo.symbol(name: "Some AirPods"), "airpods")
        XCTAssertEqual(AccessoryInfo.symbol(name: "JBL Speaker"), "hifispeaker.fill")
        XCTAssertEqual(AccessoryInfo.symbol(name: "Unknown thing", productID: "0xFFFF"), "headphones")
    }

    func testModelDetectionForEveryFamily() {
        XCTAssertEqual(AccessoryInfo.model(name: "x", productID: "0x200E"), .airpodsPro)
        XCTAssertEqual(AccessoryInfo.model(name: "x", productID: "0x2027"), .airpodsPro)
        XCTAssertEqual(AccessoryInfo.model(name: "x", productID: "0x200A"), .airpodsMax)
        XCTAssertEqual(AccessoryInfo.model(name: "x", productID: "0x201F"), .airpodsMax)
        XCTAssertEqual(AccessoryInfo.model(name: "x", productID: "0x2002"), .airpods)
        XCTAssertEqual(AccessoryInfo.model(name: "x", productID: "0x2013"), .airpods3)
        XCTAssertEqual(AccessoryInfo.model(name: "x", productID: "0x2019"), .airpods4)
        XCTAssertEqual(AccessoryInfo.model(name: "x", productID: "0x200B"), .powerbeatsPro)
        XCTAssertEqual(AccessoryInfo.model(name: "Ali's AirPods Max"), .airpodsMax)
        XCTAssertEqual(AccessoryInfo.model(name: "AirPods Pro"), .airpodsPro)
        XCTAssertEqual(AccessoryInfo.model(name: "AirPods (3rd generation)"), .airpods3)
        XCTAssertEqual(AccessoryInfo.model(name: "AirPods 4"), .airpods4)
        XCTAssertEqual(AccessoryInfo.model(name: "AirPods"), .airpods)
        XCTAssertEqual(AccessoryInfo.model(name: "Beats Studio Pro"), .beatsHeadphones)
        XCTAssertEqual(AccessoryInfo.model(name: "Beats Solo4"), .beatsHeadphones)
        XCTAssertEqual(AccessoryInfo.model(name: "Beats Fit Pro"), .beatsFitPro)
        XCTAssertEqual(AccessoryInfo.model(name: "Beats Studio Buds +"), .beatsStudioBuds)
        XCTAssertEqual(AccessoryInfo.model(name: "Powerbeats Pro 2"), .powerbeatsPro)
        XCTAssertEqual(AccessoryInfo.model(name: "Powerbeats3"), .powerbeats)
        XCTAssertEqual(AccessoryInfo.model(name: "Beats Flex"), .beatsEarphones)
        XCTAssertEqual(AccessoryInfo.model(name: "Generic Speaker"), .speaker)
        XCTAssertEqual(AccessoryInfo.model(name: "JBL Tune 770NC"), .jblHeadphones)
        XCTAssertEqual(AccessoryInfo.model(name: "JBL Live 660NC"), .jblHeadphones)
        XCTAssertEqual(AccessoryInfo.model(name: "JBL Quantum 810"), .jblHeadphones)
        XCTAssertEqual(AccessoryInfo.model(name: "JBL Live Buds 3"), .jblEarbuds)
        XCTAssertEqual(AccessoryInfo.model(name: "JBL Tune Buds"), .jblEarbuds)
        XCTAssertEqual(AccessoryInfo.model(name: "JBL Wave 300TWS"), .jblEarbuds)
        for speaker in ["JBL Flip 6", "JBL Charge 5", "JBL Go 3", "JBL Clip 4", "JBL Boombox 3", "JBL PartyBox 310", "JBL Xtreme 4", "JBL Pulse 5"] {
            XCTAssertEqual(AccessoryInfo.model(name: speaker), .jblSpeaker, speaker)
        }
        XCTAssertEqual(AccessoryInfo.model(name: "Galaxy Buds2 Pro"), .earbuds)
        XCTAssertEqual(AccessoryInfo.model(name: "WF-1000XM5"), .earbuds)
        XCTAssertEqual(AccessoryInfo.model(name: "Bose SoundLink Flex"), .speaker)
        XCTAssertEqual(AccessoryInfo.model(name: "WH-1000XM5"), .headphones)
        XCTAssertEqual(AccessoryInfo.model(name: "Sony WH-1000XM5"), .headphones)
        XCTAssertEqual(AccessoryInfo.model(name: "Renamed", productID: "0xFFFF"), .headphones)
    }

    func testEveryModelResolvesToARealSymbol() {
        let all: [AccessoryModel] = [.airpods, .airpods3, .airpods4, .airpodsPro, .airpodsMax, .beatsHeadphones, .beatsEarphones,
                                     .beatsFitPro, .beatsStudioBuds, .powerbeatsPro, .powerbeats, .jblHeadphones, .jblEarbuds, .jblSpeaker,
                                     .earbuds, .headphones, .speaker]
        for model in all {
            XCTAssertNotNil(NSImage(systemSymbolName: model.symbolName, accessibilityDescription: nil), "\(model)")
        }
        XCTAssertEqual(AccessoryModel.airpodsPro.symbolName, "airpods.pro")
        XCTAssertEqual(AccessoryModel.airpodsMax.symbolName, "airpods.max")
    }

    func testJBLUsesItsBrandColourOthersStayWhite() {
        XCTAssertNotNil(AccessoryModel.jblSpeaker.brandTint.flatMap(Color.init(hex:)))
        XCTAssertNotNil(AccessoryModel.jblEarbuds.brandTint)
        XCTAssertNil(AccessoryModel.airpodsPro.brandTint)
        XCTAssertNil(AccessoryModel.beatsHeadphones.brandTint)
    }

    func testSingleBatteryDevicesReportUnderEitherKey() {
        let data = try! JSONSerialization.data(withJSONObject: ["SPBluetoothDataType": [["device_connected": [
            ["JBL Flip 6": ["device_batteryLevel": "55%"]], ["JBL Tune 770NC": ["device_batteryLevelMain": "72 %"]]]]]])
        XCTAssertEqual(BluetoothInfo.parse(data, matching: "JBL Flip 6")?.battery, AccessoryBattery(main: 55))
        XCTAssertEqual(BluetoothInfo.parse(data, matching: "JBL Tune 770NC")?.battery, AccessoryBattery(main: 72))
    }

    func testBatteryIsClampedAndEmptyDetected() {
        XCTAssertTrue(AccessoryBattery().isEmpty)
        XCTAssertEqual(AccessoryBattery(left: 150, right: -4).clamped, AccessoryBattery(left: 100, right: 0, box: nil, main: nil))
    }

    func testDisplayNameDropsOwner() {
        XCTAssertEqual(AccessoryInfo.displayName("Ahmet Can’s AirPods Pro"), "AirPods Pro")
        XCTAssertEqual(AccessoryInfo.displayName("Ali's AirPods Max"), "AirPods Max")
        XCTAssertEqual(AccessoryInfo.displayName("Sony WH-1000XM5"), "Sony WH-1000XM5")
        XCTAssertEqual(AccessoryInfo.displayName("Mom's Speaker"), "Mom's Speaker")
    }
}

@MainActor
final class FullscreenModelTests: XCTestCase {
    private func playing() -> NowPlaying {
        NowPlaying(source: .spotify, title: "t", artist: "", album: "", duration: 10, position: 0, positionDate: Date(), isPlaying: true)
    }

    func testWhichHUDsMayAppearInFullscreen() {
        XCTAssertTrue(HUDKind.volume(level: 0, muted: false).showsInFullscreen)
        XCTAssertTrue(HUDKind.brightness(level: 0).showsInFullscreen)
        XCTAssertTrue(HUDKind.focus(name: "", symbol: "", tint: "", on: true).showsInFullscreen)
        XCTAssertTrue(HUDKind.accessory(name: "", model: .airpods, connected: true, battery: nil).showsInFullscreen)
        XCTAssertFalse(HUDKind.notification(bundleID: "", app: "", title: "", body: "").showsInFullscreen)
        XCTAssertFalse(HUDKind.custom(symbol: "", text: "", level: nil, tint: nil).showsInFullscreen)
        XCTAssertFalse(HUDKind.mediaKey(symbol: "", title: "").showsInFullscreen)
    }

    func testSuppressedPillShowsOnlyThePlainHUDAndThenRests() async {
        let m = NotchModel(geometry: .fallback)
        m.setMedia(playing(), artwork: nil)
        m.expand()
        m.suppressPill = true
        m.reset()
        XCTAssertEqual(m.presentation, .idle, "no pill and no player in full screen")
        XCTAssertTrue(m.isResting)

        m.showHUD(.volume(level: 0.4, muted: false), duration: 0.4)
        XCTAssertFalse(m.hudOverLive, "no media wings in full screen")
        XCTAssertEqual(m.bodySize.width, NotchGeometry.fallback.notchWidth)
        try? await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertTrue(m.isResting, "after the HUD the shape shrinks back and disappears")

        m.suppressPill = false
        XCTAssertEqual(m.presentation, .live)
    }

    func testHUDVisibilityCallbackAndInPlaceUpdate() async {
        let m = NotchModel(geometry: .fallback)
        var events: [Bool] = []
        m.onHUDVisibility = { events.append($0) }
        let full = HUDKind.accessory(name: "AirPods", model: .airpodsPro, connected: true, battery: AccessoryBattery(left: 80))
        m.showHUD(.accessory(name: "AirPods", model: .airpods, connected: true, battery: nil), duration: 0.4)
        m.updateHUD(channel: "accessory", to: full)
        XCTAssertEqual(m.presentation, .hud(full))
        m.updateHUD(channel: "volume", to: .volume(level: 1, muted: false))   // other channel: ignored
        XCTAssertEqual(m.presentation, .hud(full))
        try? await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(events, [true, false])
    }

    func testClosingFadeWaitsForTheSpringToSettle() {
        XCTAssertGreaterThanOrEqual(NotchModel.restFadeDelay, 0.45)
    }
}
