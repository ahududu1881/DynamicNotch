import XCTest
import SwiftUI
@testable import DynamicNotch

/// Renders the README visuals (docs/hero.jpg and docs/features/*.jpg) from the app's real views.
/// Run with `MARKETING_SNAPSHOT=docs swift test --filter MarketingSnapshotTests`.
@MainActor
final class MarketingSnapshotTests: XCTestCase {
    // MARK: Staging

    private static func hex(_ value: String) -> Color { Color(hex: value) ?? .black }

    private struct Palette {
        var top: Color, bottom: Color, glowA: Color, glowB: Color
    }

    private static let palettes: [String: Palette] = [
        "violet": Palette(top: MarketingSnapshotTests.hex("#2B2FC0"), bottom: MarketingSnapshotTests.hex("#FF5E9C"), glowA: MarketingSnapshotTests.hex("#3CC8FF"), glowB: MarketingSnapshotTests.hex("#FFB066")),
        "ocean": Palette(top: MarketingSnapshotTests.hex("#0B3A8F"), bottom: MarketingSnapshotTests.hex("#16C1B5"), glowA: MarketingSnapshotTests.hex("#6C7BFF"), glowB: MarketingSnapshotTests.hex("#B6FF9A")),
        "sunset": Palette(top: MarketingSnapshotTests.hex("#5B2A9A"), bottom: MarketingSnapshotTests.hex("#FF8A4C"), glowA: MarketingSnapshotTests.hex("#FF4F8B"), glowB: MarketingSnapshotTests.hex("#FFD36E")),
        "forest": Palette(top: MarketingSnapshotTests.hex("#0F4C5C"), bottom: MarketingSnapshotTests.hex("#6FCF97"), glowA: MarketingSnapshotTests.hex("#2D9CDB"), glowB: MarketingSnapshotTests.hex("#F2E394")),
        "ember": Palette(top: MarketingSnapshotTests.hex("#3A1C71"), bottom: MarketingSnapshotTests.hex("#FF512F"), glowA: MarketingSnapshotTests.hex("#D76D77"), glowB: MarketingSnapshotTests.hex("#FFAF7B")),
        "ice": Palette(top: MarketingSnapshotTests.hex("#1D2B64"), bottom: MarketingSnapshotTests.hex("#6DD5FA"), glowA: MarketingSnapshotTests.hex("#9B8CFF"), glowB: MarketingSnapshotTests.hex("#E0F7FF")),
    ]

    private func wallpaper(_ name: String) -> some View {
        let p = Self.palettes[name]!
        return ZStack {
            LinearGradient(colors: [p.top, p.bottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [p.glowA.opacity(0.65), .clear], center: UnitPoint(x: 0.12, y: 0.65), startRadius: 0, endRadius: 360)
            RadialGradient(colors: [p.glowB.opacity(0.7), .clear], center: UnitPoint(x: 0.9, y: 0.95), startRadius: 0, endRadius: 400)
        }
    }

    /// A faint menu bar: abstract menu titles on the left, status icons and the time on the right.
    private func menuBar(height: CGFloat, items: Bool = true) -> some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.28))
            if items { HStack(spacing: 14) {
                HStack(spacing: 10) {
                    ForEach([34, 26, 30, 28], id: \.self) { w in
                        Capsule().fill(Color.white.opacity(0.3)).frame(width: CGFloat(w), height: 5)
                    }
                }
                Spacer()
                HStack(spacing: 11) {
                    Image(systemName: "wifi")
                    Image(systemName: "battery.100")
                    Image(systemName: "magnifyingglass")
                    Text("9:41").font(.system(size: 12, weight: .medium)).fixedSize()
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 16) }
        }
        .frame(height: height)
    }

    private func albumArt() -> NSImage {
        NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            let gradient = NSGradient(colors: [NSColor(red: 1.0, green: 0.36, blue: 0.5, alpha: 1),
                                               NSColor(red: 0.45, green: 0.25, blue: 0.95, alpha: 1),
                                               NSColor(red: 0.1, green: 0.12, blue: 0.45, alpha: 1)])!
            gradient.draw(in: rect, angle: 280)
            NSColor(red: 1, green: 0.85, blue: 0.5, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 70, y: 70, width: 116, height: 116)).fill()
            NSColor(red: 0.1, green: 0.1, blue: 0.35, alpha: 0.85).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 256, height: 96)).fill()
            NSColor.white.withAlphaComponent(0.25).setFill()
            for i in 0..<4 { NSBezierPath(rect: NSRect(x: 0, y: 14 + CGFloat(i) * 20, width: 256, height: 4)).fill() }
            return true
        }
    }

    private func nowPlaying(playing: Bool = true) -> NowPlaying {
        NowPlaying(source: .music, title: "Neon Skyline", artist: "Kora Vale", album: "Afterglow",
                   duration: 214, position: 87, positionDate: Date(), isPlaying: playing)
    }

    private func makeModel(_ setup: (NotchModel) -> Void) -> NotchModel {
        let model = NotchModel(geometry: .fallback)
        setup(model)
        // Let the model's own "settled" bookkeeping run so the shape is drawn.
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        return model
    }

    private func png(_ view: some View, scale: CGFloat, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.nsImage)
        let data = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
            .representation(using: .jpeg, properties: [.compressionFactor: 0.9]))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    // MARK: Tiles

    private let tileSize = CGSize(width: 640, height: 380)

    private func caption(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 5) {
            Text(title).font(.system(size: 21, weight: .semibold))
            Text(detail).font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.75))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.25), radius: 6, y: 1)
        .multilineTextAlignment(.center)
        .frame(height: 70)
    }

    /// A zoomed shot of the top of the screen: the menu bar and the notch scale together, like a magnified screenshot.
    private func tile<Notch: View>(_ palette: String, zoom: CGFloat, _ title: String, _ detail: String,
                                   @ViewBuilder notch: () -> Notch) -> some View {
        let width = tileSize.width / zoom, height = tileSize.height / zoom
        return ZStack(alignment: .top) {
            wallpaper(palette)
            ZStack(alignment: .top) {
                VStack(spacing: 0) { menuBar(height: 32, items: width >= 560); Spacer() }
                notch().frame(width: width, height: height, alignment: .top)
            }
            .frame(width: width, height: height, alignment: .top)
            .scaleEffect(zoom, anchor: .top)
            .frame(width: tileSize.width, height: tileSize.height, alignment: .top)
            VStack { Spacer(); caption(title, detail).padding(.bottom, 14) }
        }
        .frame(width: tileSize.width, height: tileSize.height)
    }

    private func model(_ view: NotchModel) -> some View { NotchRootView(model: view) }

    func testRenderMarketing() throws {
        guard let dir = ProcessInfo.processInfo.environment["MARKETING_SNAPSHOT"] else { return }
        // Settings.shared owns the language override, so go through it (and put it back afterwards).
        Settings.shared.language = AppLanguage.en.rawValue
        defer { Settings.shared.language = AppLanguage.system.rawValue }
        let root = URL(fileURLWithPath: dir)
        let features = root.appendingPathComponent("features")
        let art = albumArt()
        let outputs = [AudioOutput(id: 1, name: "Studio Headphones", symbol: "headphones", isDefault: false, isBluetooth: true),
                       AudioOutput(id: 2, name: "MacBook Pro Speakers", symbol: "laptopcomputer", isDefault: true),
                       AudioOutput(id: 3, name: "Living Room", symbol: "airplayaudio", isDefault: false)]

        // Now playing pill and the title strip.
        let pill = makeModel { $0.setMedia(self.nowPlaying(), artwork: art) }
        try png(tile("violet", zoom: 2.1, "Live media", "Whatever is playing, right in the notch") { model(pill) },
                scale: 2, to: features.appendingPathComponent("pill.jpg"))

        // Expanded player with the output picker.
        let player = makeModel { m in m.setMedia(self.nowPlaying(), artwork: art); m.setOutputs(outputs); m.expand() }
        try png(tile("sunset", zoom: 1.15, "Full player", "Progress, controls and one click to switch the output") { model(player) },
                scale: 2, to: features.appendingPathComponent("player.jpg"))
        let picker = makeModel { m in
            m.setMedia(self.nowPlaying(), artwork: art); m.setOutputs(outputs); m.expand(); m.showOutputs = true
        }
        try png(tile("ocean", zoom: 0.82, "Output picker", "Pick speakers, AirPlay or headphones without leaving the notch") { model(picker) },
                scale: 2, to: features.appendingPathComponent("outputs.jpg"))

        // System HUDs.
        let volume = makeModel { $0.showHUD(.volume(level: 0.62, muted: false), duration: 600) }
        try png(tile("ice", zoom: 2.2, "Volume", "Replaces the macOS volume overlay") { model(volume) },
                scale: 2, to: features.appendingPathComponent("volume.jpg"))
        let brightness = makeModel { $0.showHUD(.brightness(level: 0.78), duration: 600) }
        try png(tile("sunset", zoom: 2.2, "Brightness", "Rays that follow the level") { model(brightness) },
                scale: 2, to: features.appendingPathComponent("brightness.jpg"))

        // Accessories.
        let airpods = makeModel {
            $0.showHUD(.accessory(name: "AirPods Pro", model: .airpodsPro, connected: true,
                                  battery: AccessoryBattery(left: 82, right: 80, box: 64)), duration: 600)
        }
        try png(tile("ice", zoom: 1.6, "AirPods and Beats", "Connect cards with the battery of each bud and the case") { model(airpods) },
                scale: 2, to: features.appendingPathComponent("airpods.jpg"))

        // Notifications.
        let notification = makeModel {
            $0.showHUD(.notification(bundleID: "com.apple.MobileSMS", app: "Messages", title: "Sam",
                                     body: "Are we still on for tonight? I booked the table for 8."), duration: 600)
        }
        try png(tile("forest", zoom: 1.6, "Notifications", "Messages, WhatsApp, Instagram and more, mirrored in the notch") { model(notification) },
                scale: 2, to: features.appendingPathComponent("notifications.jpg"))

        // Low battery.
        let battery = makeModel { $0.showHUD(.power(percent: 20, charging: false, plugged: false), duration: 600) }
        try png(tile("ember", zoom: 1.6, "Low battery", "An iPhone-style card with a pulsing ring") { model(battery) },
                scale: 2, to: features.appendingPathComponent("battery.jpg"))

        // Focus.
        let focus = makeModel { $0.showHUD(.focus(name: "Work", symbol: "briefcase.fill", tint: "#0A84FF", on: true), duration: 600) }
        try png(tile("ocean", zoom: 2.2, "Focus", "Mode name, icon and colour when it switches") { model(focus) },
                scale: 2, to: features.appendingPathComponent("focus.jpg"))

        // Screen recording.
        let recording = makeModel {
            $0.upsertActivity(Activity(id: Activity.recordingID, symbol: "record.circle.fill", text: "Screen recording",
                                       subtitle: nil, level: nil, tint: "#FF3B30", startDate: Date().addingTimeInterval(-754),
                                       endDate: nil, expires: .distantFuture, countsUp: true))
        }
        try png(tile("violet", zoom: 2.1, "Screen recording", "A red dot and a timer while you record") { model(recording) },
                scale: 2, to: features.appendingPathComponent("recording.jpg"))

        // Plugin card.
        let card = makeModel {
            $0.showHUD(.card(symbol: "shippingbox.fill", title: "Deploy finished", subtitle: "v2.4 is live in production",
                             tint: "#0A84FF", url: nil), duration: 600)
        }
        try png(tile("sunset", zoom: 1.6, "Plugins", "Write your own in JavaScript") { model(card) },
                scale: 2, to: features.appendingPathComponent("plugins.jpg"))

        // Touch ID: the finished check inside its ring (drawn at a fixed point of the real animation).
        let nw: CGFloat = 186, nh: CGFloat = 32, th = NotchModel.touchIDHeight
        let touchID = ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24).fill(Color.black)
            Canvas { gc, size in
                let base = Date(timeIntervalSinceReferenceDate: 1_000)
                TouchIDScan.draw(&gc, size: size, now: base.addingTimeInterval(1.9), appeared: base, successAt: base.addingTimeInterval(0))
            }
            .frame(width: 58, height: 58)
            .offset(y: nh + 8)
        }
        .frame(width: nw, height: nh + th)
        try png(tile("forest", zoom: 2.0, "Touch ID", "A Face ID style animation that ends in a check") { touchID },
                scale: 2, to: features.appendingPathComponent("touchid.jpg"))

        try renderHero(to: root.appendingPathComponent("hero.jpg"), art: art, outputs: outputs)
    }

    // MARK: Hero

    private func renderHero(to url: URL, art: NSImage, outputs: [AudioOutput]) throws {
        let player = makeModel { m in m.setMedia(self.nowPlaying(), artwork: art); m.setOutputs(outputs); m.expand() }
        let size = CGSize(width: 880, height: 470)
        let hero = ZStack(alignment: .top) {
            wallpaper("violet")
            VStack(spacing: 0) { menuBar(height: 32); Spacer() }
            NotchRootView(model: player).frame(width: size.width, height: 260, alignment: .top)
            VStack(spacing: 10) {
                Spacer()
                HStack(spacing: 16) {
                    Image(nsImage: NSImage(contentsOfFile: "docs/icon.png") ?? NSImage())
                        .resizable().frame(width: 64, height: 64)
                    Text("Dynamic Notch").font(.system(size: 56, weight: .bold, design: .rounded))
                }
                Text("Your MacBook's notch, reimagined as a Dynamic Island.")
                    .font(.system(size: 21, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 8) {
                    ForEach(["macOS 14+", "Open source", "MIT"], id: \.self) { label in
                        Text(label).font(.system(size: 12.5, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.18)))
                            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
                    }
                }
                .padding(.top, 4)
                Spacer().frame(height: 30)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.22), radius: 8, y: 2)
        }
        .frame(width: size.width, height: size.height)
        try png(hero, scale: 2, to: url)
    }
}
