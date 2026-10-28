import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import DynamicNotch

/// Renders the frames of the promo film (docs/promo.mp4) from the app's real views.
///
///     PROMO_DIR=/tmp/frames swift test --filter PromoVideoTests
///     ffmpeg -framerate 30 -i /tmp/frames/frame_%05d.jpg -i soundtrack.wav -c:v libx264 -pix_fmt yuv420p -crf 22 -c:a aac docs/promo.mp4
///
/// The film is cut to the grid of its soundtrack (130.95 BPM, starting on a downbeat): every shot lasts whole bars,
/// so each cut lands on a downbeat. The Touch ID check is timed to the one-bar break before the final chorus and the
/// montage starts exactly on the drop.
/// Within a shot the camera holds still and the island grows from the notch and shrinks back, the way it behaves on screen;
/// shots change with a short dissolve. Every frame is a pure function of time, and the clock that drives waveforms,
/// timers and ripples (`ViewClock`) is the film's own. PROMO_RANGE="120-240" renders only those frames,
/// PROMO_AT="1.5,9" renders single moments for review.
@MainActor
final class PromoVideoTests: XCTestCase {
    // MARK: Model

    struct Spec {
        var size: CGSize
        var top: CGFloat
        var bottom: CGFloat
        var content: AnyView
    }

    /// From `at` (seconds into the shot) the island takes this state; it morphs there from the previous key.
    struct Key {
        var at: Double
        var spec: (Double) -> Spec
    }

    enum Kind { case intro, feature, outro }

    struct Shot {
        var line1: String
        var line2: String
        var duration: Double
        var zoom: CGFloat
        var palette: String
        var kind: Kind = .feature
        /// false: the camera keeps rolling from the previous shot (same zoom), the island morphs on.
        var cut = true
        var dissolve = 0.28
        var keys: [Key]
    }

    static let bpm = 130.95
    static let beat = 60 / bpm
    static let bar = 4 * beat

    private let frameSize = CGSize(width: 960, height: 540)
    private let clockBase = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let nw: CGFloat = 186, nh: CGFloat = 32
    /// Seconds after the fingerprint appears at which it is accepted: the check then starts drawing exactly two bars
    /// into the Touch ID shot, which is the quiet bar of the song.
    private var touchSuccess: Double { 2 * Self.bar - 0.25 - TouchIDScan.checkStart }

    private static func hex(_ value: String) -> Color { Color(hex: value) ?? .black }

    /// Base, deep, band A, band B, glow.
    private static let palettes: [String: [Color]] = [
        "violet": [hex("#1B1F6B"), hex("#3B2A9A"), hex("#FF5EA8"), hex("#6A7CFF"), hex("#FFB36B")],
        "ocean": [hex("#06204F"), hex("#0B4C8C"), hex("#20D3C2"), hex("#5B7CFF"), hex("#B8FFE0")],
        "sunset": [hex("#3A145C"), hex("#8C2F6E"), hex("#FF8A3D"), hex("#FF4F7B"), hex("#FFD27A")],
        "forest": [hex("#062E33"), hex("#0F5B57"), hex("#3DDC97"), hex("#2EA3D8"), hex("#E8F59A")],
        "ember": [hex("#2A0E3D"), hex("#7A1C3F"), hex("#FF4E2E"), hex("#FF9A5A"), hex("#FFD0A0")],
        "ice": [hex("#0E1A4A"), hex("#1F4E9A"), hex("#7FD8FF"), hex("#8E7DFF"), hex("#E6F8FF")],
        "night": [hex("#05050C"), hex("#120E2E"), hex("#3B2A9A"), hex("#1B4F9A"), hex("#FF5EA8")],
    ]

    // MARK: Math

    private func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(max(x, lo), hi) }
    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
    private func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    private func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    /// Growing: a quick spring that overshoots by about two percent, then settles.
    private func grow(_ x: Double) -> Double { x >= 1 ? 1 : 1 - exp(-6 * x) * cos(4 * x) }
    /// Shrinking: smooth and decisive, never overshooting (an overshoot while getting small reads as a wobble).
    private func shrink(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 4) }

    // MARK: States

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

    private var idle: Spec { Spec(size: CGSize(width: nw, height: nh), top: 0, bottom: 8, content: AnyView(Color.clear)) }

    private func hudSpec(_ kind: HUDKind) -> Spec {
        let size = CGSize(width: nw, height: nh + NotchModel.hudRow)
        let content = ZStack(alignment: .topLeading) {
            HUDRow(kind: kind).padding(.horizontal, 20).frame(width: size.width, height: NotchModel.hudRow).offset(y: nh)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        return Spec(size: size, top: 0, bottom: 16, content: AnyView(content))
    }

    private func touchIDSpec(_ local: Double) -> Spec {
        let size = CGSize(width: nw, height: nh + NotchModel.touchIDHeight)
        let ref = clockBase, success = touchSuccess
        let canvas = Canvas { gc, canvasSize in
            TouchIDScan.draw(&gc, size: canvasSize, now: ref.addingTimeInterval(max(0, local)), appeared: ref,
                             successAt: local >= success ? ref.addingTimeInterval(success) : nil)
        }
        .frame(width: 58, height: 58)
        .offset(x: size.width / 2 - 29, y: nh + 8)
        let content = ZStack(alignment: .topLeading) { canvas }.frame(width: size.width, height: size.height, alignment: .topLeading)
        return Spec(size: size, top: 0, bottom: 24, content: AnyView(content))
    }

    /// A level that steps on the beat, like someone tapping the key in time with the music.
    private func steppedLevel(_ local: Double, from: Double, steps: Int, start: Double) -> Double {
        var level = from
        for i in 0..<steps {
            let at = start + Double(i) * Self.beat
            level += 1.0 / 16 * easeOut(clamp((local - at) / 0.14))
        }
        return min(1, level)
    }

    // MARK: Film

    private func buildFilm() -> [Shot] {
        let art = albumArt()
        let outputs = [AudioOutput(id: 1, name: "Studio Headphones", symbol: "headphones", isDefault: false, isBluetooth: true),
                       AudioOutput(id: 2, name: "MacBook Pro Speakers", symbol: "laptopcomputer", isDefault: true),
                       AudioOutput(id: 3, name: "Living Room", symbol: "airplayaudio", isDefault: false)]

        Settings.shared.titleStripSeconds = 3600
        let pillStrip = spec(of: makeModel { $0.setMedia(self.nowPlaying(), artwork: art) })
        Settings.shared.showTitleStrip = false
        let pill = spec(of: makeModel { $0.setMedia(self.nowPlaying(), artwork: art) })
        let player = spec(of: makeModel { m in m.setMedia(self.nowPlaying(), artwork: art); m.setOutputs(outputs); m.expand() })
        let picker = spec(of: makeModel { m in
            m.setMedia(self.nowPlaying(), artwork: art); m.setOutputs(outputs); m.expand(); m.showOutputs = true
        })
        let airpods = spec(of: makeModel {
            $0.showHUD(.accessory(name: "AirPods Pro", model: .airpodsPro, connected: true,
                                  battery: AccessoryBattery(left: 82, right: 80, box: 64)), duration: 3600)
        })
        let notification = spec(of: makeModel {
            $0.showHUD(.notification(bundleID: "com.apple.MobileSMS", app: "Messages", title: "Sam",
                                     body: "Are we still on for tonight? I booked the table for 8."), duration: 3600)
        })
        let battery = spec(of: makeModel { $0.showHUD(.power(percent: 20, charging: false, plugged: false), duration: 3600) })
        let focus = spec(of: makeModel { $0.showHUD(.focus(name: "Work", symbol: "briefcase.fill", tint: "#0A84FF", on: true), duration: 3600) })
        let recording = spec(of: makeModel {
            $0.upsertActivity(Activity(id: Activity.recordingID, symbol: "record.circle.fill", text: "Screen recording",
                                       subtitle: nil, level: nil, tint: "#FF3B30", startDate: self.clockBase.addingTimeInterval(-751),
                                       endDate: nil, expires: .distantFuture, countsUp: true))
        })
        let card = spec(of: makeModel {
            $0.showHUD(.card(symbol: "shippingbox.fill", title: "Deploy finished", subtitle: "v2.4 is live in production",
                             tint: "#0A84FF", url: nil), duration: 3600)
        })

        let bar = Self.bar
        let idle = self.idle
        func fixed(_ s: Spec) -> (Double) -> Spec { { _ in s } }
        /// Grows out of the notch on the downbeat, holds, and tucks back in just before the next cut.
        func breath(_ s: @escaping (Double) -> Spec, length: Double, inAt: Double = 0.12) -> [Key] {
            [Key(at: 0, spec: fixed(idle)), Key(at: inAt, spec: s), Key(at: length - 0.62, spec: fixed(idle))]
        }

        var film: [Shot] = [
            Shot(line1: "", line2: "", duration: 2 * bar, zoom: 1, palette: "night", kind: .intro, keys: [Key(at: 0, spec: fixed(idle))]),
            Shot(line1: "Now Playing.", line2: "Always in sight.", duration: 2 * bar, zoom: 2.0, palette: "violet",
                 keys: [Key(at: 0, spec: fixed(idle)), Key(at: 0.12, spec: fixed(pillStrip)), Key(at: 1.25 * bar, spec: fixed(pill))]),
            Shot(line1: "Everything in reach.", line2: "Without leaving your work.", duration: 2 * bar, zoom: 1.0, palette: "sunset",
                 keys: [Key(at: 0, spec: fixed(pill)), Key(at: 0.3, spec: fixed(player))]),
            Shot(line1: "Switch outputs.", line2: "In a single click.", duration: 2 * bar, zoom: 1.0, palette: "sunset", cut: false,
                 keys: [Key(at: 0.1, spec: fixed(picker)), Key(at: 2 * bar - 0.65, spec: fixed(pill))]),
            Shot(line1: "Volume.", line2: "Right where you look.", duration: 2 * bar, zoom: 2.2, palette: "ice",
                 keys: [Key(at: 0, spec: fixed(idle)),
                        Key(at: 0.12, spec: { self.hudSpec(.volume(level: self.steppedLevel($0, from: 0.3125, steps: 6, start: Self.beat), muted: false)) })]),
            Shot(line1: "Brightness.", line2: "Rays that follow the light.", duration: 2 * bar, zoom: 2.2, palette: "sunset", cut: false,
                 keys: [Key(at: 0, spec: { self.hudSpec(.brightness(level: self.steppedLevel($0, from: 0.375, steps: 6, start: Self.beat))) }),
                        Key(at: 2 * bar - 0.62, spec: fixed(idle))]),
            Shot(line1: "AirPods.", line2: "Connected in style.", duration: 2 * bar, zoom: 1.6, palette: "ice", keys: breath(fixed(airpods), length: 2 * bar)),
            Shot(line1: "Stay in the moment.", line2: "Messages, right up top.", duration: 2 * bar, zoom: 1.6, palette: "forest",
                 keys: breath(fixed(notification), length: 2 * bar)),
            Shot(line1: "Low battery.", line2: "Impossible to miss.", duration: 2 * bar, zoom: 1.6, palette: "ember", keys: breath(fixed(battery), length: 2 * bar)),
            Shot(line1: "Focus.", line2: "At a glance.", duration: 2 * bar, zoom: 2.2, palette: "ocean", keys: breath(fixed(focus), length: 2 * bar)),
            Shot(line1: "Touch ID.", line2: "With a little magic.", duration: 3 * bar, zoom: 2.0, palette: "forest",
                 keys: [Key(at: 0, spec: fixed(idle)), Key(at: 0.25, spec: { self.touchIDSpec($0 - 0.25) }), Key(at: 3 * bar - 0.62, spec: fixed(idle))]),
        ]
        // The finale: eight bars of half-bar cuts through everything, starting on the drop.
        let touchFrame = touchIDSpec(touchSuccess + 0.8)
        let montage: [(Spec, String, CGFloat)] = [
            (pill, "violet", 1.5), (recording, "ember", 1.8), (hudSpec(.volume(level: 0.75, muted: false)), "ice", 2.0), (card, "sunset", 1.5),
            (notification, "forest", 1.5), (focus, "ocean", 2.0), (airpods, "ice", 1.5), (player, "violet", 1.1),
            (battery, "ember", 1.8), (hudSpec(.brightness(level: 0.8)), "sunset", 2.0), (picker, "ocean", 0.9), (pillStrip, "violet", 2.2),
            (touchFrame, "forest", 2.0), (airpods, "violet", 1.8), (notification, "sunset", 1.8), (player, "ice", 1.2),
        ]
        for (state, palette, zoom) in montage {
            film.append(Shot(line1: "All of it.", line2: "Right at the top.", duration: bar / 2, zoom: zoom, palette: palette,
                             dissolve: 0.08, keys: [Key(at: 0, spec: fixed(state))]))
        }
        film.append(Shot(line1: "", line2: "", duration: 4 * bar, zoom: 1.5, palette: "night", kind: .outro, keys: [Key(at: 0, spec: fixed(idle))]))
        return film
    }

    // MARK: Desktop

    /// Flowing bands of colour in the manner of the recent macOS wallpapers, drifting slowly.
    private func wallpaper(_ c: [Color], t: Double) -> some View {
        ZStack {
            LinearGradient(colors: [c[0], c[1]], startPoint: .topLeading, endPoint: .bottomTrailing)
            ForEach(0..<3, id: \.self) { i in
                let d = Double(i)
                Capsule()
                    .fill(LinearGradient(colors: [i == 1 ? c[3] : c[2], (i == 1 ? c[2] : c[3]).opacity(0.0)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 1500, height: CGFloat(300 - 60 * d))
                    .rotationEffect(.degrees(-16 + 10 * d + 2.5 * sin(t * 0.22 + d)))
                    .offset(x: CGFloat(-120 + 90 * d + 30 * sin(t * 0.3 + d)), y: CGFloat(150 + 95 * d + 18 * cos(t * 0.27 + d)))
                    .blur(radius: 55)
                    .opacity(0.9 - 0.15 * d)
            }
            RadialGradient(colors: [c[4].opacity(0.45), .clear], center: UnitPoint(x: 0.85 + 0.03 * sin(t * 0.2), y: 0.9), startRadius: 0, endRadius: 420)
            LinearGradient(colors: [.black.opacity(0.18), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.25))
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .clipped()
    }

    /// The macOS menu bar as it looks over a wallpaper: translucent, app menus on the left, status items on the right,
    /// and nothing under the camera housing. Items that do not fit beside the notch are left out, as macOS does,
    /// and items the island grows over fade away rather than being cut in half.
    private func menuBar(width: CGFloat, island: CGFloat) -> some View {
        let side = (width - nw) / 2 - 10
        let islandEdge = (width - island) / 2 - 8
        func fade(_ far: CGFloat) -> Double { clamp(Double((islandEdge - far) / 14)) }

        var left: [(String, Bool, Double)] = [], x: CGFloat = 14
        for (i, m) in ["Finder", "File", "Edit", "View", "Go", "Window", "Help"].enumerated() {
            let w = CGFloat(m.count) * (i == 0 ? 8.0 : 7.4)
            if x + w > side { break }
            left.append((m, i == 0, fade(x + w)))
            x += w + 20
        }
        // Right side, from the clock inwards.
        var right: [(String?, String?, Double)] = [], r: CGFloat = 14
        for item in [(nil, "Tue Oct 28  9:41"), ("switch.2", nil), ("magnifyingglass", nil), ("wifi", nil), ("battery.75percent", nil)] as [(String?, String?)] {
            let w: CGFloat = item.1 != nil ? CGFloat(item.1!.count) * 6.9 : 17
            if r + w > side { break }
            right.append((item.0, item.1, fade(r + w)))
            r += w + 16
        }
        return ZStack {
            LinearGradient(colors: [.black.opacity(0.22), .black.opacity(0.06)], startPoint: .top, endPoint: .bottom)
            HStack(spacing: 0) {
                HStack(spacing: 20) {
                    ForEach(Array(left.enumerated()), id: \.offset) { _, item in
                        Text(item.0).font(.system(size: 13, weight: item.1 ? .bold : .medium)).fixedSize().opacity(item.2)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 16) {
                    ForEach(Array(right.reversed().enumerated()), id: \.offset) { _, item in
                        Group {
                            if let symbol = item.0 {
                                Image(systemName: symbol).font(.system(size: 13.5, weight: .medium))
                            } else if let text = item.1 {
                                Text(text).font(.system(size: 13, weight: .medium)).fixedSize()
                            }
                        }
                        .opacity(item.2)
                    }
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 0.5)
            .padding(.horizontal, 14)
        }
        .frame(width: width, height: nh)
    }

    /// Outer width of the island (with its flares) at this point of a morph, matching `notchView`.
    private func islandWidth(_ from: Spec, _ to: Spec, _ morph: Double) -> CGFloat {
        let growing = to.size.width * to.size.height >= from.size.width * from.size.height
        let shape = growing ? grow(morph) : shrink(morph)
        return lerp(from.size.width, to.size.width, shape) + 2 * lerp(from.top, to.top, shape)
    }

    private func notchView(from: Spec, to: Spec, morph: Double, glow: Color) -> some View {
        let growing = to.size.width * to.size.height >= from.size.width * from.size.height
        let shape = growing ? grow(morph) : shrink(morph)
        let size = CGSize(width: lerp(from.size.width, to.size.width, shape), height: lerp(from.size.height, to.size.height, shape))
        let top = lerp(from.top, to.top, shape), bottom = lerp(from.bottom, to.bottom, shape)
        // Growing: the old content leaves at once, the new one blurs in as the shape opens.
        // Shrinking: the content blurs away in the first moments, before the shape gets small.
        let outQ = clamp(morph / (growing ? 0.25 : 0.3))
        let inQ = easeInOut(clamp((morph - 0.18) / 0.55))
        let showsFrom = morph < 1
        return ZStack(alignment: .top) {
            if showsFrom {
                from.content.frame(width: from.size.width, height: from.size.height, alignment: .top)
                    .opacity(1 - outQ).blur(radius: 8 * outQ).scaleEffect(1 - 0.06 * outQ, anchor: .top)
            }
            to.content.frame(width: to.size.width, height: to.size.height, alignment: .top)
                .opacity(showsFrom ? inQ : 1).blur(radius: showsFrom ? 8 * (1 - inQ) : 0)
                .scaleEffect(showsFrom ? 0.94 + 0.06 * inQ : 1, anchor: .top)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
        .frame(width: size.width + 2 * top, height: size.height, alignment: .top)
        .background(NotchShape(topRadius: top, bottomRadius: bottom).fill(Color.black))
        .clipShape(NotchShape(topRadius: top, bottomRadius: bottom))
        .background(NotchShape(topRadius: top, bottomRadius: bottom).fill(glow).blur(radius: 24).offset(y: 10)
            .opacity(0.45 * Double(min(1, max(0, (size.height - nh) / 30)))))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
    }

    // MARK: Type

    private func appear(_ time: Double, from start: Double, length: Double = 0.7) -> Double { easeOut(clamp((time - start) / length)) }

    /// Two-tone headline: white, then grey; words blur in one after the other.
    private func headline(_ l1: String, _ l2: String, time: Double, out: Double) -> some View {
        func line(_ words: [String], offset: Int, color: Color) -> some View {
            HStack(spacing: 13) {
                ForEach(0..<words.count, id: \.self) { i in
                    let p = self.appear(time, from: 0.3 + Double(offset + i) * 0.08, length: 0.6)
                    Text(words[i]).opacity(p).blur(radius: 12 * (1 - p)).offset(y: 16 * (1 - p))
                }
            }
            .foregroundStyle(color)
        }
        let w1 = l1.split(separator: " ").map(String.init), w2 = l2.split(separator: " ").map(String.init)
        return VStack(spacing: 4) {
            line(w1, offset: 0, color: .white)
            line(w2, offset: w1.count, color: Color.white.opacity(0.55))
        }
        .font(.system(size: 52, weight: .semibold))
        .tracking(-1.4)
        .shadow(color: .black.opacity(0.3), radius: 12, y: 2)
        .opacity(1 - out)
        .blur(radius: 10 * out)
    }

    private func gradientTitle(_ text: String, size: CGFloat) -> some View {
        Text(text).font(.system(size: size, weight: .bold)).tracking(-size * 0.028)
            .foregroundStyle(LinearGradient(colors: [.white, Color.white.opacity(0.62)], startPoint: .top, endPoint: .bottom))
    }

    private func iconView(_ icon: NSImage, _ p: Double) -> some View {
        ZStack {
            Circle().fill(Color(red: 0.62, green: 0.42, blue: 1).opacity(0.55 * p)).frame(width: 160, height: 160).blur(radius: 50)
            Image(nsImage: icon).resizable().frame(width: 108, height: 108).shadow(color: .black.opacity(0.45), radius: 20, y: 9)
        }
        .opacity(p).scaleEffect(0.8 + 0.2 * p).blur(radius: 10 * (1 - p))
    }

    private func titleCard(icon: NSImage, local: Double, eyebrow: Bool, out: Double) -> some View {
        let iconAt = eyebrow ? 0.8 : 0.35, titleAt = eyebrow ? 1.35 : 0.85, tagAt = eyebrow ? 1.95 : 1.45
        return VStack(spacing: 18) {
            if eyebrow {
                Text("Introducing").font(.system(size: 24, weight: .medium)).tracking(0.3)
                    .foregroundStyle(Color.white.opacity(0.55)).opacity(appear(local, from: 0.25)).blur(radius: 8 * (1 - appear(local, from: 0.25)))
            }
            iconView(icon, appear(local, from: iconAt, length: 0.85))
            gradientTitle("Dynamic Notch", size: 80)
                .opacity(appear(local, from: titleAt)).blur(radius: 12 * (1 - appear(local, from: titleAt)))
                .offset(y: 14 * (1 - appear(local, from: titleAt)))
            Text("The notch, reimagined.").font(.system(size: 28, weight: .medium)).tracking(-0.4)
                .foregroundStyle(Color.white.opacity(0.6))
                .opacity(appear(local, from: tagAt)).blur(radius: 8 * (1 - appear(local, from: tagAt)))
        }
        .opacity(1 - out)
        .frame(width: frameSize.width, height: frameSize.height)
    }

    private func grain() -> CGImage? {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256)),
              let gray = CIFilter(name: "CIColorControls", parameters: [kCIInputImageKey: noise, kCIInputSaturationKey: 0])?.outputImage
        else { return nil }
        return CIContext().createCGImage(gray, from: CGRect(x: 0, y: 0, width: 256, height: 256))
    }

    // MARK: Frame

    private struct Placement { var index: Int; var local: Double; var start: Double }

    private func place(_ t: Double, _ film: [Shot]) -> Placement {
        var start = 0.0
        for (i, s) in film.enumerated() {
            if t < start + s.duration { return Placement(index: i, local: t - start, start: start) }
            start += s.duration
        }
        let last = film.count - 1
        return Placement(index: last, local: film[last].duration, start: start - film[last].duration)
    }

    /// The island's state inside a shot at `local` seconds: where it morphs from, where to, and how far along.
    private func island(_ film: [Shot], _ index: Int, _ local: Double) -> (Spec, Spec, Double) {
        let shot = film[index]
        let k = shot.keys.lastIndex { $0.at <= local } ?? 0
        let key = shot.keys[k]
        let to = key.spec(local)
        let from: Spec
        if k > 0 {
            from = shot.keys[k - 1].spec(key.at)
        } else if !shot.cut, index > 0, let last = film[index - 1].keys.last {
            from = last.spec(film[index - 1].duration)
        } else {
            return (to, to, 1)
        }
        let growing = to.size.width * to.size.height >= from.size.width * from.size.height
        return (from, to, clamp((local - key.at) / (growing ? 0.8 : 0.55)))
    }

    /// Start and end of the run of shots sharing this headline, so the words animate once across a montage.
    private func headlineSpan(_ film: [Shot], _ index: Int, _ start: Double) -> (Double, Double) {
        var i = index, s = start
        while i > 0, film[i - 1].line1 == film[index].line1 { i -= 1; s -= film[i].duration }
        var j = index, e = start + film[index].duration
        while j + 1 < film.count, film[j + 1].line1 == film[index].line1 { j += 1; e += film[j].duration }
        return (s, e)
    }

    private func shotView(_ film: [Shot], _ index: Int, local: Double, t: Double) -> some View {
        let shot = film[index]
        let (from, to, morph) = island(film, index, local)
        let colors = Self.palettes[shot.palette]!
        let width = frameSize.width / shot.zoom, height = frameSize.height / shot.zoom
        // The camera holds still: a slow push makes text creep in one-pixel steps once it is rasterised.
        return ZStack(alignment: .top) {
            wallpaper(colors, t: t)
            ZStack(alignment: .top) {
                VStack(spacing: 0) { menuBar(width: width, island: islandWidth(from, to, morph)); Spacer() }
                notchView(from: from, to: to, morph: morph, glow: colors[2])
            }
            .frame(width: width, height: height, alignment: .top)
            .scaleEffect(shot.zoom, anchor: .top)
            .frame(width: frameSize.width, height: frameSize.height, alignment: .top)
            RadialGradient(colors: [.clear, .black.opacity(0.42)], center: UnitPoint(x: 0.5, y: 0.35), startRadius: 300, endRadius: 760)
        }
        .frame(width: frameSize.width, height: frameSize.height)
        // The display's rounded top corners.
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14 * shot.zoom, topTrailingRadius: 14 * shot.zoom))
        .background(Color.black)
        .clipped()
    }

    private func frame(at t: Double, film: [Shot], icon: NSImage, grainImage: CGImage?, frameNumber: Int) -> some View {
        ViewClock.override = clockBase.addingTimeInterval(t)
        let p = place(t, film)
        let shot = film[p.index]
        let prevIndex = max(0, p.index - 1)
        let dissolving = shot.cut && p.index > 0 && p.local < shot.dissolve && film[prevIndex].kind == .feature
        let q = dissolving ? easeInOut(p.local / shot.dissolve) : 1
        let introFade = p.index > 0 && film[prevIndex].kind == .intro ? easeInOut(clamp(p.local / 0.35)) : 1

        let (hStart, hEnd) = headlineSpan(film, p.index, p.start)
        let hOut = easeInOut(clamp((t - (hEnd - 0.32)) / 0.3))

        return ZStack {
            Color.black
            if shot.kind == .feature {
                if dissolving {
                    shotView(film, prevIndex, local: film[prevIndex].duration + p.local, t: t)
                }
                shotView(film, p.index, local: p.local, t: t)
                    .opacity(q * introFade)
                    .scaleEffect(dissolving ? 1.02 - 0.02 * q : 1)
                if !shot.line1.isEmpty {
                    VStack { Spacer(); headline(shot.line1, shot.line2, time: t - hStart, out: hOut).padding(.bottom, 44) }
                        .frame(width: frameSize.width, height: frameSize.height)
                }
            }
            if shot.kind == .intro {
                titleCard(icon: icon, local: p.local, eyebrow: true, out: easeInOut(clamp((p.local - 2.95) / 0.55)))
            }
            if shot.kind == .outro {
                let fadeOut = easeInOut(clamp((p.local - (shot.duration - 0.7)) / 0.7))
                titleCard(icon: icon, local: p.local - 0.2, eyebrow: false, out: fadeOut)
            }
            if let grainImage {
                Image(decorative: grainImage, scale: 1).resizable(resizingMode: .tile)
                    .frame(width: frameSize.width + 256, height: frameSize.height + 256)
                    .offset(x: CGFloat((frameNumber * 53) % 256) - 128, y: CGFloat((frameNumber * 97) % 256) - 128)
                    .blendMode(.overlay).opacity(0.07)
                    .frame(width: frameSize.width, height: frameSize.height).clipped()
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
    }

    // MARK: Render

    private func write(_ image: CGImage, to url: URL, quality: Double) throws {
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

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
        let film = buildFilm()
        let icon = NSImage(contentsOfFile: "docs/icon.png") ?? NSImage()
        let grainImage = grain()
        let total = film.reduce(0) { $0 + $1.duration }
        let count = Int((total * fps).rounded())

        // The soundtrack is written against these moments.
        var starts: [Double] = [], cursor = 0.0
        for shot in film { starts.append(cursor); cursor += shot.duration }
        let touch = film.firstIndex { $0.line1 == "Touch ID." } ?? 0
        let montage = film.firstIndex { $0.line1 == "All of it." } ?? 0
        let timeline: [String: Any] = [
            "bpm": Self.bpm, "beat": Self.beat, "bar": Self.bar, "total": total, "starts": starts,
            "touchCheck": starts[touch] + 0.25 + touchSuccess + TouchIDScan.checkStart,
            "touchStart": starts[touch], "montageStart": starts[montage], "outroStart": starts.last ?? total,
        ]
        try JSONSerialization.data(withJSONObject: timeline, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("timeline.json"))

        if let at = ProcessInfo.processInfo.environment["PROMO_AT"] {
            for time in at.split(separator: ",").compactMap({ Double($0) }) {
                let renderer = ImageRenderer(content: frame(at: time, film: film, icon: icon, grainImage: grainImage, frameNumber: Int(time * 30)))
                renderer.scale = 1
                try write(try XCTUnwrap(renderer.cgImage), to: out.appendingPathComponent(String(format: "at_%06.2f.jpg", time)), quality: 0.9)
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
                let renderer = ImageRenderer(content: frame(at: Double(i) / fps, film: film, icon: icon, grainImage: grainImage, frameNumber: i))
                renderer.scale = 2
                try write(try XCTUnwrap(renderer.cgImage), to: out.appendingPathComponent(String(format: "frame_%05d.jpg", i)), quality: 0.93)
            }
        }
    }
}
