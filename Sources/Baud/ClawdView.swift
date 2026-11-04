import SwiftUI

private struct ClawdPose {
    var y: CGFloat = 0
    var sx: CGFloat = 1
    var sy: CGFloat = 1
}

/// 小方块 Clawd：用矢量画的，带贴纸白边，会跟着串口状态做反应，也能被戳。
struct ClawdView: View {
    @ObservedObject var mood: MoodModel
    var size: CGFloat = 46

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Local private var breathe = false
    @Local private var shake: CGFloat = 0
    @Local private var blink = false
    @Local private var hop = 0
    @Local private var flip = 0.0
    @Local private var pokes = 0
    @Local private var poked = false

    private var eyesShut: Bool { blink || mood.current == .doze }

    private var symbol: String? {
        if poked { return "!" }
        switch mood.current {
        case .unplug, .fail, .failx: return "!"
        case .hex: return "?"
        case .doze: return "z"
        case .link, .send, .shy: return "♪"
        default: return nil
        }
    }

    private var breathDuration: Double {
        switch mood.current {
        case .flood: return 0.16
        case .doze: return 2.2
        case .read: return 0.7
        default: return 1.15
        }
    }

    var body: some View {
        Button(action: poke) {
            ClawdBody(eyesShut: eyesShut)
                .frame(width: size, height: size * 9 / 13)
                .scaleEffect(x: breathe ? 1.035 : 1, y: breathe ? 0.94 : 1, anchor: .bottom)
                .keyframeAnimator(initialValue: ClawdPose(), trigger: hop) { view, pose in
                    view
                        .scaleEffect(x: pose.sx, y: pose.sy, anchor: .bottom)
                        .offset(y: pose.y)
                } keyframes: { _ in
                    KeyframeTrack(\.y) {
                        LinearKeyframe(0, duration: 0.07)
                        SpringKeyframe(-size * 0.42, duration: 0.17, spring: .snappy)
                        CubicKeyframe(0, duration: 0.16)
                        LinearKeyframe(0, duration: 0.2)
                    }
                    KeyframeTrack(\.sy) {
                        CubicKeyframe(0.8, duration: 0.07)
                        CubicKeyframe(1.14, duration: 0.17)
                        CubicKeyframe(1, duration: 0.16)
                        CubicKeyframe(0.84, duration: 0.07)
                        SpringKeyframe(1, duration: 0.13)
                    }
                    KeyframeTrack(\.sx) {
                        CubicKeyframe(1.16, duration: 0.07)
                        CubicKeyframe(0.92, duration: 0.17)
                        CubicKeyframe(1, duration: 0.16)
                        CubicKeyframe(1.14, duration: 0.07)
                        SpringKeyframe(1, duration: 0.13)
                    }
                }
                .rotationEffect(.degrees(flip + (mood.current == .hex ? -9 : 0)), anchor: .bottom)
                .offset(x: shake * size * 0.07)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if let symbol {
                Text(symbol)
                    .font(.system(size: size * 0.32, weight: .heavy, design: .rounded))
                    .foregroundStyle(Palette.tx)
                    .shadow(color: Palette.paper, radius: 1.5)
                    .offset(x: size * 0.4, y: -size * 0.3)
                    .id(symbol)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(Motion.spring, value: symbol)
        .animation(Motion.spring, value: mood.current == .hex)
        .help("Clawd")
        .accessibilityLabel("小方块 Clawd")
        .onAppear(perform: startBreathing)
        .onChange(of: breathDuration) { _, _ in startBreathing() }
        .onChange(of: mood.current) { _, new in react(to: new) }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64.random(in: 2_400_000_000...5_200_000_000))
                blink = true
                try? await Task.sleep(nanoseconds: 120_000_000)
                blink = false
            }
        }
    }

    private func startBreathing() {
        guard !reduceMotion else { return }
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { breathe = false }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: breathDuration).repeatForever(autoreverses: true)) { breathe = true }
        }
    }

    private func react(to mood: Mood) {
        guard !reduceMotion else { return }
        switch mood {
        case .unplug, .fail, .failx:
            withAnimation(.easeInOut(duration: 0.07).repeatForever(autoreverses: true)) { shake = 1 }
        default:
            if shake != 0 { withAnimation(Motion.snap) { shake = 0 } }
        }
        switch mood {
        case .link:
            hop += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { hop += 1 }
        case .send, .shy, .flood:
            hop += 1
        default:
            break
        }
    }

    private func poke() {
        Haptics.tick()
        pokes += 1
        hop += 1
        if pokes % 5 == 0 {
            withAnimation(Motion.flower) { flip += 360 }
        }
        poked = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { poked = false }
    }
}

private struct ClawdBody: View {
    let eyesShut: Bool

    var body: some View {
        Canvas { context, canvas in
            let u = canvas.width / 13
            func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: x * u, y: y * u, width: w * u, height: h * u)
            }
            var shape = Path()
            shape.addRect(box(1.5, 0, 10, 6.2))
            shape.addRect(box(0, 2, 1.5, 2))
            shape.addRect(box(11.5, 2, 1.5, 2))
            for x: CGFloat in [2.6, 4.6, 7.2, 9.2] {
                shape.addRect(box(x, 6.2, 1.2, 2.3))
            }
            context.stroke(shape, with: .color(.white), style: StrokeStyle(lineWidth: u * 1.0, lineJoin: .round))
            context.stroke(shape, with: .color(Color(red: 0.29, green: 0.17, blue: 0.11).opacity(0.85)), style: StrokeStyle(lineWidth: u * 0.36, lineJoin: .round))
            context.fill(shape, with: .color(Color(red: 215 / 255, green: 119 / 255, blue: 87 / 255)))

            let eye = Color(red: 0.16, green: 0.1, blue: 0.08)
            if eyesShut {
                context.fill(Path(box(3.6, 2.7, 1.6, 0.45)), with: .color(eye))
                context.fill(Path(box(7.8, 2.7, 1.6, 0.45)), with: .color(eye))
            } else {
                context.fill(Path(box(3.8, 1.6, 1.2, 2.4)), with: .color(eye))
                context.fill(Path(box(8, 1.6, 1.2, 2.4)), with: .color(eye))
            }
        }
    }
}
