import BaudCore
import Foundation

/// 连接过程中的竞争。核对的是虚拟设备真正收到的字节和真正生效的参数，不只看界面状态。由自检调用。
@MainActor
enum ConnectionChecks {
    private static func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func waitFor(_ timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            await wait(0.02)
        }
        return condition()
    }

    static func run(_ model: AppModel, _ check: (Bool, String) -> Void) async {
        if model.link != .idle { model.toggleLink() }
        await wait(0.2)
        model.sendHex = false
        model.ending = .none
        model.checksum = ChecksumSetting()
        model.dataBits = 8

        func port() -> VirtualPort {
            guard let port = VirtualPort() else { fatalError("无法创建虚拟串口") }
            return port
        }
        func send(_ text: String) {
            model.input = text
            model.submit()
        }
        func disconnect() async {
            if model.link != .idle { model.toggleLink() }
            await wait(0.15)
        }
        func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
        func collected(_ device: VirtualPort, into buffer: inout Data, want: Int) async {
            let end = Date().addingTimeInterval(2)
            while buffer.count < want, Date() < end {
                buffer.append(device.receive())
                await wait(0.02)
            }
        }
        func receivedText(_ device: VirtualPort, expecting expected: String) async -> String {
            var buffer = Data()
            await collected(device, into: &buffer, want: expected.utf8.count)
            return text(buffer)
        }
        func rows(since start: Int) -> [String] {
            model.log.allEntries.dropFirst(start).filter { $0.direction == .rx }.map { text($0.bytes) }
        }
        func noted(_ needle: String, since start: Int) -> Bool {
            model.log.allEntries.dropFirst(start).contains { $0.direction == .sys && $0.note.contains(needle) }
        }

        // 打开后很快就发数据的设备：动画结束之前的内容不能丢
        do {
            let device = port()
            let start = model.log.allEntries.count
            let rxBefore = model.stats.rx
            model.selectedPort = device.path
            model.toggleLink()
            await wait(0.1)
            check(model.link == .connecting, "连接动画还没结束")
            device.send("boot: early\r\n")
            await wait(0.1)
            check(model.link == .connecting, "数据到达时动画还没结束")
            check(await waitFor { model.link == .connected }, "会马上说话的设备能连接")
            device.send("later\r\n")
            check(await waitFor { rows(since: start).joined() == "boot: early\r\nlater\r\n" },
                  "动画期间和之后的内容都在日志里，顺序不变：\(rows(since: start))")
            check(await waitFor { model.stats.rx - rxBefore == 20 }, "接收统计包含动画期间的字节：\(model.stats.rx - rxBefore)")
            send("ping")
            check(await receivedText(device, expecting: "ping") == "ping", "设备收到了发送的内容")
            await disconnect()
        }

        // 动画期间断线：不能假装已连接
        do {
            let device = port()
            let start = model.log.allEntries.count
            model.selectedPort = device.path
            model.toggleLink()
            await wait(0.1)
            device.unplug()
            check(await waitFor { model.link == .lost }, "动画期间断线会进入等待：\(model.link)")
            await wait(0.6)
            check(model.link == .lost, "之后也不会变成已连接")
            check(noted("设备意外断开", since: start), "日志提示设备断开")
            await disconnect()
            check(model.link == .idle, "可以停止等待")
        }

        // 同一端口连续连接、取消、再连接
        do {
            let device = port()
            model.selectedPort = device.path
            model.toggleLink()
            model.toggleLink()
            model.toggleLink()
            check(await waitFor { model.link == .connected } && model.lastError == nil, "连点三下后是已连接，错误：\(model.lastError ?? "无")")
            await wait(0.6)
            check(model.link == .connected, "迟到的回调没有关掉它")
            send("after-triple")
            check(await receivedText(device, expecting: "after-triple") == "after-triple", "连点后设备真的收到了数据")
            await disconnect()

            model.toggleLink()
            await wait(0.1)
            model.toggleLink()
            await wait(0.05)
            model.toggleLink()
            check(await waitFor { model.link == .connected } && model.lastError == nil, "打开后取消再连接同一端口成功")
            await wait(0.6)
            send("after-reopen")
            check(await receivedText(device, expecting: "after-reopen") == "after-reopen", "重新连接后设备真的收到了数据")
            await disconnect()
            check(await waitFor { device.isReleasedByApp }, "断开后串口真的关掉了")
        }

        // 慢的连接被取消后换端口：旧的打开晚完成，不能覆盖新连接
        do {
            let slow = port(), fresh = port()
            model.selectedPort = slow.path
            model.slowOpenForSelfTest = 0.6
            model.toggleLink()
            await wait(0.1)
            model.toggleLink()
            model.slowOpenForSelfTest = 0
            model.selectedPort = fresh.path
            model.toggleLink()
            check(await waitFor { model.link == .connected }, "取消慢连接后换端口能连接")
            await wait(1)
            check(model.link == .connected && model.selectedPort == fresh.path, "旧的打开结束后仍是新连接")
            send("to-fresh")
            check(await receivedText(fresh, expecting: "to-fresh") == "to-fresh", "数据发到了新端口")
            check(slow.receive().isEmpty, "晚完成的旧端口没有收到数据")
            check(slow.isReleasedByApp, "晚完成的旧端口被关掉了")
            await disconnect()
        }

        // 连接中切换端口：实际连上的要和界面一致
        do {
            let first = port(), second = port()
            let start = model.log.allEntries.count
            model.selectedPort = first.path
            model.slowOpenForSelfTest = 0.4
            model.toggleLink()
            await wait(0.1)
            model.slowOpenForSelfTest = 0
            model.selectedPort = second.path
            check(await waitFor { model.link == .connected }, "连接中切换端口后能连接")
            await wait(0.6)
            send("switched")
            check(await receivedText(second, expecting: "switched") == "switched", "数据发到了切换后的端口")
            check(first.receive().isEmpty, "切换前的端口没有收到数据")
            check(first.isReleasedByApp, "切换前的端口被关掉了")
            let connected = model.log.allEntries.dropFirst(start).filter { $0.direction == .sys && $0.note.hasPrefix("已连接") }
            check(connected.count == 1, "只提示一次已连接，共 \(connected.count) 次")
            await disconnect()
        }

        // 还在打开时改参数：打开后要真的生效
        do {
            let device = port()
            model.selectedPort = device.path
            model.slowOpenForSelfTest = 0.5
            model.toggleLink()
            await wait(0.1)
            model.slowOpenForSelfTest = 0
            model.dataBits = 7
            check(await waitFor { model.link == .connected }, "打开途中改参数后能连接")
            check(await waitFor { device.dataBits == 7 }, "打开途中改的数据位在串口上生效了：\(device.dataBits ?? -1)")
            await disconnect()
            model.dataBits = 8
        }

        // 打开之后、动画结束之前改参数
        do {
            let device = port()
            model.selectedPort = device.path
            model.toggleLink()
            await wait(0.15)
            check(model.link == .connecting, "动画还没结束")
            model.dataBits = 6
            check(await waitFor { device.dataBits == 6 }, "动画期间改的数据位在串口上生效了：\(device.dataBits ?? -1)")
            await disconnect()
            model.dataBits = 8
        }

        // 取消后，迟到的成功或失败都不能改变状态
        do {
            let device = port()
            let start = model.log.allEntries.count
            model.selectedPort = device.path
            model.slowOpenForSelfTest = 0.5
            model.toggleLink()
            await wait(0.1)
            model.toggleLink()
            model.slowOpenForSelfTest = 0
            await wait(1)
            check(model.link == .idle && model.lastError == nil, "取消后迟到的打开成功不改变状态")
            check(!noted("已连接", since: start), "取消后没有提示已连接")
            check(device.isReleasedByApp, "迟到打开的串口被关掉了")

            model.selectedPort = "/dev/cu.baud-does-not-exist"
            model.slowOpenForSelfTest = 0.4
            model.toggleLink()
            await wait(0.1)
            model.toggleLink()
            model.slowOpenForSelfTest = 0
            await wait(0.8)
            check(model.link == .idle && model.lastError == nil, "取消后迟到的打开失败不显示错误")
            model.toggleLink()
            check(await waitFor { model.lastError != nil } && model.link == .idle, "没有取消时打开失败仍会提示：\(model.lastError ?? "无")")
        }

        // 换端口时上一个连接的半行不能接到新连接的内容前面
        do {
            let first = port(), second = port()
            let start = model.log.allEntries.count
            model.selectedPort = first.path
            model.toggleLink()
            check(await waitFor { model.link == .connected }, "半行测试连接成功")
            first.send("half")
            await wait(0.03)
            model.selectedPort = second.path
            check(await waitFor { model.link == .connected }, "半行测试换端口成功")
            second.send("new\r\n")
            check(await waitFor { rows(since: start).count >= 2 }, "收到两行")
            check(rows(since: start) == ["half", "new\r\n"], "半行没有和新连接的内容接在一起：\(rows(since: start))")
            await disconnect()
        }

        // 串口队列已经拿到旧回调，连接关掉之后它才运行：字节不能进日志，也不能拼到新连接的半行上
        do {
            let device = port()
            let start = model.log.allEntries.count
            let rxBefore = model.stats.rx
            model.selectedPort = device.path
            model.toggleLink()
            check(await waitFor { model.link == .connected }, "旧回调测试连接成功")
            let stale = model.receiveCallbackForSelfTest
            check(stale != nil, "取到了连接的接收回调")
            await disconnect()

            stale?(Data("STALE-WHILE-IDLE\r\n".utf8))
            await wait(0.15)
            check(rows(since: start).isEmpty, "断开后旧回调的字节不进日志：\(rows(since: start))")

            model.toggleLink()
            await wait(0.1)
            stale?(Data("STALE-WHILE-OPENING\r\n".utf8))
            check(await waitFor { model.link == .connected }, "旧回调测试重连成功")
            // 三次调用按顺序排进 pipe 队列，中间不等待：半行超过 100 毫秒会先显示出来，这里不能依赖时间
            guard let current = model.receiveCallbackForSelfTest else {
                check(false, "取到了新连接的接收回调")
                return
            }
            current(Data("new-".utf8))
            stale?(Data("STALE-MID-LINE".utf8))
            current(Data("line\r\n".utf8))
            check(await waitFor { !rows(since: start).isEmpty }, "新连接的一行到了")
            check(rows(since: start) == ["new-line\r\n"], "旧回调没有混进新连接的半行：\(rows(since: start))")
            check(await waitFor { model.stats.rx - rxBefore == 10 }, "接收统计只算新连接：\(model.stats.rx - rxBefore)")

            device.send("real\r\n")
            check(await waitFor { rows(since: start).last == "real\r\n" }, "新连接的真实串口数据正常到达")
            await disconnect()
        }

        model.selectedPort = DemoDevice.portID
        model.ending = .crlf
        model.input = ""
    }
}
