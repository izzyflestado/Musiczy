import SwiftUI
import AppKit
import Combine

enum ViewMode { case art, lyrics }

/// Tells the UI whether the user has moved the mouse recently.
final class ActivityState: ObservableObject {
    @Published var isActive = true
}

struct NowPlayingScreen: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    var coverNamespace: Namespace.ID? = nil
    @ObservedObject private var activity = WindowManager.shared.activity
    @State private var dragFraction: Double? = nil
    @State private var shownTitle = ""
    @State private var shownArtist = ""
    @State private var shownAlbum = ""
    @State private var shownDuration: Double = 0
    @State private var textOpacity: Double = 1
    @State private var browseFocus: CGFloat? = nil   // nil = follow the song
    @State private var browseReset: DispatchWorkItem? = nil

    
    // The display style (Art/Lyrics + its 3 styles). The main window shares it with Settings
    // and remembers it. The lock-screen copy keeps its own, so it always starts fresh.
    @StateObject private var style: DisplayStyleStore

    private var mode: ViewMode {
        get { style.mode }
        nonmutating set { style.mode = newValue }
    }

    private var artStyle: Int {
        get { style.artStyle }
        nonmutating set { style.artStyle = newValue }
    }

    init(viewModel: NowPlayingViewModel, coverNamespace: Namespace.ID? = nil) {
        self.viewModel = viewModel
        self.coverNamespace = coverNamespace
        _style = StateObject(wrappedValue: coverNamespace == nil
                             ? DisplayStyleStore.shared
                             : DisplayStyleStore(persist: false))
    }
    
    private var hasLyrics: Bool { !viewModel.lyrics.isEmpty && !viewModel.isAd }
    
    /// 0 = none, 1 = split (5 lines right), 2 = HD centered (3 lines), 3 = HD centered (3 lines but a bit bigger)
    private var lyricsStyle: Int {
        guard mode == .lyrics && !viewModel.isAd else { return 0 }
        return (artStyle >= 1 && viewModel.song.artwork != nil) ? artStyle + 1 : 1
    }
    
    private var showLyricsLayout: Bool { lyricsStyle == 1 }
    
    /// True when the full-screen HD cover should be showing (Art or Lyrics mode).
    private var fullOn: Bool {
        artStyle >= 1 && !viewModel.isAd && viewModel.song.artwork != nil
    }
    
    /// True when title, progress and controls move to the bottom bar (state 3, Art or Lyrics).
    private var bottomOn: Bool {
        fullOn && artStyle == 2
    }
    
    // ===== SIZES: change these two numbers to resize the whole left side =====
    private let artSizeCentered: CGFloat = 380  // art mode
    private let artSizeWithLyrics: CGFloat = 380 // lyrics mode
    private let modeAnimation = Animation.timingCurve(0.65, 0, 0.35, 1, duration: 0.8)
    var onScroll: ((CGFloat) -> Void)?
    // =========================================================================
    
    var body: some View {
        let song = viewModel.song
        
        ZStack {
            // 1. Blurred background made from the same artwork
            Color.black
                .overlay {
                    if let artwork = song.artwork {
                        CrossfadeImage(image: artwork)
                            .blur(radius: 60)
                            .saturation(1.6)
                            .brightness(0.05)
                            .scaleEffect(1.3)
                            .drawingGroup()
                    }
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { resetBrowse() }
                }
                .clipped()
                .ignoresSafeArea()
            
            
            // 1b. Full-screen drifting cover (alternate art mode)
            Color.clear
                .overlay {
                    if fullOn, let artwork = song.artwork {
                        DriftingImage(image: viewModel.hiResArtwork ?? artwork)
                            .transition(.opacity)
                    }
                }
                .clipped()
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: fullOn)
            
            // 2. Dark overlay so text stays readable
            Color.black.opacity(fullOn ? 0.40 : 0.30)
                .ignoresSafeArea()
            
            // Clicking empty space sends the lyrics back to the current line
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { resetBrowse() }
            
            // 3. Foreground content
            GeometryReader { geo in
                ZStack {
                    lyricsPanel(geo: geo)   // moved below, so the buttons are always clickable

                    AnimatableProgress(progress: showLyricsLayout ? 1 : 0) { t in
                        let size = artSizeCentered + (artSizeWithLyrics - artSizeCentered) * t
                        playerColumn(song: song, size: size)
                            .offset(x: -geo.size.width / 4 * t)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                    // drives only the interpolated value, not the whole ZStack
                    .animation(modeAnimation, value: showLyricsLayout)
                    
                    bottomBar
                        .opacity(bottomOn ? 1 : 0)
                        .allowsHitTesting(bottomOn)
                        .animation(.easeInOut(duration: 0.5), value: bottomOn)
                }
            }
            .ignoresSafeArea()
        }
        .onAppear {
            syncShownText()
            // Only the main window's copy handles scrolling. The lock-screen copy
            // (which has a coverNamespace) must not steal it.
            if coverNamespace == nil {
                WindowManager.shared.onScroll = { delta in handleScroll(delta) }
            }
        }
        .onChange(of: viewModel.song.id) { _, _ in
            // 1. old text fades out
            withAnimation(.easeOut(duration: 0.3)) { textOpacity = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // 2. text swaps while invisible, layout slides to its new size
                withAnimation(.easeInOut(duration: 0.5)) {
                    shownTitle = viewModel.song.title
                    shownArtist = viewModel.song.artist
                    shownAlbum = viewModel.song.album
                    shownDuration = viewModel.duration
                }
                // 3. new text fades in after the slide
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    withAnimation(.easeIn(duration: 0.5)) { textOpacity = 1 }
                }
            }
        }
        .onChange(of: viewModel.duration) { _, new in
            if textOpacity == 1 { shownDuration = new }
        }
        .onChange(of: showLyricsLayout) { _, _ in
            // Pause polling briefly so a refresh doesn't interrupt the layout animation.
            viewModel.pausePollingUntil = Date().addingTimeInterval(1.0)
        }
        .onChange(of: fullOn) { _, on in
            viewModel.setWantsHiRes(on)
        }
        .background {
            Group {
                Button("") { viewModel.playPause() }.keyboardShortcut(.space, modifiers: [])
                Button("") { viewModel.previousTrack() }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { viewModel.nextTrack() }.keyboardShortcut(.rightArrow, modifiers: [])
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
    }
    
    private func syncShownText() {
        shownTitle = viewModel.song.title
        shownArtist = viewModel.song.artist
        shownAlbum = viewModel.song.album
        shownDuration = viewModel.duration
    }
    
    // MARK: - Buttons row (sits right above the art, fades when the mouse is idle)
    
    private func topButtons(scale: CGFloat, width: CGFloat) -> some View {
        HStack(spacing: 20 * scale) {
            sideButton(icon: mode == .art ? "play.square.fill" : "play.square",
                       help: "Art",
                       selected: mode == .art,
                       scale: scale) {
                if mode == .art {
                    artStyle = (artStyle + 1) % 3
                } else {
                    mode = .art
                }
            }
            
            sideButton(icon: hasLyrics ? (mode == .lyrics ? "mic.fill" : "mic") : "mic.slash",
                       help: hasLyrics ? "Lyrics" : "No lyrics available",
                       selected: mode == .lyrics && hasLyrics,
                       enabled: hasLyrics,
                       scale: scale) {
                if mode == .lyrics {
                    artStyle = (artStyle + 1) % 3
                } else {
                    mode = .lyrics
                }
            }
            
            sideButton(icon: "xmark", help: "Quit", selected: false, scale: scale) {
                NSApp.terminate(nil)
            }
        }
        .frame(width: width, alignment: .center)
        .opacity(activity.isActive ? 1 : 0)
        .allowsHitTesting(activity.isActive)
        .animation(.easeInOut(duration: 0.3), value: activity.isActive)
    }
    
    private func sideButton(icon: String, help: String, selected: Bool,
                            enabled: Bool = true,
                            scale: CGFloat,
                            action: @escaping () -> Void) -> some View {
        // ===== BUTTON SIZE: change these two numbers =====
        let circleSize: CGFloat = 54   // size of the round button
        let iconSize: CGFloat = 23     // size of the icon inside it
        // =================================================
        return Button(action: action) {
            Image(systemName: icon)
                .contentTransition(.identity)               // icon swaps instantly, no morph
                .font(.system(size: iconSize * scale, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: circleSize * scale, height: circleSize * scale)
                .background(Circle().fill(.white.opacity(selected ? 0.28 : 0.12)))
                .contentShape(Circle())
                .transaction { $0.animation = nil }         // the slide doesn't animate the highlight
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)   // native hover tooltip
    }
    
    // MARK: - Player column (buttons, art, text, progress, controls)
    
    private func playerColumn(song: Song, size: CGFloat) -> some View {
        let s = size / 380   // everything below scales with the art size
        let rawShown = dragFraction ?? viewModel.progress
        let shown = rawShown.isFinite ? min(max(rawShown, 0), 1) : 0
        // In the HD centered view, things slide down when the controls hide.
        let slide: CGFloat = fullOn && !activity.isActive ? 40 * s : 0
        
        return VStack(spacing: 28 * s) {
            topButtons(scale: s, width: size)
            
            if let artwork = song.artwork {
                CrossfadeImage(image: artwork)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 24 * s, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 15)
                    .blur(radius: fullOn ? 30 : 0)
                    .opacity(fullOn ? 0 : 1)
                    .animation(.easeInOut(duration: 0.6), value: fullOn)
                    .coverSlot(coverNamespace, isSource: !fullOn)
            }
            
            // Everything below fades out in state 3, when the bottom bar takes over.
            VStack(spacing: 28 * s) {
                VStack(spacing: 8 * s) {
                    if viewModel.isAd {
                        Text("Made by Izzy :)")
                            .font(.system(size: 44 * s, weight: .bold))
                    } else {
                        Text(shownTitle)
                            .font(.system(size: 44 * s, weight: .bold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.5)
                        Text(shownArtist)
                            .font(.system(size: 24 * s, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                        Text(shownAlbum)
                            .font(.system(size: 17 * s))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: max(size, 420 * s))
                .frame(minHeight: 175 * s, maxHeight: fullOn ? 175 * s : nil, alignment: .bottom)
                .opacity(textOpacity)
                .offset(y: slide)
                .animation(.easeInOut(duration: 0.3), value: activity.isActive)
                
                // Times + progress bar (click or drag to seek)
                VStack(spacing: 10 * s) {
                    HStack {
                        Text(formatTime(dragFraction.map { $0 * viewModel.duration } ?? viewModel.position))
                        Spacer()
                        Text(formatTime(shownDuration))
                    }
                    .font(.system(size: 13 * s, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: size)
                    .opacity(textOpacity)
                    
                    SeekBar(fraction: shown, height: 5 * s)
                        .frame(width: size, height: 5 * s)
                        .animation(dragFraction == nil && viewModel.animateProgress ? .linear(duration: 1) : nil, value: shown)
                        .frame(height: 24 * s)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    dragFraction = min(max(value.location.x / size, 0), 1)
                                }
                                .onEnded { value in
                                    let f = min(max(value.location.x / size, 0), 1)
                                    viewModel.seek(toFraction: f)
                                    dragFraction = nil
                                }
                        )
                }
                .padding(.top, 8 * s)
                .offset(y: slide)
                .animation(.easeInOut(duration: 0.3), value: activity.isActive)
                
                // Playback controls (fade out when idle)
                HStack(spacing: 44 * s) {
                    Button { viewModel.previousTrack() } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 28 * s))
                    }
                    
                    Button { viewModel.playPause() } label: {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 40 * s))
                            .frame(width: 44 * s)
                    }
                    
                    Button { viewModel.nextTrack() } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 28 * s))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.top, 4 * s)
                .opacity(activity.isActive ? 1 : 0)
                .allowsHitTesting(activity.isActive)
                .animation(.easeInOut(duration: 0.3), value: activity.isActive)
            }
            .opacity(bottomOn ? 0 : 1)
            .allowsHitTesting(!bottomOn)
            .animation(.easeInOut(duration: 0.5), value: bottomOn)
        }
    }
    // MARK: - Bottom bar (state 2, like Spotify on TV)
    
    private var bottomBar: some View {
        let rawShown = dragFraction ?? viewModel.progress
        let shown = rawShown.isFinite ? min(max(rawShown, 0), 1) : 0
        
        return GeometryReader { geo in
            let sidePadding: CGFloat = 60
            let barWidth = max(geo.size.width - sidePadding * 2, 1)
            
            ZStack(alignment: .bottom) {
                // Soft dark fade so the text stays readable over the photo
                LinearGradient(colors: [.clear, .black.opacity(0.65)],
                               startPoint: .top, endPoint: .bottom)
                .frame(height: 460)
                .allowsHitTesting(false)
                
                VStack(alignment: .leading, spacing: 14) {
                    // Title and details, left aligned
                    VStack(alignment: .leading, spacing: 6) {
                        Text(shownTitle)
                            .font(.system(size: 48, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text(shownArtist)
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                        Text(shownAlbum)
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(textOpacity)
                    
                    // Full-width progress bar (click or drag to seek)
                    SeekBar(fraction: shown, height: 6)
                        .frame(width: barWidth, height: 6)
                        .animation(dragFraction == nil && viewModel.animateProgress ? .linear(duration: 1) : nil, value: shown)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    dragFraction = min(max(value.location.x / barWidth, 0), 1)
                                }
                                .onEnded { value in
                                    let f = min(max(value.location.x / barWidth, 0), 1)
                                    viewModel.seek(toFraction: f)
                                    dragFraction = nil
                                }
                        )
                    
                    // Times on opposite sides, under the bar
                    HStack {
                        Text(formatTime(dragFraction.map { $0 * viewModel.duration } ?? viewModel.position))
                        Spacer()
                        Text(formatTime(shownDuration))
                    }
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .opacity(textOpacity)
                    
                    // Controls, bottom center
                    HStack(spacing: 56) {
                        Button { viewModel.previousTrack() } label: {
                            Image(systemName: "backward.fill").font(.system(size: 30))
                        }
                        Button { viewModel.playPause() } label: {
                            Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 44))
                                .frame(width: 48)
                        }
                        Button { viewModel.nextTrack() } label: {
                            Image(systemName: "forward.fill").font(.system(size: 30))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                    .opacity(activity.isActive ? 1 : 0)
                    .allowsHitTesting(activity.isActive)
                    .animation(.easeInOut(duration: 0.3), value: activity.isActive)
                }
                .padding(.horizontal, sidePadding)
                .padding(.bottom, 50)
                .offset(y: activity.isActive ? 0 : 40)
                .animation(.easeInOut(duration: 0.3), value: activity.isActive)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
    }
    
    // MARK: - Lyrics scrolling

    private func handleScroll(_ delta: CGFloat) {
        guard lyricsStyle != 0, !viewModel.lyrics.isEmpty else { return }
        let start = browseFocus ?? CGFloat(max(viewModel.currentLyricIndex, 0))
        let next = start - delta / 130
        browseFocus = min(max(next, 0), CGFloat(viewModel.lyrics.count - 1))
        scheduleBrowseReset()
    }

    /// Goes back to the current line after 3 seconds without scrolling.
    private func scheduleBrowseReset() {
        browseReset?.cancel()
        let work = DispatchWorkItem { resetBrowse() }
        browseReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func resetBrowse() {
        browseReset?.cancel()
        guard browseFocus != nil else { return }
        withAnimation(.spring(response: 0.8, dampingFraction: 0.9)) { browseFocus = nil }
    }
    
    // MARK: - Lyrics panel
    
    private func lyricsPanel(geo: GeometryProxy) -> some View {
        let w = geo.size.width
        let h = geo.size.height
        let style = lyricsStyle == 3 ? 2 : lyricsStyle
        
        let panelW: CGFloat = style == 3 ? w * 0.55 : (style == 2 ? w * 0.6 : w / 2 - 80)
        let panelH: CGFloat = style == 3 ? max(h - 360, 300) : h - 80
        let x: CGFloat = style == 3 ? -w / 2 + 60 + panelW / 2
        : (style == 2 ? 0 : (style == 1 ? w / 4 : w / 2))
        let y: CGFloat = style == 3 ? -170 : (style == 2 ? -90 : 0)
        
        // Fixed font and row height; the 3rd state is scaled up so it animates smoothly.
        let scale: CGFloat = lyricsStyle == 3 ? 1.3 : (style == 2 ? 1.08 : 1.0)

        return lyricsList(rows: style == 2 ? 3 : 5,
                          rowHeight: 130,
                          fontSize: 50,
                          centered: style == 2)
            .frame(width: panelW, height: panelH)
            .scaleEffect(scale)
            .offset(x: x, y: y + (style == 2 && !activity.isActive ? 40 : 0))
            .animation(.easeInOut(duration: 0.3), value: activity.isActive)
            .opacity(style == 0 ? 0 : 1)
            .animation(modeAnimation, value: lyricsStyle)
            .allowsHitTesting(style != 0)
    }
    
    private func lyricsList(rows: Int, rowHeight: CGFloat, fontSize: CGFloat, centered: Bool) -> some View {
        let current = viewModel.currentLyricIndex
        let focusF: CGFloat = browseFocus ?? CGFloat(current)
        let focus = Int(focusF.rounded())
        let half = rows / 2

        return Group {
            if viewModel.lyrics.isEmpty {
                Text("No lyrics available")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.lyrics.enumerated()), id: \.offset) { index, line in
                        let distance = abs(index - focus)
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: fontSize, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                            .multilineTextAlignment(centered ? .center : .leading)
                            .frame(maxWidth: .infinity,
                                   minHeight: rowHeight, maxHeight: rowHeight,
                                   alignment: centered ? .center : .leading)
                            .opacity(lyricOpacity(distance: distance, rows: rows))
                            .scaleEffect(distance == 0 ? 1.0 : (distance == 1 ? 0.8 : 0.62),
                                         anchor: centered ? .center : .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { viewModel.seek(toTime: line.time); resetBrowse() }
                            .allowsHitTesting(distance <= half)
                    }
                }
                .offset(y: (CGFloat(half) - focusF) * rowHeight)
                .animation(browseFocus == nil
                           ? .spring(response: 0.8, dampingFraction: 0.9)
                           : .easeOut(duration: 0.12),
                           value: focusF)
                .frame(height: rowHeight * CGFloat(rows), alignment: .top)
                .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: -30)
    }
    
    private func lyricOpacity(distance: Int, rows: Int) -> Double {
        switch distance {
        case 0: return 1
        case 1: return 0.55
        case 2: return rows == 5 ? 0.28 : 0
        default: return 0
        }
    }
}
    
    /// Re-builds its content on every animation frame with the in-between value,
    /// so sizes change for real instead of being stretched like a picture.
    struct AnimatableProgress<Content: View>: View, Animatable {
        var progress: Double
        let content: (Double) -> Content
        
        init(progress: Double, @ViewBuilder content: @escaping (Double) -> Content) {
            self.progress = progress
            self.content = content
        }
        
        var animatableData: Double {
            get { progress }
            set { progress = newValue }
        }
        
        var body: some View { content(progress) }
    }
    
struct ContentView: View {
    @StateObject private var viewModel = NowPlayingViewModel.shared

    var body: some View {
        NowPlayingScreen(viewModel: viewModel)
            .onAppear {
                LockScreenController.shared.start(viewModel: viewModel)
            }
    }
}

    #Preview {
        ContentView()
    }
    
    // MARK: - Window handling
    
    /// A window that is allowed to sit over the menu bar / notch area.
    final class EdgeToEdgeWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            return frameRect
        }
    }
    
    /// Covers the whole screen and shows the real red/yellow/green buttons
    /// only while the mouse is near the top.
    final class WindowManager: NSObject {
        static let shared = WindowManager()
        
        /// The buttons in ContentView watch this.
        let activity = ActivityState()
        
        var onScroll: ((CGFloat) -> Void)?
        private var monitor: Any?
        private var isFilled = false
        private var buttonsVisible = true
        private var idleTimer: Timer?
        private var cursorHidden = false
        private weak var mainWindow: NSWindow?
        private var awakeActivity: NSObjectProtocol?
        
        
        private func keepAwake(_ on: Bool) {
            if on {
                guard awakeActivity == nil else { return }
                awakeActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleDisplaySleepDisabled, .userInitiated],
                    reason: "Showing now playing"
                )
            } else if let activity = awakeActivity {
                ProcessInfo.processInfo.endActivity(activity)
                awakeActivity = nil
            }
        }
        
        func setup(_ window: NSWindow) {
            guard monitor == nil else { return }
            mainWindow = window
            
            // If an old macOS fullscreen is being restored, leave it first.
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    self?.setup(window)
                }
                return
            }
            
            
            
            window.isRestorable = false
            window.level = .normal
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = .black
            window.acceptsMouseMovedEvents = true
            
            // Red button quits the app.
            let close = window.standardWindowButton(.closeButton)
            close?.target = NSApp
            close?.action = #selector(NSApplication.terminate(_:))
            
            // Green button switches between full screen and a normal window.
            let zoom = window.standardWindowButton(.zoomButton)
            zoom?.target = self
            zoom?.action = #selector(toggleFill)
            
            fill(window)
            setButtons(visible: false, window: window, animated: false)
            
            // Watch the mouse: show the buttons only near the top edge,
            // and keep track of activity for the cursor-hiding timer.
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
            ) { [weak self, weak window] event in
                guard let self, let window else { return event }
                
                self.userActive()
                
                if event.type == .scrollWheel {
                    let d = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
                    self.onScroll?(d)
                }
                
                if event.type == .mouseMoved {
                    let y = window.mouseLocationOutsideOfEventStream.y
                    let nearTop = y > window.frame.height - 60
                    self.setButtons(visible: nearTop || !self.isFilled, window: window, animated: true)
                }
                return event
            }
            
            // Start the idle countdown right away.
            userActive()
            
            // Keep the screen on only while this app is in front.
            keepAwake(NSApp.isActive)
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil, queue: .main
            ) { [weak self] _ in self?.keepAwake(true) }
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil, queue: .main
            ) { [weak self] _ in self?.keepAwake(false) }
        }
        
        /// Shows the cursor and buttons, and restarts the idle countdown.
        func userActive() {
            if cursorHidden {
                NSCursor.unhide()
                cursorHidden = false
            }
            if !activity.isActive { activity.isActive = true }
            
            idleTimer?.invalidate()
            idleTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                guard let self, !self.cursorHidden else { return }
                NSCursor.hide()
                self.cursorHidden = true
                self.activity.isActive = false
            }
        }
        
        /// Stops the idle countdown and brings the cursor and controls back.
        func stopIdle() {
            idleTimer?.invalidate()
            if cursorHidden {
                NSCursor.unhide()
                cursorHidden = false
            }
            activity.isActive = true
        }
        
        /// Brings the main player to the front and makes it fill the screen.
        func showMainWindow() {
            guard let window = mainWindow else { return }

            if window.isMiniaturized { window.deminiaturize(nil) }

            if !isFilled {
                fill(window)
                setButtons(visible: false, window: window, animated: false)
            }

            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            userActive()   // show the cursor and controls, restart the idle countdown
        }
        
        @objc func toggleFill() {
            guard let window = mainWindow else { return }
            if isFilled {
                unfill(window)
            } else {
                fill(window)
            }
        }
        
        private func fill(_ window: NSWindow) {
            guard let screen = window.screen ?? NSScreen.main else { return }
            NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
            window.hasShadow = false
            // 2 points bigger than the screen so no thin edge line shows
            window.setFrame(screen.frame.insetBy(dx: -2, dy: -2), display: true)
            isFilled = true
        }
        
        private func unfill(_ window: NSWindow) {
            guard let screen = window.screen ?? NSScreen.main else { return }
            NSApp.presentationOptions = []
            window.hasShadow = true
            let size = NSSize(width: 1000, height: 700)
            let origin = NSPoint(x: screen.frame.midX - size.width / 2,
                                 y: screen.frame.midY - size.height / 2)
            window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
            isFilled = false
            setButtons(visible: true, window: window, animated: true)
        }
        
        private func setButtons(visible: Bool, window: NSWindow, animated: Bool) {
            guard visible != buttonsVisible || !animated else { return }
            buttonsVisible = visible
            
            let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for type in types {
                guard let button = window.standardWindowButton(type) else { continue }
                if animated {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.25
                        button.animator().alphaValue = visible ? 1 : 0
                    }
                } else {
                    button.alphaValue = visible ? 1 : 0
                }
            }
        }
    }
    
    /// Turns seconds into "m:ss", for example 185 becomes "3:05".
    func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(min(max(seconds, 0), 359_999))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
    
    /// The cover, enlarged to fill the screen (no animation).
    struct DriftingImage: View {
        let image: NSImage
        
        var body: some View {
            CrossfadeImage(image: image)
                .scaleEffect(1.1)
        }
    }

/// Track and fill drawn as ONE view, so they always move together.
struct SeekBar: View, Animatable {
    var fraction: Double
    var height: CGFloat

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    var body: some View {
        Canvas { ctx, size in
            let track = Path(roundedRect: CGRect(origin: .zero, size: size),
                             cornerRadius: size.height / 2)
            ctx.fill(track, with: .color(.white.opacity(0.25)))

            let w = size.width * min(max(fraction, 0), 1)
            if w > 0 {
                let fill = Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: size.height),
                                cornerRadius: size.height / 2)
                ctx.fill(fill, with: .color(.white.opacity(0.9)))
            }
        }
        .frame(height: height)
    }
}


