import Foundation

// Asks macOS to drop the local copy of each file (cloud copy untouched).
// Bypasses OneDrive's own "Free Up Space" action, which re-pins files.
for path in CommandLine.arguments.dropFirst() {
    do {
        try FileManager.default.evictUbiquitousItem(at: URL(fileURLWithPath: path))
        print("evicted:", path)
    } catch {
        print("FAILED:", path, error.localizedDescription)
    }
}
