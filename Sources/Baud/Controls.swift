import SwiftUI

/// 一朵向日葵，花瓣可以单独缩放。
struct Sunflower: View {
    var bloom: CGFloat = 1

    var body: some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2
                for i in 0..<16 {
                    var c = context
                    c.translateBy(x: center.x, y: center.y)
                    c.rotate(by: .degrees(Double(i) * 22.5))
                    var petal = Path()
                    petal.move(to: CGPoint(x: 0, y: -radius * 0.25))
                    petal.addCurve(to: CGPoint(x: 0, y: -radius),
                                   control1: CGPoint(x: radius * 0.2, y: -radius * 0.5),
                                   control2: CGPoint(x: radius * 0.15, y: -radius * 0.8))
                    petal.addCurve(to: CGPoint(x: 0, y: -radius * 0.25),
                                   control1: CGPoint(x: -radius * 0.15, y: -radius * 0.8),
                                   control2: CGPoint(x: -radius * 0.2, y: -radius * 0.5))
                    c.fill(petal, with: .color(i % 2 == 0
                        ? Color(red: 0.88, green: 0.47, blue: 0.18)
                        : Color(red: 0.95, green: 0.63, blue: 0.31)))
                    c.stroke(petal, with: .color(Color(red: 0.56, green: 0.25, blue: 0.09)), lineWidth: 0.8)
                }
            }
            .scaleEffect(bloom)

            Circle()
                .fill(Color(red: 0.42, green: 0.18, blue: 0.08))
                .overlay(Circle().fill(Color(red: 0.65, green: 0.32, blue: 0.12)).padding(5))
                .frame(width: 13, height: 13)
        }
    }
}

extension LinkState {
    /// 拨动开关会发生什么，显示在轨道的空白侧。
    var actionTitle: String {
        switch self {
        case .idle: return "连接"
        case .connecting: return "取消"
        case .connected: return "断开"
        case .lost: return "停止"
        }
    }

    var actionDescription: String {
        switch self {
        case .idle: return "连接串口"
        case .connecting: return "取消连接"
        case .connected: return "断开串口"
        case .lost: return "停止等待重连"
        }
    }

    var statusTitle: String {
        switch self {
        case .idle: return "未连接"
        case .connecting: return "正在连接"
        case .connected: return "已连接"
        case .lost: return "等待设备"
        }
    }
}

/// 连接开关：向日葵滑过去时旋转、绽放，到位时回弹。
struct SunflowerSwitch: View {
    let state: LinkState
    let action: () -> Void

    var body: some View {
        Button(action: action) { EmptyView() }
            .buttonStyle(SunflowerStyle(state: state))
            .help(state.actionDescription)
            .accessibilityLabel(state.actionDescription)
            .accessibilityValue(state.statusTitle)
    }
}

private struct SunflowerStyle: ButtonStyle {
    let state: LinkState

    func makeBody(configuration: Configuration) -> some View {
        SunflowerBody(state: state, pressed: configuration.isPressed)
    }
}

private struct SunflowerBody: View {
    let state: LinkState
    let pressed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Local private var spin = 0.0
    @Local private var hovering = false

    private let width: CGFloat = 90
    private let height: CGFloat = 46
    private let knob: CGFloat = 38

    private var isOn: Bool { state != .idle }

    private var track: Color {
        switch state {
        case .idle: return Palette.line
        case .connecting: return Palette.honey
        case .connected: return Palette.clay
        case .lost: return Palette.bad.opacity(0.75)
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: height / 2, style: .circular)
                .fill(track)
            RoundedRectangle(cornerRadius: height / 2, style: .circular)
                .strokeBorder(Palette.ink.opacity(0.55), lineWidth: 1.25)

            // 花朵的活动范围是 4～42（关）和 48～86（开），文字留在另一侧，不会被盖住
            HStack(spacing: 0) {
                if isOn {
                    actionLabel.frame(width: 46)
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    actionLabel.frame(width: 46)
                }
            }
            .frame(width: width)
            .allowsHitTesting(false)

            Sunflower(bloom: isOn ? 1.05 : 0.78)
                .frame(width: knob, height: knob)
                .rotationEffect(.degrees((isOn ? 270 : 0) + spin))
                .scaleEffect(x: pressed ? 1.14 : (hovering ? 1.04 : 1), y: pressed ? 0.86 : (hovering ? 1.04 : 1))
                .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                .offset(x: isOn ? width - knob - 4 : 4)
        }
        .frame(width: width, height: height)
        .contentShape(Capsule())
        .animation(reduceMotion ? .easeOut(duration: 0.15) : Motion.flower, value: state)
        .animation(Motion.snap, value: pressed)
        .animation(Motion.snap, value: hovering)
        .onHover { hovering = $0 }
        .onChange(of: state) { _, new in
            if new == .connecting {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spin += 360 }
            } else {
                withAnimation(Motion.flower) { spin = 0 }
            }
        }
    }

    private var actionLabel: some View {
        Text(state.actionTitle)
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundStyle(state == .idle ? Palette.ink : Palette.onClay)
            .id(state.actionTitle)
            .transition(.opacity)
    }
}

/// 滑块会弹性移动的分段按钮。
struct SlidingSegment<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                Button {
                    Haptics.tick()
                    withAnimation(Motion.spring) { selection = value }
                } label: {
                    Text(title)
                        .font(.system(size: 12, weight: selection == value ? .semibold : .regular))
                        .foregroundStyle(selection == value ? Palette.ink : Palette.sub)
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .background {
                            if selection == value {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Palette.raised)
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.ink.opacity(0.06)))
    }
}

/// 图标按钮：悬停高亮，按下时缩小。
struct SoftButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        SoftBody(configuration: configuration, active: active)
    }

    private struct SoftBody: View {
        let configuration: ButtonStyle.Configuration
        let active: Bool
        @Local private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .foregroundStyle(active ? Palette.tx : (hovering && enabled ? Palette.ink : Palette.sub))
                .frame(minWidth: 28, minHeight: 28)
                .padding(.horizontal, 2)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Palette.ink.opacity(active ? 0.08 : (hovering && enabled ? 0.06 : 0)))
                )
                .contentShape(Rectangle())
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .opacity(enabled ? 1 : 0.4)
                .animation(Motion.snap, value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// 橘色主按钮。
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration)
    }

    private struct PrimaryBody: View {
        let configuration: ButtonStyle.Configuration
        @Local private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.onClay)
                .padding(.horizontal, 13)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.clay))
                .brightness(hovering && enabled ? 0.04 : 0)
                .scaleEffect(configuration.isPressed ? 0.94 : (hovering && enabled ? 1.03 : 1))
                .opacity(enabled ? 1 : 0.4)
                .animation(Motion.snap, value: configuration.isPressed)
                .animation(Motion.snap, value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// 跟随主题的下拉选择。系统的下拉按钮在深色模式下会保持亮白，和整体配色不搭。
struct ThemedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    var fallback = ""

    @Local private var hovering = false
    @Environment(\.isEnabled) private var enabled

    private var title: String {
        options.first { $0.0 == selection }?.1 ?? fallback
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { value, name in
                Button {
                    selection = value
                } label: {
                    if value == selection {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.tx)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(hovering && enabled ? Palette.clay.opacity(0.7) : Palette.line, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .opacity(enabled ? 1 : 0.5)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}

struct FieldLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.sub)
    }
}

/// 收发指示灯，亮得快，灭得慢，带一点余辉。
struct ActivityLED: View {
    let hot: Bool
    let color: Color

    var body: some View {
        Circle()
            .fill(hot ? color : Palette.line)
            .frame(width: 7, height: 7)
            .shadow(color: hot ? color.opacity(0.8) : .clear, radius: hot ? 4 : 0)
            .animation(hot ? .linear(duration: 0.03) : .easeOut(duration: 0.3), value: hot)
    }
}
