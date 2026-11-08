import Foundation
import CryptoKit

/// Pinned official Parakeet Unified EN Q8_0 GGUF — trusted HTTPS revision only.
/// Source: handy-computer/parakeet-unified-en-0.6b-gguf @ 7e948f21… (matches Hex setup-parakeet.sh).
public enum ParakeetModelCatalog: Sendable {
    public static let displayName = "Parakeet Unified EN 0.6B (Q8_0)"
    public static let approximateSizeLabel = "≈731 MB"
    public static let sourceLabel = "Hugging Face · handy-computer/parakeet-unified-en-0.6b-gguf"
    public static let licenseLabel = "NVIDIA Open Model License (weights) · runtime MIT"
    public static let diskRequirementLabel = "Needs ~731 MB free in QuikCal Application Support"

    public static let revision = "7e948f21b7bdbac698d3318db9d350f1096f3b6c"
    public static let fileName = ParakeetModelStore.recommendedFileName
    public static let expectedBytes = ParakeetModelStore.expectedBytes
    public static let expectedSHA256 = ParakeetModelStore.expectedSHA256

    /// Absolute pinned resolve URL — never take arbitrary user-entered URLs.
    public static let pinnedDownloadURL = URL(
        string: "https://huggingface.co/handy-computer/parakeet-unified-en-0.6b-gguf/resolve/\(revision)/\(fileName)"
    )!

    public static let trustedHostSuffixes: [String] = [
        "huggingface.co",
        "hf.co",
        "cdn-lfs.huggingface.co",
        "cdn-lfs-us-1.hf.co",
        "cdn-lfs-eu-1.hf.co"
    ]

    public static func isTrustedHost(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        let lowered = host.lowercased()
        return trustedHostSuffixes.contains { suffix in
            lowered == suffix || lowered.hasSuffix("." + suffix)
        }
    }
}

public enum ParakeetDownloadPhase: String, Sendable, Equatable, Codable {
    case idle
    case checking
    case ready
    case downloading
    case verifying
    case installing
    case failed
    case cancelled
}

public struct ParakeetDownloadProgress: Sendable, Equatable {
    public var bytesReceived: Int64
    public var bytesExpected: Int64?
    /// Honest fraction only when expected size is known and > 0; otherwise nil (never invent %).
    public var fraction: Double? {
        guard let bytesExpected, bytesExpected > 0 else { return nil }
        return min(1, max(0, Double(bytesReceived) / Double(bytesExpected)))
    }

    public init(bytesReceived: Int64 = 0, bytesExpected: Int64? = nil) {
        self.bytesReceived = bytesReceived
        self.bytesExpected = bytesExpected
    }
}

public struct ParakeetDownloadSnapshot: Sendable, Equatable, Codable {
    public var phase: ParakeetDownloadPhase
    public var bytesReceived: Int64
    public var bytesExpected: Int64?
    public var message: String?
    public var lastError: String?

    public init(
        phase: ParakeetDownloadPhase = .idle,
        bytesReceived: Int64 = 0,
        bytesExpected: Int64? = nil,
        message: String? = nil,
        lastError: String? = nil
    ) {
        self.phase = phase
        self.bytesReceived = bytesReceived
        self.bytesExpected = bytesExpected
        self.message = message
        self.lastError = lastError
    }

    public var progress: ParakeetDownloadProgress {
        ParakeetDownloadProgress(bytesReceived: bytesReceived, bytesExpected: bytesExpected)
    }
}

public enum ParakeetDownloadError: Error, Sendable, Equatable {
    case alreadyInProgress
    case untrustedRedirect(String)
    case httpStatus(Int)
    case transport(String)
    case checksumMismatch(found: String)
    case validationFailed(ParakeetModelReadiness)
    case cancelled
    case partialCorrupt
    case disk(String)
}

/// Byte-stream download transport — injectable for tests (tiny fixtures, failures, cancel).
public protocol ParakeetDownloadTransport: Sendable {
    /// Streams body to `onBytes`. May be cancelled via Task cancellation.
    func download(
        from url: URL,
        resumeFromOffset: Int64,
        onResponse: (URLResponse) throws -> Void,
        onBytes: (Data) throws -> Void
    ) async throws
}

/// Production transport: URLSession streaming with redirect host allowlist.
public struct URLSessionParakeetDownloadTransport: ParakeetDownloadTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? RedirectAllowlistSession.shared
    }

    public func download(
        from url: URL,
        resumeFromOffset: Int64,
        onResponse: (URLResponse) throws -> Void,
        onBytes: (Data) throws -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.setValue("QuietCalendar/0.2.4", forHTTPHeaderField: "User-Agent")
        if resumeFromOffset > 0 {
            request.setValue("bytes=\(resumeFromOffset)-", forHTTPHeaderField: "Range")
        }
        let (bytes, response) = try await session.bytes(for: request)
        try onResponse(response)
        if let http = response as? HTTPURLResponse {
            let code = http.statusCode
            if !(200...299).contains(code) && code != 206 {
                throw ParakeetDownloadError.httpStatus(code)
            }
            if let host = http.url?.host, !ParakeetModelCatalog.isTrustedHost(host) {
                throw ParakeetDownloadError.untrustedRedirect(host)
            }
        }
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try onBytes(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try onBytes(buffer)
        }
    }
}

/// Shared session whose delegate refuses redirects off the HF/CDN allowlist.
enum RedirectAllowlistSession {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 6
        config.httpMaximumConnectionsPerHost = 2
        config.waitsForConnectivity = true
        return URLSession(
            configuration: config,
            delegate: RedirectAllowlistDelegate.shared,
            delegateQueue: nil
        )
    }()
}

/// URLSession redirect gate — only trusted HF / CDN hosts.
final class RedirectAllowlistDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RedirectAllowlistDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if ParakeetModelCatalog.isTrustedHost(request.url?.host) {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}

/// Coordinates a single shared transfer into QuikCal Application Support.
/// Safe across app restart: partial file + sidecar; never replaces a valid installed model on failure.
public actor ParakeetModelDownloadEngine {
    private let transport: ParakeetDownloadTransport
    private let fileManager: FileManager
    private let modelsDirectory: URL
    private let fileName: String
    private let expectedBytes: Int64
    private let expectedSHA256: String
    private let downloadURL: URL
    private var snapshot = ParakeetDownloadSnapshot()
    private var activeTask: Task<Void, Never>?
    private var generation = 0

    public init(
        transport: ParakeetDownloadTransport = URLSessionParakeetDownloadTransport(),
        fileManager: FileManager = .default,
        modelsDirectory: URL? = nil,
        fileName: String = ParakeetModelCatalog.fileName,
        expectedBytes: Int64 = ParakeetModelCatalog.expectedBytes,
        expectedSHA256: String = ParakeetModelCatalog.expectedSHA256,
        downloadURL: URL = ParakeetModelCatalog.pinnedDownloadURL
    ) {
        self.transport = transport
        self.fileManager = fileManager
        self.modelsDirectory = modelsDirectory
            ?? ParakeetModelStore.modelsDirectory(fileManager: fileManager)
        self.fileName = fileName
        self.expectedBytes = expectedBytes
        self.expectedSHA256 = expectedSHA256.lowercased()
        self.downloadURL = downloadURL
    }

    public func currentSnapshot() -> ParakeetDownloadSnapshot { snapshot }

    public func refreshInstalledState(
        requireChecksum: Bool = false
    ) -> (validation: ParakeetModelValidation, snapshot: ParakeetDownloadSnapshot) {
        let dest = destinationURL()
        let validation = ParakeetModelValidator.validate(
            fileURL: dest,
            requireChecksum: requireChecksum,
            expectedBytes: expectedBytes,
            expectedSHA256: expectedSHA256,
            fileManager: fileManager
        )
        if validation.readiness == .ready {
            snapshot = ParakeetDownloadSnapshot(
                phase: .ready,
                bytesReceived: validation.bytes ?? expectedBytes,
                bytesExpected: expectedBytes,
                message: "\(ParakeetModelCatalog.displayName) ready — no re-download needed."
            )
        } else if snapshot.phase == .downloading || snapshot.phase == .verifying || snapshot.phase == .installing {
            // Keep in-flight phase.
        } else if fileManager.fileExists(atPath: partialURL().path) {
            let partialBytes = (try? fileManager.attributesOfItem(atPath: partialURL().path)[.size] as? NSNumber)?.int64Value ?? 0
            snapshot = ParakeetDownloadSnapshot(
                phase: .idle,
                bytesReceived: partialBytes,
                bytesExpected: expectedBytes,
                message: "Partial download found (\(Self.formatBytes(partialBytes))). Resume or restart."
            )
        } else if snapshot.phase != .failed && snapshot.phase != .cancelled {
            snapshot = ParakeetDownloadSnapshot(
                phase: .idle,
                message: validation.readiness.userFacingStatus
            )
        }
        return (validation, snapshot)
    }

    public func startOrResume(forceRestart: Bool = false) async -> ParakeetDownloadSnapshot {
        if snapshot.phase == .downloading || snapshot.phase == .verifying || snapshot.phase == .installing {
            return snapshot
        }
        let dest = destinationURL()
        let existing = ParakeetModelValidator.validate(
            fileURL: dest,
            requireChecksum: true,
            expectedBytes: expectedBytes,
            expectedSHA256: expectedSHA256,
            fileManager: fileManager
        )
        // Skip re-download when valid unless the user explicitly restarts.
        if existing.readiness == .ready, !forceRestart {
            snapshot = ParakeetDownloadSnapshot(
                phase: .ready,
                bytesReceived: existing.bytes ?? expectedBytes,
                bytesExpected: expectedBytes,
                message: "\(ParakeetModelCatalog.displayName) already installed."
            )
            return snapshot
        }

        generation += 1
        let token = generation
        if forceRestart {
            try? fileManager.removeItem(at: partialURL())
            try? fileManager.removeItem(at: sidecarURL())
        }

        let resumeOffset: Int64
        if forceRestart {
            resumeOffset = 0
        } else if fileManager.fileExists(atPath: partialURL().path),
                  let size = (try? fileManager.attributesOfItem(atPath: partialURL().path)[.size] as? NSNumber)?.int64Value,
                  size > 0 {
            resumeOffset = size
        } else {
            resumeOffset = 0
            try? fileManager.removeItem(at: partialURL())
        }

        snapshot = ParakeetDownloadSnapshot(
            phase: .downloading,
            bytesReceived: resumeOffset,
            bytesExpected: expectedBytes,
            message: resumeOffset > 0
                ? "Resuming download from \(Self.formatBytes(resumeOffset))…"
                : "Downloading \(ParakeetModelCatalog.displayName)…"
        )

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDownload(token: token, resumeOffset: resumeOffset)
        }
        activeTask = task
        await task.value
        return snapshot
    }

    public func cancel() {
        generation += 1
        activeTask?.cancel()
        activeTask = nil
        let bytes = snapshot.bytesReceived
        snapshot = ParakeetDownloadSnapshot(
            phase: .cancelled,
            bytesReceived: bytes,
            bytesExpected: expectedBytes,
            message: "Download cancelled. Partial file kept for resume.",
            lastError: nil
        )
    }

    public func retry() async -> ParakeetDownloadSnapshot {
        await startOrResume(forceRestart: false)
    }

    // MARK: - Internals

    private func destinationURL() -> URL {
        modelsDirectory.appendingPathComponent(fileName)
    }

    private func partialURL() -> URL {
        modelsDirectory.appendingPathComponent(fileName + ".partial")
    }

    private func sidecarURL() -> URL {
        modelsDirectory.appendingPathComponent(fileName + ".download.json")
    }

    private func stagingURL() -> URL {
        modelsDirectory.appendingPathComponent(fileName + ".installing")
    }

    private func runDownload(token: Int, resumeOffset: Int64) async {
        do {
            try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            let partial = partialURL()
            if resumeOffset == 0 {
                fileManager.createFile(atPath: partial.path, contents: nil)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
            }
            let handle: FileHandle
            do {
                handle = try FileHandle(forWritingTo: partial)
            } catch {
                throw ParakeetDownloadError.disk("Cannot open partial file for writing.")
            }
            defer { try? handle.close() }
            if resumeOffset > 0 {
                try handle.seekToEnd()
            }

            var received = resumeOffset
            try await transport.download(
                from: downloadURL,
                resumeFromOffset: resumeOffset,
                onResponse: { response in
                    if let http = response as? HTTPURLResponse {
                        if let host = http.url?.host, !ParakeetModelCatalog.isTrustedHost(host) {
                            throw ParakeetDownloadError.untrustedRedirect(host)
                        }
                        if resumeOffset > 0 && http.statusCode == 200 {
                            throw ParakeetDownloadError.partialCorrupt
                        }
                    }
                },
                onBytes: { data in
                    try Task.checkCancellation()
                    try handle.write(contentsOf: data)
                    received += Int64(data.count)
                }
            )
            // Publish honest final received count after stream (and mid-flight via polling bytes on disk).
            if token == generation {
                snapshot = ParakeetDownloadSnapshot(
                    phase: .downloading,
                    bytesReceived: received,
                    bytesExpected: expectedBytes,
                    message: "Downloaded \(Self.formatBytes(received))…"
                )
            }

            guard token == generation else { return }

            snapshot = ParakeetDownloadSnapshot(
                phase: .verifying,
                bytesReceived: received,
                bytesExpected: expectedBytes,
                message: "Verifying checksum…"
            )

            try handle.synchronize()

            let digest = ParakeetModelValidator.sha256Hex(of: partial) ?? ""
            guard digest == expectedSHA256 else {
                snapshot = ParakeetDownloadSnapshot(
                    phase: .failed,
                    bytesReceived: received,
                    bytesExpected: expectedBytes,
                    message: "Checksum mismatch — existing model untouched.",
                    lastError: "checksumMismatch:\(digest)"
                )
                return
            }

            snapshot = ParakeetDownloadSnapshot(
                phase: .installing,
                bytesReceived: received,
                bytesExpected: expectedBytes,
                message: "Installing into Application Support…"
            )

            let installed = try atomicInstall(from: partial)
            guard installed.readiness == .ready else {
                snapshot = ParakeetDownloadSnapshot(
                    phase: .failed,
                    bytesReceived: received,
                    bytesExpected: expectedBytes,
                    message: "Validation failed after download — existing model untouched.",
                    lastError: installed.readiness.userFacingStatus
                )
                return
            }

            try? fileManager.removeItem(at: partial)
            try? fileManager.removeItem(at: sidecarURL())
            stampNVIDIANotice()

            snapshot = ParakeetDownloadSnapshot(
                phase: .ready,
                bytesReceived: installed.bytes ?? received,
                bytesExpected: expectedBytes,
                message: "\(ParakeetModelCatalog.displayName) ready."
            )
        } catch is CancellationError {
            if token == generation {
                snapshot = ParakeetDownloadSnapshot(
                    phase: .cancelled,
                    bytesReceived: snapshot.bytesReceived,
                    bytesExpected: expectedBytes,
                    message: "Download cancelled. Partial file kept for resume."
                )
            }
        } catch let error as ParakeetDownloadError {
            if token == generation {
                if error == .partialCorrupt {
                    try? fileManager.removeItem(at: partialURL())
                    snapshot = ParakeetDownloadSnapshot(
                        phase: .failed,
                        message: "Server ignored resume — restart download.",
                        lastError: "partialCorrupt"
                    )
                } else {
                    snapshot = ParakeetDownloadSnapshot(
                        phase: .failed,
                        bytesReceived: snapshot.bytesReceived,
                        bytesExpected: expectedBytes,
                        message: "Download failed — existing model untouched.",
                        lastError: String(describing: error)
                    )
                }
            }
        } catch {
            if token == generation {
                snapshot = ParakeetDownloadSnapshot(
                    phase: .failed,
                    bytesReceived: snapshot.bytesReceived,
                    bytesExpected: expectedBytes,
                    message: "Download failed — existing model untouched.",
                    lastError: error.localizedDescription
                )
            }
        }
    }

    /// Move validated partial → staging → final. Never deletes a currently-valid final on failure.
    private func atomicInstall(from partial: URL) throws -> ParakeetModelValidation {
        let headerCheck = ParakeetModelValidator.validate(
            fileURL: partial,
            requireChecksum: true,
            expectedBytes: expectedBytes,
            expectedSHA256: expectedSHA256,
            fileManager: fileManager
        )
        guard headerCheck.readiness == .ready else {
            throw ParakeetDownloadError.validationFailed(headerCheck.readiness)
        }

        let dest = destinationURL()
        let staging = stagingURL()
        try? fileManager.removeItem(at: staging)
        try fileManager.copyItem(at: partial, to: staging)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)

        let stagingValidation = ParakeetModelValidator.validate(
            fileURL: staging,
            requireChecksum: true,
            expectedBytes: expectedBytes,
            expectedSHA256: expectedSHA256,
            fileManager: fileManager
        )
        guard stagingValidation.readiness == .ready else {
            try? fileManager.removeItem(at: staging)
            throw ParakeetDownloadError.validationFailed(stagingValidation.readiness)
        }

        let previousValid: URL?
        if fileManager.fileExists(atPath: dest.path) {
            let prev = ParakeetModelValidator.validate(
                fileURL: dest,
                requireChecksum: true,
                expectedBytes: expectedBytes,
                expectedSHA256: expectedSHA256,
                fileManager: fileManager
            )
            if prev.readiness == .ready {
                let backup = dest.appendingPathExtension("bak")
                try? fileManager.removeItem(at: backup)
                try fileManager.moveItem(at: dest, to: backup)
                previousValid = backup
            } else {
                try fileManager.removeItem(at: dest)
                previousValid = nil
            }
        } else {
            previousValid = nil
        }

        do {
            try fileManager.moveItem(at: staging, to: dest)
            if let previousValid {
                try? fileManager.removeItem(at: previousValid)
            }
        } catch {
            if let previousValid, fileManager.fileExists(atPath: previousValid.path) {
                try? fileManager.removeItem(at: dest)
                try? fileManager.moveItem(at: previousValid, to: dest)
            }
            try? fileManager.removeItem(at: staging)
            throw ParakeetDownloadError.disk(error.localizedDescription)
        }

        return ParakeetModelValidator.validate(
            fileURL: dest,
            requireChecksum: true,
            expectedBytes: expectedBytes,
            expectedSHA256: expectedSHA256,
            fileManager: fileManager
        )
    }

    private func stampNVIDIANotice() {
        let notice = modelsDirectory.appendingPathComponent(ParakeetModelStore.nvidiaNoticeFileName)
        guard !fileManager.fileExists(atPath: notice.path) else { return }
        let text = """
        NVIDIA Open Model License — Parakeet weights stored for QuikCal local speech.
        Downloaded from \(ParakeetModelCatalog.sourceLabel) revision \(ParakeetModelCatalog.revision).
        See Resources/Notices/NOTICE-NVIDIA-Parakeet.txt in the app bundle.
        """
        try? Data(text.utf8).write(to: notice, options: .atomic)
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// Mock transport for unit tests — serves an in-memory body with optional failure/cancel hooks.
public struct MockParakeetDownloadTransport: ParakeetDownloadTransport {
    public enum Behavior: Sendable {
        case succeed(Data, expectedLength: Int64?)
        case httpError(Int)
        case failAfterBytes(Int, body: Data)
        case hangUntilCancelled
        case untrustedHostRedirect
    }

    public let behavior: Behavior

    public init(behavior: Behavior) {
        self.behavior = behavior
    }

    public func download(
        from url: URL,
        resumeFromOffset: Int64,
        onResponse: (URLResponse) throws -> Void,
        onBytes: (Data) throws -> Void
    ) async throws {
        switch behavior {
        case .succeed(let data, let expectedLength):
            let slice: Data
            if resumeFromOffset > 0, resumeFromOffset < data.count {
                slice = data.suffix(from: Int(resumeFromOffset))
            } else if resumeFromOffset >= data.count {
                slice = Data()
            } else {
                slice = data
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: resumeFromOffset > 0 ? 206 : 200,
                httpVersion: "1.1",
                headerFields: [
                    "Content-Length": "\(slice.count)",
                    "Content-Type": "application/octet-stream"
                ]
            )!
            // Silence unused expectedLength for honest progress tests.
            _ = expectedLength
            try onResponse(response)
            let chunkSize = 32
            var offset = 0
            while offset < slice.count {
                try Task.checkCancellation()
                let end = min(offset + chunkSize, slice.count)
                try onBytes(slice.subdata(in: offset..<end))
                offset = end
            }
        case .httpError(let code):
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "1.1", headerFields: nil)!
            try onResponse(response)
            throw ParakeetDownloadError.httpStatus(code)
        case .failAfterBytes(let limit, let body):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "1.1", headerFields: nil)!
            try onResponse(response)
            let slice = body.prefix(limit)
            try onBytes(Data(slice))
            throw ParakeetDownloadError.transport("simulated mid-stream failure")
        case .hangUntilCancelled:
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "1.1", headerFields: nil)!
            try onResponse(response)
            while true {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        case .untrustedHostRedirect:
            throw ParakeetDownloadError.untrustedRedirect("evil.example")
        }
    }
}
