import XCTest
import SwiftUI
@testable import DynamicNotch

/// Renders the card and wing-pill HUDs with the real notch view, over a stand-in wallpaper.
@MainActor
final class FeatureSnapshotTests: XCTestCase {
    private func shot(_ setup: (NotchModel) -> Void) -> some View {
        let model = NotchModel(geometry: .fallback)
        setup(model)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.55, green: 0.6, blue: 0.7), Color(red: 0.85, green: 0.87, blue: 0.9)], startPoint: .top, endPoint: .bottom)
            NotchRootView(model: model)
        }
        .frame(width: 400, height: 130)
    }

    func testRender() throws {
        guard let out = ProcessInfo.processInfo.environment["FEATURE_SNAPSHOT"] else { return }
        Settings.shared.language = AppLanguage.en.rawValue
        defer { Settings.shared.language = AppLanguage.system.rawValue }
        let timer = Activity(id: "tea", symbol: "timer", text: "Timer", subtitle: nil, level: nil, tint: "#FF9F0A",
                             startDate: Date(), endDate: Date().addingTimeInterval(117), expires: Date().addingTimeInterval(3600))
        let sheet = VStack(spacing: 10) {
            HStack(spacing: 10) {
                shot { $0.showHUD(.accessory(name: "AirPods Pro", model: .airpodsPro, connected: true, battery: AccessoryBattery(left: 80, right: 78, box: 55)), duration: 600) }
                shot { $0.showHUD(.accessory(name: "AirPods Pro", model: .airpodsPro, connected: true, battery: nil), duration: 600) }
            }
            HStack(spacing: 10) {
                shot { $0.showHUD(.accessory(name: "Beats Studio Pro", model: .beatsHeadphones, connected: true, battery: AccessoryBattery(main: 14)), duration: 600) }
                shot { $0.showHUD(.accessory(name: "AirPods Max", model: .airpodsMax, connected: false, battery: nil), duration: 600) }
            }
            HStack(spacing: 10) {
                shot { $0.upsertActivity(timer) }
                shot { $0.showHUD(.focus(name: "Work", symbol: "moon.fill", tint: "#5E5CE6", on: true), duration: 600) }
            }
            HStack(spacing: 10) {
                shot { $0.showHUD(.focus(name: "Work", symbol: "moon.fill", tint: "#5E5CE6", on: false), duration: 600) }
                shot { $0.showHUD(.custom(symbol: "link", text: "", level: nil, tint: "#34C759"), duration: 600) }
            }
            HStack(spacing: 10) {
                shot { $0.showHUD(.lock(locked: true), duration: 600) }
                shot { $0.showHUD(.lock(locked: false), duration: 600) }
            }
        }
        .padding(12).background(Color(white: 0.12))
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: out))
    }
}

@MainActor
final class LevelSnapshotTests: XCTestCase {
    func testRender() throws {
        guard let out = ProcessInfo.processInfo.environment["LEVEL_SNAPSHOT"] else { return }
        let nw: CGFloat = 186, nh: CGFloat = 32
        func notch(_ kind: HUDKind) -> some View {
            ZStack(alignment: .top) {
                Color.black
                VStack(spacing: 0) {
                    Spacer().frame(height: nh)
                    HUDRow(kind: kind).padding(.horizontal, 20).frame(width: nw, height: NotchModel.hudRow)
                }
            }
            .frame(width: nw, height: nh + NotchModel.hudRow)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16))
        }
        let sheet = VStack(spacing: 12) {
            HStack(spacing: 12) {
                notch(.volume(level: 0.0, muted: true)); notch(.volume(level: 0.2, muted: false)); notch(.volume(level: 0.55, muted: false)); notch(.volume(level: 1, muted: false))
            }
            HStack(spacing: 12) {
                notch(.brightness(level: 0.1)); notch(.brightness(level: 0.4)); notch(.brightness(level: 0.75)); notch(.brightness(level: 1))
            }
        }
        .padding(14).background(Color(white: 0.2))
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.nsImage)
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: out))
    }
}

@MainActor
final class OutputSnapshotTests: XCTestCase {
    func testRender() throws {
        guard let out = ProcessInfo.processInfo.environment["OUTPUT_SNAPSHOT"] else { return }
        func picker(_ list: [AudioOutput]) -> some View {
            let m = NotchModel(geometry: .fallback)
            m.setOutputs(list)
            return OutputPickerView(model: m)
                .frame(width: NotchModel.expandedWidth - 40,
                       height: m.pickerHeight - NotchModel.outputTopGap - NotchModel.outputBottomGap)
                .padding(.horizontal, 20).padding(.top, NotchModel.outputTopGap).padding(.bottom, NotchModel.outputBottomGap + 14)
                .background(Color.black)
        }
        let two = [AudioOutput(id: 1, name: "neediiyoooluum", symbol: "headphones", isDefault: false, isBluetooth: true),
                   AudioOutput(id: 2, name: "MacBook Pro Hoparlörü", symbol: "laptopcomputer", isDefault: true)]
        let many = two + [AudioOutput(id: 3, name: "LG UltraFine Display", symbol: "display", isDefault: false),
                          AudioOutput(id: 4, name: "Salon HomePod", symbol: "airplayaudio", isDefault: false),
                          AudioOutput(id: 5, name: "AirPods Pro", symbol: "airpods.pro", isDefault: false, isBluetooth: true)]
        let sheet = HStack(alignment: .top, spacing: 14) { picker(two); picker(Array(many.prefix(4))) }
            .padding(14).background(Color(white: 0.2))
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: out))
    }
}
