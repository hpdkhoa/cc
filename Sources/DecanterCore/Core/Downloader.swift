import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DownloadProgress: Sendable, Equatable {
    public var bytesReceived: Int64
    public var totalBytes: Int64   // -1 if unknown
    public var fraction: Double? { totalBytes > 0 ? Double(bytesReceived) / Double(totalBytes) : nil }
}

public struct HTTPError: Error, LocalizedError, Sendable {
    public let url: URL
    public let status: Int
    public var errorDescription: String? { "HTTP \(status) from \(url.absoluteString)" }
}

/// Small URLSession wrapper: GET with GitHub-friendly headers, and a download
/// task with progress that lands the file at a chosen path.
public enum Downloader {
    static let userAgent = "Decanter/0.1 (+https://github.com/hpdkhoa/cc)"

    public static func request(_ url: URL, accept: String? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
        return req
    }

    public static func fetchData(_ url: URL, accept: String? = nil) async throws -> Data {
        // Continuation-based so it also works with corelibs-foundation on Linux.
        let (data, response): (Data, URLResponse?) = try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request(url, accept: accept)) { data, response, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (data ?? Data(), response)) }
            }
            task.resume()
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError(url: url, status: http.statusCode)
        }
        return data
    }

    /// Download `url` to `destination` (replacing it), reporting progress.
    public static func download(_ url: URL, to destination: URL,
                                progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        Log.shared.info("download", "GET \(url.absoluteString) -> \(destination.path)")
        let delegate = DownloadDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let tmp: URL = try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: request(url)).resume()
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: tmp, to: destination)
        Log.shared.info("download", "saved \(destination.lastPathComponent)")
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (DownloadProgress) -> Void
        var continuation: CheckedContinuation<URL, Error>?
        private let lock = NSLock()

        init(progress: @escaping @Sendable (DownloadProgress) -> Void) { self.progress = progress }

        private func finish(_ result: Result<URL, Error>) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(with: result)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                finish(.failure(HTTPError(url: downloadTask.originalRequest?.url ?? location, status: http.statusCode)))
                return
            }
            // The file at `location` is deleted when this method returns; move it out now.
            let keep = FileManager.default.temporaryDirectory.appendingPathComponent("decanter-dl-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: location, to: keep)
                finish(.success(keep))
            } catch {
                finish(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            progress(DownloadProgress(bytesReceived: totalBytesWritten, totalBytes: totalBytesExpectedToWrite))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure(error)) }
        }
    }
}
