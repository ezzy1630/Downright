import Foundation
import Testing
@testable import DownrightApp

/// The production probe's conditional-GET contract: validators round-trip as
/// the matching conditional header, the server's own validators are preferred
/// over ours, and an unchanged feed answers with no body to hash.
@Suite(.serialized)
@MainActor
struct ReleaseFeedURLProbeTests {
    private final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
        nonisolated(unsafe) static var seenRequests: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.seenRequests.append(request)
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let (response, data) = handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeProbe() -> ReleaseFeedURLProbe {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.seenRequests = []
        return ReleaseFeedURLProbe(session: URLSession(configuration: configuration))
    }

    private static func response(
        status: Int, headers: [String: String] = [:], url: URL
    ) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    @Test("A Last-Modified validator is stored and sent back as If-Modified-Since")
    func lastModifiedRoundTrips() async throws {
        let feed = URL(string: "https://feeds.example/appcast.xml")!
        let date = "Wed, 21 Oct 2026 07:28:00 GMT"
        StubURLProtocol.handler = { request in
            (Self.response(status: 200, headers: ["Last-Modified": date], url: request.url!), Data("feed".utf8))
        }
        let probe = makeProbe()

        guard case .changed(let validator?) = await probe.probe(feed: feed, validator: nil) else {
            Issue.record("a first probe must report a change")
            return
        }
        #expect(validator == "lastModified:\(date)")

        // The next probe carries the date and a 304 answers without a body.
        StubURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "If-Modified-Since") == date)
            return (Self.response(status: 304, url: request.url!), Data())
        }
        let second = await probe.probe(feed: feed, validator: validator)
        #expect(second == .unchanged)
    }

    @Test("The server ETag is preferred over the document date")
    func etagWinsOverLastModified() async throws {
        let feed = URL(string: "https://feeds.example/appcast.xml")!
        StubURLProtocol.handler = { request in
            (Self.response(
                status: 200,
                headers: ["ETag": "\"v2\"", "Last-Modified": "Wed, 21 Oct 2026 07:28:00 GMT"],
                url: request.url!
            ), Data("feed".utf8))
        }
        let probe = makeProbe()

        guard case .changed(let validator?) = await probe.probe(feed: feed, validator: nil) else {
            Issue.record("a first probe must report a change")
            return
        }
        #expect(validator == "etag:\"v2\"")
    }

    @Test("A body-hash validator is never offered back as a conditional header")
    func bodyHashStaysLocal() async throws {
        let feed = URL(string: "https://feeds.example/appcast.xml")!
        StubURLProtocol.handler = { request in
            (Self.response(status: 200, url: request.url!), Data("feed".utf8))
        }
        let probe = makeProbe()

        guard case .changed(let validator?) = await probe.probe(feed: feed, validator: nil) else {
            Issue.record("a first probe must report a change")
            return
        }
        #expect(validator.hasPrefix("sha256:"))

        StubURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
            #expect(request.value(forHTTPHeaderField: "If-Modified-Since") == nil)
            return (Self.response(status: 200, url: request.url!), Data("feed".utf8))
        }
        let second = await probe.probe(feed: feed, validator: validator)
        #expect(second == .unchanged)
    }
}
