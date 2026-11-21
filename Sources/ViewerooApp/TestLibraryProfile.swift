#if DEBUG
import CryptoKit
import Foundation
import ViewerooCore

@MainActor
enum TestLibraryProfile {
    static func model(at root: URL, preferences testPreferences: UserDefaults? = nil) -> LibraryModel {
        let manifest = root.appending(path: "prdb.json")
        let media = root.appending(path: "Media", directoryHint: .isDirectory)
        let state = root.appending(path: "State", directoryHint: .isDirectory)
        let fingerprint = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).prefix(12)
        let suite = "net.prdb.vieweroo.test-library." + fingerprint.map { String(format: "%02x", $0) }.joined()
        let preferences = testPreferences ?? UserDefaults(suiteName: suite)!
        return LibraryModel(access: TestLibraryAPI.access(preferences: preferences),
                            client: TestLibraryAPI(manifest: manifest).client, preferences: preferences,
                            directory: state, cache: PreviewCache(root: state.appending(path: "Previews")),
                            artworkURL: { url in
            guard let url, url.host == "portraits.vieweroo.invalid", url.pathExtension == "png",
                  UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { return nil }
            return root.appending(path: "Portraits").appending(path: url.lastPathComponent)
        }, prepareCatalog: { catalog in
            let files = FileManager.default
            guard files.isReadableFile(atPath: manifest.path), files.isReadableFile(atPath: media.path) else {
                throw TestLibraryError.missingFixtures
            }
            let marker = state.appending(path: "LibraryPrepared")
            guard !files.fileExists(atPath: marker.path) else { return }
            let name = "Motion Archive"
            let existing = try catalog.libraries().first { $0.name == name }
            let library = try existing ?? catalog.createLibrary(name: name)
            _ = try catalog.addSource(libraryID: library.id, url: media)
            try Data().write(to: marker, options: .atomic)
        })
    }
}

private enum TestLibraryError: LocalizedError {
    case missingFixtures
    var errorDescription: String? { "Run ./scripts/test-library in the checkout to prepare the test videos and PRDB fixture." }
}
#endif
