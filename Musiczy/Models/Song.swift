import AppKit

struct Song: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let artist: String
    let album: String
    let artwork: NSImage?
}
