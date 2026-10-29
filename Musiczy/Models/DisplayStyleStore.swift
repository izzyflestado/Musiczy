import SwiftUI

extension SettingsKey {
    static let displayMode = "displayMode"   // 0 = Art, 1 = Lyrics
    static let artStyle = "artStyle"         // 0, 1 or 2
}

/// The six looks of the player: Art or Lyrics, each in three display styles.
enum DisplayState: Int, CaseIterable, Identifiable {
    case artNormal, artFull, artFullBar
    case lyricsNormal, lyricsFull, lyricsFullBar

    var id: Int { rawValue }
    var mode: ViewMode { rawValue < 3 ? .art : .lyrics }
    var artStyle: Int { rawValue % 3 }

    init(mode: ViewMode, artStyle: Int) {
        let style = min(max(artStyle, 0), 2)
        self = DisplayState(rawValue: (mode == .art ? 0 : 3) + style) ?? .artNormal
    }

    var group: String { mode == .art ? "Art" : "Lyrics" }

    var title: String {
        switch artStyle {
        case 0:  return "Normal"
        case 1:  return "Full HD"
        default: return "Full HD + bar"
        }
    }
}

/// Which display style the player is showing. The main window and Settings share
/// `DisplayStyleStore.shared`, and it is remembered between launches.
final class DisplayStyleStore: ObservableObject {
    static let shared = DisplayStyleStore()

    @Published var mode: ViewMode { didSet { save() } }
    @Published var artStyle: Int { didSet { save() } }

    private let persist: Bool

    init(persist: Bool = true) {
        self.persist = persist
        if persist {
            let d = UserDefaults.standard
            mode = d.integer(forKey: SettingsKey.displayMode) == 1 ? .lyrics : .art
            artStyle = min(max(d.integer(forKey: SettingsKey.artStyle), 0), 2)
        } else {
            mode = .art
            artStyle = 0
        }
    }

    var current: DisplayState { DisplayState(mode: mode, artStyle: artStyle) }

    func select(_ state: DisplayState) {
        mode = state.mode
        artStyle = state.artStyle
    }

    private func save() {
        guard persist else { return }
        let d = UserDefaults.standard
        d.set(mode == .lyrics ? 1 : 0, forKey: SettingsKey.displayMode)
        d.set(artStyle, forKey: SettingsKey.artStyle)
    }
}
