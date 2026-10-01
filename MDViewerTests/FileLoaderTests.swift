import Foundation
import Testing
@testable import MDViewer

struct FileLoaderTests {
    let directory = TemporaryDirectory()

    @Test func loadsUTF8() throws {
        let url = directory.write("a.md", "# Héllo 👋")
        let file = try FileLoader.load(url).get()
        #expect(file.text == "# Héllo 👋")
        #expect(file.modificationDate != nil)
    }

    @Test func stripsUTF8ByteOrderMark() {
        #expect(FileLoader.decode(Data([0xEF, 0xBB, 0xBF]) + Data("# Title".utf8)) == "# Title")
    }

    @Test func decodesUTF16WithBOM() {
        let data = "# Wide".data(using: .utf16)!
        #expect(FileLoader.decode(data) == "# Wide")
    }

    @Test func fallsBackToLegacyEncodings() {
        let data = "café".data(using: .windowsCP1252)!
        #expect(FileLoader.decode(data) == "café")
    }

    @Test func rejectsBinaryData() {
        #expect(FileLoader.decode(Data([0x00, 0xFF, 0xFE, 0x00, 0x81, 0x00])) == nil)
    }

    @Test func emptyFileIsEmptyText() throws {
        let url = directory.write("empty.md", "")
        #expect(try FileLoader.load(url).get().text == "")
    }

    @Test func missingFile() {
        #expect(FileLoader.load(directory.path("nope.md")) == .failure(.missing))
    }

    @Test func directoryIsNotAFile() {
        #expect(FileLoader.load(directory.url) == .failure(.isDirectory))
    }

    @Test func unreadableFile() throws {
        let url = directory.write("secret.md", "hidden")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        #expect(FileLoader.load(url) == .failure(.permissionDenied))
    }
}
