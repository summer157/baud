import AppKit
import BaudCore

private struct AXSnapshot: Sendable {
    struct Row: Sendable {
        let path: [String]
        let role: String
        let name: String
    }

    var rows: [Row] = []
    var status = 0
}

/// 通过系统 AX 接口读取本进程的辅助功能树。必须在主线程之外调用，否则主线程无法应答。
private func axSnapshot(pid: pid_t) -> AXSnapshot {
    var snapshot = AXSnapshot()
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 0.5)

    func text(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
    func walk(_ element: AXUIElement, _ path: [String], _ depth: Int) {
        guard depth < 40 else { return }
        let role = text(element, kAXRoleAttribute) ?? ""
        let name = [kAXDescriptionAttribute, kAXTitleAttribute].compactMap { text(element, $0) }.first { !$0.isEmpty } ?? ""
        snapshot.rows.append(.init(path: path, role: role, name: name))
        var children: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        if depth == 0 { snapshot.status = Int(result.rawValue) }
        for child in children as? [AXUIElement] ?? [] {
            walk(child, name.isEmpty ? path : path + [name], depth + 1)
        }
    }
    walk(app, [], 0)
    return snapshot
}

/// 开发用自检：设置环境变量 BAUD_SELFTEST=<目录> 后启动，应用会自己走一遍完整流程，
/// 把窗口截图存到该目录，打印检查结果，然后退出。正常双击打开时不会运行。
@MainActor
enum SelfTest {
    static func startIfRequested(_ model: AppModel) {
        guard let dir = ProcessInfo.processInfo.environment["BAUD_SELFTEST"] else { return }
        Task { await run(model, dir: URL(fileURLWithPath: dir, isDirectory: true)) }
    }

    private static func run(_ model: AppModel, dir: URL) async {
        var failures = 0
        // 用 -appearance dark 启动时，可以从这一行确认保存的外观在启动时就生效
        print("启动时外观：\(NSApp.appearance?.name.rawValue ?? "跟随系统")")
        fflush(stdout)

        func wait(_ seconds: Double) async {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        func check(_ condition: Bool, _ name: String) {
            print((condition ? "通过 " : "失败 ") + name)
            if !condition { failures += 1 }
        }
        func shot(_ name: String) {
            guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                let states = NSApp.windows.map { "visible=\($0.isVisible) mini=\($0.isMiniaturized) frame=\($0.frame)" }
                print("失败 无法截图 \(name) hidden=\(NSApp.isHidden) active=\(NSApp.isActive) windows=\(states)")
                failures += 1
                return
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
        }

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await wait(1)
        // 只跑连接相关的检查，不用等完整的自检
        if ProcessInfo.processInfo.environment["BAUD_SELFTEST_ONLY"] == "connection" {
            await ConnectionChecks.run(model, check)
            print(failures == 0 ? "自检全部通过" : "自检有 \(failures) 项失败")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        model.selectedPort = DemoDevice.portID
        await wait(0.3)
        shot("01-idle")
        check(model.link == .idle, "启动后未连接")

        model.toggleLink()
        check(model.link == .connecting, "拨动开关后进入连接中")
        await wait(0.2)
        shot("02-connecting")
        await wait(1.2)
        shot("03-connected")
        check(model.link == .connected, "连接演示设备成功")
        check(model.stats.rx > 0, "收到数据，RX=\(model.stats.rx)")

        let lines = model.log.shownCount
        model.input = "AT+GMR"
        model.submit()
        check(model.input.isEmpty, "发送后清空输入框")
        await wait(0.15)
        shot("04-sending")
        await wait(0.6)
        check(model.stats.tx == 8, "发送字节数含行尾，TX=\(model.stats.tx)")
        check(model.log.shownCount >= lines + 3, "日志里有发送行和设备回复")
        check(model.log.allEntries.contains { String(decoding: $0.bytes, as: UTF8.self).contains("v2.4.1") }, "收到 AT+GMR 的回复")

        model.input = "ABC"
        model.sendHex = true
        model.submit()
        check(model.inputError, "奇数位 HEX 被拒绝")
        await wait(0.4)
        shot("05-hex-error")
        model.input = "41 54 0D 0A"
        model.submit()
        check(!model.inputError && model.input.isEmpty, "合法 HEX 能发送")
        model.sendHex = false
        await wait(0.4)

        model.query = "sensor"
        await wait(0.4)
        shot("06-search")
        check(model.log.shownCount < model.log.allEntries.count, "搜索会过滤日志")
        model.query = ""
        await wait(0.3)

        model.viewMode = .hex
        await wait(0.3)
        shot("07-hex-view")
        model.viewMode = .text
        await wait(0.2)

        model.togglePause()
        await wait(1.5)
        check(model.log.paused && model.log.pending > 0, "暂停时后台继续接收，待显示 \(model.log.pending) 行")
        shot("08-paused")
        model.togglePause()
        await wait(0.2)
        check(!model.log.paused && model.log.pending == 0, "继续后补上暂停期间的内容")

        model.demoUnplug()
        await wait(0.6)
        check(model.link == .lost, "拔出设备后进入等待状态")
        shot("09-lost")
        model.demoPlugBack()
        await wait(1.3)
        check(model.link == .connected, "插回后自动重连")
        shot("10-reconnected")

        model.input = "AT"
        model.timerMs = "100"
        model.toggleTimer()
        let tx = model.stats.tx
        await wait(1.05)
        check(model.stats.tx - tx >= 28, "定时发送在工作，增加 \(model.stats.tx - tx) 字节")
        model.toggleTimer()
        check(!model.timerOn, "定时发送可以停止")
        model.input = ""
        model.timerMs = "1000"

        // 校验
        func sent() -> [Data] { model.log.allEntries.filter { $0.direction == .tx }.map(\.bytes) }
        model.sendHex = true
        model.checksum.kind = .modbusCRC16
        model.input = "01 03 00 00 00 0A"
        check(model.checksumPreview == "C5 CD", "输入时能看到校验字节，预览=\(model.checksumPreview ?? "无")")
        model.submit()
        check(sent().last == Data([0x01, 0x03, 0x00, 0x00, 0x00, 0x0A, 0xC5, 0xCD]), "Modbus 校验加在 HEX 后面")
        model.checksum.startByte = 20
        model.input = "01 02"
        check(model.checksumPreview == nil, "内容不够长时不显示预览")
        model.submit()
        check(model.inputProblem == .tooShort(startByte: 20) && model.input == "01 02", "内容不够长时拒绝发送，保留输入")
        await wait(0.3)
        shot("10a-checksum-too-short")
        model.checksum.startByte = 1
        model.sendHex = false
        model.checksum.kind = .add8
        model.input = "AT"
        model.submit()
        check(sent().last == Data([0x41, 0x54, 0x95, 0x0D, 0x0A]), "文本的校验放在行尾前面")
        check(model.log.exportText().contains("AT  [校验 95]"), "文本视图里单独写出校验字节")
        await wait(0.3)
        model.sendQuick("AT")
        check(sent().last == Data([0x41, 0x54, 0x95, 0x0D, 0x0A]), "快捷指令也带校验")
        model.checksum.kind = .none
        model.sendQuick("AT")
        check(sent().last == Data("AT\r\n".utf8), "关掉校验后恢复原样")
        await wait(0.3)

        // 多条发送
        let multi = model.multi
        let rowA = SendItem(text: "AT", delay: "150")
        var rowB = SendItem(text: "skipped", delay: "150")
        rowB.enabled = false
        let rowC = SendItem(hex: true, text: "41 54 0D 0A", delay: "150")
        let rowD = SendItem(text: "status", delay: "150")
        let blank = SendItem(text: "  ", delay: "150")
        multi.items = [rowA, rowB, blank, rowC, rowD]
        model.multiOpen = true
        await wait(0.6)
        var before = sent().count
        var startedAt = Date()
        multi.start()
        check(multi.running, "依次发送开始")
        await wait(0.2)
        shot("10b-multi-running")
        await wait(0.6)
        let elapsed = Date().timeIntervalSince(startedAt)
        check(!multi.running && multi.currentID == nil, "发完最后一条自动停止，用时 \(elapsed)")
        check(Array(sent()[before...]) == [Data("AT\r\n".utf8), Data("AT\r\n".utf8), Data("status\r\n".utf8)], "按顺序发送，跳过没勾选和空白的条目")
        let times = model.log.allEntries.filter { $0.direction == .tx }.suffix(3).map(\.time)
        let gaps = zip(times.dropFirst(), times).map { $0.timeIntervalSince($1) }
        print("多条发送间隔：\(gaps)")
        check(gaps.allSatisfy { $0 >= 0.14 && $0 < 0.3 }, "按设定的 150 ms 间隔发送")

        multi.items = [SendItem(text: "AT", delay: "50"), SendItem(text: "AT+GMR", delay: "50")]
        multi.loop = true
        before = sent().count
        multi.start()
        await wait(1.05)
        var looped = sent().count - before
        check(multi.running && looped >= 14 && multi.round >= 5, "循环发送在工作：\(looped) 条，第 \(multi.round) 轮")
        let beforeRemoval = sent().count
        multi.items.removeFirst()
        await wait(0.3)
        let afterRemoval = Array(sent()[beforeRemoval...])
        check(multi.running && afterRemoval.count >= 3 && afterRemoval.allSatisfy { $0 == Data("AT+GMR\r\n".utf8) },
              "发送途中删掉条目后只发剩下的，发了 \(afterRemoval.count) 条")
        multi.items.append(SendItem(text: "status", delay: "50"))
        multi.items[1].text = "AT"
        multi.stop()
        looped = sent().count
        await wait(0.3)
        check(!multi.running && sent().count == looped, "可以停止，停止后不再发送")

        await MultiSendChecks.run(check)

        // 全部写好才开始：写错的那条标出来，一条都不发
        let bad = SendItem(hex: true, text: "ABC")
        multi.items = [SendItem(text: "AT"), bad]
        before = sent().count
        multi.start()
        check(!multi.running && multi.failure?.id == bad.id && multi.failure?.problem == .badHex && sent().count == before, "有一条 HEX 写错时不开始")
        await wait(0.4)
        shot("10c-multi-bad-hex")
        multi.items[1].text = "ABCD"
        check(multi.failure == nil, "改过之后错误提示消失")

        // 单独发一条；没勾选的也能发
        var solo = SendItem(text: "AT")
        solo.enabled = false
        multi.items = [solo]
        check(multi.queue.isEmpty, "全部没勾选时依次发送没有可发的")
        multi.start()
        check(!multi.running, "没有可发的内容时不开始")
        before = sent().count
        model.sendRow(solo)
        check(sent().count == before + 1, "没勾选的条目也能单独发送")

        // 定时发送和依次发送不同时跑
        multi.items = [SendItem(text: "AT", delay: "100")]
        model.input = "AT"
        model.toggleTimer()
        multi.start()
        check(multi.running && !model.timerOn, "开始依次发送时定时发送会停")
        model.toggleTimer()
        check(model.timerOn && !multi.running, "开始定时发送时依次发送会停")
        model.toggleTimer()
        model.input = ""

        // 设备掉线时停下，重连后不会自己接着发
        multi.start()
        await wait(0.15)
        model.demoUnplug()
        await wait(0.4)
        check(!multi.running, "设备掉线后停止发送")
        model.demoPlugBack()
        await wait(1.3)
        check(model.link == .connected && !multi.running, "重连后不会自己继续发")

        // 下次打开时列表和设置都还在
        multi.items = [SendItem(enabled: false, hex: true, text: "AA 55", note: "握手", delay: "250")]
        let reopened = MultiSendModel(defaults: UserDefaults(suiteName: "local.summer.baud.selftest")!)
        check(reopened.items == multi.items && reopened.loop, "多条发送的内容重开后还在")
        multi.loop = false
        multi.items = ["AT", "AT+GMR", "status"].map { SendItem(text: $0) }
        model.multiOpen = false
        await wait(0.6)

        let rxBefore = model.stats.rx
        model.demoToggleFlood()
        await wait(5)
        shot("11-flood")
        model.demoToggleFlood()
        print("高速测试：5 秒收到 \(model.stats.rx - rxBefore) 字节，当前显示 \(model.log.shownCount) 行，共保存 \(model.log.allEntries.count) 行")
        check(model.stats.rx - rxBefore > 1_000_000, "高速接收没有被界面拖慢")
        await wait(0.5)

        model.focusMode = true
        await wait(0.6)
        shot("12-focus")
        model.focusMode = false
        await wait(0.6)

        // 外观设置不依赖系统：窗口实际外观、保存的值都要对，贴纸和日志用的动态颜色也要跟着变
        let store = UserDefaults(suiteName: "local.summer.baud.selftest")!
        func effective() -> NSAppearance.Name? {
            NSApp.windows.first { $0.isVisible }?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        }
        func paperHex() -> String {
            var hex = ""
            NSApp.windows.first { $0.isVisible }?.effectiveAppearance.performAsCurrentDrawingAppearance {
                let c = Palette.paperNS.usingColorSpace(.sRGB)
                hex = String(format: "%02X%02X%02X", Int((c?.redComponent ?? 0) * 255 + 0.5), Int((c?.greenComponent ?? 0) * 255 + 0.5), Int((c?.blueComponent ?? 0) * 255 + 0.5))
            }
            return hex
        }
        let systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        for (choice, name, color) in [(AppearanceChoice.dark, NSAppearance.Name.darkAqua, "211915"), (.light, .aqua, "FFF8EC")] {
            model.appearance = choice
            await wait(0.5)
            check(effective() == name, "选\(choice.title)后窗口是\(choice.title)")
            check(paperHex() == color, "选\(choice.title)后配色正确：\(paperHex())")
            check(store.string(forKey: "appearance") == choice.rawValue, "\(choice.title)已保存")
            shot("13-appearance-\(choice.rawValue)")
        }
        model.appearance = .system
        await wait(0.5)
        check(NSApp.appearance == nil, "回到跟随系统时不再指定外观")
        check(effective() == (systemIsDark ? .darkAqua : .aqua), "跟随系统时窗口和系统一致")
        check(store.string(forKey: "appearance") == "system", "跟随系统已保存")

        func lastNote() -> LogEntry? { model.log.allEntries.last { $0.direction == .sys } }

        // 表情在 30 kB/s 阈值附近是否来回跳
        await wait(2.5)
        model.demoSetFlood(30_000)
        await wait(2)
        var changes = 0, lastMood = model.mood.current, rates: [Int] = []
        for i in 0..<100 {
            await wait(0.1)
            if model.mood.current != lastMood {
                changes += 1
                lastMood = model.mood.current
            }
            if i % 10 == 0 { rates.append(model.stats.rate) }
        }
        model.demoSetFlood(0)
        print("30 kB/s 边界：10 秒内表情切换 \(changes) 次，每秒速率 \(rates)")
        check(changes <= 1, "阈值附近表情不来回跳")
        await wait(0.5)

        // 主动断开是中性的
        model.toggleLink()
        await wait(0.8)
        check(model.link == .idle, "可以主动断开")
        check(lastNote()?.note.hasPrefix("已断开") == true && lastNote()?.severity == .info, "主动断开记为普通事件")
        shot("14-off")

        // 意外掉线和连接失败是错误
        model.toggleLink()
        await wait(1)
        model.demoUnplug()
        await wait(0.5)
        check(model.link == .lost, "意外掉线进入等待状态")
        check(lastNote()?.severity == .error, "意外掉线记为错误事件")
        model.demoPlugBack()
        await wait(1.3)
        check(model.link == .connected && lastNote()?.note.hasPrefix("已自动重连") == true && lastNote()?.severity == .info, "重连成功记为普通事件")
        model.toggleLink()
        await wait(0.6)

        model.selectedPort = "/dev/cu.baud-selftest-missing"
        model.toggleLink()
        await wait(1)
        check(model.link == .idle && model.lastError != nil, "打不开端口时回到未连接并提示")
        check(lastNote()?.severity == .error, "连接失败记为错误事件")
        shot("15-failed")
        model.selectedPort = DemoDevice.portID
        model.toggleLink()
        await wait(1.2)
        check(model.link == .connected && model.lastError == nil, "失败后还能重新连接，错误提示会清除")

        // 两种窗口尺寸、深浅色，都检查展开高级设置后能否滚到底
        for (width, height) in [(1120.0, 760.0), (900.0, 640.0)] {
            NSApp.windows.first { $0.isVisible }?.setContentSize(NSSize(width: width, height: height))
            await wait(0.6)
            let bounds = NSApp.windows.first { $0.isVisible }?.contentView?.bounds.size ?? .zero
            check(abs(bounds.width - width) < 1 && abs(bounds.height - height) < 1, "窗口尺寸 \(bounds.width)×\(bounds.height)")
            for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let tag = "\(Int(width))x\(Int(height))-\(scheme)"
                NSApp.appearance = NSAppearance(named: appearance)
                model.advancedOpen = false
                await wait(1.0)
                check(model.log.atBottom, "\(tag) 缩放和切换外观后仍跟随最新")
                shot("\(tag)-1-default")
                model.advancedOpen = true
                await wait(1.0)
                shot("\(tag)-2-advanced")
                model.scrollSidebarToEnd()
                await wait(1.0)
                shot("\(tag)-3-scrolled")
                model.input = "ABC"
                model.sendHex = true
                model.submit()
                await wait(0.4)
                shot("\(tag)-4-hex-error")
                model.input = ""
                model.sendHex = false
                await wait(0.2)
                // 面板打开、校验名字最长时，发送区和工具栏也要放得下
                model.multiOpen = true
                model.checksum.kind = .modbusCRC16
                model.input = "AT+GMR"
                await wait(1.0)
                check(model.log.atBottom, "\(tag) 打开多条发送后仍跟随最新")
                shot("\(tag)-5-multi")
                model.multiOpen = false
                model.checksum.kind = .none
                model.input = ""
                await wait(0.6)
            }
        }
        NSApp.appearance = nil
        model.advancedOpen = false

        // 分清窗口框架、内容尺寸和 safe area，并实测窗口实际能缩到多小
        if let window = NSApp.windows.first(where: { $0.isVisible }), let content = window.contentView {
            func describe(_ label: String) {
                print("\(label)：frame=\(window.frame.size) contentRect=\(window.contentRect(forFrameRect: window.frame).size) "
                    + "contentView=\(content.bounds.size) layoutRect=\(window.contentLayoutRect.size) "
                    + "safeArea=\(content.safeAreaInsets) minSize=\(window.minSize) contentMinSize=\(window.contentMinSize)")
            }
            window.setContentSize(NSSize(width: 900, height: 640))
            await wait(0.6)
            describe("约定尺寸")
            check(content.bounds.size == NSSize(width: 900, height: 640), "内容尺寸正好是 900×640")

            window.setContentSize(NSSize(width: 400, height: 300))
            await wait(0.8)
            describe("尝试缩到 400×300 后")
            check(content.bounds.width == 900 && content.bounds.height == 640, "窗口不能缩到约定的 900×640 以下")

            window.setContentSize(NSSize(width: 900, height: 640))
            await wait(0.6)
        }

        // 走真实的窗口事件点击控件，确认列表里的按钮、输入框和弹窗都点得到。坐标按 900×640 的布局
        if let window = NSApp.windows.first(where: { $0.isVisible }), let content = window.contentView {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            func press(_ x: CGFloat, _ top: CGFloat, in target: NSWindow? = nil) async {
                let host = target ?? window
                let point = host.contentView.map { $0.convert(NSPoint(x: x, y: $0.isFlipped ? top : $0.bounds.height - top), to: nil) } ?? .zero
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                      pressure: type == .leftMouseDown ? 1 : 0) {
                        host.sendEvent(event)
                    }
                }
                await wait(0.35)
            }
            let list = model.multi
            model.multiOpen = false
            model.input = ""
            model.checksum = ChecksumSetting()
            list.items = ["AT", "AT+GMR", "status"].map { SendItem(text: $0) }
            await wait(0.6)
            await press(686, 23)
            await wait(0.5)
            check(model.multiOpen && content.bounds.width == 900, "点工具栏能打开多条发送")

            await press(632, 108)
            check(!list.items[0].enabled, "点圆圈能取消勾选第一条")
            await press(632, 108)
            check(list.items[0].enabled, "再点一次恢复勾选")
            await press(660, 173)
            check(list.items[1].hex, "点第二条的标签切换成 HEX")
            await press(660, 173)
            check(!list.items[1].hex, "再点切回文本")

            await press(760, 108)
            if let editor = window.firstResponder as? NSTextView {
                editor.insertText("+X", replacementRange: NSRange(location: 2, length: 0))
                await wait(0.2)
            }
            check(list.items[0].text == "AT+X", "点输入框能打字，内容=\(list.items[0].text)")
            window.makeFirstResponder(nil)
            list.items[0].text = "AT"
            await wait(0.2)

            let txBefore = model.log.allEntries.filter { $0.direction == .tx }.count
            await press(862, 238)
            let txEntries = model.log.allEntries.filter { $0.direction == .tx }
            check(txEntries.count == txBefore + 1 && txEntries.last?.bytes == Data("status\r\n".utf8), "点第三条的纸飞机只发这一条")

            await press(718, 531)
            check(list.loop, "点循环按钮能打开循环")
            await press(718, 531)
            check(!list.loop, "再点关闭循环")

            await press(645, 531)
            await wait(0.3)
            check(list.items.count == 4, "点加一条能新增")
            check(window.firstResponder is NSTextView, "新增后光标落在新的一条里")
            shot("18-multi-added")
            window.makeFirstResponder(nil)
            list.items.removeLast()
            await wait(0.3)

            let firstID = list.items[0].id
            list.move(firstID, by: -1)
            check(list.items[0].id == firstID, "第一条不能再上移")
            list.move(firstID, by: 1)
            check(list.items[1].id == firstID, "可以下移一位")
            list.move(from: IndexSet(integer: 1), to: 0)
            check(list.items[0].id == firstID, "拖动排序的数据操作正确")

            await press(847, 531)
            check(list.running, "点依次发送能开始")
            shot("19-multi-clicked-run")
            await press(847, 531)
            check(!list.running, "再点能停止")

            // 校验弹窗
            await press(667, 607)
            await wait(0.4)
            let popover = NSApp.windows.first { $0.isVisible && $0 !== window && String(describing: type(of: $0)).contains("Popover") }
            check(popover != nil, "点校验按钮能打开弹窗，窗口：\(NSApp.windows.map { String(describing: type(of: $0)) })")
            func popoverShot(_ name: String) {
                guard let view = popover?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
            }
            if let popover, let view = popover.contentView {
                let popoverHeight = view.bounds.height
                print("弹窗内容尺寸：\(view.bounds.size)")
                popoverShot("20-checksum-popover-off")
                model.input = "AT+GMR"
                await press(197, 57, in: popover)
                await wait(0.4)
                check(model.checksum.kind == .modbusCRC16 && model.checksum.lowFirst, "在弹窗里点选 ModbusCRC16，默认低字节在前")
                popoverShot("21-checksum-popover-on")
                model.checksum.kind = .crc32
                await wait(0.4)
                popoverShot("22-checksum-popover-crc32")
                check(view.bounds.height == popoverHeight, "换算法时弹窗高度不变")
                NSApp.appearance = NSAppearance(named: .darkAqua)
                await wait(0.5)
                popoverShot("23-checksum-popover-dark")
                NSApp.appearance = nil
                await wait(0.3)
                popover.close()
                await wait(0.3)
            }
            model.input = ""
            model.checksum = ChecksumSetting()
            list.items = ["AT", "AT+GMR", "status"].map { SendItem(text: $0) }
            model.multiOpen = false
            await wait(0.6)

            // 长内容：校验预览不能盖住输入框的末尾和光标
            let longHex = (0...255).map { String(format: "%02X", $0) }.joined(separator: " ")
            let longText = String(repeating: "status-0123456789 ", count: 20) + "END"
            let previewWidth = ceil(NSAttributedString(string: "+ 00 00 00 00", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            ]).size().width)

            func composerEditor() async -> (editor: NSTextView, field: NSTextField)? {
                await press(400, content.bounds.height - 65)
                guard let editor = window.firstResponder as? NSTextView, let field = editor.delegate as? NSTextField else { return nil }
                return (editor, field)
            }
            func replaceText(_ editor: NSTextView, _ text: String) async {
                editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                await wait(0.25)
            }
            func append(_ editor: NSTextView, _ text: String) async {
                editor.insertText(text, replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
                await wait(0.25)
            }
            /// 第 glyph 个字符完整落在输入框的可见范围里。
            /// 3pt 容差只留给字体和排版的测量误差（AppKit 连续输入时会差零点几 pt），不到半个字符宽，
            /// 显示跳回开头时差的是几千 pt，不可能混过去。
            func glyphVisible(_ editor: NSTextView, _ glyph: Int) -> Bool {
                guard let layout = editor.layoutManager, let container = editor.textContainer else { return false }
                layout.ensureLayout(for: container)
                guard glyph >= 0, glyph < layout.numberOfGlyphs else { return false }
                let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                let origin = editor.textContainerOrigin.x
                let visible = editor.visibleRect
                return visible.width > 1 && rect.minX + origin >= visible.minX - 3 && rect.maxX + origin <= visible.maxX + 3
            }
            /// 最后一个字符完整可见，并且选区还停在内容末尾。
            func caretAtVisibleEnd(_ editor: NSTextView) -> Bool {
                let end = editor.string.utf16.count
                return editor.selectedRange() == NSRange(location: end, length: 0) && glyphVisible(editor, end - 1)
            }

            for (width, height) in [(1120.0, 760.0), (900.0, 640.0)] {
                window.setContentSize(NSSize(width: width, height: height))
                await wait(0.6)
                for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    let tag = "composer-\(Int(width))x\(Int(height))-\(scheme)"
                    NSApp.appearance = NSAppearance(named: appearance)
                    model.sendHex = true
                    model.checksum = ChecksumSetting()
                    model.input = ""
                    await wait(0.5)
                    guard let (editor, field) = await composerEditor() else {
                        check(false, "\(tag) 点输入框能进入编辑")
                        continue
                    }
                    await replaceText(editor, longHex)
                    let fullWidth = field.frame.width
                    check(model.input == longHex && caretAtVisibleEnd(editor), "\(tag) 不开校验时能看到长 HEX 的末尾")
                    shot("\(tag)-1-hex-off")

                    // 走真实的弹窗操作切换算法，输入内容、焦点和末尾都要留着
                    await press(667, content.bounds.height - 33)
                    await wait(0.4)
                    let checksumPopover = NSApp.windows.first { $0.isVisible && $0 !== window && String(describing: type(of: $0)).contains("Popover") }
                    await press(197, 91, in: checksumPopover)
                    await wait(0.3)
                    checksumPopover?.close()
                    await wait(0.5)
                    check(model.checksum.kind == .crc32, "\(tag) 在弹窗里选中 CRC32")
                    check(model.checksumPreview == "29 05 8C 73", "\(tag) 00～FF 的 CRC32 是 29 05 8C 73，现在 \(model.checksumPreview ?? "无")")
                    let slotWidth = field.frame.width
                    check(fullWidth - slotWidth >= previewWidth, "\(tag) 预览有自己的位置：输入框从 \(fullWidth) 让到 \(slotWidth)，预览宽 \(previewWidth)")
                    check(window.firstResponder === editor, "\(tag) 切换算法后焦点还在输入框")
                    check(model.input == longHex, "\(tag) 切换算法后内容完整")
                    check(caretAtVisibleEnd(editor), "\(tag) 切换算法后不用打字也能看到末尾和光标")
                    shot("\(tag)-2-hex-crc32")

                    // 奇偶位交替时输入框的宽度不变
                    await append(editor, " A")
                    let oddWidth = field.frame.width
                    let oddPreview = model.checksumPreview
                    shot("\(tag)-3-hex-odd")
                    await append(editor, "B")
                    check(oddPreview == nil && model.checksumPreview != nil, "\(tag) 奇数位没有预览，补齐后才有")
                    check(oddWidth == slotWidth && field.frame.width == slotWidth, "\(tag) 奇偶位时输入框宽度不变：\(oddWidth) / \(field.frame.width) / \(slotWidth)")
                    check(caretAtVisibleEnd(editor), "\(tag) 接着打字时末尾和光标可见")

                    // 宽度不同的算法之间切换
                    model.checksum.kind = .add8
                    await wait(0.4)
                    check(field.frame.width > slotWidth && caretAtVisibleEnd(editor), "\(tag) 换成 1 字节校验后输入框变宽，末尾可见")
                    model.checksum.kind = .none
                    await wait(0.4)
                    check(field.frame.width == fullWidth && caretAtVisibleEnd(editor), "\(tag) 关掉校验后输入框恢复原宽，末尾可见")

                    // 光标在中间时停在原处，不会被挪到末尾
                    let middle = NSRange(location: 300, length: 0)
                    editor.setSelectedRange(middle)
                    editor.scrollRangeToVisible(middle)
                    await wait(0.2)
                    model.checksum.kind = .crc32
                    await wait(0.4)
                    check(editor.selectedRange() == middle && glyphVisible(editor, 300), "\(tag) 光标在中间时切换算法，留在原处并且可见")

                    // 窗口缩放也会改变输入框宽度
                    let end = NSRange(location: editor.string.utf16.count, length: 0)
                    editor.setSelectedRange(end)
                    editor.scrollRangeToVisible(end)
                    await wait(0.2)
                    window.setContentSize(NSSize(width: width + 60, height: height))
                    await wait(0.5)
                    check(caretAtVisibleEnd(editor), "\(tag) 窗口变宽后末尾可见")
                    window.setContentSize(NSSize(width: width, height: height))
                    await wait(0.5)
                    check(caretAtVisibleEnd(editor), "\(tag) 窗口变回原宽后末尾可见")
                    check(window.firstResponder === editor && model.input.hasPrefix(longHex), "\(tag) 缩放后焦点和内容都还在")

                    // 长文本
                    model.sendHex = false
                    model.checksum.kind = .modbusCRC16
                    await wait(0.4)
                    guard let (textEditor, _) = await composerEditor() else {
                        check(false, "\(tag) 切到文本后能进入编辑")
                        continue
                    }
                    await replaceText(textEditor, longText)
                    check(model.input == longText && caretAtVisibleEnd(textEditor), "\(tag) 长文本的末尾和光标可见")
                    shot("\(tag)-4-text-crc16")

                    // 点预览时回到输入框
                    window.makeFirstResponder(nil)
                    await wait(0.2)
                    await press(width - 50, content.bounds.height - 65)
                    await wait(0.2)
                    check(window.firstResponder is NSTextView, "\(tag) 点预览区域会回到输入框")

                    // 回车发送和上下键历史
                    let before = model.log.allEntries.filter { $0.direction == .tx }.count
                    model.checksum.kind = .none
                    model.input = ""
                    await wait(0.3)
                    guard let (sendEditor, _) = await composerEditor() else {
                        check(false, "\(tag) 清空后能进入编辑")
                        continue
                    }
                    await replaceText(sendEditor, "AT")
                    sendEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                    await wait(0.3)
                    check(model.log.allEntries.filter { $0.direction == .tx }.count == before + 1 && model.input.isEmpty, "\(tag) 回车发送并清空")
                    check(window.firstResponder is NSTextView, "\(tag) 发送后焦点留在输入框")
                    func arrow(_ function: Int, code: UInt16) {
                        let text = String(UnicodeScalar(UInt32(function)).map(Character.init) ?? " ")
                        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, characters: text,
                                                        charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) {
                            window.sendEvent(event)
                        }
                    }
                    arrow(NSUpArrowFunctionKey, code: 126)
                    await wait(0.3)
                    check(model.input == "AT", "\(tag) ↑ 翻出上一条，现在“\(model.input.prefix(20))”")
                    arrow(NSDownArrowFunctionKey, code: 125)
                    await wait(0.3)
                    check(model.input.isEmpty, "\(tag) ↓ 回到空输入，现在“\(model.input.prefix(20))”")

                    window.makeFirstResponder(nil)
                }
            }
            NSApp.appearance = nil
            model.sendHex = false
            model.checksum = ChecksumSetting()
            model.input = ""
            await wait(0.4)

            // 只管发送框：搜索框和日志的位置不能被带动
            model.focusSearch()
            await wait(0.4)
            if let search = window.firstResponder as? NSTextView {
                search.insertText(String(repeating: "no-such-text-", count: 30), replacementRange: NSRange(location: 0, length: search.string.utf16.count))
                await wait(0.3)
                search.setSelectedRange(NSRange(location: 0, length: 0))
                search.scroll(NSPoint(x: 200, y: 0))
                await wait(0.2)
                let searchOrigin = search.visibleRect.minX
                model.checksum.kind = .crc32
                await wait(0.4)
                check(window.firstResponder === search && searchOrigin > 100 && search.visibleRect.minX == searchOrigin, "发送框变窄时搜索框的滚动位置不变：\(searchOrigin) → \(search.visibleRect.minX)")
                model.checksum.kind = .none
                await wait(0.3)
            } else {
                check(false, "搜索框能进入编辑")
            }
            model.query = ""
            window.makeFirstResponder(nil)
            await wait(0.4)
            if let logText = model.log.scrollView.documentView as? NSTextView {
                model.log.jumpToEnd()
                await wait(0.3)
                let oldLines = NSRange(location: 0, length: 5)
                window.makeFirstResponder(logText)
                logText.setSelectedRange(oldLines)
                let logOrigin = model.log.scrollView.contentView.bounds.origin.y
                model.checksum.kind = .crc32
                await wait(0.4)
                check(logText.selectedRange() == oldLines && model.log.scrollView.contentView.bounds.origin.y >= logOrigin - 1, "发送框变窄时日志不会被滚到选区")
                model.checksum.kind = .none
                logText.setSelectedRange(NSRange(location: 0, length: 0))
                window.makeFirstResponder(nil)
                await wait(0.3)
            }

            window.setContentSize(NSSize(width: 900, height: 640))
            await wait(0.6)
        }

        // 辅助功能树：两组“文本/HEX”都要能被单独访问
        let pid = getpid()
        let ax = await Task.detached { axSnapshot(pid: pid) }.value
        let axRows = ax.rows
        let segmentButtons = axRows.filter { $0.role == "AXButton" && ($0.name == "文本" || $0.name == "HEX") }
        print("辅助功能树：AX 状态=\(ax.status) 共 \(axRows.count) 个节点；文本/HEX 按钮：" + segmentButtons.map { ($0.path.last ?? "?") + " > " + $0.name }.joined(separator: " | "))
        print("开关和分组标签：" + axRows.filter { $0.name.contains("串口") || $0.name.contains("格式") }.map { "\($0.role):\($0.name)" }.joined(separator: " | "))
        if axRows.count > 20 {
            check(segmentButtons.filter { $0.name == "文本" }.count == 2 && segmentButtons.filter { $0.name == "HEX" }.count == 2, "两组文本/HEX 按钮都能被辅助功能访问")
            for group in ["接收内容的显示格式", "发送内容的格式"] {
                check(segmentButtons.filter { $0.path.contains(group) }.count == 2, "“\(group)”分组下有自己的两个按钮")
            }
        } else {
            // 没有辅助功能权限时读不到内容树。这里不算通过，也不算产品失败
            print("未验证 辅助功能树读不到内容（AX 状态=\(ax.status)），需要用有权限的外部工具核对")
        }

        // 各种“用户离开底部”的方式，都要在数据持续到来时生效，不能被下一批日志拉回
        model.input = ""
        let logScroll = model.log.scrollView
        let clip = logScroll.contentView
        guard let logText = logScroll.documentView as? NSTextView, let logWindow = logText.window else {
            print("失败 找不到日志视图")
            exit(1)
        }
        func wheelEvent(_ pixels: Int32) -> NSEvent? {
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0)
                .flatMap { NSEvent(cgEvent: $0) }
        }
        func key(_ function: Int, code: UInt16) -> NSEvent? {
            let text = String(UnicodeScalar(UInt32(function)).map(Character.init) ?? " ")
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function], timestamp: 0,
                                    windowNumber: logWindow.windowNumber, context: nil, characters: text,
                                    charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)
        }
        func dragAboveLog() -> NSEvent? {
            let top = logText.convert(NSPoint(x: 120, y: clip.bounds.minY - 60), to: nil)
            return NSEvent.mouseEvent(with: .leftMouseDragged, location: top, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: logWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }

        model.demoSetFlood(100_000)
        await wait(1)
        logWindow.makeFirstResponder(logText)
        check(model.log.atBottom, "持续收数据时保持跟随最新")

        let departures: [(String, () -> Void)] = [
            ("滚轮大幅上翻", { _ = wheelEvent(600).map { logScroll.scrollWheel(with: $0) } }),
            ("滚轮轻微上翻", { _ = wheelEvent(12).map { logScroll.scrollWheel(with: $0) } }),
            ("PageUp 键", { _ = key(NSPageUpFunctionKey, code: 116).map { logText.keyDown(with: $0) } }),
            ("Home 键", { _ = key(NSHomeFunctionKey, code: 115).map { logText.keyDown(with: $0) } }),
            ("拖选时向上自动滚动", {
                for _ in 0..<6 { _ = dragAboveLog().map { logText.autoscroll(with: $0) } }
            }),
            ("滚动条 live-scroll 生命周期内移动", {
                NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: logScroll)
                clip.scroll(to: NSPoint(x: 0, y: max(0, clip.bounds.origin.y - 800)))
                logScroll.reflectScrolledClipView(clip)
                NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: logScroll)
            }),
        ]
        for (name, leave) in departures {
            model.log.jumpToEnd()
            await wait(0.5)
            let before = clip.bounds.origin.y
            leave()
            await wait(0.1)
            let moved = clip.bounds.origin.y
            let line = model.log.topVisibleLine
            await wait(2.5)
            let lineAfter = model.log.topVisibleLine
            print("\(name)：滚动位置 \(Int(before)) → \(Int(moved)) → \(Int(clip.bounds.origin.y))，跟随=\(model.log.atBottom)，顶部内容不变=\(line == lineAfter)")
            check(moved < before, "\(name) 确实让视图上移")
            check(!model.log.atBottom, "\(name) 后不会被新数据拉回")
            // Home 停在最顶上，那里的内容本来就会先被裁掉
            if !name.hasPrefix("Home") {
                check(line == lineAfter, "\(name) 后正在看的内容留在原处")
            }
        }

        // 留在历史位置选中一段文字，日志继续增长、顶部被裁剪时选区内容不变
        model.log.jumpToEnd()
        await wait(0.4)
        _ = wheelEvent(1500).map { logScroll.scrollWheel(with: $0) }
        await wait(0.2)
        let storage = logText.string as NSString
        let selected = NSRange(location: storage.length * 3 / 4, length: 40)
        let selectedText = storage.substring(with: selected)
        logText.setSelectedRange(selected)
        let selectionStart = selected.location
        await wait(3)
        let current = (logText.string as NSString).substring(with: logText.selectedRange())
        print("选区：起点 \(selectionStart) → \(logText.selectedRange().location)，发生裁剪=\(logText.selectedRange().location != selectionStart)，文字相同=\(current == selectedText)，跟随=\(model.log.atBottom)")
        if current != selectedText { print("  选中时=\(selectedText.debugDescription) 现在=\(current.debugDescription)") }
        check(current == selectedText && !model.log.atBottom, "查看历史时选中的文字不受新数据和裁剪影响")
        logText.setSelectedRange(NSRange(location: 0, length: 0))

        // 走真实的拖选跟踪循环：按下后拖到日志上方，松手
        model.log.jumpToEnd()
        await wait(0.5)
        let dragBefore = clip.bounds.origin.y
        let dragStart = logText.convert(NSPoint(x: 160, y: clip.bounds.midY), to: nil)
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: logWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseUp ? 0 : 1)
        }
        let dragEnd = logText.convert(NSPoint(x: 160, y: clip.bounds.minY - 80), to: nil)
        for _ in 0..<8 { _ = mouse(.leftMouseDragged, dragEnd).map { NSApp.postEvent($0, atStart: false) } }
        _ = mouse(.leftMouseUp, dragEnd).map { NSApp.postEvent($0, atStart: false) }
        _ = mouse(.leftMouseDown, dragStart).map { logText.mouseDown(with: $0) }
        let dragMoved = clip.bounds.origin.y
        let dragSelection = logText.selectedRange().length
        let dragLine = model.log.topVisibleLine
        await wait(2)
        print("真实拖选：滚动位置 \(Int(dragBefore)) → \(Int(dragMoved)) → \(Int(clip.bounds.origin.y))，选中 \(dragSelection) 字符，跟随=\(model.log.atBottom)")
        check(dragSelection > 0, "拖选能选中文字")
        check(!model.log.atBottom && model.log.topVisibleLine == dragLine, "选中文字后留在原处，不被新数据带走")
        logText.setSelectedRange(NSRange(location: 0, length: 0))

        shot("16-jump-button-900x640")

        // 程序直接改滚动位置不代表用户操作，应继续跟随
        model.log.jumpToEnd()
        await wait(0.5)
        clip.scroll(to: NSPoint(x: 0, y: max(0, clip.bounds.origin.y - 800)))
        logScroll.reflectScrolledClipView(clip)
        await wait(0.5)
        let gap = logText.frame.height - clip.bounds.maxY
        check(model.log.atBottom && gap < 200, "程序改滚动位置不影响跟随，距底部 \(Int(gap))")

        model.log.jumpToEnd()
        await wait(0.5)
        check(model.log.atBottom, "点“回到最新”后恢复跟随")
        _ = key(NSHomeFunctionKey, code: 115).map { logText.keyDown(with: $0) }
        await wait(0.4)
        check(!model.log.atBottom, "再次按 Home 离开底部")
        _ = key(NSEndFunctionKey, code: 119).map { logText.keyDown(with: $0) }
        await wait(0.5)
        check(model.log.atBottom, "End 键回到底部后恢复跟随")
        shot("17-after-jump-900x640")
        model.demoSetFlood(0)
        logWindow.makeFirstResponder(nil)
        await wait(0.5)

        model.toggleLink()
        await wait(0.8)

        await ConnectionChecks.run(model, check)

        model.clearLog()
        await wait(0.2)
        check(model.log.isEmpty, "清屏后日志为空")

        print(failures == 0 ? "自检全部通过" : "自检有 \(failures) 项失败")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}
