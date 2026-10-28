import XCTest
@testable import DynamicNotch

final class HTTPParserTests: XCTestCase {
    private func parse(_ text: String) -> LocalHTTPServer.Parsed { LocalHTTPServer.parse(Data(text.utf8)) }

    private func complete(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> HTTPRequest? {
        guard case .complete(let r) = parse(text) else { XCTFail("expected complete", file: file, line: line); return nil }
        return r
    }

    private func invalidStatus(_ text: String) -> Int? {
        if case .invalid(let status, _) = parse(text) { return status }
        return nil
    }

    func testParsesGetAndLowercasesHeaders() {
        let r = complete("GET /v1/health?x=1 HTTP/1.1\r\nHost: 127.0.0.1:1\r\nX-Thing: A\r\n\r\n")
        XCTAssertEqual(r?.method, "GET")
        XCTAssertEqual(r?.path, "/v1/health")
        XCTAssertEqual(r?.headers["x-thing"], "A")
    }

    func testParsesBody() {
        let r = complete("POST /v1/toast HTTP/1.1\r\nContent-Length: 7\r\n\r\n{\"a\":1}")
        XCTAssertEqual(String(data: r?.body ?? Data(), encoding: .utf8), "{\"a\":1}")
    }

    func testIgnoresBytesBeyondContentLength() {
        let r = complete("POST /x HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}EXTRA")
        XCTAssertEqual(r?.body.count, 2)
    }

    func testIncompleteHeadersAndBody() {
        guard case .incomplete = parse("GET /v1/health HTTP/1.1\r\nHost: x") else { return XCTFail() }
        guard case .incomplete = parse("POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\n12345") else { return XCTFail() }
    }

    func testNegativeContentLengthIsRejectedNotCrashing() {
        XCTAssertEqual(invalidStatus("POST /x HTTP/1.1\r\nContent-Length: -5\r\n\r\n"), 400)
    }

    func testBadContentLengths() {
        XCTAssertEqual(invalidStatus("POST /x HTTP/1.1\r\nContent-Length: abc\r\n\r\n"), 400)
        XCTAssertEqual(invalidStatus("POST /x HTTP/1.1\r\nContent-Length: \r\n\r\n"), 400)
        XCTAssertEqual(invalidStatus("POST /x HTTP/1.1\r\nContent-Length: 99999999999999\r\n\r\n"), 400)
        XCTAssertEqual(invalidStatus("POST /x HTTP/1.1\r\nContent-Length: 300000\r\n\r\n"), 413)
    }

    func testMalformedRequestLines() {
        XCTAssertEqual(invalidStatus("GARBAGE\r\n\r\n"), 400)
        XCTAssertEqual(invalidStatus("GET /x\r\n\r\n"), 400)
        XCTAssertEqual(invalidStatus("GET x HTTP/1.1\r\n\r\n"), 400)
        XCTAssertEqual(invalidStatus("GET /x SPDY/3\r\n\r\n"), 400)
        XCTAssertEqual(invalidStatus("G3T /x HTTP/1.1\r\n\r\n"), 400)
        XCTAssertEqual(invalidStatus("GET /x\0y HTTP/1.1\r\n\r\n"), 400)
    }

    func testMalformedHeaderLine() {
        XCTAssertEqual(invalidStatus("GET /x HTTP/1.1\r\nno-colon-here\r\n\r\n"), 400)
    }

    func testChunkedIsNotSupported() {
        XCTAssertEqual(invalidStatus("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"), 501)
    }

    func testHeaderSizeLimit() {
        let big = "GET /x HTTP/1.1\r\nX: " + String(repeating: "A", count: 20_000) + "\r\n\r\n"
        XCTAssertEqual(invalidStatus(big), 431)
        let noTerminator = "GET /x HTTP/1.1\r\nX: " + String(repeating: "A", count: 20_000)
        XCTAssertEqual(invalidStatus(noTerminator), 431)
    }

    func testBinaryGarbageNeverCrashes() {
        for _ in 0..<500 {
            var bytes = [UInt8](repeating: 0, count: Int.random(in: 0...600))
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
            _ = LocalHTTPServer.parse(Data(bytes))
        }
        // Random printable fragments of real requests.
        let pieces = ["GET", " ", "/v1/toast", "HTTP/1.1", "\r\n", "Content-Length:", "5", "-1", ":", "\r\n\r\n", "{", "}", "\0"]
        for _ in 0..<2000 {
            let text = (0..<Int.random(in: 1...12)).map { _ in pieces.randomElement()! }.joined()
            _ = LocalHTTPServer.parse(Data(text.utf8))
        }
    }
}
