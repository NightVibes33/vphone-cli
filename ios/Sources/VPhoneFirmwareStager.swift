import Foundation
import Combine

protocol FirmwareTransferEngine: AnyObject {
    func start() throws
    func cancel()
}

/// Apple IPSW/cloudOS firmware streams directly into the destination chosen by
/// the user: the app's Files-visible Documents/Firmware directory, or an
/// external USB folder provided by the Files picker. No staging copy is made.
/// This stages original firmware; it does NOT restore or boot a guest VM.
@MainActor
final class VPhoneFirmwareStager: ObservableObject {
    enum Kind { case ios, cloudOS }
    enum Destination {
        case chosenFolder(URL)
    }

    @Published var selection: Int = 0
    @Published private(set) var status = "Choose On My iPhone or USB drive, then select firmware."
    @Published private(set) var isDownloading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var destinationDescription = "No download in progress"
    @Published private(set) var onDeviceFiles: [URL] = []

    let pairings = VPhoneFirmwareCatalog.pairings.filter { $0.iosName.hasPrefix("iOS 27") }
    private var transfer: (any FirmwareTransferEngine)?
    private var probeTask: Task<Void, Never>?
    private var previousReceived: Int64 = 0
    private var previousReportAt: TimeInterval = 0
    @Published private(set) var transferMode = ""

    static var onDeviceFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Firmware", isDirectory: true)
    }

    init() {
        selection = max(0, pairings.count - 1)
        refreshOnDeviceFiles()
    }

    func refreshOnDeviceFiles() {
        let folder = Self.onDeviceFolder
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        onDeviceFiles = entries.filter {
            $0.pathExtension.lowercased() == "ipsw" || $0.pathExtension.lowercased() == "partial"
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func download(_ kind: Kind, destination: Destination) {
        guard !isDownloading, pairings.indices.contains(selection) else { return }
        let pairing = pairings[selection]
        let remoteString = kind == .ios ? pairing.iosURL : pairing.cloudosURL
        guard let remote = URL(string: remoteString), remote.scheme == "https",
              remote.host == "updates.cdn-apple.com" else {
            status = "Firmware catalog URL rejected — only Apple's HTTPS CDN is accepted."
            return
        }
        let fileName = kind == .ios
            ? "\(pairing.iosName.replacingOccurrences(of: " ", with: "-"))-iPhone17,3.ipsw"
            : "\(pairing.cloudosName.replacingOccurrences(of: " ", with: "-"))-cloudOS.ipsw"
        let folder: URL
        let destinationLabel: String
        switch destination {
        case .chosenFolder(let selected):
            folder = selected
            destinationLabel = "Selected USB folder: \(selected.lastPathComponent)"
        }
        // Large firmware downloads are never written to the iPhone's internal
        // Documents or temporary storage. The Files picker owns this URL.
        guard folder.isFileURL else {
            status = "Select a writable USB drive folder in Files."
            return
        }

        destinationDescription = destinationLabel
        isDownloading = true
        progress = 0
        transferMode = "Preparing download"
        previousReceived = 0
        previousReportAt = 0
        status = "Checking Apple's CDN for faster downloading…"

        // Existing serial .partial files continue with the legacy streaming
        // implementation. Never pretend they are completed parallel ranges.
        let folderScope = folder.startAccessingSecurityScopedResource()
        let useParallel = kind == .ios &&
            ParallelFirmwareTransfer.canResumeInParallel(folder: folder, fileName: fileName)
        if folderScope { folder.stopAccessingSecurityScopedResource() }

        probeTask = Task { [weak self] in
            guard let self else { return }
            var source: ParallelFirmwareTransfer.Source?
            if useParallel {
                do {
                    var head = URLRequest(url: remote)
                    head.httpMethod = "HEAD"
                    head.timeoutInterval = 18
                    head.cachePolicy = .reloadIgnoringLocalCacheData
                    head.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    let (_, response) = try await URLSession.shared.data(for: head)
                    if let http = response as? HTTPURLResponse,
                       http.statusCode == 200,
                       let contentLength = http.value(forHTTPHeaderField: "Content-Length"),
                       let length = Int64(contentLength),
                       length > 128 * 1_048_576,
                       http.value(forHTTPHeaderField: "Accept-Ranges")?
                           .lowercased().contains("bytes") == true {
                        source = .init(total: length,
                                       eTag: http.value(forHTTPHeaderField: "ETag"),
                                       lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
                    }
                } catch {
                    // A CDN without HEAD support still works in serial mode.
                }
            }
            guard !Task.isCancelled else { return }
            self.probeTask = nil

            let scope = folder.startAccessingSecurityScopedResource()
            let indexURL = folder.appendingPathComponent(fileName + ".ranges.json")
            let hasCheckpoint = FileManager.default.fileExists(atPath: indexURL.path)
            if scope { folder.stopAccessingSecurityScopedResource() }
            if source == nil && hasCheckpoint {
                self.isDownloading = false
                self.status = "This folder contains a parallel download checkpoint, but Apple didn't confirm byte-range support. Keep the files and retry on a working network."
                return
            }

            let report: (Int64, Int64) -> Void = { [weak self] bytes, expected in
                Task { @MainActor in
                    guard let self, self.isDownloading else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    let seconds = max(0.2, now - self.previousReportAt)
                    let delta = max(0, bytes - self.previousReceived)
                    let speed = self.previousReportAt > 0 ?
                        Double(delta) / 1_048_576 / seconds : 0
                    self.previousReceived = bytes
                    self.previousReportAt = now
                    if expected > 0 { self.progress = min(1, Double(bytes) / Double(expected)) }
                    let transferSpeed = String(format: "%.1f MB/s", speed)
                    self.status = "\(self.transferMode) · \(bytes / 1_048_576)"
                        + (expected > 0 ? " / \(expected / 1_048_576) MB" : " MB")
                        + " · \(transferSpeed) · \(destinationLabel)"
                }
            }
            let finish: (Result<URL, Error>) -> Void = { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.isDownloading = false
                    self.transfer = nil
                    self.probeTask = nil
                    self.refreshOnDeviceFiles()
                    switch result {
                    case .success(let url):
                        self.progress = 1
                        self.status = "Saved \(url.lastPathComponent) to \(destinationLabel). Firmware restore is still required."
                    case .failure(let error):
                        self.status = "Transfer stopped: \(error.localizedDescription). Completed data stays in \(destinationLabel) for resume."
                    }
                }
            }

            let downloader: any FirmwareTransferEngine
            if let source {
                self.transferMode = "Fast IPSW (4 connections)"
                downloader = ParallelFirmwareTransfer(
                    remote: remote, directory: folder, fileName: fileName,
                    source: source, report: report, finish: finish)
            } else {
                self.transferMode = "Compatible download (1 connection)"
                downloader = DirectFirmwareTransfer(
                    remote: remote, folder: folder, fileName: fileName,
                    report: report, finish: finish)
            }
            self.transfer = downloader
            self.status = "\(self.transferMode): streaming directly to \(destinationLabel). Keep VPhone foregrounded."
            do {
                try downloader.start()
            } catch {
                self.isDownloading = false
                self.transfer = nil
                self.status = "Download failed to start: \(error.localizedDescription)"
            }
        }
    }

    func cancel() {
        if let probeTask {
            probeTask.cancel()
            self.probeTask = nil
            isDownloading = false
            status = "Download cancelled before transfer started."
        } else {
            transfer?.cancel()
        }
    }

}

/// URLSessionDataDelegate callback queue is serial, so large archives are written
/// incrementally in received chunks rather than via a full-RAM/data cache.
private final class DirectFirmwareTransfer: NSObject, FirmwareTransferEngine, URLSessionDataDelegate, @unchecked Sendable {
    private let remote: URL
    private let folder: URL
    private let fileName: String
    private let report: (Int64, Int64) -> Void
    private let finish: (Result<URL, Error>) -> Void
    private let delegateQueue: OperationQueue
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var output: FileHandle?
    private var partial: URL?
    private var scopeAcquired = false
    private var bytesWritten: Int64 = 0
    private var totalExpected: Int64 = -1
    private var writingError: Error?
    private var responseValid = false
    private var lastReportAt: TimeInterval = 0

    init(remote: URL, folder: URL, fileName: String,
         report: @escaping (Int64, Int64) -> Void,
         finish: @escaping (Result<URL, Error>) -> Void) {
        self.remote = remote
        self.folder = folder
        self.fileName = fileName
        self.report = report
        self.finish = finish
        let queue = OperationQueue()
        queue.name = "vphone.firmware.destination.serial"
        queue.maxConcurrentOperationCount = 1
        delegateQueue = queue
    }

    func start() throws {
        // For app-owned Documents the scope can be false and writing still works.
        // Files-provider destinations require the scope granted by the picker.
        scopeAcquired = folder.startAccessingSecurityScopedResource()
        do {
            let finalURL = folder.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                throw NSError(domain: "VPhoneFirmware", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "Firmware is already saved in this location. Choose a different folder or delete the existing file."])
            }
            let target = folder.appendingPathComponent(fileName + ".partial")
            partial = target
            if !FileManager.default.fileExists(atPath: target.path) {
                guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
                    throw NSError(domain: "VPhoneFirmware", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Selected destination is not writable"])
                }
            }
            output = try FileHandle(forUpdating: target)
            bytesWritten = Int64(try output!.seekToEnd())
            var request = URLRequest(url: remote)
            request.timeoutInterval = 90
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if bytesWritten > 0 {
                request.setValue("bytes=\(bytesWritten)-", forHTTPHeaderField: "Range")
            }
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 90
            configuration.timeoutIntervalForResource = 60 * 60 * 8
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            self.session = session
            task = session.dataTask(with: request)
            task?.resume()
        } catch {
            try? output?.close()
            output = nil
            if scopeAcquired { folder.stopAccessingSecurityScopedResource() }
            scopeAcquired = false
            throw error
        }
    }

    func cancel() {
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse,
              [200, 206].contains(http.statusCode) else {
            writingError = NSError(domain: "VPhoneFirmware", code: 2,
                                   userInfo: [NSLocalizedDescriptionKey: "Apple CDN did not return a firmware download"])
            completionHandler(.cancel)
            return
        }
        do {
            if http.statusCode == 206 {
                // A 206 response must start at the last complete byte on disk.
                guard let header = http.value(forHTTPHeaderField: "Content-Range"),
                      header.hasPrefix("bytes \(bytesWritten)-") else {
                    throw NSError(domain: "VPhoneFirmware", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "Unexpected range response"])
                }
            } else if bytesWritten > 0 {
                // Server ignored Range: restart correctly instead of corrupting an IPA.
                try output?.truncate(atOffset: 0)
                try output?.seek(toOffset: 0)
                bytesWritten = 0
            }
            if response.expectedContentLength > 0 {
                totalExpected = bytesWritten + response.expectedContentLength
            }
            responseValid = true
            completionHandler(.allow)
        } catch {
            writingError = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard responseValid else { return }
        do {
            try output?.write(contentsOf: data)
            bytesWritten += Int64(data.count)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastReportAt >= 0.45 {
                lastReportAt = now
                report(bytesWritten, totalExpected)
            }
        } catch {
            writingError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        do {
            try output?.close()
            output = nil
            defer {
                if scopeAcquired { folder.stopAccessingSecurityScopedResource() }
                scopeAcquired = false
                session.finishTasksAndInvalidate()
                self.session = nil
                self.task = nil
            }
            if let failure = writingError ?? error { throw failure }
            guard responseValid, let partial else {
                throw NSError(domain: "VPhoneFirmware", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "No valid firmware received"])
            }
            if totalExpected > 0 && bytesWritten != totalExpected {
                throw NSError(domain: "VPhoneFirmware", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "Incomplete firmware download"])
            }
            let finished = folder.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: finished.path) {
                throw NSError(domain: "VPhoneFirmware", code: 6,
                              userInfo: [NSLocalizedDescriptionKey: "Destination already exists; file not overwritten"])
            }
            try FileManager.default.moveItem(at: partial, to: finished)
            report(bytesWritten, bytesWritten)
            finish(.success(finished))
        } catch {
            if scopeAcquired { folder.stopAccessingSecurityScopedResource() }
            scopeAcquired = false
            session.finishTasksAndInvalidate()
            self.session = nil
            self.task = nil
            finish(.failure(error))
        }
    }
}
