import Foundation
import Darwin

/// Writes up to four validated HTTP byte ranges concurrently into ONE sparse
/// .partial file. Completed 32 MiB ranges are fsynced and checkpointed; an
/// interrupted range is simply re-fetched when the user resumes.
final class ParallelFirmwareTransfer: NSObject, FirmwareTransferEngine, URLSessionDataDelegate, @unchecked Sendable {
    struct Source {
        let total: Int64
        let eTag: String?
        let lastModified: String?
    }

    private struct Checkpoint: Codable {
        let url: String
        let total: Int64
        let chunkSize: Int64
        let eTag: String?
        let lastModified: String?
        var completed: [Int]
    }

    private struct Part {
        let index: Int
        let start: Int64
        let end: Int64
        var received: Int64 = 0
        var responseValidated = false
    }

    private let remote: URL
    private let directory: URL
    private let fileName: String
    private let source: Source
    private let report: (Int64, Int64) -> Void
    private let finish: (Result<URL, Error>) -> Void
    private let queue: OperationQueue
    private let chunkSize: Int64 = 32 * 1024 * 1024
    private let maxConnections = 4
    private var session: URLSession?
    private var fd: Int32 = -1
    private var scopeAcquired = false
    private var checkpointURL: URL { directory.appendingPathComponent(fileName + ".ranges.json") }
    private var partialURL: URL { directory.appendingPathComponent(fileName + ".partial") }
    private var completeURL: URL { directory.appendingPathComponent(fileName) }
    private var checkpoint: Checkpoint?
    private var completed = Set<Int>()
    private var active: [Int: Part] = [:]
    private var nextPart = 0
    private var partCount = 0
    private var finished = false
    private var lastReportTime = 0.0

    init(remote: URL, directory: URL, fileName: String, source: Source,
         report: @escaping (Int64, Int64) -> Void,
         finish: @escaping (Result<URL, Error>) -> Void) {
        self.remote = remote
        self.directory = directory
        self.fileName = fileName
        self.source = source
        self.report = report
        self.finish = finish
        let q = OperationQueue()
        q.name = "vphone.ipsw.parallel.ranges"
        q.maxConcurrentOperationCount = 1
        queue = q
    }

    static func canResumeInParallel(folder: URL, fileName: String) -> Bool {
        let fm = FileManager.default
        let file = folder.appendingPathComponent(fileName + ".partial")
        let index = folder.appendingPathComponent(fileName + ".ranges.json")
        // The original single-stream .partial is compatible only with the
        // serial downloader. Never reinterpret its existing bytes as chunks.
        return !fm.fileExists(atPath: file.path) || fm.fileExists(atPath: index.path)
    }

    func start() throws {
        guard source.total > 64 * 1024 * 1024 else {
            throw problem(1, "Firmware is too small for a parallel transfer.")
        }
        scopeAcquired = directory.startAccessingSecurityScopedResource()
        let previouslyIndexed = FileManager.default.fileExists(atPath: checkpointURL.path)
        do {
            if FileManager.default.fileExists(atPath: completeURL.path) {
                throw problem(2, "Firmware already downloaded at the selected destination.")
            }
            partCount = Int((source.total + chunkSize - 1) / chunkSize)
            guard partCount > 0 && partCount < 100_000 else {
                throw problem(3, "Invalid IPSW size.")
            }

            let indexExists = FileManager.default.fileExists(atPath: checkpointURL.path)
            let fileExists = FileManager.default.fileExists(atPath: partialURL.path)
            if indexExists != fileExists {
                throw problem(4, "Incomplete parallel download state: both .partial and .ranges.json must exist.")
            }
            if indexExists {
                let indexData = try Data(contentsOf: checkpointURL)
                let saved = try JSONDecoder().decode(Checkpoint.self, from: indexData)
                guard saved.url == remote.absoluteString, saved.total == source.total,
                      saved.chunkSize == chunkSize, saved.eTag == source.eTag,
                      saved.lastModified == source.lastModified,
                      saved.completed.allSatisfy({ $0 >= 0 && $0 < partCount }) else {
                    throw problem(5, "Firmware source changed. Existing .partial and .ranges.json were preserved; choose a clean destination.")
                }
                checkpoint = saved
                completed = Set(saved.completed)
            } else {
                checkpoint = Checkpoint(url: remote.absoluteString, total: source.total,
                                        chunkSize: chunkSize, eTag: source.eTag,
                                        lastModified: source.lastModified, completed: [])
            }

            fd = Darwin.open(partialURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard fd >= 0 else {
                throw problem(6, "Cannot open IPSW on selected storage: errno \(errno)")
            }
            if ftruncate(fd, off_t(source.total)) != 0 {
                throw problem(7, "Cannot size the IPSW file on selected storage: errno \(errno)")
            }
            // Save an empty index only after the .partial file is created.
            // On crash before this write, the extra file is never trusted.
            if !indexExists { try saveCheckpoint() }
            let config = URLSessionConfiguration.default
            config.httpMaximumConnectionsPerHost = maxConnections
            config.timeoutIntervalForRequest = 90
            config.timeoutIntervalForResource = 8 * 3600
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.urlCache = nil
            session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
            scheduleMore()
        } catch {
            closeFD()
            // A newly created sparse file without its checkpoint is unsafe
            // to interpret as a serial .partial on the next launch.
            if !previouslyIndexed && active.isEmpty {
                try? FileManager.default.removeItem(at: partialURL)
                try? FileManager.default.removeItem(at: checkpointURL)
            }
            if scopeAcquired { directory.stopAccessingSecurityScopedResource() }
            scopeAcquired = false
            throw error
        }
    }

    func cancel() {
        queue.addOperation { [weak self] in
            guard let self, !self.finished else { return }
            self.abort(self.problem(8, "Transfer cancelled; completed ranges can resume later."))
        }
    }

    private func scheduleMore() {
        guard !finished, let session else { return }
        while active.count < maxConnections && nextPart < partCount {
            let idx = nextPart
            nextPart += 1
            if completed.contains(idx) { continue }
            let first = Int64(idx) * chunkSize
            let last = min(source.total - 1, first + chunkSize - 1)
            var request = URLRequest(url: remote)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            request.setValue("bytes=\(first)-\(last)", forHTTPHeaderField: "Range")
            if let validator = source.eTag ?? source.lastModified {
                request.setValue(validator, forHTTPHeaderField: "If-Range")
            }
            let task = session.dataTask(with: request)
            active[task.taskIdentifier] = Part(index: idx, start: first, end: last)
            task.resume()
        }
        if active.isEmpty && completed.count == partCount { completeTransfer() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !finished, var part = active[dataTask.taskIdentifier],
              let http = response as? HTTPURLResponse,
              http.statusCode == 206,
              let range = http.value(forHTTPHeaderField: "Content-Range"),
              range == "bytes \(part.start)-\(part.end)/\(source.total)",
              http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased() != "gzip",
              http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased() != "br" else {
            abort(problem(9, "Apple CDN did not return the expected byte range; refusing to corrupt the IPSW."))
            completionHandler(.cancel)
            return
        }
        part.responseValidated = true
        active[dataTask.taskIdentifier] = part
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        guard !finished, var part = active[dataTask.taskIdentifier],
              part.responseValidated, fd >= 0 else { return }
        let expected = part.end - part.start + 1
        guard Int64(data.count) <= expected - part.received else {
            abort(problem(10, "Server sent more data than the requested IPSW range."))
            return
        }
        let written = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return data.isEmpty }
            var amount = 0
            while amount < data.count {
                let n = Darwin.pwrite(fd, base.advanced(by: amount),
                                      data.count - amount,
                                      off_t(part.start + part.received + Int64(amount)))
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                amount += n
            }
            return true
        }
        guard written else {
            abort(problem(11, "Writing IPSW to selected disk failed (possibly full or disconnected): errno \(errno)"))
            return
        }
        part.received += Int64(data.count)
        active[dataTask.taskIdentifier] = part
        publishProgress()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard !finished, let part = active.removeValue(forKey: task.taskIdentifier) else { return }
        if let error {
            abort(error)
            return
        }
        guard part.responseValidated,
              part.received == part.end - part.start + 1 else {
            abort(problem(12, "Range \(part.index) ended early; download can resume."))
            return
        }
        // Sync this range before recording its completion. On interruption
        // only ranges with a durable checkpoint are trusted during resume.
        guard fsync(fd) == 0 else {
            abort(problem(13, "Cannot flush IPSW range to external storage: errno \(errno)"))
            return
        }
        completed.insert(part.index)
        do {
            try saveCheckpoint()
        } catch {
            abort(error)
            return
        }
        publishProgress(force: true)
        scheduleMore()
    }

    private func saveCheckpoint() throws {
        guard var state = checkpoint else { throw problem(14, "No checkpoint state.") }
        state.completed = completed.sorted()
        let data = try JSONEncoder().encode(state)
        try data.write(to: checkpointURL, options: .atomic)
        checkpoint = state
    }

    private func publishProgress(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastReportTime >= 0.45 else { return }
        lastReportTime = now
        let completeBytes = completed.reduce(Int64(0)) { sum, idx in
            sum + min(chunkSize, source.total - Int64(idx) * chunkSize)
        }
        let activeBytes = active.values.reduce(Int64(0)) { $0 + $1.received }
        report(min(source.total, completeBytes + activeBytes), source.total)
    }

    private func completeTransfer() {
        guard !finished else { return }
        if fsync(fd) != 0 {
            abort(problem(15, "Could not flush finished IPSW to disk."))
            return
        }
        closeFD()
        do {
            try FileManager.default.moveItem(at: partialURL, to: completeURL)
            try? FileManager.default.removeItem(at: checkpointURL)
            publishProgress(force: true)
            end(.success(completeURL))
        } catch {
            // Preserve checkpoint and partial file when rename fails.
            end(.failure(error))
        }
    }

    private func abort(_ error: Error) {
        guard !finished else { return }
        session?.invalidateAndCancel()
        end(.failure(error))
    }

    private func end(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        closeFD()
        session?.invalidateAndCancel()
        session = nil
        if scopeAcquired { directory.stopAccessingSecurityScopedResource() }
        scopeAcquired = false
        finish(result)
    }

    private func closeFD() {
        if fd >= 0 { _ = Darwin.close(fd); fd = -1 }
    }

    private func problem(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "VPhoneParallelIPSW", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
