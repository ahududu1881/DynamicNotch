import Foundation
import Network

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

struct HTTPResponse {
    var status = 200
    var json: [String: Any]

    static func ok(_ extra: [String: Any] = [:]) -> HTTPResponse { HTTPResponse(json: ["ok": true].merging(extra) { $1 }) }
    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status, json: ["ok": false, "error": message])
    }
}

/// Minimal HTTP/1.1 server bound to 127.0.0.1 only. One request per connection.
/// Built to survive anything a local client (or a hostile web page) can throw at it.
final class LocalHTTPServer: @unchecked Sendable {
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 256 * 1024
    static let maxConnections = 64
    static let connectionTimeout: TimeInterval = 5

    let port: UInt16
    var handler: (@Sendable (HTTPRequest) async -> HTTPResponse)?

    private let lock = NSLock()
    private var _token: String?
    var token: String? {
        get { lock.lock(); defer { lock.unlock() }; return _token }
        set { lock.lock(); _token = (newValue?.isEmpty == false) ? newValue : nil; lock.unlock() }
    }

    private var listener: NWListener?
    private var ready = false
    var isListening: Bool { queue.sync { ready } }
    private var running = false
    private var restartDelay: TimeInterval = 1
    /// Open connections in arrival order. When the table is full the oldest one is dropped (slow-client defence).
    private var connections: [(id: ObjectIdentifier, connection: NWConnection)] = []
    private let queue = DispatchQueue(label: "dynamicnotch.http")

    init(port: UInt16) { self.port = port }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            listen()
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            ready = false
            listener?.cancel()
            listener = nil
        }
    }

    private func listen() {
        guard running, listener == nil, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        do {
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.ready = true
                    self.restartDelay = 1
                case .failed(let error):
                    NSLog("DynamicNotch API listener failed: \(error)")
                    self.ready = false
                    self.listener?.cancel()
                    self.listener = nil
                    self.scheduleRestart()
                default: break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NSLog("DynamicNotch API cannot listen on \(port): \(error)")
            scheduleRestart()
        }
    }

    /// Port busy, network stack reset, wake from sleep...: keep trying with a capped back-off.
    private func scheduleRestart() {
        guard running else { return }
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 30)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.listen() }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        if connections.count >= Self.maxConnections {
            let oldest = connections.removeFirst()
            oldest.connection.cancel()
        }
        let id = ObjectIdentifier(connection)
        connections.append((id, connection))

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.queue.async { self?.connections.removeAll { $0.id == id } }
                if case .failed = state { connection.cancel() }
            default: break
            }
        }
        connection.start(queue: queue)

        let timeout = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + Self.connectionTimeout, execute: timeout)
        receive(connection, buffer: Data(), timeout: timeout)
    }

    private func receive(_ connection: NWConnection, buffer: Data, timeout: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch Self.parse(buffer) {
            case .complete(let request):
                self.respond(to: request, on: connection, timeout: timeout)
            case .invalid(let status, let reason):
                self.send(.error(status, reason), on: connection, timeout: timeout)
            case .incomplete:
                if error == nil, !isComplete, buffer.count < Self.maxHeaderBytes + Self.maxBodyBytes + 1024 {
                    self.receive(connection, buffer: buffer, timeout: timeout)
                } else {
                    self.send(.error(400, "incomplete request"), on: connection, timeout: timeout)
                }
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection, timeout: DispatchWorkItem) {
        // DNS-rebinding guard: the Host header must be the loopback address with our port.
        let host = (request.headers["host"] ?? "").lowercased()
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else {
            return send(.error(403, "forbidden host"), on: connection, timeout: timeout)
        }
        // JSON-only POSTs force browsers into a CORS preflight that is never answered.
        if request.method == "POST", !(request.headers["content-type"] ?? "").lowercased().contains("application/json") {
            return send(.error(415, "Content-Type must be application/json"), on: connection, timeout: timeout)
        }
        if let token, request.path != "/v1/health" {
            let supplied = request.headers["authorization"] ?? ""
            guard Self.constantTimeEqual(supplied, "Bearer \(token)") else {
                return send(.error(401, "missing or wrong bearer token"), on: connection, timeout: timeout)
            }
        }
        guard let handler else { return send(.error(503, "not ready"), on: connection, timeout: timeout) }
        Task { [weak self] in
            let response = await handler(request)
            self?.send(response, on: connection, timeout: timeout)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection, timeout: DispatchWorkItem) {
        var response = response
        // NaN / infinity would make JSONSerialization raise an Objective-C exception.
        if !JSONSerialization.isValidJSONObject(response.json) {
            response = .error(500, "response could not be encoded")
        }
        let body = (try? JSONSerialization.data(withJSONObject: response.json)) ?? Data("{}".utf8)
        let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                       409: "Conflict", 413: "Payload Too Large", 415: "Unsupported Media Type",
                       431: "Request Header Fields Too Large", 500: "Internal Server Error",
                       501: "Not Implemented", 503: "Service Unavailable"]
        var head = "HTTP/1.1 \(response.status) \(reasons[response.status] ?? "Error")\r\nContent-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            timeout.cancel()
            connection.cancel()
        })
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<min(x.count, y.count) { diff |= Int(x[i] ^ y[i]) }
        return diff == 0
    }

    // MARK: Parsing

    enum Parsed {
        case complete(HTTPRequest)
        case incomplete
        case invalid(Int, String)
    }

    static func parse(_ data: Data) -> Parsed {
        let terminator = Data("\r\n\r\n".utf8)
        guard let separator = data.range(of: terminator) else {
            return data.count > maxHeaderBytes ? .invalid(431, "headers too large") : .incomplete
        }
        guard separator.lowerBound <= maxHeaderBytes else { return .invalid(431, "headers too large") }
        guard let head = String(data: data[data.startIndex..<separator.lowerBound], encoding: .utf8) else {
            return .invalid(400, "headers are not valid UTF-8")
        }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."),
              requestLine[0].allSatisfy({ $0.isASCII && $0.isLetter }),
              requestLine[1].hasPrefix("/"), !requestLine[1].contains("\0") else {
            return .invalid(400, "malformed request line")
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(400, "malformed header") }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .invalid(501, "chunked bodies are not supported") }

        var length = 0
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.count <= 9, raw.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(raw) else {
                return .invalid(400, "invalid Content-Length")
            }
            guard value <= maxBodyBytes else { return .invalid(413, "body too large") }
            length = value
        }

        let bodyStart = separator.upperBound
        guard data.count - bodyStart >= length else { return .incomplete }
        let body = data.subdata(in: bodyStart..<(bodyStart + length))
        let path = String(requestLine[1]).components(separatedBy: "?")[0]
        return .complete(HTTPRequest(method: String(requestLine[0]).uppercased(), path: path, headers: headers, body: body))
    }
}
