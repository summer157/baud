import BaudCore
import SwiftUI

struct Sidebar: View {
    @ObservedObject var model: AppModel

    @Local private var contentBottom: CGFloat = 0
    @Local private var viewportHeight: CGFloat = 0

    /// 贴纸只跟窗口高度走（640pt 时 132，760pt 及以上 168），不随连接状态变化。
    private static func stickerSide(forWindowHeight height: CGFloat) -> CGFloat {
        132 + 36 * min(1, max(0, (height - 640) / 120))
    }

    private var hasMoreBelow: Bool { contentBottom > viewportHeight + 1 }

    var body: some View {
        GeometryReader { window in
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    if model.focusMode {
                        // 专注模式收起她，小方块还留在这里陪你
                        ClawdView(mood: model.mood, size: 27)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    }
                    Text("Baud")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.sub)
                }
                .frame(height: 30)
                .padding(.horizontal, 14)

                if !model.focusMode {
                    StickerStage(mood: model.mood, side: Self.stickerSide(forWindowHeight: window.size.height))
                        .padding(.bottom, 20)
                        .transition(.scale(scale: 0.6, anchor: .top).combined(with: .opacity))
                        .zIndex(1)
                }

                // 连接开关固定在滚动区外面，设置再多也不会被滚走
                ConnectionHeader(model: model)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)

                settings

                moreBelowHint

                StatsFooter(stats: model.stats, connected: model.link == .connected)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 11)
            }
        }
        .frame(width: 256)
        .background(Palette.panel)
    }

    private var settings: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    PortFields(model: model)
                    AdvancedFields(model: model)
                    QuickCommands(model: model)
                    Color.clear.frame(height: 1).id("sidebarEnd")
                }
                .padding(.horizontal, 14)
                .padding(.top, 2)
                .background(GeometryReader { content in
                    Color.clear.preference(key: SidebarContentBottomKey.self,
                                           value: content.frame(in: .named("sidebarScroll")).maxY)
                })
            }
            .coordinateSpace(.named("sidebarScroll"))
            .scrollIndicators(.visible)
            .scrollIndicatorsFlash(onAppear: true)
            .scrollIndicatorsFlash(trigger: model.advancedOpen)
            .background(GeometryReader { viewport in
                Color.clear.preference(key: SidebarViewportHeightKey.self, value: viewport.size.height)
            })
            .onPreferenceChange(SidebarContentBottomKey.self) { contentBottom = $0 }
            .onPreferenceChange(SidebarViewportHeightKey.self) { viewportHeight = $0 }
            .onChange(of: model.sidebarScrollTick) { _, _ in
                withAnimation(Motion.spring) { proxy.scrollTo("sidebarEnd", anchor: .bottom) }
            }
        }
    }

    /// 放在滚动区外面，不遮挡设置项；高度固定，出现和消失都不会带动布局。
    private var moreBelowHint: some View {
        Button(action: model.scrollSidebarToEnd) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                Text("下方还有内容").font(.system(size: 11))
            }
            .foregroundStyle(Palette.sub)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: 20)
        .opacity(hasMoreBelow ? 1 : 0)
        .disabled(!hasMoreBelow)
        .animation(.easeOut(duration: 0.15), value: hasMoreBelow)
        .accessibilityHidden(!hasMoreBelow)
    }
}

private struct SidebarContentBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct SidebarViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ConnectionHeader: View {
    @ObservedObject var model: AppModel

    private var title: String {
        switch model.link {
        case .idle: return "未连接"
        case .connecting: return "正在连接…"
        case .connected: return "已连接"
        case .lost: return "等待设备…"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            SunflowerSwitch(state: model.link) { model.toggleLink() }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.link == .lost ? Palette.bad : Palette.ink)
                    .contentTransition(.opacity)
                Text(model.config.summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.sub)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            .animation(Motion.spring, value: title)
            Spacer(minLength: 0)
        }
    }
}

private struct PortFields: View {
    @ObservedObject var model: AppModel

    private static let bauds = ["9600", "19200", "38400", "57600", "115200", "230400", "460800", "921600", "1500000"]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 4) {
                FieldLabel("端口")
                ThemedPicker(selection: $model.selectedPort,
                             options: model.ports.map { ($0.id, $0.menuTitle) },
                             fallback: model.selectedPort.isEmpty ? "没有可用端口" : model.selectedName + "（未找到）")
            }
            VStack(alignment: .leading, spacing: 4) {
                FieldLabel("波特率")
                ThemedPicker(selection: $model.baudChoice,
                             options: Self.bauds.map { ($0, $0) } + [("custom", "自定义…")])
                if model.baudChoice == "custom" {
                    TextField("例如 250000", text: $model.customBaud)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(Motion.spring, value: model.baudChoice)
        }
    }
}

private struct AdvancedFields: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Motion.spring) { model.advancedOpen.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(model.advancedOpen ? 90 : 0))
                    Text("高级设置")
                        .font(.system(size: 12))
                    Spacer()
                }
                .foregroundStyle(Palette.sub)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if model.advancedOpen {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                    labeled("数据位") {
                        ThemedPicker(selection: $model.dataBits, options: [5, 6, 7, 8].map { ($0, "\($0)") })
                    }
                    labeled("停止位") {
                        ThemedPicker(selection: $model.stopBits, options: [(1, "1"), (2, "2")])
                    }
                    labeled("校验位") {
                        ThemedPicker(selection: $model.parity,
                                     options: [(Parity.none, "无"), (.even, "偶校验"), (.odd, "奇校验")])
                    }
                    labeled("流控") {
                        ThemedPicker(selection: $model.flow,
                                     options: [(FlowControl.none, "无"), (.rtsCts, "RTS/CTS"), (.xonXoff, "XON/XOFF")])
                    }
                    labeled("文本编码") {
                        ThemedPicker(selection: $model.encoding,
                                     options: TextEncodingChoice.allCases.map { ($0, $0.title) })
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .clipped()
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            FieldLabel(title)
            content()
        }
    }
}

private struct QuickCommands: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                FieldLabel("快捷指令")
                Spacer()
                Button {
                    withAnimation(Motion.spring) { model.addQuickFromInput() }
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(SoftButtonStyle())
                .disabled(model.input.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("把输入框的内容加为快捷指令")
            }
            ForEach(model.quick, id: \.self) { command in
                QuickRow(command: command, enabled: model.link == .connected) {
                    model.sendQuick(command)
                } remove: {
                    withAnimation(Motion.spring) { model.removeQuick(command) }
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
    }
}

private struct QuickRow: View {
    let command: String
    let enabled: Bool
    let send: () -> Void
    let remove: () -> Void

    @Local private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: send) {
                HStack {
                    Text(command)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(enabled ? Palette.ink : Palette.faint)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.clay)
                        .opacity(hovering && enabled ? 1 : 0)
                        .offset(x: hovering && enabled ? 0 : -6)
                }
                .padding(.leading, 8)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            .disabled(!enabled)

            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.faint)
            .frame(width: 20, height: 26)
            .contentShape(Rectangle())
            .opacity(hovering ? 1 : 0)
            .help("删除这条快捷指令")
        }
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.ink.opacity(hovering ? 0.06 : 0)))
        .animation(Motion.snap, value: hovering)
        .onHover { hovering = $0 }
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.snap, value: configuration.isPressed)
    }
}

private struct StatsFooter: View {
    @ObservedObject var stats: StatsModel
    let connected: Bool

    private func format(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1_048_576 { return String(format: "%.1f KB", Double(n) / 1024) }
        return String(format: "%.2f MB", Double(n) / 1_048_576)
    }

    var body: some View {
        VStack(spacing: 5) {
            Divider().overlay(Palette.line).padding(.bottom, 4)
            row("RX", value: format(stats.rx), hot: stats.rxHot, color: Palette.ok,
                trailing: connected ? format(stats.rate) + "/s" : "")
            row("TX", value: format(stats.tx), hot: stats.txHot, color: Palette.clay, trailing: "")
        }
        .font(.system(size: 11.5, design: .monospaced))
    }

    private func row(_ title: String, value: String, hot: Bool, color: Color, trailing: String) -> some View {
        HStack(spacing: 7) {
            ActivityLED(hot: hot, color: color)
            Text(title).foregroundStyle(Palette.sub)
            Text(value).foregroundStyle(Palette.ink)
            Spacer()
            Text(trailing).foregroundStyle(Palette.sub)
        }
    }
}
