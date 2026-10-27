import AppKit
import Testing
import MarkdownRender
@testable import DownrightApp

@Suite("Remote images are an explicit host action")
struct RemoteImagePolicyTests {
    @Test func onlyCredentialFreeHTTPSDestinationsAreAccepted() throws {
        #expect(RemoteImageTransfer.accepts(try #require(URL(string: "https://example.com/image.png"))))
        for raw in ["http://example.com/image.png", "file:///tmp/image.png", "data:image/png,abc", "https://user:password@example.com/image.png"] {
            #expect(!RemoteImageTransfer.accepts(try #require(URL(string: raw))))
        }
    }

}

@Suite("Remote image request lifetime", .serialized)
@MainActor
struct RemoteImageLifetimeTests {
    @Test func requestsAreBoundedAndRevokingConsentCancelsTheQueue() async throws {
        PendingImageProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PendingImageProtocol.self]
        var loader: RemoteImageLoader? = RemoteImageLoader(session: URLSession(configuration: configuration))
        weak var weakLoader = loader
        for index in 0..<12 {
            loader?.loadImage(for: try #require(URL(string: "https://downright-test.invalid/\(index).png")), maxPixelDimension: 64) { _ in }
        }
        let deadline = Date().addingTimeInterval(5)
        while PendingImageProtocol.counts.started < 4 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(PendingImageProtocol.counts.started == 4)
        loader = nil
        #expect(weakLoader == nil)
        let cancelledDeadline = Date().addingTimeInterval(5)
        while PendingImageProtocol.counts.stopped < 4 && Date() < cancelledDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(PendingImageProtocol.counts == (started: 4, stopped: 4))
    }
}

private final class PendingImageProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var started = 0
    private static var stopped = 0
    static var counts: (started: Int, stopped: Int) {
        lock.lock(); defer { lock.unlock() }
        return (started, stopped)
    }
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        started = 0; stopped = 0
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "downright-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.started += 1
    }
    override func stopLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.stopped += 1
    }
}
