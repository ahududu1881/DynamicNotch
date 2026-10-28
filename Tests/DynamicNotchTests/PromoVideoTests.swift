import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import DynamicNotch

/// Renders the frames of the promo video (docs/promo.mp4) from the app's real views.
///
///     PROMO_DIR=/tmp/frames swift test --filter PromoVideoTests
///     ffmpeg -framerate 30 -i /tmp/frames/frame_%05d.jpg -c:v libx264 -pix_fmt yuv420p -crf 18 docs/promo.mp4
///
/// Every frame is a pure function of time: the notch morphs between the app's real states the way the Dynamic Island does
/// (the shape grows with a light spring while the old content blurs out and the new content blurs in), and the clock
/// that drives waveforms, timers and ripples (`ViewClock`) is the video's own.
/// PROMO_RANGE="120-240" renders only those frames, PROMO_FPS changes the frame rate (default 30).
@MainActor
final class PromoVideoTests: XCTestCase {
    // MARK: Scene model

    struct Spec {
        var size: CGSize
        var top: CGFloat
        var bottom: CGFloat
        var content: AnyView
    }

    struct PromoScene {
        var line1: String
        var line2: String
        var duration: Double
        var zoom: CGFloat
        var palette: String
        var spec: (Double) -> Spec
    }

    private let frameSize = CGSize(width: 960, height: 540)
    private let clockBase = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let nw: CGFloat = 186, nh: CGFloat = 32

    private static func hex(_ value: String) -> Color { Color(hex: value) ?? .black }

    private static let palettes: [String: [Color]] = [
        "violet": [hex("#2B2FC0"), hex("#FF5E9C"), hex("#3CC8FF"), hex("#FFB066")],
        "ocean": [hex("#0B3A8F"), hex("#16C1B5"), hex("#6C7BFF"), hex("#B6FF9A")],
        "sunset": [hex("#5B2A9A"), hex("#FF8A4C"), hex("#FF4F8B"), hex("#FFD36E")],
        "forest": [hex("#0F4C5C"), hex("#6FCF97"), hex("#2D9CDB"), hex("#F2E394")],
        "ember": [hex("#3A1C71"), hex("#FF512F"), hex("#D76D77"), hex("#FFAF7B")],
        "ice": [hex("#1D2B64"), hex("#6DD5FA"), hex("#9B8CFF"), hex("#E0F7FF")],
        "night": [hex("#0B0B1E"), hex("#3A1C71"), hex("#2B2FC0"), hex("#FF5E9C")],
    ]

    // MARK: Math

    private func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(max(x, lo), hi) }
    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
    private func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    /// A lightly under-damped spring from 0 to 1: grows fast, overshoots a hair, settles.
    private func spring(_ x: Double) -> Double { x >= 1 ? 1 : 1 - exp(-5.2 * x) * cos(3.3 * x) }

    private func mix(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let x = NSColor(a).usingColorSpace(.sRGB)!, y = NSColor(b).usingColorSpace(.sRGB)!
        return Color(red: lerp(Double(x.redComponent), Double(y.redComponent), t),
                     green: lerp(Double(x.greenComponent), Double(y.greenComponent), t),
                     blue: lerp(Double(x.blueComponent), Double(y.blueComponent), t))
    }

    // MARK: Staging

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

    private func nowPlaying() -> NowPlaying {
        NowPlaying(source: .music, title: "Neon Skyline", artist: "Kora Vale", album: "Afterglow",
                   duration: 214, position: 40, positionDate: clockBase, isPlaying: true)
    }

    private func makeModel(_ setup: (NotchModel) -> Void) -> NotchModel {
        let model = NotchModel(geometry: .fallback)
        setup(model)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return model
    }

    private func spec(of model: NotchModel) -> Spec {
        Spec(size: model.bodySize, top: model.topRadius, bottom: model.bottomRadius,
             content: AnyView(NotchContent(model: model, size: model.bodySize)))
    }

    private var idleSpec: Spec { Spec(size: CGSize(width: nw, height: nh), top: 0, bottom: 8, content: AnyView(Color.clear)) }

    /// A volume / brightness row laid out exactly like the notch lays out its HUD strip.
    private func hudSpec(_ kind: HUDKind) -> Spec {
        let size = CGSize(width: nw, height: nh + NotchModel.hudRow)
        let content = ZStack(alignment: .topLeading) {
            HUDRow(kind: kind).padding(.horizontal, 20).frame(width: size.width, height: NotchModel.hudRow).offset(y: nh)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        return Spec(size: size, top: 0, bottom: 16, content: AnyView(content))
    }

    private func touchIDSpec(local: Double) -> Spec {
        let size = CGSize(width: nw, height: nh + NotchModel.touchIDHeight)
        let ref = clockBase
        let successAt = 1.9
        let canvas = Canvas { gc, canvasSize in
            TouchIDScan.draw(&gc, size: canvasSize, now: ref.addingTimeInterval(local), appeared: ref,
                             successAt: local >= successAt ? ref.addingTimeInterval(successAt) : nil)
        }
        .frame(width: 58, height: 58)
        .offset(x: size.width / 2 - 29, y: nh + 8)
        let content = ZStack(alignment: .topLeading) { canvas }.frame(width: size.width, height: size.height, alignment: .topLeading)
        return Spec(size: size, top: 0, bottom: 24, content: AnyView(content))
    }

    private func buildScenes() -> [PromoScene] {
        let art = albumArt()
        let outputs = [AudioOutput(id: 1, name: "Studio Headphones", symbol: "headphones", isDefault: false, isBluetooth: true),
                       AudioOutput(id: 2, name: "MacBook Pro Speakers", symbol: "laptopcomputer", isDefault: true),
                       AudioOutput(id: 3, name: "Living Room", symbol: "airplayaudio", isDefault: false)]

        // The strip stays up for the whole render (its real timer would otherwise retract it).
        Settings.shared.titleStripSeconds = 3600
        let pillStrip = makeModel { $0.setMedia(self.nowPlaying(), artwork: art) }
        Settings.shared.showTitleStrip = false
        let pill = makeModel { $0.setMedia(self.nowPlaying(), artwork: art) }
        let player = makeModel { m in m.setMedia(self.nowPlaying(), artwork: art); m.setOutputs(outputs); m.expand() }
        let picker = makeModel { m in
            m.setMedia(self.nowPlaying(), artwork: art); m.setOutputs(outputs); m.expand(); m.showOutputs = true
        }
        let airpods = makeModel {
            $0.showHUD(.accessory(name: "AirPods Pro", model: .airpodsPro, connected: true,
                                  battery: AccessoryBattery(left: 82, right: 80, box: 64)), duration: 3600)
        }
        let notification = makeModel {
            $0.showHUD(.notification(bundleID: "com.apple.MobileSMS", app: "Messages", title: "Sam",
                                     body: "Are we still on for tonight? I booked the table for 8."), duration: 3600)
        }
        let battery = makeModel { $0.showHUD(.power(percent: 20, charging: false, plugged: false), duration: 3600) }
        let focus = makeModel { $0.showHUD(.focus(name: "Work", symbol: "briefcase.fill", tint: "#0A84FF", on: true), duration: 3600) }
        let recording = makeModel {
            $0.upsertActivity(Activity(id: Activity.recordingID, symbol: "record.circle.fill", text: "Screen recording",
                                       subtitle: nil, level: nil, tint: "#FF3B30", startDate: self.clockBase.addingTimeInterval(-751),
                                       endDate: nil, expires: .distantFuture, countsUp: true))
        }
        let card = makeModel {
            $0.showHUD(.card(symbol: "shippingbox.fill", title: "Deploy finished", subtitle: "v2.4 is live in production",
                             tint: "#0A84FF", url: nil), duration: 3600)
        }
        let specs: [String: Spec] = ["pillStrip": spec(of: pillStrip), "pill": spec(of: pill), "player": spec(of: player),
                                     "picker": spec(of: picker), "airpods": spec(of: airpods), "notification": spec(of: notification),
                                     "battery": spec(of: battery), "focus": spec(of: focus), "recording": spec(of: recording),
                                     "card": spec(of: card)]

        func level(_ local: Double, from a: Double, to b: Double) -> Double { lerp(a, b, easeInOut(clamp((local - 0.7) / 1.8))) }

        return [
            PromoScene(line1: "", line2: "", duration: 4.6, zoom: 1.0, palette: "night") { _ in self.idleSpec },
            PromoScene(line1: "Now Playing.", line2: "Always in sight.", duration: 4.0, zoom: 2.1, palette: "violet") { local in
                local < 2.6 ? specs["pillStrip"]! : specs["pill"]! },
            PromoScene(line1: "Everything in reach.", line2: "Without leaving your work.", duration: 3.8, zoom: 1.15, palette: "sunset") { _ in specs["player"]! },
            PromoScene(line1: "Switch outputs.", line2: "In a single tap.", duration: 3.6, zoom: 0.84, palette: "ocean") { _ in specs["picker"]! },
            PromoScene(line1: "Volume.", line2: "Right where you look.", duration: 3.4, zoom: 2.2, palette: "ice") { local in
                self.hudSpec(.volume(level: level(local, from: 0.25, to: 0.8), muted: false)) },
            PromoScene(line1: "Brightness.", line2: "Rays that follow the light.", duration: 3.2, zoom: 2.2, palette: "sunset") { local in
                self.hudSpec(.brightness(level: level(local, from: 0.2, to: 0.9))) },
            PromoScene(line1: "AirPods.", line2: "Connected in style.", duration: 3.8, zoom: 1.6, palette: "ice") { _ in specs["airpods"]! },
            PromoScene(line1: "Stay in the moment.", line2: "Messages appear right here.", duration: 3.8, zoom: 1.6, palette: "forest") { _ in specs["notification"]! },
            PromoScene(line1: "Low battery.", line2: "Impossible to miss.", duration: 3.8, zoom: 1.6, palette: "ember") { _ in specs["battery"]! },
            PromoScene(line1: "Focus.", line2: "At a glance.", duration: 3.2, zoom: 2.2, palette: "ocean") { _ in specs["focus"]! },
            PromoScene(line1: "Touch ID.", line2: "With a little magic.", duration: 4.4, zoom: 2.0, palette: "forest") { local in self.touchIDSpec(local: local) },
            PromoScene(line1: "Recording?", line2: "You'll always know.", duration: 3.2, zoom: 2.1, palette: "violet") { _ in specs["recording"]! },
            PromoScene(line1: "Make it yours.", line2: "Plugins in JavaScript.", duration: 3.6, zoom: 1.6, palette: "sunset") { _ in specs["card"]! },
            PromoScene(line1: "", line2: "", duration: 5.4, zoom: 1.0, palette: "night") { _ in self.idleSpec },
        ]
    }

    // MARK: Frame

    private func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }

    /// Slowly drifting colour fields, like a macOS wallpaper that is alive.
    private func wallpaper(_ c: [Color], t: Double) -> some View {
        let a = 0.05 * sin(t * 0.35), b = 0.05 * cos(t * 0.28)
        return ZStack {
            LinearGradient(colors: [c[0], c[1]], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [c[2].opacity(0.7), .clear], center: UnitPoint(x: 0.14 + a, y: 0.62 + b), startRadius: 0, endRadius: 440)
            RadialGradient(colors: [c[3].opacity(0.75), .clear], center: UnitPoint(x: 0.88 - a, y: 0.95 - b), startRadius: 0, endRadius: 500)
            RadialGradient(colors: [c[2].opacity(0.35), .clear], center: UnitPoint(x: 0.7 + b, y: 0.3 - a), startRadius: 0, endRadius: 320)
        }
    }

    private func menuBar(width: CGFloat, itemsOpacity: Double) -> some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.28))
            HStack(spacing: 14) {
                HStack(spacing: 10) {
                    ForEach([34, 26, 30, 28], id: \.self) { w in Capsule().fill(Color.white.opacity(0.3)).frame(width: CGFloat(w), height: 5) }
                }
                Spacer()
                HStack(spacing: 11) {
                    Image(systemName: "wifi"); Image(systemName: "battery.100"); Image(systemName: "magnifyingglass")
                    Text("9:41").font(.system(size: 12, weight: .medium)).fixedSize()
                }
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 16)
            .opacity(itemsOpacity)
        }
        .frame(width: width, height: 32)
    }

    private func notchView(from: Spec, to: Spec, morph: Double, glow: Color) -> some View {
        let shape = spring(morph)
        let size = CGSize(width: lerp(from.size.width, to.size.width, shape), height: lerp(from.size.height, to.size.height, shape))
        let top = lerp(from.top, to.top, shape), bottom = lerp(from.bottom, to.bottom, shape)
        // The old content leaves quickly, the new one comes in a little later, blurring in as it scales up.
        let q = easeInOut(clamp((morph - 0.12) / 0.55))
        let showsFrom = morph < 1
        return ZStack(alignment: .top) {
            if showsFrom {
                from.content.frame(width: from.size.width, height: from.size.height, alignment: .top)
                    .opacity(1 - clamp(q * 1.7)).blur(radius: 7 * q).scaleEffect(1 - 0.05 * q, anchor: .top)
            }
            to.content.frame(width: to.size.width, height: to.size.height, alignment: .top)
                .opacity(showsFrom ? clamp((q - 0.25) / 0.75) : 1).blur(radius: showsFrom ? 7 * (1 - q) : 0)
                .scaleEffect(showsFrom ? 0.95 + 0.05 * q : 1, anchor: .top)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
        .frame(width: size.width + 2 * top, height: size.height, alignment: .top)
        .background(NotchShape(topRadius: top, bottomRadius: bottom).fill(Color.black))
        .clipShape(NotchShape(topRadius: top, bottomRadius: bottom))
        // Light spilling from the island onto the wallpaper.
        .background(NotchShape(topRadius: top, bottomRadius: bottom).fill(glow).blur(radius: 26).offset(y: 12).opacity(0.5))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
    }

    /// Two-tone headline: the first line in white, the second in grey; words blur in one after the other.
    private func headline(_ l1: String, _ l2: String, time: Double, out: Double) -> some View {
        func line(_ words: [String], offset: Int, color: Color) -> some View {
            HStack(spacing: 13) {
                ForEach(0..<words.count, id: \.self) { i in
                    let p = self.easeOut(self.clamp((time - 0.45 - Double(offset + i) * 0.09) / 0.65))
                    Text(words[i]).opacity(p).blur(radius: 12 * (1 - p)).offset(y: 16 * (1 - p))
                }
            }
            .foregroundStyle(color)
        }
        let w1 = l1.split(separator: " ").map(String.init), w2 = l2.split(separator: " ").map(String.init)
        return VStack(spacing: 4) {
            line(w1, offset: 0, color: .white)
            line(w2, offset: w1.count, color: Color.white.opacity(0.52))
        }
        .font(.system(size: 50, weight: .semibold))
        .tracking(-1.3)
        .shadow(color: .black.opacity(0.28), radius: 10, y: 2)
        .opacity(1 - out)
    }

    private func grain() -> CGImage? {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256)),
              let gray = CIFilter(name: "CIColorControls", parameters: [kCIInputImageKey: noise, kCIInputSaturationKey: 0])?.outputImage
        else { return nil }
        return CIContext().createCGImage(gray, from: CGRect(x: 0, y: 0, width: 256, height: 256))
    }

    private func gradientTitle(_ text: String, size: CGFloat) -> some View {
        Text(text).font(.system(size: size, weight: .bold)).tracking(-size * 0.025)
            .foregroundStyle(LinearGradient(colors: [.white, Color.white.opacity(0.6)], startPoint: .top, endPoint: .bottom))
    }

    private func appear(_ time: Double, from start: Double, length: Double = 0.8) -> Double { easeOut(clamp((time - start) / length)) }

    private func iconView(_ icon: NSImage, _ p: Double) -> some View {
        ZStack {
            Circle().fill(Color(red: 0.6, green: 0.4, blue: 1).opacity(0.5 * p)).frame(width: 150, height: 150).blur(radius: 46)
            Image(nsImage: icon).resizable().frame(width: 104, height: 104).shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        }
        .opacity(p).scaleEffect(0.78 + 0.22 * p).blur(radius: 10 * (1 - p))
    }

    private func introCard(icon: NSImage, local: Double) -> some View {
        let out = easeInOut(clamp((local - 3.55) / 0.7))
        return VStack(spacing: 18) {
            Text("Introducing").font(.system(size: 24, weight: .medium)).tracking(0.4)
                .foregroundStyle(Color.white.opacity(0.55)).opacity(appear(local, from: 0.35)).blur(radius: 8 * (1 - appear(local, from: 0.35)))
            iconView(icon, appear(local, from: 1.0, length: 0.9))
            gradientTitle("Dynamic Notch", size: 76)
                .opacity(appear(local, from: 1.7)).blur(radius: 12 * (1 - appear(local, from: 1.7))).offset(y: 14 * (1 - appear(local, from: 1.7)))
            Text("The notch, reimagined.").font(.system(size: 28, weight: .medium)).tracking(-0.4)
                .foregroundStyle(Color.white.opacity(0.6))
                .opacity(appear(local, from: 2.45)).blur(radius: 8 * (1 - appear(local, from: 2.45)))
        }
        .opacity(1 - out)
        .frame(width: frameSize.width, height: frameSize.height)
    }

    private func endCard(icon: NSImage, local: Double) -> some View {
        VStack(spacing: 16) {
            iconView(icon, appear(local, from: 1.1, length: 0.9))
            gradientTitle("Dynamic Notch", size: 76)
                .opacity(appear(local, from: 1.7)).blur(radius: 12 * (1 - appear(local, from: 1.7))).offset(y: 14 * (1 - appear(local, from: 1.7)))
            Text("Free. Open source. macOS 14 or later.").font(.system(size: 26, weight: .medium)).tracking(-0.3)
                .foregroundStyle(Color.white.opacity(0.6))
                .opacity(appear(local, from: 2.3)).blur(radius: 8 * (1 - appear(local, from: 2.3)))
            Text("github.com/ahududu1881/DynamicNotch").font(.system(size: 20, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1))
                .opacity(appear(local, from: 2.9)).blur(radius: 8 * (1 - appear(local, from: 2.9)))
                .padding(.top, 8)
        }
        .frame(width: frameSize.width, height: frameSize.height)
    }

    private func frame(at t: Double, scenes: [PromoScene], icon: NSImage, grainImage: CGImage?, frameNumber: Int) -> some View {
        ViewClock.override = clockBase.addingTimeInterval(t)

        var start = 0.0, index = scenes.count - 1, local = scenes[index].duration
        for (i, s) in scenes.enumerated() {
            if t < start + s.duration { index = i; local = t - start; break }
            start += s.duration
        }
        let scene = scenes[index], previous = index > 0 ? scenes[index - 1] : scenes[index]
        let isFirst = index == 0, isLast = index == scenes.count - 1

        let morph = index > 0 ? clamp(local / 0.95) : 1
        let zoom = lerp(previous.zoom, scene.zoom, easeInOut(clamp(local / 1.1)))
        let blend = easeInOut(clamp(local / 1.2))
        let from = previous.spec(previous.duration), to = scene.spec(local)

        func colors(_ name: String) -> [Color] { Self.palettes[name]! }
        let mixed = (0..<4).map { mix(colors(previous.palette)[$0], colors(scene.palette)[$0], index > 0 ? blend : 1) }

        let width = frameSize.width / zoom, height = frameSize.height / zoom
        let itemsOpacity = clamp((1.9 - Double(zoom)) / 0.3)

        // A very slow push-in keeps every shot alive.
        let drift = 1 + 0.035 * clamp(local / scene.duration)
        let wordsOut = (isFirst || isLast) ? 0 : easeInOut(clamp((local - (scene.duration - 0.4)) / 0.4))
        // Black at the start and the end, like a keynote film.
        let dark = isFirst ? 1 - easeInOut(clamp((local - 3.55) / 1.0)) : (isLast ? easeInOut(clamp((local - 0.3) / 1.0)) : 0)

        return ZStack(alignment: .top) {
            Color.black
            ZStack(alignment: .top) {
                wallpaper(mixed, t: t)
                ZStack(alignment: .top) {
                    VStack(spacing: 0) { menuBar(width: width, itemsOpacity: itemsOpacity); Spacer() }
                    notchView(from: from, to: to, morph: morph, glow: mixed[2])
                }
                .frame(width: width, height: height, alignment: .top)
                .scaleEffect(zoom, anchor: .top)
                .frame(width: frameSize.width, height: frameSize.height, alignment: .top)
                RadialGradient(colors: [.clear, .black.opacity(0.5)], center: .center, startRadius: 260, endRadius: 720)
                    .frame(width: frameSize.width, height: frameSize.height).allowsHitTesting(false)
            }
            .frame(width: frameSize.width, height: frameSize.height)
            .scaleEffect(drift)
            .overlay(Color.black.opacity(dark))
            .clipped()

            if !scene.line1.isEmpty {
                VStack { Spacer(); headline(scene.line1, scene.line2, time: local, out: wordsOut).padding(.bottom, 40) }
                    .frame(width: frameSize.width, height: frameSize.height)
            }
            if isFirst { introCard(icon: icon, local: local) }
            if isLast { endCard(icon: icon, local: local) }

            if let grainImage {
                Image(decorative: grainImage, scale: 1).resizable(resizingMode: .tile)
                    .frame(width: frameSize.width + 256, height: frameSize.height + 256)
                    .offset(x: CGFloat((frameNumber * 53) % 256) - 128, y: CGFloat((frameNumber * 97) % 256) - 128)
                    .blendMode(.overlay).opacity(0.1)
                    .frame(width: frameSize.width, height: frameSize.height).clipped().allowsHitTesting(false)
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
    }

    // MARK: Render

    func testRenderPromo() throws {
        guard let dir = ProcessInfo.processInfo.environment["PROMO_DIR"] else { return }
        let fps = Double(ProcessInfo.processInfo.environment["PROMO_FPS"] ?? "") ?? 30
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        Settings.shared.language = AppLanguage.en.rawValue
        defer {
            Settings.shared.language = AppLanguage.system.rawValue
            Settings.shared.showTitleStrip = true
            Settings.shared.titleStripSeconds = 1.8
            ViewClock.override = nil
        }
        let scenes = buildScenes()
        let icon = NSImage(contentsOfFile: "docs/icon.png") ?? NSImage()
        let grainImage = grain()
        let total = scenes.reduce(0) { $0 + $1.duration }
        let count = Int(total * fps)

        // The audio script syncs its sound design to these moments.
        var starts: [Double] = [], cursor = 0.0
        for scene in scenes { starts.append(cursor); cursor += scene.duration }
        let touch = scenes.firstIndex { $0.line1 == "Touch ID." } ?? 0
        let timeline: [String: Any] = ["total": total, "starts": starts, "touchStart": starts[touch], "durations": scenes.map(\.duration)]
        try JSONSerialization.data(withJSONObject: timeline, options: [.prettyPrinted]).write(to: out.appendingPathComponent("timeline.json"))

        // PROMO_AT="1.8,4.2" renders just those moments (named by time) for a quick look.
        if let at = ProcessInfo.processInfo.environment["PROMO_AT"] {
            for time in at.split(separator: ",").compactMap({ Double($0) }) {
                let renderer = ImageRenderer(content: frame(at: time, scenes: scenes, icon: icon, grainImage: grainImage, frameNumber: Int(time * 30)))
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.cgImage)
                let url = out.appendingPathComponent(String(format: "at_%06.2f.jpg", time))
                let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                CGImageDestinationFinalize(dest)
            }
            return
        }

        var range = 0..<count
        if let r = ProcessInfo.processInfo.environment["PROMO_RANGE"]?.split(separator: "-").compactMap({ Int($0) }), r.count == 2 {
            range = max(0, r[0])..<min(count, r[1] + 1)
        }
        print("PROMO total \(total)s, \(count) frames, rendering \(range)")
        for i in range {
            try autoreleasepool {
                let view = frame(at: Double(i) / fps, scenes: scenes, icon: icon, grainImage: grainImage, frameNumber: i)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage)
                let url = out.appendingPathComponent(String(format: "frame_%05d.jpg", i))
                let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.93] as CFDictionary)
                XCTAssertTrue(CGImageDestinationFinalize(dest))
            }
            if i % 60 == 0 { print("PROMO frame \(i)/\(count)") }
        }
    }
}
