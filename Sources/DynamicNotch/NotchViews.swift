import SwiftUI

private let notchBlue = Color(red: 0.04, green: 0.52, blue: 1.0)

struct NotchRootView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        let size = model.bodySize
        let top = model.topRadius
        let shape = NotchShape(topRadius: top, bottomRadius: model.bottomRadius)

        ZStack(alignment: .topLeading) {
            NotchContent(model: model, size: size)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .frame(width: size.width + 2 * top, height: size.height, alignment: .top)
        .background(shape.fill(Color.black))
        .clipShape(shape)
        .shadow(color: .black.opacity(model.showsShadow ? 0.24 : 0), radius: 10, y: 4)
        // At rest nothing is drawn; the physical notch is all you see.
        .opacity(model.shapeHidden ? 0 : 1)
        .animation(.easeOut(duration: 0.12), value: model.shapeHidden)
        .contentShape(shape)
        .onTapGesture { model.primaryClick() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}

/// Every element lives for the whole session and only moves / resizes between presentations,
/// so growing or shrinking the notch never swaps views: the artwork travels from the small
/// pill to the big player, the rest is uncovered by the growing shape.
struct NotchContent: View {
    @ObservedObject var model: NotchModel
    let size: CGSize

    private let pad: CGFloat = 24
    private let art: CGFloat = 56
    /// Five bars of 1.8 pt with 2 pt gaps.
    private let waveWidth = NotchModel.PillLayout.waveWidth
    private let waveHeight: CGFloat = 9

    var body: some View {
        let nh = model.geometry.notchHeight
        let presentation = model.presentation
        let expanded = presentation == .expanded
        let live = presentation == .live
        let hasMedia = model.media != nil
        let playing = model.media?.isPlaying == true
        let pillOn = live || model.hudOverLive
        let mediaVisible = hasMedia && (expanded || (pillOn && model.pillShowsMedia))
        let controlsY = nh + 6 + art + 16 + 24

        ZStack(alignment: .topLeading) {
            // Artwork and waveform travel between the pill and the player (matched, not swapped).
            ArtworkView(image: model.artwork, size: expanded ? art : 18, radius: expanded ? 12 : 5)
                .offset(x: expanded ? pad : 8, y: expanded ? nh + 6 : (nh - 18) / 2)
                .blurReveal(mediaVisible, delay: 0.08, scale: 0.75, blur: 4, anchor: .center)

            WaveformView(isPlaying: playing && mediaVisible, color: model.accent.opacity(0.9),
                         bars: 5, height: waveHeight, barWidth: 1.8, spacing: 2)
                .frame(width: waveWidth)
                .offset(x: size.width - (expanded ? pad : 8) - waveWidth, y: expanded ? nh + 6 + (art - waveHeight) / 2 : (nh - waveHeight) / 2)
                .blurReveal(mediaVisible, delay: 0.08, scale: 0.75, blur: 4, anchor: .center)

            // Activities pushed by other apps use the pill when no media is live.
            if let activity = model.pillActivity, pillOn {
                Image(systemName: activity.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(activity.tint.flatMap(Color.init(hex:)) ?? .white)
                    .symbolEffect(.pulse, options: .repeating, isActive: activity.isRecording)
                    .frame(width: NotchModel.PillLayout.activityIconSize, height: 16)
                    .offset(x: NotchModel.PillLayout.activityIconX, y: (nh - 16) / 2)
                    .transition(.blurScale)
                ActivityTrailing(activity: activity)
                    .frame(width: 34, height: 16, alignment: .trailing)
                    .offset(x: NotchModel.PillLayout.trailingX(width: size.width), y: (nh - 16) / 2)
                    .transition(.blurScale)
            }

            // While media is in the pill a recording is shown as a pulsing red dot next to the waveform.
            if model.isRecording, model.pillShowsMedia, !expanded {
                RecordingDot()
                    .frame(width: 8, height: 8)
                    .offset(x: NotchModel.PillLayout.dotX(width: size.width), y: (nh - 8) / 2)
                    .transition(.blurScale)
            }

            // Title line that peeks out under the pill for a moment.
            MarqueeText(text: model.stripText, font: .system(size: 9, weight: .medium),
                        color: .white.opacity(0.7), height: 12, active: live && model.stripVisible)
                .frame(width: max(0, size.width - 36))
                .offset(x: 18, y: nh + 2)
                .blurReveal(live && model.stripVisible, delay: 0.06, scale: 0.85, blur: 6)

            // Everything that only exists in the big player; it blurs in once the shape is growing.
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(text: model.media?.title ?? "", font: .system(size: 13.5, weight: .semibold),
                                color: .white, height: 18, alignment: .leading, active: expanded)
                    MarqueeText(text: subtitle, font: .system(size: 12),
                                color: .white.opacity(0.55), height: 16, alignment: .leading, active: expanded)
                }
                .frame(width: max(0, size.width - (pad + art + 14) - pad - waveWidth - 12), alignment: .leading)
                .offset(x: pad + art + 14, y: nh + 6 + 10)

                ProgressRow(model: model, active: expanded)
                    .frame(width: max(0, size.width - 2 * pad))
                    .offset(x: pad, y: nh + 6 + art + 16)

                controls
                    .frame(width: max(0, size.width - 2 * pad), height: 46)
                    .offset(x: pad, y: controlsY)
                    .allowsHitTesting(expanded)

                // Volume / brightness feedback: the player grows a little at the bottom and shows it there.
                if let inline = model.inlineHUD {
                    HUDRow(kind: inline)
                        .frame(width: max(0, size.width - 2 * pad), height: 26)
                        .offset(x: pad, y: controlsY + 46 + 2)
                        .transition(.blurScale)
                }

                // The output list always stays at the very bottom, below the feedback row.
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
                    .frame(width: max(0, size.width - 2 * pad))
                    .offset(x: pad, y: controlsY + 46 + 3 + inlineShift)
                    .blurReveal(model.showOutputs, delay: 0.08, scale: 0.9, blur: 6)
                OutputPickerView(model: model)
                    .frame(width: max(0, size.width - 2 * pad), height: model.pickerHeight - NotchModel.outputTopGap - NotchModel.outputBottomGap)
                    .offset(x: pad, y: controlsY + 46 + NotchModel.outputTopGap + inlineShift)
                    .blurReveal(model.showOutputs, delay: 0.08, scale: 0.9, blur: 6)
                    .allowsHitTesting(expanded && model.showOutputs)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .blurReveal(expanded)

            // Full HUD (volume, brightness...) in the strip under the notch.
            if let hud = model.hud {
                if case .touchID(let phase) = hud {
                    TouchIDScan(phase: phase)
                        .frame(width: 58, height: 58)
                        .offset(x: size.width / 2 - 29, y: nh + 8)
                        .transition(.opacity)
                } else if case .accessory(let name, let model, let connected, let battery) = hud {
                    AccessoryFeature(name: name, model: model, connected: connected, battery: battery)
                        .frame(width: size.width - 44, height: hud.cardHeight - 14, alignment: .center)
                        .offset(x: 22, y: nh + 4)
                        .transition(.blurScale)
                } else if case .timer(let id) = hud {
                    TimerCard(model: model, id: id)
                        .frame(width: size.width - 36, height: hud.cardHeight - 14, alignment: .center)
                        .offset(x: 18, y: nh + 4)
                        .transition(.blurScale)
                } else if hud.isWing {
                    wingPill(for: hud, width: size.width, height: nh)
                        .transition(.blurScale)
                } else if case .card(let symbol, let title, let subtitle, let tint, _) = hud {
                    PluginCard(symbol: symbol, title: title, subtitle: subtitle, tint: tint)
                        .frame(width: size.width - 36, height: hud.cardHeight - 14, alignment: .center)
                        .offset(x: 18, y: nh + 6)
                        .transition(.blurScale)
                } else if case .power(let percent, let charging, let plugged) = hud {
                    PowerCard(percent: percent, charging: charging, plugged: plugged)
                        .frame(width: size.width - 44, height: hud.cardHeight - 14, alignment: .center)
                        .offset(x: 22, y: nh + 6)
                        .transition(.blurScale)
                } else if case .notification(let bundleID, let app, let title, let body) = hud {
                    NotificationCard(model: model, bundleID: bundleID, app: app, title: title, message: body)
                        .frame(width: size.width - 32, height: NotchModel.notificationHeight - 14, alignment: .topLeading)
                        .offset(x: 16, y: nh + 4)
                        .transition(.blurScale)
                } else {
                    HUDRow(kind: hud)
                        .padding(.horizontal, 20)
                        .frame(width: size.width, height: NotchModel.hudRow)
                        .offset(y: nh)
                        .transition(.blurScale)
                }
            }
        }
    }

    private var inlineShift: CGFloat { model.inlineHUD != nil ? NotchModel.inlineExtra : 0 }

    /// Focus, lock and icon-only toasts: they live inside the notch's own height, beside the camera housing.
    @ViewBuilder
    private func wingPill(for hud: HUDKind, width: CGFloat, height: CGFloat) -> some View {
        let notchWidth = model.geometry.notchWidth
        switch hud {
        case .focus(_, let symbol, let tint, let on):
            WingPill(symbol: symbol, tint: Color(hex: tint) ?? .white, text: on ? L("Açık", "On") : L("Kapalı", "Off"),
                     notchWidth: notchWidth, symbolOffEffect: !on)
                .frame(width: width, height: height)
        case .lock(let locked):
            WingPill(symbol: locked ? "lock.fill" : "lock.open.fill", tint: .white, text: nil, notchWidth: notchWidth,
                     symbolOffEffect: false)
                .frame(width: width, height: height)
        case .custom(let symbol, _, _, let tint):
            WingPill(symbol: symbol, tint: tint.flatMap(Color.init(hex:)) ?? .white, text: nil, notchWidth: notchWidth,
                     symbolOffEffect: false)
                .frame(width: width, height: height)
        default:
            EmptyView()
        }
    }

    private var subtitle: String {
        guard let m = model.media else { return "" }
        return m.artist.isEmpty ? m.album : m.artist
    }

    private var controls: some View {
        ZStack {
            HStack(spacing: 30) {
                TransportButton(symbol: "backward.fill", size: 21, diameter: 46) { model.onCommand?(.previous) }
                TransportButton(symbol: model.media?.isPlaying == true ? "pause.fill" : "play.fill",
                                size: 29, diameter: 52) { model.onCommand?(.toggle) }
                TransportButton(symbol: "forward.fill", size: 21, diameter: 46) { model.onCommand?(.next) }
            }
            HStack {
                Spacer()
                TransportButton(symbol: model.currentOutput?.symbol ?? "laptopcomputer", size: 14, diameter: 32,
                                tint: model.showOutputs ? notchBlue : .white.opacity(0.6),
                                highlighted: model.showOutputs) { model.toggleOutputs() }
            }
        }
    }
}

/// Dynamic Island style appearance: content blurs and scales out quickly toward the notch,
/// and comes back after the shape has started to grow, un-blurring while it scales up.
private struct BlurReveal: ViewModifier {
    var visible: Bool
    var delay: Double
    var scale: CGFloat
    var blur: CGFloat
    var anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .blur(radius: visible ? 0 : blur)
            .scaleEffect(visible ? 1 : scale, anchor: anchor)
            .opacity(visible ? 1 : 0)
            .animation(visible ? .spring(response: 0.38, dampingFraction: 0.8).delay(delay)
                               : .easeIn(duration: 0.13), value: visible)
    }
}

private extension View {
    func blurReveal(_ visible: Bool, delay: Double = 0.07, scale: CGFloat = 0.92, blur: CGFloat = 8,
                    anchor: UnitPoint = .top) -> some View {
        modifier(BlurReveal(visible: visible, delay: delay, scale: scale, blur: blur, anchor: anchor))
    }
}

private struct BlurScaleTransition: ViewModifier {
    var hidden: Bool
    func body(content: Content) -> some View {
        content.blur(radius: hidden ? 6 : 0).scaleEffect(hidden ? 0.92 : 1, anchor: .top).opacity(hidden ? 0 : 1)
    }
}

private extension AnyTransition {
    static var blurScale: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurScaleTransition(hidden: true), identity: BlurScaleTransition(hidden: false))
                .animation(.spring(response: 0.36, dampingFraction: 0.8).delay(0.07)),
            removal: .modifier(active: BlurScaleTransition(hidden: true), identity: BlurScaleTransition(hidden: false))
                .animation(.easeIn(duration: 0.13)))
    }
}

/// Icon button with a soft circular highlight on hover and a gentle press.
struct TransportButton: View {
    var symbol: String
    var size: CGFloat
    var diameter: CGFloat
    var tint: Color = .white
    /// Keeps the soft circle on while the button's panel is open.
    var highlighted = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(Color.white.opacity(highlighted ? 0.12 : (hovering ? 0.1 : 0))))
                .animation(.easeOut(duration: 0.2), value: highlighted)
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: hovering)
    }
}

struct ProgressRow: View {
    @ObservedObject var model: NotchModel
    var active = true
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !active)) { ctx in
            let duration = model.media?.duration ?? 0
            let position = model.media?.currentPosition(at: ViewClock.date(ctx.date)) ?? 0
            let fraction = dragFraction ?? (duration > 0 ? position / duration : 0)
            HStack(spacing: 10) {
                Text(formatTime(dragFraction.map { $0 * duration } ?? position))
                    .frame(width: 34, alignment: .leading)
                ScrubBar(fraction: fraction, enabled: duration > 0,
                         onBegan: { model.isInteracting = true },
                         onChanged: { dragFraction = $0 },
                         onEnded: { value in
                             model.onSeek?(value * duration)
                             dragFraction = nil
                             model.isInteracting = false
                         })
                    .animation(dragFraction == nil ? .linear(duration: 0.25) : nil, value: fraction)
                Text(duration > 0 ? formatTime(duration) : "--:--")
                    .frame(width: 34, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.45))
        }
        .frame(height: 14)
    }
}

// MARK: Audio output list

/// Control Center style list: a small caption, then one row per device with its icon in a round chip.
/// The active device gets a filled blue chip and a check mark; a tap moves both there right away.
struct OutputPickerView: View {
    @ObservedObject var model: NotchModel
    /// Shown as selected from the moment of the tap until the device list confirms it.
    @State private var pendingID: UInt32?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Ses Çıkışı", "Audio Output"))
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.2)
                .foregroundStyle(.white.opacity(0.4))
                .padding(.leading, 7)
                .frame(height: NotchModel.outputHeaderHeight, alignment: .center)

            if model.outputs.count > model.visibleRows {
                // More devices than fit: the last row fades out to hint that the list scrolls.
                ScrollView(.vertical, showsIndicators: false) { rows }
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.8),
                                                 .init(color: .black.opacity(0.15), location: 1)],
                                         startPoint: .top, endPoint: .bottom))
            } else {
                rows
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.outputs.map(\.id))
        .onChange(of: model.outputs) { _, _ in pendingID = nil }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(model.outputs) { output in
                OutputRow(output: output, selected: isSelected(output)) {
                    guard !isSelected(output) else { return }
                    pendingID = output.id
                    model.onSelectOutput?(output)
                }
            }
        }
    }

    private func isSelected(_ output: AudioOutput) -> Bool {
        pendingID.map { $0 == output.id } ?? output.isDefault
    }
}

private struct OutputRow: View {
    let output: AudioOutput
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(selected ? notchBlue : Color.white.opacity(hovering ? 0.14 : 0.1))
                    Image(systemName: output.symbol)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Color.white.opacity(0.85))
                }
                .frame(width: 26, height: 26)

                Text(output.name)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.78))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(notchBlue)
                    .opacity(selected ? 1 : 0)
                    .scaleEffect(selected ? 1 : 0.5)
            }
            .padding(.leading, 5)
            .padding(.trailing, 12)
            .frame(height: NotchModel.outputRowHeight)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.07 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(RowPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: selected)
    }
}

/// Rows only give a slight press, a full-width row shrinking like the round buttons would look heavy.
private struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

// MARK: HUD row (volume, brightness, media keys, output change, power)

/// Icon on the left, level bar (or a short label) right next to it. Used under the notch and inside the player.
struct HUDRow: View {
    let kind: HUDKind

    var body: some View {
        switch kind {
        case .volume(let level, let muted):
            LevelHUD(glyph: .speaker(level: level, muted: muted), level: muted ? 0 : level)
        case .brightness(let level):
            LevelHUD(glyph: .sun(level: level), level: level)
        default:
            HStack(spacing: 10) {
                icon.frame(width: 18)
                detail
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch kind {
        case .volume(let level, let muted):
            Image(systemName: muted || level <= 0 ? "speaker.slash.fill" : "speaker.wave.3.fill",
                  variableValue: muted ? 0 : level)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
        case .brightness(let level):
            Image(systemName: level < 0.5 ? "sun.min.fill" : "sun.max.fill")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
        case .mediaKey(let symbol, _), .output(_, let symbol):
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
        case .power(let percent, let charging, let plugged):
            Image(systemName: charging || plugged ? "bolt.fill" : batterySymbol(percent))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(charging || plugged ? Color.green : (percent <= 20 ? Color.red : Color.white))
        case .custom(let symbol, _, _, let tint):
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint.flatMap(Color.init(hex:)) ?? .white)
        case .notification:
            EmptyView()
        case .touchID:
            EmptyView()
        case .accessory, .focus, .card, .timer, .lock:
            EmptyView()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch kind {
        case .volume(let level, let muted):
            levelBar(muted ? 0 : level)
        case .brightness(let level):
            levelBar(level)
        case .mediaKey(_, let title):
            label(title)
        case .output(let name, _):
            label(name)
        case .notification:
            EmptyView()
        case .touchID:
            EmptyView()
        case .accessory, .focus, .card, .timer, .lock:
            EmptyView()
        case .custom(_, let text, let level, let tint):
            if let level { levelBar(level, tint: tint.flatMap(Color.init(hex:))) } else { label(text) }
        case .power(let percent, let charging, let plugged):
            label("\(percent)% · " + (charging ? L("Şarj oluyor", "Charging") : plugged ? L("Güce bağlı", "Plugged in") : L("Pil", "Battery")))
        }
    }

    private func label(_ text: String) -> some View {
        MarqueeText(text: text, font: .system(size: 10, weight: .medium), color: .white.opacity(0.75),
                    height: 14, alignment: .leading)
    }

    private func levelBar(_ level: Double, tint: Color? = nil) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule().fill(tint ?? Color.white)
                    .frame(width: max(4, geo.size.width * min(max(level, 0), 1)))
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: level)
        }
        .frame(height: 14)
    }

    private func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

extension Color {
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// Right side of an activity pill: countdown, progress ring, or a pulsing dot.
struct ActivityTrailing: View {
    let activity: Activity

    var body: some View {
        if activity.countsUp {
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                Text(formatTime(ViewClock.date(ctx.date).timeIntervalSince(activity.startDate)))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
            }
        } else if activity.isTimer {
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                Text(formatTime(activity.remaining(at: ViewClock.date(ctx.date)).rounded(.up)))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
            }
        } else if let level = activity.level {
            ZStack {
                Circle().stroke(Color.white.opacity(0.2), lineWidth: 2)
                Circle().trim(from: 0, to: level)
                    .stroke(activity.tint.flatMap(Color.init(hex:)) ?? .white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)
            .animation(.easeOut(duration: 0.3), value: level)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { ctx in
                let pulse = 0.55 + 0.45 * sin(ViewClock.date(ctx.date).timeIntervalSinceReferenceDate * 3)
                Circle().fill(activity.tint.flatMap(Color.init(hex:)) ?? .white)
                    .frame(width: 6, height: 6).opacity(pulse)
            }
        }
    }
}

/// A mirrored macOS notification: app icon, sender, message.
struct NotificationCard: View {
    @ObservedObject var model: NotchModel
    let bundleID: String
    let app: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: AppInfo.icon(for: bundleID))
                .resizable()
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(app).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    Text(L("şimdi", "now")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                }
                Text(title.isEmpty ? app : title)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The Touch ID animation, in the manner of the Face ID one in the Dynamic Island.
///
/// Waiting: Apple's fingerprint glyph alone, with a soft sheen sweeping up through its ridges.
/// Accepted: the glyph flashes green and dissolves into three thin rings spinning in 3D, smeared by motion blur.
/// The spin then slows down and every ring turns to face the viewer, so they settle into one single ring,
/// the very ring the checkmark is then drawn into. Nothing pops in or out; each stage becomes the next.
struct TouchIDScan: View {
    let phase: TouchIDPhase
    @State private var appeared = Date()
    @State private var successAt: Date?

    static let green = Color(red: 0.40, green: 0.89, blue: 0.50)
    static let pinkTop = Color(red: 1.0, green: 0.42, blue: 0.53)
    static let pinkBottom = Color(red: 1.0, green: 0.22, blue: 0.37)
    static let radius: CGFloat = 17.5
    static let lineWidth: CGFloat = 2.2

    // Timeline after the fingerprint is accepted (seconds).
    /// The glyph flashes and dissolves while the rings grow out of it.
    static let dissolveTime: Double = 0.24
    /// Full speed spin.
    static let spinEnd: Double = 0.62
    /// The spin has run down and the rings lie flat as one ring.
    static let settleEnd: Double = 1.02
    static let checkStart: Double = 0.9
    static let checkTime: Double = 0.42
    /// How long the success HUD stays: the whole animation plus a short look at the result.
    static var successDuration: Double { checkStart + checkTime + 0.75 }

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { gc, size in
                Self.draw(&gc, size: size, now: context.date, appeared: appeared, successAt: successAt)
            }
        }
        .onAppear {
            appeared = Date()
            if phase == .success { successAt = Date() }
        }
        .onChange(of: phase) { _, new in successAt = new == .success ? Date() : nil }
    }

    // MARK: Frame

    /// One frame; static so it can be rendered at chosen times (see the snapshot test).
    static func draw(_ gc: inout GraphicsContext, size: CGSize, now: Date, appeared: Date, successAt: Date?) {
        gc.translateBy(x: size.width / 2, y: size.height / 2)

        guard let successAt else {
            // Comes in like the island content: from slightly smaller and soft to sharp.
            let a = now.timeIntervalSince(appeared)
            let intro = spring(min(1, a / 0.45))
            drawFingerprint(&gc, t: a, scale: 0.82 + 0.18 * intro, blur: 4 * (1 - easeOut(min(1, a / 0.3))),
                            opacity: easeOut(min(1, a / 0.22)), green: 0)
            return
        }
        let e = max(0, now.timeIntervalSince(successAt))

        // 1. The glyph flashes green, shrinks a little and blurs away into the rings.
        if e < dissolveTime {
            let p = e / dissolveTime
            drawFingerprint(&gc, t: e + now.timeIntervalSince(appeared), scale: 1 - 0.3 * easeIn(p), blur: 5 * easeIn(p),
                            opacity: 1 - easeIn(p), green: min(1, p / 0.35))
        }

        // 2. Spinning rings that run down and lie flat.
        let ringsIn = easeOut(min(1, max(0, (e - 0.06) / 0.28)))
        if e < settleEnd + 0.05, ringsIn > 0 {
            drawRings(&gc, e: e, appear: ringsIn)
        }

        // 3. One crisp ring from the moment the rings have merged; the check is drawn into it,
        //    and both give a small, damped swell as the check lands.
        let swellT = max(0, e - (checkStart + checkTime * 0.8))
        let swell = 1 + 0.055 * exp(-swellT * 9) * sin(min(swellT * 14, .pi * 3))
        gc.scaleBy(x: swell, y: swell)
        if e >= settleEnd { strokeRing(&gc) }
        let checkP = min(1, max(0, (e - checkStart) / checkTime))
        if checkP > 0 { drawCheck(&gc, progress: checkP) }
    }

    // MARK: Easing

    private static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    private static func easeIn(_ x: Double) -> Double { x * x * x }
    private static func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    /// Damped spring step from 0 to 1 with a hint of overshoot, landing exactly on 1.
    private static func spring(_ x: Double) -> Double { 1 - exp(-6 * x) * cos(4.2 * x) * (1 - x) }

    // MARK: Fingerprint

    private static func drawFingerprint(_ gc: inout GraphicsContext, t: Double, scale: Double, blur: Double,
                                        opacity: Double, green g: Double) {
        guard opacity > 0.01 else { return }
        let glyph = gc.resolve(Image(systemName: "touchid"))
        let side: CGFloat = 26 * scale
        let rect = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
        gc.drawLayer { layer in
            layer.opacity = opacity
            if blur > 0.05 { layer.addFilter(.blur(radius: blur)) }
            layer.clipToLayer { mask in mask.draw(glyph, in: rect) }
            // Pink with a slight vertical gradient. On success green fills the ridges from the bottom up with a soft
            // edge (a crossfade would pass through a muddy olive).
            let pink = Gradient.Stop(color: pinkTop, location: 0)
            let stops: [Gradient.Stop]
            if g > 0 {
                let edge = 1 - g * 1.15
                stops = [pink,
                         .init(color: pinkBottom, location: min(1, max(0.001, edge))),
                         .init(color: green, location: min(1, max(0.002, edge + 0.15))),
                         .init(color: green, location: 1)]
            } else {
                stops = [pink, .init(color: pinkBottom, location: 1)]
            }
            layer.fill(Path(rect.insetBy(dx: -2, dy: -2)),
                       with: .linearGradient(Gradient(stops: stops),
                                             startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
            // A sheen travels up through the ridges every 2 seconds, like a sensor reading.
            let cycle = 2.0
            let p = (t.truncatingRemainder(dividingBy: cycle)) / cycle
            let y = rect.maxY + 10 - (rect.height + 20) * easeInOut(min(1, p / 0.7))
            if p < 0.7 {
                layer.fill(Path(rect.insetBy(dx: -2, dy: -12)),
                           with: .linearGradient(Gradient(stops: [.init(color: .white.opacity(0), location: 0),
                                                                  .init(color: .white.opacity(0.55), location: 0.5),
                                                                  .init(color: .white.opacity(0), location: 1)]),
                                                 startPoint: CGPoint(x: 0, y: y - 7), endPoint: CGPoint(x: 0, y: y + 7)))
            }
        }
    }

    // MARK: Rings

    /// Each ring: how fast it tumbles relative to the others, and the direction of its tumbling axis.
    private static let rings: [(rate: Double, axis: Double, precess: Double)] = [
        (1.0, 0.35, 0.9), (1.27, 1.9, -0.7), (0.83, 3.0, 0.55)
    ]

    /// Spin progress: accelerates, holds at full speed, then runs down to a stop at `settleEnd`.
    /// The integral of the speed profile, so rotation is perfectly smooth.
    private static func travel(_ t: Double) -> Double {
        let up = dissolveTime, hold = spinEnd, end = settleEnd
        let t = min(max(t, 0), end)
        if t < up { return t * t / (2 * up) }                  // linear speed ramp 0 → 1
        if t < hold { return up / 2 + (t - up) }
        // Speed (1 - x/d)² runs down to rest; its integral is d/3 · (1 - (1 - x/d)³).
        let d = end - hold, x = t - hold
        return up / 2 + (hold - up) + d / 3 * (1 - pow(1 - x / d, 3))
    }

    /// Tumble angle of a ring at time t; offset so that every ring ends exactly face-on (a multiple of π).
    private static func tumble(_ ring: Int, _ t: Double) -> Double {
        let speed = 2 * .pi * 2.3      // radians per unit travel at full speed
        let total = rings[ring].rate * speed * travel(settleEnd)
        let end = (total / .pi).rounded(.up) * .pi
        return rings[ring].rate * speed * travel(t) + (end - total)
    }

    /// The ring's tilt axis drifts while spinning and comes to rest wherever it is; a face-on ring looks the same at any axis.
    private static func axis(_ ring: Int, _ t: Double) -> Double {
        rings[ring].axis + rings[ring].precess * travel(t)
    }

    /// A circle tumbled by `theta` about an in-plane axis at angle `psi`; split into the half nearer the viewer and the far half.
    private static func ringHalves(theta: Double, psi: Double, scale: CGFloat) -> (front: Path, back: Path) {
        var front = Path(), back = Path()
        let steps = 40
        let r = radius * scale
        let (cp, sp) = (cos(psi), sin(psi))
        let ct = cos(theta), st = sin(theta)
        for half in 0..<2 {
            var path = Path()
            for i in 0...steps {
                let phi = (Double(half) + Double(i) / Double(steps)) * .pi
                let u = cos(phi) * r, v = sin(phi) * ct * r
                let point = CGPoint(x: u * cp - v * sp, y: u * sp + v * cp)
                i == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            // z = sin(phi) * sin(theta): positive on the first half when sin(theta) > 0.
            if (half == 0) == (st >= 0) { front = path } else { back = path }
        }
        return (front, back)
    }

    private static func drawRings(_ gc: inout GraphicsContext, e: Double, appear: Double) {
        // 0 while spinning, 1 once they lie flat: the rings tighten into one crisp line.
        let settle = easeInOut(min(1, max(0, (e - spinEnd) / (settleEnd - spinEnd))))
        let speed = 1 - settle
        // Motion blur: samples spread over a short exposure, longer at speed.
        let samples = 12
        let exposure = 0.03 * speed
        let scale = 0.62 + 0.38 * easeOut(appear)
        // Light adds up (plus-lighter): samples are weighted to sum to one, so a still ring is exactly as bright as
        // the crisp one; spread-out samples get a boost so the smear stays visible. The three rings meet as one,
        // so each takes a third of the light by then.
        let weights = (0..<samples).map { 1 - 0.7 * Double($0) / Double(samples) }
        let weightSum = weights.reduce(0, +)
        let perRing = (1 - settle) * 0.75 + settle / 3

        gc.drawLayer { layer in
            layer.opacity = appear
            if speed > 0.02 { layer.addFilter(.blur(radius: 0.3 + 0.7 * speed)) }
            layer.blendMode = .plusLighter
            for ring in 0..<rings.count {
                for i in 0..<samples {
                    let back = exposure * Double(i) / Double(samples - 1)
                    let t = e - back
                    let halves = ringHalves(theta: tumble(ring, t), psi: axis(ring, t), scale: scale)
                    let base = perRing * weights[i] / weightSum * (1 + 1.5 * speed)
                    let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    // The far half is dimmer while spinning, which gives the rings depth.
                    layer.stroke(halves.front, with: .color(green.opacity(min(1, base))), style: style)
                    layer.stroke(halves.back, with: .color(green.opacity(min(1, base * (0.45 + 0.55 * settle)))), style: style)
                }
            }
        }
    }

    private static func strokeRing(_ gc: inout GraphicsContext) {
        let circle = Path(ellipseIn: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius))
        gc.drawLayer { layer in
            layer.addFilter(.blur(radius: 2))
            layer.opacity = 0.12
            layer.stroke(circle, with: .color(green), lineWidth: lineWidth + 1.5)
        }
        gc.stroke(circle, with: .color(green), lineWidth: lineWidth)
    }

    // MARK: Checkmark

    private static func drawCheck(_ gc: inout GraphicsContext, progress: Double) {
        var check = Path()
        check.move(to: CGPoint(x: -7.0, y: 0.4))
        check.addLine(to: CGPoint(x: -2.4, y: 5.0))
        check.addLine(to: CGPoint(x: 7.4, y: -5.6))
        // The short stroke goes down quickly, the long one is drawn out more slowly.
        let eased = easeInOut(progress)
        let trimmed = check.trimmedPath(from: 0, to: eased)
        let style = StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
        gc.drawLayer { layer in
            layer.addFilter(.blur(radius: 2))
            layer.opacity = 0.12
            layer.stroke(trimmed, with: .color(green), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
        }
        gc.stroke(trimmed, with: .color(green), style: style)
    }
}

/// Battery card in the style of the iPhone's low-battery alert: big title, a hint under it,
/// and a tinted capsule with a battery glyph on the right.
struct PowerCard: View {
    let percent: Int
    let charging: Bool
    let plugged: Bool

    private var low: Bool { !plugged && !charging && percent <= 20 }

    private var tint: Color {
        if charging || plugged { return Color(red: 0.30, green: 0.85, blue: 0.45) }
        return low ? Color(red: 1.0, green: 0.27, blue: 0.30) : Color.white
    }

    private var title: String {
        if charging { return L("Şarj oluyor", "Charging") }
        if plugged { return L("Güce bağlı", "Plugged in") }
        return L("%\(percent) Pil", "\(percent)% Battery")
    }

    private var subtitle: String {
        if charging || plugged { return L("%\(percent) şarj", "\(percent)% charged") }
        if low {
            return ProcessInfo.processInfo.isLowPowerModeEnabled
                ? L("Düşük Güç Modu açık", "Low Power Mode is on")
                : L("Düşük Güç Modu için dokun", "Tap to turn on Low Power Mode")
        }
        return L("Pil kullanılıyor", "Running on battery")
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 8)
            BatteryCapsule(percent: percent, tint: tint, charging: charging || plugged, pulsing: low, period: percent <= 10 ? 0.9 : 1.5)
        }
        .padding(.leading, 6)
    }
}

/// Rounded tinted capsule holding a battery drawing and a thin ring, like the iPhone alert.
/// For low battery the ring pulses outward like a sonar ripple.
struct BatteryCapsule: View {
    let percent: Int
    let tint: Color
    let charging: Bool
    var pulsing = false
    /// Seconds per ripple; the closer to empty, the faster.
    var period: Double = 1.5

    var body: some View {
        if pulsing {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                let t = ViewClock.date(ctx.date).timeIntervalSinceReferenceDate / period
                // Two ripples half a cycle apart keep the motion continuous.
                BatteryCapsuleBody(percent: percent, tint: tint, charging: charging,
                                   ripples: [t.truncatingRemainder(dividingBy: 1), (t + 0.5).truncatingRemainder(dividingBy: 1)])
            }
        } else {
            BatteryCapsuleBody(percent: percent, tint: tint, charging: charging, ripples: [])
        }
    }
}

/// One frame of the capsule; `ripples` are phases (0...1) of expanding rings.
struct BatteryCapsuleBody: View {
    let percent: Int
    let tint: Color
    let charging: Bool
    let ripples: [Double]

    var body: some View {
        let level = CGFloat(min(max(percent, 0), 100)) / 100
        ZStack {
            Capsule().fill(tint.opacity(0.24))
            Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 1)
            ZStack {
                // The ring behind the battery, and the ripples that leave it.
                Circle().stroke(tint.opacity(0.5), lineWidth: 1.2).frame(width: 33, height: 33)
                ForEach(Array(ripples.enumerated()), id: \.offset) { _, phase in
                    let eased = 1 - pow(1 - phase, 2)
                    Circle()
                        .stroke(tint.opacity(0.55 * (1 - phase)), lineWidth: 1.2 + 0.8 * (1 - phase))
                        .frame(width: 33, height: 33)
                        .scaleEffect(1 + 0.6 * eased)
                }
            }
            .offset(x: -14)
            HStack(spacing: 1.5) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.opacity(0.28))
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(tint == .white ? Color.white.opacity(0.9) : tint.opacity(0.95))
                        .frame(width: max(7, 28 * level), height: 14)
                        .padding(.leading, 2)
                    if charging {
                        Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.black.opacity(0.7))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(width: 33, height: 18)
                RoundedRectangle(cornerRadius: 1.5).fill(tint.opacity(0.55)).frame(width: 2.5, height: 7)
            }
            .offset(x: -1)
        }
        .frame(width: 76, height: 44)
        .clipShape(Capsule())
    }
}

/// AirPods / Beats / JBL connected or disconnected: the device's own drawing, the name and the battery levels below.
/// AirPods, Beats and the like: the model's icon, "Connected" over the name, and the battery as a ring on the right.
struct AccessoryFeature: View {
    let name: String
    let model: AccessoryModel
    let connected: Bool
    let battery: AccessoryBattery?

    private var tint: Color { model.brandTint.flatMap(Color.init(hex:)) ?? .white }

    /// The ring shows the weakest earbud (or the single battery of headphones).
    private var level: Int? {
        guard let battery else { return nil }
        return battery.main ?? [battery.left, battery.right].compactMap { $0 }.min() ?? battery.box
    }

    /// "Connected" first; once the levels are known the label tells the details.
    private var detail: String {
        guard connected else { return L("Bağlantı kesildi", "Disconnected") }
        guard let battery else { return L("Bağlandı", "Connected") }
        var parts: [String] = []
        if let left = battery.left { parts.append("L \(left)") }
        if let right = battery.right { parts.append("R \(right)") }
        if let box = battery.box { parts.append(L("Kutu", "Case") + " \(box)") }
        return parts.isEmpty ? L("Bağlandı", "Connected") : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.symbolName)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(tint.opacity(connected ? 0.96 : 0.4))
                .frame(width: 46)
            VStack(alignment: .leading, spacing: 1) {
                Text(detail)
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(connected ? 1 : 0.7))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if connected, let level {
                BatteryRing(percent: level)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.35), value: level)
        .animation(.easeOut(duration: 0.25), value: connected)
    }
}

/// A thin progress ring with the percentage inside, green and red when low.
struct BatteryRing: View {
    let percent: Int
    var size: CGFloat = 34

    private var color: Color { percent <= 20 ? Color(red: 1.0, green: 0.27, blue: 0.30) : Color(red: 0.30, green: 0.85, blue: 0.45) }

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.22), lineWidth: 3)
            Circle().trim(from: 0, to: CGFloat(min(max(percent, 0), 100)) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(percent)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.5), value: percent)
    }
}

/// A light event in the notch's own height: an icon in the left wing and, optionally, a word in the right one.
struct WingPill: View {
    let symbol: String
    let tint: Color
    let text: String?
    let notchWidth: CGFloat
    /// Strikes the icon through, for "off" states.
    let symbolOffEffect: Bool

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(symbolOffEffect ? Color.white.opacity(0.6) : tint)
                    .contentTransition(.symbolEffect(.replace))
                if symbolOffEffect {
                    Capsule().fill(Color.white.opacity(0.6)).frame(width: 19, height: 1.8).rotationEffect(.degrees(-45))
                }
            }
            .frame(width: 22)
            Spacer(minLength: notchWidth)   // stays clear of the camera housing
            if let text {
                Text(text)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(symbolOffEffect ? Color.white.opacity(0.6) : tint)
                    .lineLimit(1)
                    .frame(minWidth: 22, alignment: .trailing)
            }
        }
        .padding(.horizontal, 13)
    }
}

/// A running timer: pause and cancel on the left, the label and the time left in large type on the right.
struct TimerCard: View {
    @ObservedObject var model: NotchModel
    let id: String

    private static let orange = Color(red: 1.0, green: 0.62, blue: 0.04)

    var body: some View {
        let activity = model.activities.first { $0.id == id }
        let tint = activity?.tint.flatMap(Color.init(hex:)) ?? Self.orange
        let paused = activity?.isPaused == true
        HStack(spacing: 8) {
            roundButton(paused ? "play.fill" : "pause.fill", fill: tint.opacity(0.28), foreground: tint) { model.toggleTimerPause(id: id) }
            roundButton("xmark", fill: Color.white.opacity(0.16), foreground: .white) { model.cancelTimer(id: id) }
            Spacer(minLength: 6)
            HStack(alignment: .lastTextBaseline, spacing: 7) {
                Text(label(activity)).font(.system(size: 12, weight: .medium)).foregroundStyle(tint.opacity(0.9)).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                    let left = activity?.remaining(at: ViewClock.date(ctx.date)).rounded(.up) ?? 0
                    Text(String(format: "%02d:%02d", Int(left) / 60, Int(left) % 60))
                        .font(.system(size: 31, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(tint)
                        .opacity(paused ? 0.6 : 1)
                }
            }
        }
    }

    private func label(_ activity: Activity?) -> String {
        let text = activity?.text ?? ""
        return text.isEmpty ? L("Zamanlayıcı", "Timer") : text
    }

    private func roundButton(_ symbol: String, fill: Color, foreground: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(foreground)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 38, height: 38)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
    }
}

/// Red recording dot with a soft pulsing halo.
struct RecordingDot: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24)) { ctx in
            let pulse = 0.5 + 0.5 * sin(ViewClock.date(ctx.date).timeIntervalSinceReferenceDate * 3.2)
            ZStack {
                Circle().fill(Color(red: 1, green: 0.27, blue: 0.23).opacity(0.25 * pulse)).scaleEffect(1.9)
                Circle().fill(Color(red: 1, green: 0.27, blue: 0.23))
            }
        }
    }
}

/// A card pushed by a plugin: a tinted tile with a symbol, a title and a subtitle.
struct PluginCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    let tint: String?

    private var color: Color { tint.flatMap(Color.init(hex:)) ?? .white }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(color.opacity(0.22))
                Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(color)
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Volume / brightness feedback: a glyph that fills with the level next to a smooth, softly glowing bar.
struct LevelHUD: View {
    enum Glyph {
        case speaker(level: Double, muted: Bool)
        case sun(level: Double)
    }

    let glyph: Glyph
    let level: Double

    var body: some View {
        HStack(spacing: 11) {
            glyphView
                .frame(width: 22, height: 22)
            LevelTrack(level: level)
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var glyphView: some View {
        switch glyph {
        case .speaker(let level, let muted):
            let silent = muted || level <= 0
            // Quick crossfade between the two glyphs; the system `.replace` effect is noticeably slower.
            ZStack {
                Image(systemName: "speaker.slash.fill")
                    .opacity(silent ? 1 : 0)
                    .scaleEffect(silent ? 1 : 0.85)
                Image(systemName: "speaker.wave.3.fill", variableValue: muted ? 0 : level)
                    .opacity(silent ? 0 : 1)
                    .scaleEffect(silent ? 0.85 : 1)
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white.opacity(muted ? 0.6 : 1))
            .animation(.easeInOut(duration: 0.33), value: silent)
            .animation(.easeOut(duration: 0.2), value: level)
        case .sun(let level):
            SunGlyph(level: level)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: level)
        }
    }
}

struct LevelTrack: View {
    let level: Double

    var body: some View {
        GeometryReader { geo in
            let fraction = CGFloat(min(max(level, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.17))
                Capsule()
                    .fill(LinearGradient(colors: [.white, .white.opacity(0.82)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(fraction > 0 ? 6 : 0, geo.size.width * fraction))
                    .shadow(color: .white.opacity(0.3), radius: 2.5)
            }
            .frame(height: 6)
            .frame(maxHeight: .infinity)
            .animation(.spring(response: 0.3, dampingFraction: 0.82), value: level)
        }
        .frame(height: 20)
    }
}

/// Apple's own sun drawings: the long-rayed one fades in over the short-rayed one as the brightness rises,
/// so the rays grow a little and the shape stays as well drawn as the system icons.
struct SunGlyph: View {
    var level: Double

    var body: some View {
        let level = min(max(level, 0), 1)
        ZStack {
            // The short-rayed sun stays solid underneath; the long-rayed one fades in over it, so nothing ever looks dim.
            Image(systemName: "sun.min.fill")
            Image(systemName: "sun.max.fill").opacity(level)
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 22, height: 22)
    }
}
