import SwiftUI
import AppKit
import Combine
import SkyLightWindow

// MARK: - Look & position (change the numbers here)

enum LockStyle {
    static let coverSize: CGFloat = 240        // cover art size (was 200)
    static let cardWidth: CGFloat = 320        // card width (was 270)
    static let expandedSide: CGFloat = 480     // size of the square when hovered
    static let coverRounding: CGFloat = 0.10   // 0 = square, 0.5 = circle
    static let glowOpacity: Double = 0.30      // 0 = no glow
    static let glowBlur: CGFloat = 20          // lower = tighter glow
    static let glowSaturation: Double = 1.3    // 1 = natural colors
    static let compactGlowOpacity: Double = 0.7    // compact card glow strength
    static let compactGlowBlur: CGFloat = 50       // compact card glow softness
    static let compactGlowScale: CGFloat = 1.10    // how far it spreads past the cover
    
    // Where the TOP of the cover sits, as a fraction of the screen height from the top.
    // Bigger number = lower on the screen.
    static let coverTopFraction: CGFloat = 0.42

    // .top = centered, .topLeading = left side, .topTrailing = right side
    static var horizontalPosition: Alignment { .top }

    static let inset: CGFloat = 18
    static let textHeight: CGFloat = 64   // space reserved above the cover for the text
    static let glowRoom: CGFloat = 40
}

// MARK: - Controller (lock detection + the lock-screen window)

final class LockScreenController: ObservableObject {
    static let shared = LockScreenController()

    @Published var isLocked = false
    @Published var isFullscreen = false

    private var viewModel: NowPlayingViewModel?
    private var observers: [NSObjectProtocol] = []
    private var skyWindow: Any?          // whatever SkyLightWindow returns; we just keep it alive
    private var collapseWork: DispatchWorkItem?
    private var activity: NSObjectProtocol?
    private var started = false
    private var awake: NSObjectProtocol?
    private var mouseTimer: Timer?
    private var lastMouse = NSEvent.mouseLocation

    func start(viewModel: NowPlayingViewModel) {
        guard !started else { return }
        started = true
        self.viewModel = viewModel

        // Stops macOS from slowing the app down while the screen is locked.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Keep now-playing updates running on the lock screen"
        )

        let center = DistributedNotificationCenter.default()

        observers.append(center.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screenLocked()
        })

        observers.append(center.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screenUnlocked()
        })
    }

    private func screenLocked() {
        keepAwake(false)
        stopMouseWatch()
        isFullscreen = false
        isLocked = true
        createSkyWindowIfNeeded()
    }
    

    private func screenUnlocked() {
        collapseWork?.cancel()
        isFullscreen = false
        isLocked = false
        keepAwake(false)
        stopMouseWatch()
    }

    /// Creates the lock-screen window the first time the screen locks.
    private func createSkyWindowIfNeeded() {
        guard skyWindow == nil,
              let viewModel,
              let screen = NSScreen.main else { return }

        let root = AnyView(LockScreenRoot(viewModel: viewModel, controller: self))
        skyWindow = SkyLightOperator.shared.delegateView(root, toScreen: screen)
    }
    
    private func keepAwake(_ on: Bool) {
        if on {
            guard awake == nil else { return }
            awake = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated],
                reason: "Fullscreen now playing on lock screen"
            )
        } else if let a = awake {
            ProcessInfo.processInfo.endActivity(a)
            awake = nil
        }
    }

    private func startMouseWatch() {
        mouseTimer?.invalidate()
        lastMouse = NSEvent.mouseLocation
        WindowManager.shared.userActive()
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = NSEvent.mouseLocation
            if now != self.lastMouse {
                self.lastMouse = now
                WindowManager.shared.userActive()
            }
        }
    }

    private func stopMouseWatch() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        WindowManager.shared.stopIdle()
    }
    
    // MARK: Fullscreen

    func enterFullscreen() {
        isFullscreen = true
        keepAwake(true)
        startMouseWatch()
        scheduleCollapse()
    }

    func exitFullscreen() {
        collapseWork?.cancel()
        isFullscreen = false
        keepAwake(false)
        stopMouseWatch()
    }

    /// Call on any click in fullscreen to restart the auto-collapse countdown.
    func touch() {
        if isFullscreen { scheduleCollapse() }
    }

    private func scheduleCollapse() {
        // auto-collapse disabled: fullscreen stays until you click the collapse button
        collapseWork?.cancel()
    }
}

// MARK: - Root view (card or fullscreen)

struct LockScreenRoot: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @ObservedObject var controller: LockScreenController
    
    @State private var hovering = false
    @State private var frames: [String: CGRect] = [:]
    @State private var atFull = false
    @State private var lastFull: CGRect? = nil
    @Namespace private var coverNS
    @ObservedObject private var activity = WindowManager.shared.activity
    
    private var hasSong: Bool {
        let title = viewModel.song.title
        return !title.isEmpty && title != "Nothing playing"
    }
    
    private var screenSize: CGSize {
        NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
    }
    
    /// Pushes the card down so the TOP OF THE COVER lands at coverTopFraction.
    private var topPadding: CGFloat {
        max(0, screenSize.height * LockStyle.coverTopFraction
            - LockStyle.glowRoom - LockStyle.inset
            - LockStyle.textHeight - 14)
    }
    
    var body: some View {
        ZStack {
            if controller.isLocked && hasSong {
                if controller.isFullscreen {
                    NowPlayingScreen(viewModel: viewModel, coverNamespace: coverNS)
                        .frame(width: screenSize.width, height: screenSize.height)
                        .overlay(alignment: .topTrailing) {
                            // Always-visible way back to the small card
                            Button { controller.exitFullscreen() } label: {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .padding(12)
                                    .background(.white.opacity(0.15), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .padding(24)
                            .opacity(activity.isActive ? 1 : 0)
                            .allowsHitTesting(activity.isActive)
                            .animation(.easeInOut(duration: 0.3), value: activity.isActive)
                            }
                        // Any click is reported to the controller (auto-collapse is currently off)
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0).onEnded { _ in controller.touch() }
                        )
                        .transition(.blurFade)
                } else {
                    LockCard(viewModel: viewModel, controller: controller, expanded: hovering, coverNS: coverNS)
                        .onHover { inside in
                            withAnimation(.easeInOut(duration: 0.5)) {
                                hovering = inside
                            }
                        }
                        .padding(LockStyle.glowRoom)   // room for the glow
                        .padding(.top, topPadding)
                        .transition(.blurFade)
                }
            }
        }
        .animation(.easeInOut(duration: 0.5), value: controller.isFullscreen)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: LockStyle.horizontalPosition)
        .coordinateSpace(name: "lockRoot")
        .onPreferenceChange(CoverFrameKey.self) { new in
            if let c = new["compact"] { frames["compact"] = c }
            frames["full"] = new["full"]
            if let f = new["full"] { lastFull = f }
            if controller.isFullscreen, new["full"] != nil, !atFull {
                withAnimation(.easeInOut(duration: 0.5)) { atFull = true }
            }
        }
        .onChange(of: controller.isFullscreen) { _, on in
            if !on { withAnimation(.easeInOut(duration: 0.5)) { atFull = false } }
        }
        .overlay {
            if controller.isLocked && hasSong, let art = viewModel.song.artwork,
               let rect = atFull
                   ? (frames["full"] ?? (controller.isFullscreen ? nil : lastFull))
                   : frames["compact"] {
                Color.clear
                    .overlay {
                        Image(nsImage: art)
                            .resizable()
                            .scaledToFill()
                    }
                    .frame(width: rect.width, height: rect.height)
                    .clipShape(RoundedRectangle(cornerRadius: LockStyle.coverSize * LockStyle.coverRounding, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: atFull ? 30 : 10, y: 5)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: controller.isLocked)
    }
}
// MARK: - Card: the cover is the anchor, everything else appears relative to it

struct LockCard: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @ObservedObject var controller: LockScreenController
    let expanded: Bool
    let coverNS: Namespace.ID

    private var innerWidth: CGFloat { LockStyle.cardWidth - LockStyle.inset * 2 }
    
    /// The compact card's height written as a number, so it can animate smoothly.
    private var compactHeight: CGFloat {
        LockStyle.inset * 2 + LockStyle.textHeight + 14 + LockStyle.coverSize
    }

    /// Extra rows fade in and unfold downward from under the cover.
    private var detailTransition: AnyTransition {
        .blurFade.combined(with: .scale(scale: 0.92, anchor: .top))
    }

    private var cardWidth: CGFloat { expanded ? LockStyle.expandedSide : LockStyle.cardWidth }
    private var cardHeight: CGFloat { expanded ? LockStyle.expandedSide : compactHeight }

    var body: some View {
        ZStack(alignment: .top) {
            glass.frame(width: cardWidth, height: cardHeight)
            glow.opacity(expanded ? 1 : 0).frame(width: cardWidth, height: cardHeight)

            // Header + cover only (these never move)
            VStack(spacing: 14) {
                Button { controller.enterFullscreen() } label: {
                    VStack(spacing: 14) {
                        header
                        cover
                    }
                    .contentShape(Rectangle().inset(by: expanded ? 0 : (headerWidth - (LockStyle.cardWidth - LockStyle.inset * 2)) / 2))
                }
                .buttonStyle(.plain)
            }
            .padding(LockStyle.inset)

            // Progress + controls, pinned to the bottom edge of the animating box
            VStack(spacing: 14) {
                LockProgressBar(viewModel: viewModel, width: innerWidth,
                                onTouch: { controller.touch() })
                LockControls(viewModel: viewModel, controller: controller,
                             iconSize: 22, spacing: 40)
            }
            .padding(.bottom, 30)
            .frame(width: cardWidth, height: cardHeight, alignment: .bottom)
            .opacity(expanded ? 1 : 0)
            .allowsHitTesting(expanded)
        }
        .frame(width: LockStyle.expandedSide, height: LockStyle.expandedSide, alignment: .top)
        .contentShape(HoverArea(width: cardWidth, height: cardHeight))
    }

    // Width of the text row. It grows together with the card.
    // Constant on purpose: if this changes with `expanded`, the cover placeholder
    // gets re-laid-out mid-animation and the cover overshoots.
    private var headerWidth: CGFloat {
        LockStyle.expandedSide - LockStyle.inset * 2
    }
    private let sideWidth: CGFloat = 104      // room for the artist on the left
    private let artistMargin: CGFloat = 12    // gap between the card's left edge and the artist
    // Just the artist
    private var subtitle: String {
        viewModel.song.artist
    }
    private let topMargin: CGFloat = 12       // gap between the card's top edge and the text when expanded

    // Only the title shrinks (it's centered, so nothing else moves)
    private var titleWidth: CGFloat {
        expanded ? headerWidth - 2 * 56
                 : LockStyle.cardWidth - LockStyle.inset * 2
    }

    private var header: some View {
        ZStack(alignment: .top) {
            // Title (the album joins it when expanded)
            VStack(spacing: 3) {
                Text(viewModel.song.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .multilineTextAlignment(.center)
            .frame(width: titleWidth)
            .offset(y: expanded ? topMargin : 19)      // compact: sits lower, above the cover

            // Artist (and album when expanded): always right below the title
            Text(subtitle)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
                .frame(width: titleWidth)
                .offset(y: expanded ? topMargin + 27 : 46)

            // Expand icon: top-right corner, opens the fullscreen view.
            Button {
                controller.enterFullscreen()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(8)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
            .frame(width: cardWidth - LockStyle.inset * 2, alignment: .trailing)
            .offset(y: expanded ? topMargin : 0)
            .opacity(expanded ? 1 : 0)
            .allowsHitTesting(expanded)
        }
        .frame(width: headerWidth, height: LockStyle.textHeight, alignment: .top)
    }
    
    private var glass: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        return shape
            .fill(.ultraThinMaterial.opacity(0.5))
            // soft light across the surface
            .overlay(
                shape.fill(LinearGradient(
                    colors: [.white.opacity(0.18), .white.opacity(0.03), .clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            // inner highlight: light rolling over the top-left edge (emboss)
            .overlay(
                shape.stroke(.white.opacity(0.35), lineWidth: 6)
                    .blur(radius: 5)
                    .offset(x: 3, y: 3)
                    .clipShape(shape)
            )
            // inner shadow: depth along the bottom-right edge
            .overlay(
                shape.stroke(.black.opacity(0.30), lineWidth: 10)
                    .blur(radius: 6)
                    .offset(x: -4, y: -4)
                    .clipShape(shape)
            )
            // crisp rim: bright top-left, dark bottom-right
            .overlay(
                shape.strokeBorder(LinearGradient(
                    colors: [.white.opacity(0.65), .white.opacity(0.08),
                             .black.opacity(0.10), .black.opacity(0.25)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2)
            )
            // lift off the background: wide soft shadow + tight contact shadow
            .shadow(color: .black.opacity(0.25), radius: 30, y: 18)
            .shadow(color: .black.opacity(0.20), radius: 6, y: 3)
            .opacity(expanded ? 1 : 0)
    }

    /// Soft glow made from the cover itself. It follows the card's size.
    private var glow: some View {
        Color.clear
            .overlay {
                if let art = viewModel.song.artwork {
                    Image(nsImage: art)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .scaleEffect(1.08)
            .blur(radius: LockStyle.glowBlur)
            .saturation(LockStyle.glowSaturation)
            .opacity(LockStyle.glowOpacity)
            .allowsHitTesting(false)
    }

    /// Glow shaped like the cover (rounded), used when the card is compact.
    private var coverGlow: some View {
        Group {
            if let art = viewModel.song.artwork {
                Image(nsImage: art).resizable().scaledToFill()
            }
        }
        .frame(width: LockStyle.coverSize, height: LockStyle.coverSize)
        .clipShape(RoundedRectangle(cornerRadius: LockStyle.coverSize * LockStyle.coverRounding,
                                    style: .continuous))
        .scaleEffect(LockStyle.compactGlowScale)
        .blur(radius: LockStyle.compactGlowBlur)
        .saturation(LockStyle.glowSaturation)
        .opacity(LockStyle.compactGlowOpacity)
        .allowsHitTesting(false)
    }
    
    private var cover: some View {
        Color.clear
            .frame(width: LockStyle.coverSize, height: LockStyle.coverSize)
            .reportCoverFrame("compact")
            .background {
                coverGlow.opacity(expanded ? 0 : 1)
            }
    }
}

// MARK: - Shared pieces

struct LockProgressBar: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    let width: CGFloat
    var onTouch: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(formatTime(viewModel.position))
                Spacer()
                Text(formatTime(viewModel.duration))
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
            .frame(width: width)

            SeekBar(fraction: viewModel.progress, height: 5)
                .frame(width: width, height: 5)
                .animation(.linear(duration: 1), value: viewModel.progress)
            // Taller invisible hit area so the thin bar is easy to click.
            .frame(width: width, height: 22)
            .contentShape(Rectangle())
            // Click (or release a drag) to seek.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        onTouch?()
                        viewModel.seek(toFraction: min(max(value.location.x / width, 0), 1))
                    }
            )
        }
    }
}

struct LockControls: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @ObservedObject var controller: LockScreenController
    var iconSize: CGFloat
    var spacing: CGFloat

    var body: some View {
        HStack(spacing: spacing) {
            Button {
                controller.touch()
                viewModel.previousTrack()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: iconSize))
            }

            Button {
                controller.touch()
                viewModel.playPause()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: iconSize * 1.4))
                    .frame(width: iconSize * 1.6)
            }

            Button {
                controller.touch()
                viewModel.nextTrack()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: iconSize))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.92))
    }
}

// MARK: - Blur transition

struct LockBlurModifier: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

extension AnyTransition {
    /// Fades and blurs in/out.
    static var blurFade: AnyTransition {
        .modifier(active: LockBlurModifier(radius: 30),
                  identity: LockBlurModifier(radius: 0))
            .combined(with: .opacity)
    }
}

struct CoverSlot: ViewModifier {
    var namespace: Namespace.ID?
    var isSource: Bool = true

    func body(content: Content) -> some View {
        if namespace != nil {
            if isSource {
                content.opacity(0).reportCoverFrame("full")
            } else {
                content.opacity(0)   // cover hidden in this state: report nothing
            }
        } else {
            content
        }
    }
}

extension View {
    func coverSlot(_ namespace: Namespace.ID?, isSource: Bool = true) -> some View {
        modifier(CoverSlot(namespace: namespace, isSource: isSource))
    }
}

struct HoverArea: Shape {
    var width: CGFloat
    var height: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: height))
    }
}

struct CoverFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func reportCoverFrame(_ key: String) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: CoverFrameKey.self,
                                   value: [key: geo.frame(in: .named("lockRoot"))])
        })
    }
}
