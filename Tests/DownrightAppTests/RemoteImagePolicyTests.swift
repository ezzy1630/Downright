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
        let started = TestSignal()
        let stopped = TestSignal()
        PendingImageProtocol.reset(started: started, stopped: stopped)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PendingImageProtocol.self]
        var loader: RemoteImageLoader? = RemoteImageLoader(session: URLSession(configuration: configuration))
        weak var weakLoader = loader
        for index in 0..<12 {
            loader?.loadImage(for: try #require(URL(string: "https://downright-test.invalid/\(index).png")), maxPixelDimension: 64) { _ in }
        }
        try #require(await started.wait(), "Four loads did not reach URLSession")
        #expect(PendingImageProtocol.counts.started == 4)
        loader = nil
        #expect(weakLoader == nil)
        try #require(await stopped.wait(), "Revoking consent did not cancel all four active loads")
        #expect(PendingImageProtocol.counts == (started: 4, stopped: 4))
    }
}

private final class PendingImageProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var started = 0
    private static var stopped = 0
    private static var fourStarted: TestSignal?
    private static var fourStopped: TestSignal?
    static var counts: (started: Int, stopped: Int) {
        lock.lock(); defer { lock.unlock() }
        return (started, stopped)
    }
    static func reset(started: TestSignal, stopped: TestSignal) {
        lock.lock(); defer { lock.unlock() }
        Self.started = 0
        Self.stopped = 0
        fourStarted = started
        fourStopped = stopped
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "downright-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.started += 1
        if Self.started == 4 { Self.fourStarted?.signal() }
    }
    override func stopLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.stopped += 1
        if Self.stopped == 4 { Self.fourStopped?.signal() }
    }
}
