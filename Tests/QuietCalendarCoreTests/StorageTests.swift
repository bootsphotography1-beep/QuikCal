import Testing
import Foundation
@testable import QuietCalendarCore

struct StorageTests {
    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test func roundTripCRUD() throws {
        let dir = tempDir()
        let store = EventStore(directory: dir)
        let e1 = Event(title: "A", start: Date(timeIntervalSince1970: 1000), end: Date(timeIntervalSince1970: 2000))
        try store.save([e1])
        var loaded = try store.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].title == "A")

        // update
        var e2 = loaded[0]; e2.title = "B"
        try store.save([e2])
        loaded = try store.load()
        #expect(loaded[0].title == "B")

        // delete
        try store.save([])
        loaded = try store.load()
        #expect(loaded.isEmpty)
    }

    @Test func missingFileReturnsEmpty() throws {
        let dir = tempDir()
        let store = EventStore(directory: dir)
        let loaded = try store.load()
        #expect(loaded.isEmpty)
    }

    @Test func corruptFileThrowsAndPreserves() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = EventStore(directory: dir)
        let url = store.storageFileURL
        try Data("not json".utf8).write(to: url)
        do {
            _ = try store.load()
            Issue.record("expected throw")
        } catch StoreError.corruptFile {
            // ok
        } catch {
            Issue.record("unexpected error \(error)")
        }
        // corrupt preserved
        #expect(FileManager.default.fileExists(atPath: url.path))
        let backup = url.appendingPathExtension("corrupt")
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func noSilentOverwriteOnCorruptLoad() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = EventStore(directory: dir)
        let url = store.storageFileURL
        try Data("garbage".utf8).write(to: url)
        // load throws; file still contains garbage (not reset)
        _ = try? store.load()
        let data = try Data(contentsOf: url)
        #expect(String(data: data, encoding: .utf8) == "garbage")
    }

    @Test func corruptBackupPreservedAfterSave() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = EventStore(directory: dir)
        let url = store.storageFileURL
        try Data("garbage".utf8).write(to: url)
        _ = try? store.load()
        let backup = url.appendingPathExtension("corrupt")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        // saving new data must not delete corrupt backup
        try store.save([Event(title: "A", start: Date(timeIntervalSince1970: 1000), end: Date(timeIntervalSince1970: 2000))])
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }
}