import BaudCore
import SwiftUI

/// 日志右边的多条发送面板。
struct MultiSendPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var multi: MultiSendModel

    @FocusState private var focusedRow: UUID?

    private var connected: Bool { model.link == .connected }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.line)
            if multi.items.isEmpty {
                VStack(spacing: 5) {
                    Text("还没有内容").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.sub)
                    Text("点右上角的 + 加一条").font(.system(size: 12)).foregroundStyle(Palette.faint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                rows
            }
            Divider().overlay(Palette.line)
            footer
        }
        .frame(width: 300)
        .background(Palette.panel)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("多条发送")
                .font(.system(size: 12.5, weight: .semibold))
            Text("勾选 \(multi.queue.count) 条")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Palette.faint)
            Spacer()
            Button {
                withAnimation(Motion.spring) { model.multiOpen = false }
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(SoftButtonStyle())
            .help("收起")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 38)
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            List {
                ForEach($multi.items) { $item in
                    SendRow(item: $item,
                            current: multi.currentID == item.id,
                            problem: multi.failure?.id == item.id ? multi.failure?.problem : nil,
                            connected: connected,
                            focusedRow: $focusedRow) {
                        model.sendRow(item)
                    } move: { offset in
                        withAnimation(Motion.spring) { multi.move(item.id, by: offset) }
                    } remove: {
                        withAnimation(Motion.spring) { multi.remove(item.id) }
                    }
                    .id(item.id)
                    .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .onMove(perform: multi.move)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 10)
            .onChange(of: focusedRow) { _, id in
                if let id { withAnimation(Motion.snap) { proxy.scrollTo(id) } }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let failure = multi.failure {
                Text(failure.problem.message)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.bad)
                    .lineLimit(2)
            } else if multi.running {
                Text(progressText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Palette.tx)
            } else if model.checksum.isOn {
                Text("每条都会带上 \(model.checksum.kind.title) 校验")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.sub)
            }

            HStack(spacing: 6) {
                Button {
                    let id = multi.add()
                    DispatchQueue.main.async { focusedRow = id }
                } label: {
                    Label("加一条", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12))
                        .padding(.horizontal, 5)
                }
                .buttonStyle(SoftButtonStyle())
                .fixedSize()

                Button {
                    Haptics.tick()
                    withAnimation(Motion.snap) { multi.loop.toggle() }
                } label: {
                    Label("循环", systemImage: "repeat")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12))
                        .padding(.horizontal, 5)
                }
                .buttonStyle(SoftButtonStyle(active: multi.loop))
                .fixedSize()
                .help(multi.loop ? "发完最后一条再从头开始，直到手动停止" : "发完最后一条就停")

                Spacer(minLength: 0)

                Button(action: multi.toggleRun) {
                    HStack(spacing: 4) {
                        Image(systemName: multi.running ? "stop.fill" : "play.fill").font(.system(size: 9))
                        Text(multi.running ? "停止" : "依次发送")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .fixedSize()
                .disabled(!multi.running && (!connected || multi.queue.isEmpty))
                .help(connected ? "从上到下发送勾选的条目" : "连接后才能发送")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.15), value: multi.running)
    }

    private var progressText: String {
        var parts: [String] = []
        if let progress = multi.progress { parts.append("第 \(progress.index) / \(progress.total) 条") }
        if multi.loop { parts.append("第 \(multi.round) 轮") }
        return parts.isEmpty ? "正在发送" : parts.joined(separator: " · ")
    }
}

private struct SendRow: View {
    @Binding var item: SendItem
    let current: Bool
    let problem: SendProblem?
    let connected: Bool
    var focusedRow: FocusState<UUID?>.Binding
    let send: () -> Void
    let move: (Int) -> Void
    let remove: () -> Void

    @Local private var hovering = false

    private var border: Color {
        if problem != nil { return Palette.bad }
        return current ? Palette.clay : Palette.line
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Button {
                    Haptics.tick()
                    item.enabled.toggle()
                } label: {
                    Image(systemName: item.enabled ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(item.enabled ? Palette.clay : Palette.faint)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help(item.enabled ? "参与依次发送，点一下取消" : "不参与依次发送，点一下勾选")
                .accessibilityLabel("参与依次发送")
                .accessibilityValue(item.enabled ? "是" : "否")

                Button {
                    Haptics.tick()
                    item.hex.toggle()
                } label: {
                    Text(item.hex ? "HEX" : "文本")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(item.hex ? Palette.tx : Palette.sub)
                        .frame(width: 30, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Palette.ink.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help("点一下切换文本和 HEX")

                TextField(item.hex ? "AA 55 01 FF" : "要发送的内容", text: $item.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .focused(focusedRow, equals: item.id)
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "paperplane.fill").font(.system(size: 10))
                }
                .buttonStyle(SoftButtonStyle())
                .disabled(!connected || item.isBlank)
                .help("只发这一条")
            }

            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.faint)
                    .frame(width: 14)
                    .opacity(hovering ? 1 : 0)
                    .help("拖动可以调整顺序")

                TextField("备注", text: $item.note)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.sub)

                Text("等").font(.system(size: 11)).foregroundStyle(Palette.faint)
                TextField("1000", text: $item.delay)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 38)
                    .accessibilityLabel("发完这条后等多久，单位毫秒")
                Text("ms").font(.system(size: 11)).foregroundStyle(Palette.faint)

                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.faint)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
                .opacity(hovering ? 1 : 0)
                .help("删除这一条")
            }
            .help("发完这条后等多久再发下一条，最短 \(SendItem.minDelay) ms")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(current ? Palette.selected : Palette.raised))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(border, lineWidth: current || problem != nil ? 1.5 : 1))
        .opacity(item.enabled ? 1 : 0.6)
        .animation(.easeOut(duration: 0.12), value: current)
        .animation(Motion.snap, value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("只发这一条", action: send).disabled(!connected || item.isBlank)
            Button("上移") { move(-1) }
            Button("下移") { move(1) }
            Button("删除", role: .destructive, action: remove)
        }
    }
}

/// 发送区的校验按钮，点开选算法和范围。
struct ChecksumButton: View {
    @ObservedObject var model: AppModel

    @Local private var open = false

    var body: some View {
        Button {
            Haptics.tick()
            open.toggle()
        } label: {
            Label(model.checksum.isOn ? model.checksum.kind.title : "校验", systemImage: "checkmark.seal")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12))
                .lineLimit(1)
                .padding(.horizontal, 5)
        }
        .buttonStyle(SoftButtonStyle(active: model.checksum.isOn))
        .fixedSize()
        .help("在发送的内容后面加校验")
        .popover(isPresented: $open, arrowEdge: .top) {
            ChecksumPopover(model: model)
                .presentationBackground(Palette.raised)
        }
    }
}

private struct ChecksumPopover: View {
    @ObservedObject var model: AppModel

    private var kind: ChecksumKind { model.checksum.kind }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("发送时加校验").font(.system(size: 13, weight: .semibold))

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], spacing: 6) {
                ForEach(ChecksumKind.allCases, id: \.self) { option in
                    Button {
                        Haptics.tick()
                        withAnimation(Motion.snap) { model.checksum.kind = option }
                    } label: {
                        Text(option.title)
                            .font(.system(size: 12, weight: kind == option ? .semibold : .regular))
                            .foregroundStyle(kind == option ? Palette.onClay : Palette.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(kind == option ? Palette.clay : Palette.ink.opacity(0.06)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityAddTraits(kind == option ? .isSelected : [])
                }
            }

            // 选项一直占位，用不上时变灰。弹窗打开后不会跟着内容变高，换算法时也不会跳
            Text(kind.detail)
                .font(.system(size: 11))
                .foregroundStyle(Palette.sub)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(Palette.line)

            Stepper(value: $model.checksum.startByte, in: 1...4096) {
                Text("从第 \(model.checksum.startByte) 字节算到末尾")
                    .font(.system(size: 12).monospacedDigit())
            }
            .disabled(!model.checksum.isOn)
            .help("设备的校验不算帧头时，把起点往后调")

            SlidingSegment(selection: $model.checksum.lowFirst, options: [(false, "高字节在前"), (true, "低字节在前")])
                .fixedSize()
                .disabled(kind.width < 2)
                .opacity(kind.width < 2 ? 0.45 : 1)
                .help(kind.width < 2 ? "这个算法的校验只有 1 个字节，不分先后" : "和设备的协议保持一致")

            HStack(spacing: 5) {
                Text("输入框这一条的校验").foregroundStyle(Palette.sub)
                Text(model.checksumPreview ?? "—").foregroundStyle(Palette.tx)
            }
            .font(.system(size: 11.5, design: .monospaced))
        }
        .padding(14)
        .frame(width: 270)
        .foregroundStyle(Palette.ink)
    }
}
