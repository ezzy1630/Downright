import Foundation

/// Host-owned network boundary. A document cannot initiate a request until its
/// reader installs a loader. Limits apply while receiving, before decoding.
final class RemoteImageTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let completion: @Sendable (Data?, URLResponse?, Error?) -> Void
    private var bytes = Data()
    private var response: URLResponse?
    private var session: URLSession?

    private init(maximumBytes: Int, completion: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) {
        self.maximumBytes = maximumBytes
        self.completion = completion
    }
    @discardableResult
    static func fetch(_ url: URL, configuration: URLSessionConfiguration, maximumBytes: Int,
                      completion: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) -> URLSessionTask? {
        guard accepts(url) else { completion(nil, nil, URLError(.unsupportedURL)); return nil }
        let transfer = RemoteImageTransfer(maximumBytes: maximumBytes, completion: completion)
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
        transfer.session = session
        let task = session.dataTask(with: url)
        task.resume()
        return task
    }
    static func accepts(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.accepts) == true ? request : nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.url.map(Self.accepts) == true, response.expectedContentLength <= maximumBytes else {
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= maximumBytes - bytes.count else { dataTask.cancel(); return }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        completion(error == nil ? bytes : nil, response, error)
        session.finishTasksAndInvalidate()
        self.session = nil
    }
}
