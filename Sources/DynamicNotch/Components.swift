import SwiftUI

/// Lets the promo video renderer drive every time-based animation from its own clock. Always nil in the app.
enum ViewClock {
    nonisolated(unsafe) static var override: Date?
    static func date(_ live: Date) -> Date { override ?? live }
}

struct WaveformView: View {
    var isPlaying: Bool
    var color: Color
    var bars = 5
    var height: CGFloat = 18
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2.5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !isPlaying)) { ctx in
            let t = ViewClock.date(ctx.date).timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<bars, id: \.self) { i in
                    let phase = Double(i) * 1.9
                    let wave = abs(sin(t * 3.4 + phase) * cos(t * 1.9 + phase * 0.6))
                    let level = isPlaying ? 0.28 + 0.72 * wave : 0.16
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth, height: max(barWidth, height * level))
                }
            }
            .frame(height: height)
            .animation(.easeOut(duration: 0.3), value: isPlaying)
        }
    }
}

struct ArtworkView: View {
    var image: NSImage?
    var size: CGFloat
    var radius: CGFloat
    var tint: Color = .gray

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.white.opacity(0.09))
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

private struct WidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Single-line text that scrolls sideways only when it does not fit.
struct MarqueeText: View {
    var text: String
    var font: Font
    var color: Color
    var height: CGFloat
    var alignment: Alignment = .center
    var speed: CGFloat = 26
    var gap: CGFloat = 32
    var pause: Double = 1.4
    var active = true

    @State private var textWidth: CGFloat = 0
    @State private var start = Date()

    var body: some View {
        GeometryReader { geo in
            let overflow = textWidth > geo.size.width + 1
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !overflow || !active)) { ctx in
                HStack(spacing: gap) {
                    label.background(GeometryReader { Color.clear.preference(key: WidthKey.self, value: $0.size.width) })
                    if overflow { label }
                }
                .offset(x: overflow ? offset(at: ctx.date) : 0)
                .frame(width: geo.size.width, alignment: overflow ? .leading : alignment)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .mask(edgeFade(overflow: overflow))
        }
        .frame(height: height)
        .onPreferenceChange(WidthKey.self) { textWidth = $0 }
        .onChange(of: text) { start = Date() }
    }

    private var label: some View {
        Text(text).font(font).foregroundStyle(color).lineLimit(1).fixedSize()
    }

    private func offset(at date: Date) -> CGFloat {
        let cycle = textWidth + gap
        let period = pause + Double(cycle / speed)
        let phase = date.timeIntervalSince(start).truncatingRemainder(dividingBy: period)
        return phase < pause ? 0 : -CGFloat(phase - pause) * speed
    }

    @ViewBuilder
    private func edgeFade(overflow: Bool) -> some View {
        if overflow {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                   .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        } else {
            Color.black
        }
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// Thin horizontal slider used for scrubbing and volume.
struct ScrubBar: View {
    var fraction: Double
    var enabled = true
    var onBegan: () -> Void = {}
    var onChanged: (Double) -> Void
    var onEnded: (Double) -> Void
    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule().fill(Color.white.opacity(0.92))
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
            .frame(height: dragging ? 8 : (hovering ? 6 : 4))
            .frame(maxHeight: .infinity)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dragging)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
            .onHover { hovering = $0 }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard enabled else { return }
                    if !dragging { dragging = true; onBegan() }
                    onChanged(min(max(value.location.x / geo.size.width, 0), 1))
                }
                .onEnded { value in
                    guard enabled else { return }
                    dragging = false
                    onEnded(min(max(value.location.x / geo.size.width, 0), 1))
                })
        }
        .frame(height: 16)
    }
}

func formatTime(_ t: TimeInterval) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let s = Int(t.rounded(.down))
    return String(format: "%d:%02d", s / 60, s % 60)
}
