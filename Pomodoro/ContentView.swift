import AVFoundation
import Combine
import CoreText
import SwiftUI

enum TimerPanelTransition {
    static let duration = 0.3
    static let animation = Animation.timingCurve(0.42, 0, 0.58, 1, duration: duration)
}

@MainActor
final class PomodoroTimerModel: ObservableObject {
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var isRunning = false
    @Published private(set) var isAlarmPlaying = false
    @Published private(set) var isAlarmVisible = true

    private var endDate: Date?
    private var ticker: Timer?
    private var alarmBlinkTimer: Timer?
    private var sleepActivity: NSObjectProtocol?
    private let alarmPlayer = TimerAlarmPlayer()

    var formattedTime: String {
        let hours = remainingSeconds / 3600
        let minutes = (remainingSeconds % 3600) / 60
        let seconds = remainingSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    func addTime(_ seconds: Int) {
        guard !isRunning else { return }
        remainingSeconds += seconds
    }

    func toggle() {
        if isRunning {
            if let endDate {
                remainingSeconds = max(0, Int(ceil(endDate.timeIntervalSinceNow)))
            }
            stop()
        } else if remainingSeconds > 0 {
            alarmPlayer.stop()
            stopAlarmBlinking()
            isAlarmPlaying = false
            endDate = Date().addingTimeInterval(TimeInterval(remainingSeconds))
            withAnimation(TimerPanelTransition.animation) {
                isRunning = true
            }
            beginSleepPrevention()
            ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    updateCountdown()
                }
            }
        }
    }

    func reset() {
        stop()
        alarmPlayer.stop()
        stopAlarmBlinking()
        isAlarmPlaying = false
        remainingSeconds = 0
    }

    private func updateCountdown() {
        guard isRunning, let endDate else { return }
        remainingSeconds = max(0, Int(ceil(endDate.timeIntervalSinceNow)))
        if remainingSeconds == 0 {
            stop()
            let alarmStarted = alarmPlayer.play { [weak self] in
                self?.stopAlarmBlinking()
                self?.isAlarmPlaying = false
            }
            isAlarmPlaying = alarmStarted
            if alarmStarted {
                startAlarmBlinking()
            } else {
                stopAlarmBlinking()
            }
        }
    }

    private func startAlarmBlinking() {
        alarmBlinkTimer?.invalidate()
        isAlarmVisible = true
        alarmBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isAlarmVisible.toggle()
            }
        }
    }

    private func stopAlarmBlinking() {
        alarmBlinkTimer?.invalidate()
        alarmBlinkTimer = nil
        isAlarmVisible = true
    }

    private func stop() {
        withAnimation(TimerPanelTransition.animation) {
            isRunning = false
        }
        endDate = nil
        ticker?.invalidate()
        ticker = nil
        endSleepPrevention()
    }

    private func beginSleepPrevention() {
        guard sleepActivity == nil else { return }
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled],
            reason: "Pomodoro timer is running"
        )
    }

    private func endSleepPrevention() {
        guard let sleepActivity else { return }
        ProcessInfo.processInfo.endActivity(sleepActivity)
        self.sleepActivity = nil
    }
}

struct ContentView: View {
    @ObservedObject var timer: PomodoroTimerModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredIncrement: String?
    @State private var isResetHovered = false

    private let increments: [(String, Int)] = [("1h", 3600), ("20m", 1200), ("10m", 600), ("5m", 300)]
    private var ink: Color {
        colorScheme == .dark
            ? .white
            : Color(red: 62 / 255, green: 64 / 255, blue: 68 / 255)
    }
    private let orange = Color(red: 231 / 255, green: 58 / 255, blue: 0)

    var body: some View {
        GeometryReader { geometry in
        VStack(spacing: 0) {
            HStack(spacing: timerCharacterSpacing) {
                ForEach(Array(timer.formattedTime.enumerated()), id: \.offset) { element in
                    let character = element.element
                    Text(String(character))
                        .font(timerFont)
                        .monospacedDigit()
                        .foregroundStyle(ink)
                        .frame(
                            width: character == ":" ? timerGlyphWidths.separator : timerGlyphWidths.digit,
                            height: 191
                        )
                        .offset(y: character == ":" ? -17 : 0)
                }
            }
            .contentTransition(.identity)
            .frame(width: 289, height: 191)
            .accessibilityElement()
            .accessibilityLabel("Timer: \(timer.formattedTime)")
            .opacity(timer.isAlarmPlaying && !timer.isAlarmVisible ? 0 : 1)

            VStack(spacing: 0) {
                Color.clear
                    .frame(height: 74)
                    .overlay(alignment: .top) {
                        HStack(spacing: 6) {
                            ForEach(increments, id: \.0) { title, seconds in
                                Button {
                                    timer.addTime(seconds)
                                } label: {
                                    Text(title)
                                        .font(.system(size: 16, weight: .regular))
                                        .foregroundStyle(ink)
                                        .frame(width: 68, height: 68)
                                        .background {
                                            Circle()
                                                .fill(hoveredIncrement == title ? .regularMaterial : .ultraThinMaterial)
                                                .overlay { Circle().fill(.white.opacity(0.18)) }
                                                .overlay { Circle().strokeBorder(.regularMaterial, lineWidth: 1) }
                                        }
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .onHover { isHovering in
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        hoveredIncrement = isHovering ? title : nil
                                    }
                                }
                                .accessibilityLabel("Add \(title)")
                            }
                        }
                        .frame(height: 68, alignment: .top)
                        .opacity(timer.isRunning ? 0 : 1)
                        .allowsHitTesting(!timer.isRunning)
                        .accessibilityHidden(timer.isRunning)
                    }

                coordinatedButtonPair
            }
            .frame(width: 290)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(width: 330, height: 361, alignment: .top)
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        .clipped()
        .modifier(NativePanelGlass())
        }
    }

    private var startButtonLabel: some View {
        ZStack {
            Text("START")
                .opacity(timer.isRunning ? 0 : 1)
                .accessibilityHidden(timer.isRunning)
            Text("STOP")
                .opacity(timer.isRunning ? 1 : 0)
                .accessibilityHidden(!timer.isRunning)
        }
        .font(.system(size: 14, weight: .regular))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Capsule())
    }

    @ViewBuilder
    private var coordinatedButtonPair: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) {
                animatedButtonPair
            }
        } else {
            animatedButtonPair
        }
    }

    private var animatedButtonPair: some View {
        buttonPair
            .offset(y: controlsOffset)
    }

    private var buttonPair: some View {
        HStack(spacing: 6) {
            Button(action: timer.reset) {
                Text("RESET")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        Circle()
                            .fill(isResetHovered ? .regularMaterial : .ultraThinMaterial)
                            .overlay { Circle().fill(.white.opacity(0.18)) }
                            .overlay { Circle().strokeBorder(.regularMaterial, lineWidth: 1) }
                    }
            }
            .buttonStyle(.plain)
            .frame(width: 68, height: 68)
            .onHover { isHovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isResetHovered = isHovering
                }
            }

            startStopButton
        }
        .frame(width: 290, height: 68)
    }

    @ViewBuilder
    private var startStopButton: some View {
        if #available(macOS 26.0, *) {
            Button(action: timer.toggle) {
                startButtonLabel
                    .frame(width: 216, height: 68)
                    .glassEffect(.regular.tint(orange).interactive(), in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
        } else {
            Button(action: timer.toggle) {
                startButtonLabel
                    .frame(width: 216, height: 68)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(orange)
            .keyboardShortcut(.space, modifiers: [])
            .frame(width: 216, height: 68)
        }
    }

    private var controlsOffset: CGFloat {
        timer.isRunning ? -74 : 0
    }

    private var timerFont: Font {
        Font(timerCTFont)
    }

    private var timerCTFont: CTFont {
        guard let systemFont = CTFontCreateUIFontForLanguage(.system, 160, nil) else {
            return CTFontCreateWithName(".AppleSystemUIFont" as CFString, 160, nil)
        }
        let axes: [NSNumber: NSNumber] = [
            NSNumber(value: fontAxisTag("wdth")): 35,
            NSNumber(value: fontAxisTag("wght")): 200,
            NSNumber(value: fontAxisTag("opsz")): 28
        ]
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(systemFont),
            [kCTFontVariationAttribute: axes] as CFDictionary
        )
        return CTFontCreateWithFontDescriptor(descriptor, 160, nil)
    }

    private var timerGlyphWidths: (digit: CGFloat, separator: CGFloat) {
        let characters: [UniChar] = Array("0123456789:".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        let glyphsCreated = characters.withUnsafeBufferPointer { charactersBuffer in
            glyphs.withUnsafeMutableBufferPointer { glyphsBuffer in
                CTFontGetGlyphsForCharacters(
                    timerCTFont,
                    charactersBuffer.baseAddress!,
                    glyphsBuffer.baseAddress!,
                    charactersBuffer.count
                )
            }
        }
        guard glyphsCreated else { return (40, 16) }

        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        let advanceCount = glyphs.withUnsafeBufferPointer { glyphsBuffer in
            advances.withUnsafeMutableBufferPointer { advancesBuffer in
                CTFontGetAdvancesForGlyphs(
                    timerCTFont,
                    .horizontal,
                    glyphsBuffer.baseAddress!,
                    advancesBuffer.baseAddress!,
                    glyphsBuffer.count
                )
            }
        }
        guard advanceCount == Double(glyphs.count) else { return (40, 16) }

        let digitWidth = advances.prefix(10).map(\.width).max() ?? 40
        return (digitWidth, advances[10].width)
    }

    private var timerCharacterSpacing: CGFloat {
        let glyphWidths = timerGlyphWidths
        let fixedGlyphWidth = 6 * glyphWidths.digit + 2 * glyphWidths.separator
        return max(0, (289 - fixedGlyphWidth) / 7)
    }

    private func fontAxisTag(_ tag: String) -> UInt32 {
        tag.utf8.reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
    }
}

private struct NativePanelGlass: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 56))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 56))
        }
    }
}

@MainActor
private final class TimerAlarmPlayer {
    private static let playbackDuration: TimeInterval = 4.2
    private var player: AVAudioPlayer?
    private var stopWorkItem: DispatchWorkItem?

    func play(onFinished: @escaping () -> Void) -> Bool {
        stop()
        guard let url = Bundle.main.url(forResource: "alarm", withExtension: "mp3"),
              let audioPlayer = try? AVAudioPlayer(contentsOf: url) else { return false }
        player = audioPlayer
        audioPlayer.numberOfLoops = -1
        guard audioPlayer.play() else {
            player = nil
            return false
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.stop()
            onFinished()
        }
        stopWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.playbackDuration, execute: workItem)
        return true
    }

    func stop() {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        player?.stop()
        player = nil
    }
}
