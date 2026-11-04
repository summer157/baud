import BaudCore
import SwiftUI

struct LogTextView: NSViewRepresentable {
    let controller: LogController

    func makeNSView(context: Context) -> NSScrollView { controller.scrollView }
    func updateNSView(_ view: NSScrollView, context: Context) {}
}

struct MainPane: View {
    @ObservedObject var model: AppModel

    @Local private var flights: [UUID] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(model: model, log: model.log)
            Divider().overlay(Palette.line)
            Banners(model: model, log: model.log)
            HStack(spacing: 0) {
                ZStack {
                    LogTextView(controller: model.log)
                    LogOverlays(model: model, log: model.log)
                }
                if model.multiOpen {
                    Rectangle().fill(Palette.line).frame(width: 1)
                    MultiSendPanel(model: model, multi: model.multi)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .clipped()
            Composer(model: model)
        }
        .background(Palette.paper)
        .overlay(alignment: .bottomTrailing) {
            ZStack {
                ForEach(flights, id: \.self) { _ in PaperPlane() }
            }
            .allowsHitTesting(false)
        }
        .onChange(of: model.sendTick) { _, _ in
            guard !reduceMotion else { return }
            let id = UUID()
            flights.append(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { flights.removeAll { $0 == id } }
        }
    }
}

/// 发送时飞向日志区的纸飞机。
private struct PaperPlane: View {
    @Local private var flown = false

    var body: some View {
        Image(systemName: "paperplane.fill")
            .font(.system(size: 17))
            .foregroundStyle(Palette.clay)
            .rotationEffect(.degrees(flown ? -18 : 12))
            .scaleEffect(flown ? 0.72 : 1.1)
            .opacity(flown ? 0 : 1)
            .offset(x: flown ? -150 : -44, y: flown ? -190 : -48)
            .onAppear {
                withAnimation(.timingCurve(0.25, 0.7, 0.35, 1, duration: 0.65)) { flown = true }
            }
    }
}

private struct Toolbar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var log: LogController

    @FocusState private var searchFocused: Bool

    /// 窗口窄的时候文字让位给图标，否则整个界面会被撑得超出窗口。
    private static let compactWidth: CGFloat = 720

    var body: some View {
        GeometryReader { space in
            content(compact: space.size.width < Self.compactWidth)
        }
        .frame(height: 46)
    }

    @ViewBuilder
    private func toolLabel(_ title: String, short: String?, icon: String, compact: Bool) -> some View {
        if compact, short == nil {
            Image(systemName: icon).font(.system(size: 12)).accessibilityLabel(title)
        } else {
            Label(compact ? short ?? title : title, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12))
                .padding(.horizontal, 6)
                .accessibilityLabel(title)
        }
    }

    private func content(compact: Bool) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.faint)
                TextField("搜索日志", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($searchFocused)
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.faint)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 9)
            .frame(minWidth: 110, idealWidth: 220, maxWidth: 220, minHeight: 28, maxHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(searchFocused ? Palette.raised : Palette.ink.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(searchFocused ? Palette.clay.opacity(0.7) : .clear, lineWidth: 1.5)
            )
            .scaleEffect(searchFocused ? 1.015 : 1)
            .animation(Motion.snap, value: searchFocused)
            .animation(Motion.snap, value: model.query.isEmpty)

            Text(model.query.isEmpty ? "\(log.shownCount) 行" : "\(log.shownCount) 行匹配")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Palette.faint)
                .fixedSize()

            Spacer(minLength: 8)

            FieldLabel("显示").fixedSize()
            SlidingSegment(selection: $model.viewMode, options: [(.text, "文本"), (.hex, "HEX")])
                .fixedSize()
                .accessibilityElement(children: .contain)
                .accessibilityLabel("接收内容的显示格式")

            Button {
                Haptics.tick()
                withAnimation(Motion.snap) { model.showTime.toggle() }
            } label: {
                toolLabel("时间戳", short: nil, icon: "clock", compact: compact)
            }
            .buttonStyle(SoftButtonStyle(active: model.showTime))
            .fixedSize()
            .help(model.showTime ? "隐藏时间戳" : "显示时间戳")

            Button {
                Haptics.tick()
                withAnimation(Motion.spring) { model.multiOpen.toggle() }
            } label: {
                toolLabel("多条发送", short: "多条", icon: "list.bullet.rectangle", compact: compact)
            }
            .buttonStyle(SoftButtonStyle(active: model.multiOpen))
            .fixedSize()
            .help(model.multiOpen ? "收起多条发送" : "打开多条发送")

            Rectangle().fill(Palette.line).frame(width: 1, height: 16)

            Button(action: model.togglePause) {
                Image(systemName: log.paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 12))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(SoftButtonStyle(active: log.paused))
            .help(log.paused ? "继续显示" : "暂停显示")

            Button(action: model.saveLog) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 12))
            }
            .buttonStyle(SoftButtonStyle())
            .help("保存日志")

            Button(action: model.clearLog) {
                Image(systemName: "trash").font(.system(size: 12))
            }
            .buttonStyle(SoftButtonStyle())
            .help("清屏")

            Button {
                withAnimation(Motion.spring) { model.focusMode.toggle() }
            } label: {
                Image(systemName: model.focusMode ? "face.smiling" : "moon.zzz")
                    .font(.system(size: 12))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(SoftButtonStyle(active: model.focusMode))
            .help(model.focusMode ? "请回看板娘" : "专注模式：收起看板娘")
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .onChange(of: model.searchFocusTick) { _, _ in searchFocused = true }
    }
}

private struct Banners: View {
    @ObservedObject var model: AppModel
    @ObservedObject var log: LogController

    var body: some View {
        VStack(spacing: 0) {
            if model.link == .lost {
                banner {
                    Text("设备已断开").fontWeight(.semibold).foregroundStyle(Palette.bad)
                    Text("插回后会自动重连").foregroundStyle(Palette.sub)
                    Spacer()
                    if model.canPlugDemoBack {
                        Button("模拟插回", action: model.demoPlugBack).buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            if let error = model.lastError {
                banner {
                    Text("连接失败").fontWeight(.semibold).foregroundStyle(Palette.bad)
                    Text(error).foregroundStyle(Palette.sub).lineLimit(1)
                    Spacer()
                }
            }
            if log.paused {
                banner {
                    Text("显示已暂停，后台继续接收").foregroundStyle(Palette.sub)
                    Text("\(log.pending) 行待显示")
                        .fontWeight(.semibold)
                        .foregroundStyle(Palette.tx)
                        .contentTransition(.numericText())
                    Spacer()
                    Button("继续", action: model.togglePause).buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .animation(Motion.spring, value: model.link == .lost)
        .animation(Motion.spring, value: model.lastError)
        .animation(Motion.spring, value: log.paused)
    }

    private func banner<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Palette.ink.opacity(0.05))
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

private struct LogOverlays: View {
    @ObservedObject var model: AppModel
    @ObservedObject var log: LogController

    private var emptyTitle: String {
        if !model.query.isEmpty { return "没有匹配的内容" }
        return model.link == .connected ? "正在等待数据" : "还没有数据"
    }

    private var emptyHint: String {
        if !model.query.isEmpty { return "换个关键词试试" }
        return model.link == .connected ? "设备发来的内容会显示在这里" : "选择端口，然后拨动向日葵"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if log.isEmpty {
                VStack(spacing: 5) {
                    Text(emptyTitle).font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.sub)
                    Text(emptyHint).font(.system(size: 12.5)).foregroundStyle(Palette.faint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            if !log.atBottom && !log.paused && !log.isEmpty {
                Button(action: log.jumpToEnd) {
                    Label("回到最新", systemImage: "arrow.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 13)
                        .frame(height: 28)
                        .background(Capsule().fill(Palette.raised))
                        .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
                        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
                }
                .buttonStyle(PressScaleStyle())
                .padding(.bottom, 12)
                .transition(.scale(scale: 0.7).combined(with: .opacity).combined(with: .offset(y: 10)))
            }
        }
        // 填满日志区，按钮才会贴在底部。这个外框本身不拦截点击，日志照常能选中和滚动
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(Motion.spring, value: log.atBottom)
        .animation(.easeOut(duration: 0.15), value: log.isEmpty)
    }
}

private struct Composer: View {
    @ObservedObject var model: AppModel

    @FocusState private var focused: Bool

    private var connected: Bool { model.link == .connected }
    private var empty: Bool { model.input.trimmingCharacters(in: .whitespaces).isEmpty }

    private var prompt: String {
        if !connected { return "连接后即可发送" }
        return model.sendHex ? "输入十六进制，例如 AA 55 01 FF" : "输入要发送的内容"
    }

    private var borderColor: Color {
        if model.inputError { return Palette.bad }
        return focused ? Palette.clay.opacity(0.7) : Palette.line
    }

    /// 校验字节不用自己算，打字时就能看到。
    /// 按算法固定占位：HEX 打到奇数位时没有预览，输入框也不会跟着变宽变窄。
    private var checksumSlot: some View {
        ZStack(alignment: .trailing) {
            Text("+ " + Codec.hexString(Data(repeating: 0, count: model.checksum.kind.width))).hidden()
            if let preview = model.checksumPreview {
                Text("+ " + preview).foregroundStyle(Palette.tx)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .help("这几个校验字节会加在内容后面")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                TextField(prompt, text: $model.input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .frame(height: 32)
                    .background(CaretKeeper())
                    .focused($focused)
                    .onSubmit(model.submit)
                    .onKeyPress(.upArrow) {
                        model.historyUp()
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        model.historyDown()
                        return .handled
                    }

                if model.checksum.isOn { checksumSlot }
            }
            .padding(.horizontal, 8)

            HStack(spacing: 8) {
                FieldLabel("发送").fixedSize()
                SlidingSegment(selection: $model.sendHex, options: [(false, "文本"), (true, "HEX")])
                    .fixedSize()
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("发送内容的格式")

                ThemedPicker(selection: $model.ending, options: LineEnding.allCases.map { ($0, $0.title) })
                    .frame(width: 80)
                    .disabled(model.sendHex)

                // 定时和间隔是一组，开始之前就能改间隔
                HStack(spacing: 2) {
                    Button(action: model.toggleTimer) {
                        Label("定时", systemImage: model.timerOn ? "stop.fill" : "repeat")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 12))
                            .padding(.horizontal, 5)
                    }
                    .buttonStyle(SoftButtonStyle(active: model.timerOn))
                    .disabled(!connected || (empty && !model.timerOn))

                    Rectangle().fill(Palette.line).frame(width: 1, height: 14)

                    TextField("1000", text: $model.timerMs)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 40)
                        .accessibilityLabel("定时发送的间隔，单位毫秒")
                    Text("ms").font(.system(size: 11)).foregroundStyle(Palette.sub)
                }
                .padding(.trailing, 7)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.ink.opacity(0.05)))
                .fixedSize()

                ChecksumButton(model: model)

                Spacer(minLength: 4)

                if let problem = model.inputProblem {
                    Text(problem.message)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.bad)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    // 放不下时收起，同样的内容还在发送按钮的帮助提示里
                    ViewThatFits(in: .horizontal) {
                        Text("↩ 发送  ↑ 上一条")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.faint)
                            .lineLimit(1)
                            .fixedSize()
                        Color.clear.frame(width: 0, height: 0)
                    }
                }

                Button(action: model.submit) {
                    HStack(spacing: 4) {
                        Text("发送")
                        Image(systemName: "paperplane.fill").font(.system(size: 10))
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .fixedSize()
                .disabled(!connected || empty)
                .help("回车发送，↑ 翻出上一条")
            }
        }
        .padding(.horizontal, 7)
        .padding(.top, 3)
        .padding(.bottom, 7)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.raised))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(borderColor, lineWidth: 1.5))
        .modifier(ShakeEffect(trigger: model.inputError))
        .animation(.easeOut(duration: 0.14), value: focused)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 2)
    }
}

/// 输入框变宽或变窄时，AppKit 会把正在编辑的内容滚回开头。这里在布局更新后把光标滚回可见范围。
private struct CaretKeeper: NSViewRepresentable {
    func makeNSView(context: Context) -> WidthWatcher { WidthWatcher() }
    func updateNSView(_ view: WidthWatcher, context: Context) {}

    final class WidthWatcher: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func setFrameSize(_ size: NSSize) {
            let changed = size.width != frame.width
            super.setFrameSize(size)
            guard changed else { return }
            DispatchQueue.main.async { [weak self] in self?.revealCaret() }
        }

        private func revealCaret() {
            // 全窗口共用一个编辑器，所以要确认它正在编辑的就是这个位置上的输入框，而不是搜索框
            guard let editor = window?.firstResponder as? NSTextView, let field = editor.delegate as? NSTextField,
                  field.convert(field.bounds, to: nil).intersects(convert(bounds, to: nil)) else { return }
            editor.scrollRangeToVisible(editor.selectedRange())
        }
    }
}

/// 输入有误时轻轻摇一下。
private struct ShakeEffect: ViewModifier {
    let trigger: Bool
    @Local private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .onChange(of: trigger) { _, new in
                guard new else { return }
                offset = 7
                withAnimation(.interpolatingSpring(stiffness: 700, damping: 11)) { offset = 0 }
            }
    }
}
