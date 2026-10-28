import AppKit
import SwiftUI

/// The local control API other apps can call (see README.md). Everything is JSON over HTTP on 127.0.0.1.
@MainActor
final class NotchAPI {
    private let controller: NotchController
    private let hub: MediaHub
    private let settings = Settings.shared
    private var server: LocalHTTPServer?
    var diagnostics: (() -> [ComponentStatus])?
    var demo: ((String) -> Bool)?

    init(controller: NotchController, hub: MediaHub) {
        self.controller = controller
        self.hub = hub
    }

    /// Starts, stops or reconfigures the server to match the settings.
    func apply() {
        guard settings.apiEnabled else {
            server?.stop()
            server = nil
            return
        }
        if server == nil {
            let new = LocalHTTPServer(port: settings.apiPort)
            new.handler = { [weak self] request in
                await MainActor.run { self?.handle(request) ?? .error(503, "not ready") }
            }
            new.start()
            server = new
        }
        server?.token = settings.apiToken
    }

    var isListening: Bool { server?.isListening ?? false }

    private var model: NotchModel { controller.model }

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        var json: [String: Any] = [:]
        if !request.body.isEmpty {
            guard let parsed = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
                return .error(400, "body must be a JSON object")
            }
            json = parsed
        }
        do {
            switch (request.method, request.path) {
            case ("GET", "/v1/health"):
                return .ok(["version": 2, "port": Int(settings.apiPort)])
            case ("GET", "/v1/state"):
                return .ok(state())
            case ("GET", "/v1/diagnostics"):
                return .ok(["macOS": Diagnostics.osVersion, "components": Diagnostics.json(diagnostics?() ?? [])])
            case ("GET", "/v1/activities"):
                return .ok(["activities": model.activities.map(describe)])
            case ("POST", "/v1/toast"):
                return try toast(json)
            case ("POST", "/v1/activity"):
                return try activity(json)
            case ("POST", "/v1/activity/end"):
                guard let id = try JSONField.identifier(try JSONField.string(json, "id")) else { throw APIError.bad("\"id\" is required") }
                return .ok(["ended": model.endActivity(id: id)])
            case ("POST", "/v1/activity/clear"):
                let ids = model.activities.map(\.id)
                ids.forEach { model.endActivity(id: $0) }
                return .ok(["cleared": ids.count])
            case ("POST", "/v1/demo"):
                // {"kind": "all" | "toast" | "volume" | "brightness" | "focus" | "airpods" | "output" | "charging" | "battery" | "critical" | "notification" | "touchid" | "timer"}
                let kind = try JSONField.string(json, "kind") ?? "all"
                guard demo?(kind) == true else { throw APIError.bad("unknown demo kind \"\(kind)\"") }
                return .ok(["kind": kind])
            case ("POST", "/v1/timer"):
                return try timer(json)
            case ("POST", "/v1/media"):
                return try media(json)
            case ("POST", "/v1/expand"):
                model.expand()
                return .ok()
            case ("POST", "/v1/collapse"):
                model.collapse()
                return .ok()
            default:
                return .error(404, "unknown route \(request.method) \(request.path)")
            }
        } catch let error as APIError {
            return .error(error.status, error.message)
        } catch {
            return .error(500, "\(error)")
        }
    }

    // MARK: Routes

    private func toast(_ json: [String: Any]) throws -> HTTPResponse {
        // Validate first so mistakes are reported the same way whether or not the notch is hidden.
        let request = try ToastRequest.parse(json, defaultDuration: settings.defaultToastSeconds)
        guard !controller.isSuspended else { return .error(409, "notch is hidden (full screen)") }
        model.showHUD(.custom(symbol: request.symbol, text: request.text, level: request.level, tint: request.tint),
                      duration: request.duration, id: request.id)
        return .ok(["queued": model.queuedHUDCount])
    }

    private func activity(_ json: [String: Any]) throws -> HTTPResponse {
        let request = try ActivityRequest.parse(json)
        model.upsertActivity(Activity(id: request.id, symbol: request.symbol, text: request.text, subtitle: request.subtitle,
                                      level: request.level, tint: request.tint,
                                      expires: Date().addingTimeInterval(request.ttl)))
        return .ok(["count": model.activities.count])
    }

    private func timer(_ json: [String: Any]) throws -> HTTPResponse {
        let request = try TimerRequest.parse(json)
        let now = Date()
        model.upsertActivity(Activity(id: request.id, symbol: request.symbol, text: request.label, subtitle: nil, level: nil,
                                      tint: request.tint, startDate: now, endDate: now.addingTimeInterval(request.seconds),
                                      expires: now.addingTimeInterval(request.seconds + 5)))
        return .ok(["id": request.id])
    }

    private func media(_ json: [String: Any]) throws -> HTTPResponse {
        switch try JSONField.string(json, "action") {
        case "toggle": hub.send(.toggle)
        case "next": hub.send(.next)
        case "previous": hub.send(.previous)
        case "seek":
            guard let seconds = try JSONField.number(json, "seconds") else { throw APIError.bad("seek needs \"seconds\"") }
            hub.seek(to: max(0, seconds))
        default:
            throw APIError.bad("action must be toggle, next, previous or seek")
        }
        return .ok()
    }

    // MARK: Descriptions

    private func describe(_ a: Activity) -> [String: Any] {
        var out: [String: Any] = ["id": a.id, "text": a.text, "symbol": a.symbol]
        if let level = a.level { out["level"] = level }
        if a.isTimer { out["remaining"] = a.remaining() }
        return out
    }

    private func state() -> [String: Any] {
        var out: [String: Any] = [:]
        switch model.presentation {
        case .idle: out["presentation"] = "idle"
        case .live: out["presentation"] = "live"
        case .expanded: out["presentation"] = "expanded"
        case .hud: out["presentation"] = "hud"
        }
        out["hidden"] = controller.isSuspended
        if let m = model.media {
            let position = m.currentPosition()
            out["media"] = ["title": m.title, "artist": m.artist, "album": m.album, "app": m.source.bundleID,
                            "playing": m.isPlaying, "duration": m.duration.isFinite ? m.duration : 0,
                            "position": position.isFinite ? position : 0]
        } else {
            out["media"] = NSNull()
        }
        out["activities"] = model.activities.count
        if let volume = AudioControl.shared.volume(), volume.isFinite { out["volume"] = volume } else { out["volume"] = NSNull() }
        return out
    }
}
