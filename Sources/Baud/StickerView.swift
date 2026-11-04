import AppKit
import SwiftUI

enum Mood: String {
    case cool, peek, link, read, flood, wait, send, hex, unplug, fail, failx, doze, shy, annoyed

    var sticker: String {
        switch self {
        case .cool: return "r1c3"
        case .peek: return "r3c5"
        case .link: return "r3c1"
        case .read: return "r2c3"
        case .flood: return "r3c3"
        case .wait: return "r2c6"
        case .send: return "r1c1"
        case .hex: return "r1c5"
        case .unplug: return "r1c6"
        case .fail: return "r1c4"
        case .failx: return "r2c2"
        case .doze: return "r2c1"
        case .shy: return "r4c6"
        case .annoyed: return "r4c4"
        }
    }

    var line: String {
        switch self {
        case .cool: return "……有事吗？"
        case .peek: return "端口……还没连哦。"
        case .link: return "连上啦！"
        case .read: return "我看着呢。"
        case .flood: return "好、好多数据！"
        case .wait: return "不急，喝口咖啡。"
        case .send: return "送出去了～"
        case .hex: return "这个……不是成对的吧？"
        case .unplug: return "诶？！线呢？！"
        case .fail: return "连不上，哼！"
        case .failx: return "呜呜，还是连不上……"
        case .doze: return "zzz……"
        case .shy: return "别、别戳了……"
        case .annoyed: return "再戳我要生气了。"
        }
    }

    var burst: String? {
        switch self {
        case .link: return "★"
        case .flood: return "✦"
        case .send, .shy: return "♥"
        case .hex: return "?"
        case .unplug: return "!"
        case .fail: return "✖"
        default: return nil
        }
    }
}

final class MoodModel: ObservableObject {
    @Published private(set) var current = Mood.peek
    @Published private(set) var burstID = 0

    private var ambient = Mood.peek
    private var flashUntil = Date.distantPast
    private var restore: DispatchWorkItem?
    private var pokes = 0
    private var pokeReset: DispatchWorkItem?

    func setAmbient(_ mood: Mood) {
        ambient = mood
        if Date() >= flashUntil { show(mood) }
    }

    /// 临时换一个表情，到时间后回到当前状态对应的表情。
    func flash(_ mood: Mood, for duration: TimeInterval) {
        flashUntil = Date().addingTimeInterval(duration)
        show(mood)
        restore?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.show(self.ambient)
        }
        restore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func poke() {
        pokes += 1
        pokeReset?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pokes = 0 }
        pokeReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        flash(pokes >= 3 ? .annoyed : .shy, for: 1.8)
    }

    private func show(_ mood: Mood) {
        guard mood != current else { return }
        withAnimation(Motion.spring) { current = mood }
        if mood.burst != nil { burstID += 1 }
    }
}

enum StickerLibrary {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "stickers"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }
}

private struct PeelOff: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(progress * 15), anchor: .topTrailing)
            .offset(x: progress * 34, y: progress * -30)
            .scaleEffect(1 - progress * 0.14)
            .opacity(1 - progress)
    }
}

private struct PopIn: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(progress * -7))
            .offset(y: progress * 16)
            .scaleEffect(x: 1 - progress * 0.26, y: 1 - progress * 0.32)
            .opacity(1 - progress)
    }
}

extension AnyTransition {
    static var stickerSwap: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: PopIn(progress: 1), identity: PopIn(progress: 0)),
            removal: .modifier(active: PeelOff(progress: 1), identity: PeelOff(progress: 0))
                .animation(.easeIn(duration: 0.26))
        )
    }
}

private struct StickerCard: View {
    let name: String
    let side: CGFloat

    var body: some View {
        Group {
            if let image = StickerLibrary.image(name) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.white
            }
        }
        .frame(width: side, height: side)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: side * 0.13, style: .continuous).strokeBorder(Color.white, lineWidth: 2.5))
        .shadow(color: Color(red: 0.36, green: 0.23, blue: 0.12).opacity(0.18), radius: 8, y: 4)
    }
}

private struct Particle: Identifiable {
    let id = UUID()
    let symbol: String
    let angle: Double
    let distance: CGFloat
    let delay: Double
}

private struct ParticleView: View {
    let particle: Particle
    let radius: CGFloat
    @Local private var flown = false

    private var color: Color {
        switch particle.symbol {
        case "♥": return Color(red: 0.95, green: 0.52, blue: 0.54)
        case "★", "✦": return Color(red: 0.94, green: 0.68, blue: 0.24)
        case "!", "✖": return Color(red: 0.89, green: 0.27, blue: 0.24)
        default: return Palette.clay
        }
    }

    var body: some View {
        let dx = cos(particle.angle), dy = sin(particle.angle)
        let reach = radius + (flown ? particle.distance : 0)
        Text(particle.symbol)
            .font(.system(size: 18, weight: .heavy, design: .rounded))
            .foregroundStyle(color)
            .scaleEffect(flown ? 0.7 : 0.2)
            .rotationEffect(.degrees(flown ? 24 : -24))
            .opacity(flown ? 0 : 1)
            .offset(x: dx * reach, y: dy * reach - (flown ? 12 : 0))
            .onAppear {
                withAnimation(.timingCurve(0.2, 0.8, 0.3, 1, duration: 0.85).delay(particle.delay)) { flown = true }
            }
    }
}

/// 看板娘：贴纸可以被拖动、按压和戳，鼠标移过时会跟着倾斜。
struct StickerStage: View {
    @ObservedObject var mood: MoodModel
    var side: CGFloat = 168

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Local private var tilt = CGSize.zero
    @Local private var drag = CGSize.zero
    @Local private var pressed = false
    @Local private var moved = false
    @Local private var hovering = false
    @Local private var glare = UnitPoint.center
    @Local private var particles: [Particle] = []

    var body: some View {
        VStack(spacing: 12) {
            Text(mood.current.line)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(Capsule().fill(Palette.raised))
                .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
                .id(mood.current.line)
                .transition(.scale(scale: 0.86).combined(with: .opacity).combined(with: .offset(y: 6)))

            ZStack {
                StickerCard(name: mood.current.sticker, side: side)
                    .id(mood.current.sticker)
                    .transition(reduceMotion ? .opacity : .stickerSwap)

                RoundedRectangle(cornerRadius: side * 0.13, style: .continuous)
                    .fill(RadialGradient(colors: [.white.opacity(0.55), .white.opacity(0)], center: glare,
                                         startRadius: 0, endRadius: side * 0.72))
                    .blendMode(.softLight)
                    .opacity(hovering ? 1 : 0)
                    .frame(width: side, height: side)
                    .allowsHitTesting(false)

                ForEach(particles) { particle in
                    ParticleView(particle: particle, radius: side * 0.46)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .scaleEffect(x: pressed ? 1.04 : 1, y: pressed ? 0.94 : 1, anchor: .bottom)
            .rotation3DEffect(.degrees(Double(tilt.width) * 15), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(Double(tilt.height) * -15), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .offset(drag)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case let .active(point):
                    guard !reduceMotion else { return }
                    let x = point.x / side, y = point.y / side
                    glare = UnitPoint(x: x, y: y)
                    hovering = true
                    if drag == .zero {
                        withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.72)) {
                            tilt = CGSize(width: x - 0.5, height: y - 0.5)
                        }
                    }
                case .ended:
                    hovering = false
                    withAnimation(Motion.spring) { tilt = .zero }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !pressed {
                            moved = false
                            withAnimation(Motion.snap) { pressed = true }
                        }
                        let t = value.translation
                        if hypot(t.width, t.height) > 3 { moved = true }
                        guard moved, !reduceMotion else { return }
                        withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.8)) {
                            drag = t
                            tilt = CGSize(width: max(-0.6, min(0.6, t.width / 90)), height: max(-0.6, min(0.6, t.height / 90)))
                        }
                    }
                    .onEnded { _ in
                        withAnimation(Motion.release) {
                            pressed = false
                            drag = .zero
                            tilt = .zero
                        }
                        if !moved {
                            Haptics.tick()
                            mood.poke()
                        } else {
                            Haptics.bump()
                        }
                    }
            )
            .accessibilityLabel("看板娘，\(mood.current.line)")
            .accessibilityAddTraits(.isButton)
            .overlay(alignment: .bottomTrailing) {
                // 蹲在贴纸的右下角。拖动贴纸时它慢半拍跟上来
                ClawdView(mood: mood, size: side * 0.3)
                    .offset(x: side * 0.095 + drag.width, y: side * 0.077 + drag.height)
                    .animation(.spring(response: 0.42, dampingFraction: 0.55), value: drag)
            }
        }
        .animation(Motion.spring, value: mood.current)
        .onChange(of: mood.burstID) { _, _ in spawnBurst() }
    }

    private func spawnBurst() {
        guard !reduceMotion, let symbol = mood.current.burst else { return }
        let batch = (0..<7).map { i in
            Particle(symbol: symbol,
                     angle: -Double.pi / 2 + Double(i - 3) * 0.46,
                     distance: CGFloat.random(in: 26...48),
                     delay: Double(i) * 0.02)
        }
        particles.append(contentsOf: batch)
        let ids = Set(batch.map(\.id))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            particles.removeAll { ids.contains($0.id) }
        }
    }
}
