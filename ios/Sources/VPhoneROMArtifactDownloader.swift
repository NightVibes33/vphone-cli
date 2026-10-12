import Foundation
import Combine

/// GitHub Actions archive -> user-selected Files/USB URL, no iPhone temporary ZIP.
@MainActor
final class VPhoneROMArtifactDownloader: ObservableObject {
    @Published private(set) var status = "Mac runner ROM artifact → USB."
    @Published private(set) var downloading = false
    @Published private(set) var fraction = 0.0
    private var lookup: Task<Void, Never>?
    private var receiver: VPhoneUSBArtifactStream?

    func fetch(to folder: URL, token: String) {
        guard !downloading else { return }
        let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else {
            status = "Paste a GitHub fine-grained token with Actions: Read access to NightVibes33/vphone-cli. The token is kept only in memory, never logged or saved."
            return
        }
        downloading = true
        fraction = 0
        status = "Checking the most recent ROM artifact in GitHub Actions…"
        lookup = Task { [weak self] in
            guard let self else { return }
            do {
                var components = URLComponents(string: "https://api.github.com/repos/NightVibes33/vphone-cli/actions/artifacts")!
                components.queryItems = [
                    .init(name: "name", value: "VPhone-macOS-host-ROMs"),
                    .init(name: "per_page", value: "20")
                ]
                var request = URLRequest(url: components.url!)
                request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("VPhone-iOS", forHTTPHeaderField: "User-Agent")
                let config = URLSessionConfiguration.ephemeral
                config.urlCache = nil
                let session = URLSession(configuration: config)
                let (data, response) = try await session.data(for: request)
                session.finishTasksAndInvalidate()
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw VPhoneROMArtifactFailure.reason("GitHub artifact listing denied; check Actions: Read token permission")
                }
                let listing = try JSONDecoder().decode(VPhoneROMArtifacts.self, from: data)
                guard let latest = listing.artifacts
                    .filter({ $0.name == "VPhone-macOS-host-ROMs" && !$0.expired &&
                        $0.sizeInBytes > 512 && $0.sizeInBytes < 64 * 1024 * 1024 })
                    .sorted(by: { $0.id > $1.id }).first else {
                    throw VPhoneROMArtifactFailure.reason("No unexpired ROM artifact. Re-run Prepare VPhone host ROM artifact on GitHub.")
                }
                try Task.checkCancellation()
                self.status = "Downloading artifact #\(latest.id) to selected USB folder…"
                let download = VPhoneUSBArtifactStream(folder: folder, artifact: latest.id, token: credential,
                    progress: { [weak self] received, total in
                        Task { @MainActor in
                            guard let self, self.downloading else { return }
                            self.fraction = total > 0 ? min(1, Double(received) / Double(total)) : 0
                            self.status = "Writing ROM ZIP to USB: \(received / 1024) KB"
                        }
                    }, finish: { [weak self] result in
                        Task { @MainActor in
                            guard let self else { return }
                            self.downloading = false
                            self.lookup = nil
                            self.receiver = nil
                            switch result {
                            case .success(let url):
                                self.fraction = 1
                                self.status = "Saved \(url.lastPathComponent) on USB. Extract the ZIP with Files on that SAME drive; then create the VM in that USB folder. No iPhone copy."
                            case .failure(let error):
                                self.status = "USB ROM download failed: \(error.localizedDescription)"
                            }
                        }
                    })
                self.receiver = download
                try download.start()
            } catch {
                self.downloading = false
                self.lookup = nil
                self.receiver = nil
                self.status = "ROM download unavailable: \(error.localizedDescription)"
            }
        }
    }

    func cancel() {
        if let receiver { receiver.cancel() }
        else {
            lookup?.cancel()
            lookup = nil
            downloading = false
            status = "ROM download cancelled."
        }
    }
}

private struct VPhoneROMArtifacts: Decodable {
    let artifacts: [Entry]
    struct Entry: Decodable {
        let id: Int64
        let name: String
        let expired: Bool
        let sizeInBytes: Int64
        enum CodingKeys: String, CodingKey {
            case id, name, expired
            case sizeInBytes = "size_in_bytes"
        }
    }
}

private enum VPhoneROMArtifactFailure: LocalizedError {
    case reason(String)
    var errorDescription: String? {
        if case .reason(let message) = self { return message }
        return nil
    }
}

/// Streams each URLSession chunk directly to Files' security-scoped USB handle.
/// Token is removed on GitHub's redirect to the signed download host.
private final class VPhoneUSBArtifactStream: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let folder: URL
    private let artifact: Int64
    private let token: String
    private let progress: (Int64, Int64) -> Void
    private let onFinish: (Result<URL, Error>) -> Void
    private let workQueue: OperationQueue
    private let fileName = "VPhone-macOS-host-ROMs.zip"
    private var file: FileHandle?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var scope = false
    private var received: Int64 = 0
    private var expected: Int64 = -1
    private var firstChunk = true
    private var validResponse = false
    private var failure: Error?
    private var finished = false
    private var lastProgress: TimeInterval = 0

    private var partial: URL { folder.appendingPathComponent(fileName + ".partial") }
    private var complete: URL { folder.appendingPathComponent(fileName) }

    init(folder: URL, artifact: Int64, token: String,
         progress: @escaping (Int64, Int64) -> Void,
         finish: @escaping (Result<URL, Error>) -> Void) {
        self.folder = folder
        self.artifact = artifact
        self.token = token
        self.progress = progress
        self.onFinish = finish
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "vphone.usb.rom.artifact.stream"
        workQueue = queue
    }

    func start() throws {
        scope = folder.startAccessingSecurityScopedResource()
        do {
            guard folder.isFileURL else { throw VPhoneROMArtifactFailure.reason("Select a USB folder in Files") }
            guard !FileManager.default.fileExists(atPath: complete.path) else {
                throw VPhoneROMArtifactFailure.reason("ROM ZIP already exists on USB; extract it in Files or delete it to download again.")
            }
            // The ROM ZIP is small; restart any incomplete archive rather than
            // appending garbage. Never create an internal temporary file.
            if FileManager.default.fileExists(atPath: partial.path) {
                try FileManager.default.removeItem(at: partial)
            }
            guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
                throw VPhoneROMArtifactFailure.reason("Files provider denied writing to the selected USB folder")
            }
            file = try FileHandle(forWritingTo: partial)
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForResource = 1800
            session = URLSession(configuration: config, delegate: self, delegateQueue: workQueue)
            var request = URLRequest(url: URL(string:
                "https://api.github.com/repos/NightVibes33/vphone-cli/actions/artifacts/\(artifact)/zip")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("VPhone-iOS", forHTTPHeaderField: "User-Agent")
            task = session?.dataTask(with: request)
            task?.resume()
        } catch {
            try? file?.close()
            file = nil
            try? FileManager.default.removeItem(at: partial)
            if scope { folder.stopAccessingSecurityScopedResource() }
            scope = false
            throw error
        }
    }

    func cancel() { task?.cancel() }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" else { completionHandler(nil); return }
        var sanitized = request
        sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
        sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(sanitized)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            failure = VPhoneROMArtifactFailure.reason("GitHub did not return a ROM archive. Token may lack Actions: Read permission.")
            completionHandler(.cancel)
            return
        }
        expected = http.expectedContentLength
        validResponse = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard validResponse, !finished else { return }
        if firstChunk {
            firstChunk = false
            guard data.count >= 4, data.prefix(4).elementsEqual([0x50, 0x4b, 0x03, 0x04]) else {
                failure = VPhoneROMArtifactFailure.reason("GitHub returned data that is not a ZIP artifact")
                dataTask.cancel()
                return
            }
        }
        guard received + Int64(data.count) <= 64 * 1024 * 1024 else {
            failure = VPhoneROMArtifactFailure.reason("Unexpectedly large ROM artifact")
            dataTask.cancel()
            return
        }
        do {
            try file?.write(contentsOf: data)
            received += Int64(data.count)
            let t = ProcessInfo.processInfo.systemUptime
            if t - lastProgress >= 0.4 {
                lastProgress = t
                progress(received, expected)
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard !finished else { return }
        finished = true
        do {
            try file?.synchronize()
            try file?.close()
            file = nil
            if let issue = failure ?? error { throw issue }
            guard validResponse && received > 512 else {
                throw VPhoneROMArtifactFailure.reason("ROM ZIP is empty or incomplete")
            }
            if expected > 0 && received != expected {
                throw VPhoneROMArtifactFailure.reason("Downloaded ROM artifact size mismatch")
            }
            try FileManager.default.moveItem(at: partial, to: complete)
            end(.success(complete))
        } catch {
            end(.failure(error))
        }
    }

    private func end(_ result: Result<URL, Error>) {
        session?.finishTasksAndInvalidate()
        session = nil
        task = nil
        if scope { folder.stopAccessingSecurityScopedResource() }
        scope = false
        onFinish(result)
    }
}
