import Foundation
import CryptoKit

/// QuikCal–owned Parakeet weight layout under Application Support.
/// Weights are **not** shipped in the DMG until NVIDIA Open Model License review completes.
public enum ParakeetModelStore: Sendable {
    public static let recommendedFileName = "parakeet-unified-en-0.6b-Q8_0.gguf"
    public static let expectedArchitecture = "parakeet"
    public static let expectedBytes: Int64 = 731_357_568
    public static let expectedSHA256 = "4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795"
    public static let nvidiaNoticeFileName = "NOTICE-NVIDIA.txt"
    public static let applicationSupportFolderName = "QuietCalendar"
    public static let modelsFolderName = "models"

    /// Dev-only known Hex path — read-only source for an explicit “Use existing model” copy.
    public static var hexDevModelURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/hex/models", isDirectory: true)
            .appendingPathComponent(recommendedFileName)
    }

    public static func applicationSupportRoot(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent(applicationSupportFolderName, isDirectory: true)
    }

    public static func modelsDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        applicationSupportRoot(fileManager: fileManager)
            .appendingPathComponent(modelsFolderName, isDirectory: true)
    }

    public static func defaultModelURL(
        fileManager: FileManager = .default
    ) -> URL {
        modelsDirectory(fileManager: fileManager)
            .appendingPathComponent(recommendedFileName)
    }

    public static func ensureModelsDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        let dir = modelsDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

public enum ParakeetModelReadiness: String, Sendable, Equatable {
    case ready
    case missing
    case corrupt
    case incompatibleArchitecture
    case sizeMismatch
    case checksumMismatch
    case helperMissing

    public var userFacingStatus: String {
        switch self {
        case .ready:
            return "Parakeet model ready (local Application Support)."
        case .missing:
            return "Parakeet model missing — select a GGUF or use “Use existing model” (read-only copy into QuikCal Application Support)."
        case .corrupt:
            return "Parakeet model file is corrupt or unreadable."
        case .incompatibleArchitecture:
            return "Selected GGUF is not a Parakeet architecture model."
        case .sizeMismatch:
            return "Parakeet model size does not match the expected Q8_0 weight."
        case .checksumMismatch:
            return "Parakeet model checksum does not match the pinned Q8_0 digest."
        case .helperMissing:
            return "Bundled QuietCalendarTranscribe helper is missing — rebuild the app bundle."
        }
    }

    public var isUsable: Bool { self == .ready }
}

public struct ParakeetModelValidation: Sendable, Equatable {
    public var readiness: ParakeetModelReadiness
    public var path: String?
    public var bytes: Int64?
    public var architecture: String?
    public var sha256: String?

    public init(
        readiness: ParakeetModelReadiness,
        path: String? = nil,
        bytes: Int64? = nil,
        architecture: String? = nil,
        sha256: String? = nil
    ) {
        self.readiness = readiness
        self.path = path
        self.bytes = bytes
        self.architecture = architecture
        self.sha256 = sha256
    }
}

/// Header / size / architecture / optional checksum checks for Parakeet GGUF files.
public enum ParakeetModelValidator: Sendable {
    public static func validate(
        fileURL: URL,
        requireChecksum: Bool = false,
        expectedBytes: Int64 = ParakeetModelStore.expectedBytes,
        expectedSHA256: String = ParakeetModelStore.expectedSHA256,
        fileManager: FileManager = .default
    ) -> ParakeetModelValidation {
        let path = fileURL.path
        guard fileManager.fileExists(atPath: path) else {
            return ParakeetModelValidation(readiness: .missing, path: path)
        }
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let sizeNumber = attrs[.size] as? NSNumber else {
            return ParakeetModelValidation(readiness: .corrupt, path: path)
        }
        let bytes = sizeNumber.int64Value
        guard bytes > 0 else {
            return ParakeetModelValidation(readiness: .corrupt, path: path, bytes: bytes)
        }

        guard let header = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
              header.count >= 8 else {
            return ParakeetModelValidation(readiness: .corrupt, path: path, bytes: bytes)
        }
        let magic = String(data: header.prefix(4), encoding: .ascii) ?? ""
        guard magic == "GGUF" else {
            return ParakeetModelValidation(readiness: .corrupt, path: path, bytes: bytes)
        }

        let architecture = scanArchitecture(in: header)
        if let architecture, architecture != ParakeetModelStore.expectedArchitecture {
            return ParakeetModelValidation(
                readiness: .incompatibleArchitecture,
                path: path,
                bytes: bytes,
                architecture: architecture
            )
        }
        if architecture == nil {
            // Missing arch key in the scanned window — treat as incompatible for safety.
            return ParakeetModelValidation(
                readiness: .incompatibleArchitecture,
                path: path,
                bytes: bytes,
                architecture: nil
            )
        }

        if bytes != expectedBytes {
            return ParakeetModelValidation(
                readiness: .sizeMismatch,
                path: path,
                bytes: bytes,
                architecture: architecture
            )
        }

        if requireChecksum {
            guard let digest = sha256Hex(of: fileURL) else {
                return ParakeetModelValidation(
                    readiness: .corrupt,
                    path: path,
                    bytes: bytes,
                    architecture: architecture
                )
            }
            if digest != expectedSHA256.lowercased() {
                return ParakeetModelValidation(
                    readiness: .checksumMismatch,
                    path: path,
                    bytes: bytes,
                    architecture: architecture,
                    sha256: digest
                )
            }
            return ParakeetModelValidation(
                readiness: .ready,
                path: path,
                bytes: bytes,
                architecture: architecture,
                sha256: digest
            )
        }

        return ParakeetModelValidation(
            readiness: .ready,
            path: path,
            bytes: bytes,
            architecture: architecture
        )
    }

    /// Best-effort scan of the mapped GGUF for `general.architecture` = `parakeet`.
    public static func scanArchitecture(in data: Data) -> String? {
        let needle = Data("general.architecture".utf8)
        guard let range = data.range(of: needle) else { return nil }
        // After the key name GGUF stores type (u32) + length (u64) + UTF-8 bytes.
        // Search a small window for the ASCII token "parakeet" as a practical check.
        let start = range.lowerBound
        let end = min(data.count, start + 128)
        let window = data[start..<end]
        if let archRange = window.range(of: Data("parakeet".utf8)) {
            return String(data: window[archRange], encoding: .utf8)
        }
        // Capture other short ASCII arch tokens if present after the key.
        if let alt = firstASCIIToken(in: window, after: needle.count) {
            return alt
        }
        return nil
    }

    private static func firstASCIIToken(in data: Data, after offset: Int) -> String? {
        let slice = data.dropFirst(offset)
        var bytes: [UInt8] = []
        for byte in slice {
            if (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || (0x30...0x39).contains(byte) || byte == 0x2D || byte == 0x5F {
                bytes.append(byte)
                if bytes.count > 32 { break }
            } else if !bytes.isEmpty {
                break
            }
        }
        guard bytes.count >= 3 else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    public static func sha256Hex(of fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum ParakeetModelInstallAction: Sendable, Equatable {
    case selectUserGGUF
    case useExistingReadOnlySource
}

/// Copies a validated source GGUF into QuikCal Application Support (never mutates the source).
public enum ParakeetModelInstaller: Sendable {
    public static func copyExistingModel(
        from sourceURL: URL,
        fileManager: FileManager = .default,
        requireChecksum: Bool = true
    ) throws -> ParakeetModelValidation {
        let validation = ParakeetModelValidator.validate(
            fileURL: sourceURL,
            requireChecksum: requireChecksum,
            fileManager: fileManager
        )
        guard validation.readiness == .ready else {
            return validation
        }
        let dir = try ParakeetModelStore.ensureModelsDirectory(fileManager: fileManager)
        let destination = dir.appendingPathComponent(ParakeetModelStore.recommendedFileName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        // Stamp NVIDIA notice beside weights.
        let notice = dir.appendingPathComponent(ParakeetModelStore.nvidiaNoticeFileName)
        if !fileManager.fileExists(atPath: notice.path) {
            let text = """
            NVIDIA Open Model License — Parakeet weights stored for QuikCal local speech.
            Source file was copied read-only into QuikCal Application Support.
            See Resources/Notices/NOTICE-NVIDIA-Parakeet.txt in the app bundle.
            """
            try Data(text.utf8).write(to: notice, options: .atomic)
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )

        return ParakeetModelValidator.validate(
            fileURL: destination,
            requireChecksum: requireChecksum,
            fileManager: fileManager
        )
    }
}
