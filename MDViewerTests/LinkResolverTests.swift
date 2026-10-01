import Foundation
import Testing
@testable import MDViewer

struct LinkResolverTests {
    let directory = TemporaryDirectory()
    var document: URL { directory.path("docs/README.md") }

    init() {
        directory.write("docs/README.md", "# Readme")
        directory.write("docs/ARCHITECTURE.md", "# Arch")
        directory.write("docs/images/architecture.png", "png")
        directory.write("docs/guide/README.md", "# Guide")
        directory.write("CHANGELOG.md", "# Changes")
        directory.write("docs/My File.md", "# Spaces")
    }

    @Test func relativeMarkdownLinkResolvesAgainstDocumentDirectory() {
        #expect(LinkResolver.resolve("./ARCHITECTURE.md", relativeTo: document) == .markdownFile(directory.path("docs/ARCHITECTURE.md"), fragment: nil))
        #expect(LinkResolver.resolve("ARCHITECTURE.md", relativeTo: document) == .markdownFile(directory.path("docs/ARCHITECTURE.md"), fragment: nil))
        #expect(LinkResolver.resolve("../CHANGELOG.md", relativeTo: document) == .markdownFile(directory.path("CHANGELOG.md"), fragment: nil))
    }

    @Test func fragmentsAreSeparated() {
        #expect(LinkResolver.resolve("ARCHITECTURE.md#data-flow", relativeTo: document) == .markdownFile(directory.path("docs/ARCHITECTURE.md"), fragment: "data-flow"))
        #expect(LinkResolver.resolve("#installation", relativeTo: document) == .anchor("installation"))
    }

    @Test func percentEncodedPaths() {
        #expect(LinkResolver.resolve("My%20File.md", relativeTo: document) == .markdownFile(directory.path("docs/My File.md"), fragment: nil))
    }

    @Test func externalLinks() {
        #expect(LinkResolver.resolve("https://example.com/a?b=c", relativeTo: document) == .external(URL(string: "https://example.com/a?b=c")!))
        #expect(LinkResolver.resolve("mailto:someone@example.com", relativeTo: document) == .external(URL(string: "mailto:someone@example.com")!))
    }

    @Test func folderLinksOpenTheirReadme() {
        #expect(LinkResolver.resolve("guide/", relativeTo: document) == .markdownFile(directory.path("docs/guide/README.md"), fragment: nil))
    }

    @Test func otherLocalFiles() {
        #expect(LinkResolver.resolve("images/architecture.png", relativeTo: document) == .localFile(directory.path("docs/images/architecture.png")))
    }

    @Test func missingTargetsStillResolveToAPath() {
        // Existence is checked when the link is followed so the user can be told what's missing.
        #expect(LinkResolver.resolve("./NOPE.md", relativeTo: document) == .markdownFile(directory.url.appendingPathComponent("docs/NOPE.md").standardizedFileURL, fragment: nil))
    }

    @Test func emptyDestinationIsInvalid() {
        #expect(LinkResolver.resolve("  ", relativeTo: document) == .invalid)
    }

    @Test func relativeImagesResolveAgainstDocumentDirectory() {
        #expect(LinkResolver.resourceURL("./images/architecture.png", relativeTo: document) == directory.path("docs/images/architecture.png"))
        #expect(LinkResolver.resourceURL("images/architecture.png?raw=true", relativeTo: document) == directory.path("docs/images/architecture.png"))
        #expect(LinkResolver.resourceURL("../docs/images/architecture.png", relativeTo: document) == directory.path("docs/images/architecture.png"))
    }

    @Test func remoteImagesStayRemote() {
        #expect(LinkResolver.resourceURL("https://img.shields.io/badge/x-y-green", relativeTo: document) == URL(string: "https://img.shields.io/badge/x-y-green"))
    }

    @Test func repositoryRootRelativeLinks() throws {
        try FileManager.default.createDirectory(at: directory.url.appendingPathComponent(".git"), withIntermediateDirectories: true)
        #expect(LinkResolver.resolve("/CHANGELOG.md", relativeTo: document) == .markdownFile(directory.path("CHANGELOG.md"), fragment: nil))
    }
}
