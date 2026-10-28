import XCTest
import SwiftUI
@testable import DynamicNotch

/// Renders the focus and accessory HUDs the way they sit under the notch.
@MainActor
final class FeatureSnapshotTests: XCTestCase {
    func testRender() throws {
        guard let out = ProcessInfo.processInfo.environment["FEATURE_SNAPSHOT"] else { return }
        let nw: CGFloat = 186, nh: CGFloat = 32
        func notch<V: View>(_ height: CGFloat, @ViewBuilder _ content: () -> V) -> some View {
            ZStack(alignment: .top) {
                Color.black
                VStack(spacing: 0) { Spacer().frame(height: nh); content().frame(width: nw, height: height) }
            }
            .frame(width: nw, height: nh + height)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16))
        }
        let accessories: [(String, AccessoryModel, AccessoryBattery?)] = [
            ("AirPods Pro", .airpodsPro, AccessoryBattery(left: 80, right: 78, box: 55)),
            ("AirPods 4", .airpods4, AccessoryBattery(left: 92, right: 18, box: 70)),
            ("AirPods Max", .airpodsMax, AccessoryBattery(main: 64)),
            ("Beats Studio Pro", .beatsHeadphones, nil),
            ("Beats Fit Pro", .beatsFitPro, AccessoryBattery(left: 60, right: 58, box: 35)),
        ]
        let sheet = VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(0..<accessories.count, id: \.self) { i in
                    notch(132) { AccessoryFeature(name: accessories[i].0, model: accessories[i].1, connected: true, battery: accessories[i].2) }
                }
                notch(132) { AccessoryFeature(name: "AirPods Pro", model: .airpodsPro, connected: false, battery: nil) }
            }
            HStack(alignment: .top, spacing: 14) {
                notch(58) { FocusFeature(name: "İş", symbol: "briefcase.fill", tint: "#0A84FF", on: true) }
                notch(58) { FocusFeature(name: "İş", symbol: "briefcase.fill", tint: "#0A84FF", on: false) }
                notch(58) { FocusFeature(name: "Rahatsız Etme", symbol: "moon.fill", tint: "#5E5CE6", on: true) }
                notch(58) { FocusFeature(name: "Uyku", symbol: "bed.double.fill", tint: "#64D2FF", on: true) }
                notch(58) { FocusFeature(name: "Oyun", symbol: "gamecontroller.fill", tint: "#30D158", on: true) }
            }
        }
        .padding(16).background(Color(white: 0.18))
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
