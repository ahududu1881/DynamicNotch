import AppKit

/// Validation for everything the local API accepts. Pure functions so they can be tested exhaustively.
struct APIError: Error, Equatable {
    let status: Int
    let message: String
    static func bad(_ message: String) -> APIError { APIError(status: 400, message: message) }
}

enum JSONField {
    static func string(_ json: [String: Any], _ key: String, maxLength: Int = 200) throws -> String? {
        guard let raw = json[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? String else { throw APIError.bad("\"\(key)\" must be a string") }
        return String(value.prefix(maxLength))
    }

    static func number(_ json: [String: Any], _ key: String) throws -> Double? {
        guard let raw = json[key], !(raw is NSNull) else { return nil }
        // JSON booleans bridge to NSNumber; they are not numbers here.
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw APIError.bad("\"\(key)\" must be a number")
        }
        guard number.doubleValue.isFinite else { throw APIError.bad("\"\(key)\" must be a finite number") }
        return number.doubleValue
    }

    static func symbol(_ name: String?, fallback: String) -> String {
        guard let name, !name.isEmpty, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else { return fallback }
        return name
    }

    static func bool(_ json: [String: Any], _ key: String) throws -> Bool? {
        guard let raw = json[key], !(raw is NSNull) else { return nil }
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw APIError.bad("\"\(key)\" must be true or false") }
        return number.boolValue
    }

    /// Links a plugin may attach to a card or open: web pages, mail and system settings, never files or scripts.
    static func safeURL(_ value: String?) -> String? {
        guard let value, let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "x-apple.systempreferences"].contains(scheme) else { return nil }
        return value
    }

    static func tint(_ value: String?) -> String? {
        guard let value, Color(hex: value) != nil else { return nil }
        return value
    }

    static func identifier(_ value: String?) throws -> String? {
        guard let value else { return nil }
        guard (1...64).contains(value.count), value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:".contains($0)) }) else {
            throw APIError.bad("\"id\" must be 1-64 characters of letters, digits, - _ . :")
        }
        return value
    }
}

import SwiftUI

struct ToastRequest: Equatable {
    var id: String?
    var text: String
    var symbol: String
    var level: Double?
    var tint: String?
    var duration: Double

    /// {"text","symbol","level","tint","duration","id"}; needs text and/or level.
    static func parse(_ json: [String: Any], defaultDuration: Double) throws -> ToastRequest {
        let text = try JSONField.string(json, "text", maxLength: 80) ?? ""
        let level = try JSONField.number(json, "level").map { min(max($0, 0), 1) }
        guard !text.isEmpty || level != nil else { throw APIError.bad("provide \"text\" and/or \"level\"") }
        return ToastRequest(id: try JSONField.identifier(try JSONField.string(json, "id", maxLength: 80)),
                            text: text,
                            symbol: JSONField.symbol(try JSONField.string(json, "symbol"), fallback: "bell.fill"),
                            level: level,
                            tint: JSONField.tint(try JSONField.string(json, "tint")),
                            duration: min(max(try JSONField.number(json, "duration") ?? defaultDuration, 0.5), 10))
    }
}

struct ActivityRequest: Equatable {
    var id: String
    var text: String
    var subtitle: String?
    var symbol: String
    var level: Double?
    var tint: String?
    var ttl: Double
    var countsUp = false

    /// {"id" (required),"text","subtitle","symbol","level","tint","ttl"}
    static func parse(_ json: [String: Any]) throws -> ActivityRequest {
        guard let id = try JSONField.identifier(try JSONField.string(json, "id", maxLength: 80)) else {
            throw APIError.bad("\"id\" is required")
        }
        return ActivityRequest(id: id,
                               text: try JSONField.string(json, "text", maxLength: 80) ?? "",
                               subtitle: try JSONField.string(json, "subtitle", maxLength: 120),
                               symbol: JSONField.symbol(try JSONField.string(json, "symbol"), fallback: "circle.fill"),
                               level: try JSONField.number(json, "level").map { min(max($0, 0), 1) },
                               tint: JSONField.tint(try JSONField.string(json, "tint")),
                               ttl: min(max(try JSONField.number(json, "ttl") ?? 3600, 1), 86_400),
                               countsUp: try JSONField.bool(json, "countsUp") ?? false)
    }
}

struct TimerRequest: Equatable {
    var id: String
    var seconds: Double
    var label: String
    var symbol: String
    var tint: String

    /// {"seconds" (required, 1...86400),"label","id","symbol","tint"}
    static func parse(_ json: [String: Any]) throws -> TimerRequest {
        guard let seconds = try JSONField.number(json, "seconds") else { throw APIError.bad("\"seconds\" is required") }
        guard (1...86_400).contains(seconds) else { throw APIError.bad("\"seconds\" must be between 1 and 86400") }
        return TimerRequest(id: try JSONField.identifier(try JSONField.string(json, "id", maxLength: 80)) ?? "timer",
                            seconds: seconds,
                            label: try JSONField.string(json, "label", maxLength: 60) ?? L("Zamanlayıcı", "Timer"),
                            symbol: JSONField.symbol(try JSONField.string(json, "symbol"), fallback: "timer"),
                            tint: JSONField.tint(try JSONField.string(json, "tint")) ?? "#FF9F0A")
    }
}

struct CardRequest: Equatable {
    var title: String
    var subtitle: String
    var symbol: String
    var tint: String?
    var url: String?
    var duration: Double
    var id: String?

    /// {"title" (required),"subtitle","symbol","tint","url","duration","id"}
    static func parse(_ json: [String: Any], defaultDuration: Double) throws -> CardRequest {
        guard let title = try JSONField.string(json, "title", maxLength: 80), !title.isEmpty else { throw APIError.bad("\"title\" is required") }
        return CardRequest(title: title,
                           subtitle: try JSONField.string(json, "subtitle", maxLength: 140) ?? "",
                           symbol: JSONField.symbol(try JSONField.string(json, "symbol"), fallback: "square.grid.2x2.fill"),
                           tint: JSONField.tint(try JSONField.string(json, "tint")),
                           url: JSONField.safeURL(try JSONField.string(json, "url", maxLength: 500)),
                           duration: min(max(try JSONField.number(json, "duration") ?? max(defaultDuration, 4), 1), 15),
                           id: try JSONField.identifier(try JSONField.string(json, "id", maxLength: 80)))
    }
}
