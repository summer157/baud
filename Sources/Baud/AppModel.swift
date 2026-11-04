import AppKit
import BaudCore
import Combine
import Foundation
import UniformTypeIdentifiers

enum LinkState { case idle, connecting, connected, lost }

/// 变化频繁的统计数据单独放，避免每次刷新都让整个界面重算。
final class StatsModel: ObservableObject {
    @Published var rx = 0
    @Published var tx = 0
    @Published var rate = 0
    @Published var rxHot = false
    @Published var txHot = false

    private var rxOff: DispatchWorkItem?
    private var txOff: DispatchWorkItem?

    func addRx(_ count: Int) {
        rx += count
        flash(\.rxHot, cancelling: &rxOff)
    }

    func addTx(_ count: Int) {
        tx += count
        flash(\.txHot, cancelling: &txOff)
    }

    private func flash(_ key: ReferenceWritableKeyPath<StatsModel, Bool>, cancelling item: inout DispatchWorkItem?) {
        item?.cancel()
        if !self[keyPath: key] { self[keyPath: key] = true }
        let off = DispatchWorkItem { [weak self] in self?[keyPath: key] = false }
        item = off
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: off)
    }
}

final class AppModel: ObservableObject, @unchecked Sendable {
    static let shared = AppModel()

    let log = LogController()
    let stats = StatsModel()
    let mood = MoodModel()
    let multi: MultiSendModel

    /// 自检用单独的存储，跑完不会影响平时的设置。
    private static let selfTesting = ProcessInfo.processInfo.environment["BAUD_SELFTEST"] != nil
    private let defaults = selfTesting ? UserDefaults(suiteName: "local.summer.baud.selftest")! : UserDefaults.standard

    // MARK: 端口与连接

    @Published private(set) var ports: [PortInfo] = []
    @Published var selectedPort = "" {
        didSet {
            guard selectedPort != oldValue else { return }
            defaults.set(selectedPort, forKey: "port")
            if link == .connected || link == .lost {
                closeCurrent()
                connect()
            }
        }
    }
    @Published private(set) var link = LinkState.idle
    @Published private(set) var lastError: String?

    @Published var baudChoice = "115200" { didSet { saveConfig() } }
    @Published var customBaud = "250000" { didSet { saveConfig() } }
    @Published var dataBits = 8 { didSet { saveConfig() } }
    @Published var stopBits = 1 { didSet { saveConfig() } }
    @Published var parity = Parity.none { didSet { saveConfig() } }
    @Published var flow = FlowControl.none { didSet { saveConfig() } }
    @Published var encoding = TextEncodingChoice.utf8 {
        didSet {
            defaults.set(encoding.rawValue, forKey: "encoding")
            log.configure(encoding: encoding)
        }
    }

    // MARK: 显示

    @Published var viewMode = ViewMode.text {
        didSet {
            defaults.set(viewMode.rawValue, forKey: "view")
            log.configure(view: viewMode)
        }
    }
    @Published var showTime = true {
        didSet {
            defaults.set(showTime, forKey: "showTime")
            log.configure(showTime: showTime)
        }
    }
    @Published var query = "" {
        didSet {
            queryWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.log.configure(query: self.query)
            }
            queryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }
    @Published var focusMode = false { didSet { defaults.set(focusMode, forKey: "focus") } }
    @Published var appearance = AppearanceChoice.system {
        didSet {
            defaults.set(appearance.rawValue, forKey: "appearance")
            NSApplication.shared.appearance = appearance.nsAppearance
        }
    }
    @Published var advancedOpen = false
    @Published var multiOpen = false { didSet { defaults.set(multiOpen, forKey: "multiOpen") } }
    @Published private(set) var searchFocusTick = 0
    @Published private(set) var sidebarScrollTick = 0
    @Published private(set) var sendTick = 0
    @Published private(set) var flooding = false

    // MARK: 发送

    @Published var input = "" { didSet { if inputProblem != nil { inputProblem = nil } } }
    @Published var sendHex = false {
        didSet {
            defaults.set(sendHex, forKey: "sendHex")
            inputProblem = nil
        }
    }
    @Published var ending = LineEnding.crlf { didSet { defaults.set(ending.title, forKey: "ending") } }
    @Published var checksum = ChecksumSetting() {
        didSet {
            if let data = try? JSONEncoder().encode(checksum) { defaults.set(data, forKey: "checksum") }
            inputProblem = nil
        }
    }
    @Published private(set) var inputProblem: SendProblem?
    @Published private(set) var timerOn = false
    @Published var timerMs = "1000" {
        didSet {
            defaults.set(timerMs, forKey: "timerMs")
            if timerOn { startTimer() }
        }
    }
    @Published var quick: [String] = ["AT", "AT+GMR", "status", "reset"] {
        didSet { defaults.set(quick, forKey: "quick") }
    }

    private let scanner = PortScanner()
    private var port: SerialPort?
    private var demo: DemoDevice?
    private var demoPlugged = true
    private var generation = 0
    private var failCount = 0
    private var history: [String] = []
    private var historyIndex: Int?
    private var sendTimer: DispatchSourceTimer?
    private var queryWork: DispatchWorkItem?
    private var configWork: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var loading = true

    // 接收管线：在自己的队列上分行，定时批量交给主线程
    private let pipe = DispatchQueue(label: "baud.pipeline", qos: .userInitiated)
    private var pipeTimer: DispatchSourceTimer?
    private var assembler = LineAssembler()
    private var pipeLines: [LogEntry] = []
    private var pipeBytes = 0
    private var pipeLastData = Date.distantPast
    private var pipeInFlight = false

    private var secondTimer: Timer?
    private var lastRxTotal = 0
    private var lastRxAt = Date.distantPast
    private var connectedAt = Date.distantPast
    private var floodMood = false

    var config: SerialConfig {
        var c = SerialConfig()
        c.baud = (baudChoice == "custom" ? Int(customBaud) : Int(baudChoice)) ?? 115_200
        c.dataBits = dataBits
        c.stopBits = stopBits
        c.parity = parity
        c.flow = flow
        return c
    }

    var isDemoSelected: Bool { selectedPort == DemoDevice.portID }
    var isDemoConnected: Bool { isDemoSelected && link == .connected }
    var canPlugDemoBack: Bool { !demoPlugged }
    var inputError: Bool { inputProblem != nil }

    /// 输入框当前内容会带上的校验字节，内容不完整时没有。
    var checksumPreview: String? {
        guard checksum.isOn, !input.trimmingCharacters(in: .whitespaces).isEmpty,
              case let .success(frame) = makeFrame(input, hex: sendHex) else { return nil }
        return Codec.hexString(frame.trailer)
    }

    private init() {
        if Self.selfTesting { defaults.removePersistentDomain(forName: "local.summer.baud.selftest") }
        multi = MultiSendModel(defaults: defaults)
        loadSettings()
        loading = false
        log.configure(view: viewMode, showTime: showTime, encoding: encoding)

        multi.check = { [weak self] item in
            guard let self else { return .offline }
            if case let .failure(problem) = self.makeFrame(item.text, hex: item.hex) { return problem }
            return nil
        }
        multi.send = { [weak self] item in
            guard let self else { return .offline }
            return self.transmit(item.text, hex: item.hex)
        }
        multi.onStart = { [weak self] in
            guard let self else { return }
            // 和定时发送同时跑，两边的数据会穿插在一起
            self.stopTimer()
            Haptics.tick()
            self.sendTick += 1
            self.mood.flash(.send, for: 1.2)
        }

        scanner.onChange = { [weak self] found in self?.portsChanged(found) }
        scanner.start()
        startPipeline()

        secondTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.everySecond() }
        updateMood()
    }

    // MARK: 设置

    private func loadSettings() {
        let d = defaults
        if let v = d.string(forKey: "appearance"), let a = AppearanceChoice(rawValue: v) { appearance = a }
        if let v = d.string(forKey: "baud") { baudChoice = v }
        if let v = d.string(forKey: "customBaud") { customBaud = v }
        if d.object(forKey: "dataBits") != nil { dataBits = d.integer(forKey: "dataBits") }
        if d.object(forKey: "stopBits") != nil { stopBits = d.integer(forKey: "stopBits") }
        if let v = d.string(forKey: "parity"), let p = Parity(rawValue: v) { parity = p }
        if let v = d.string(forKey: "flow"), let f = FlowControl(rawValue: v) { flow = f }
        if let v = d.string(forKey: "encoding"), let e = TextEncodingChoice(rawValue: v) { encoding = e }
        if let v = d.string(forKey: "view"), let m = ViewMode(rawValue: v) { viewMode = m }
        if d.object(forKey: "showTime") != nil { showTime = d.bool(forKey: "showTime") }
        focusMode = d.bool(forKey: "focus")
        sendHex = d.bool(forKey: "sendHex")
        if let v = d.string(forKey: "ending"), let e = LineEnding.allCases.first(where: { $0.title == v }) { ending = e }
        if let v = d.string(forKey: "timerMs") { timerMs = v }
        if let v = d.stringArray(forKey: "quick") { quick = v }
        if let data = d.data(forKey: "checksum"), let v = try? JSONDecoder().decode(ChecksumSetting.self, from: data) { checksum = v }
        multiOpen = d.bool(forKey: "multiOpen")
        if let v = d.string(forKey: "port") { selectedPort = v }
    }

    private func saveConfig() {
        guard !loading else { return }
        let d = defaults
        d.set(baudChoice, forKey: "baud")
        d.set(customBaud, forKey: "customBaud")
        d.set(dataBits, forKey: "dataBits")
        d.set(stopBits, forKey: "stopBits")
        d.set(parity.rawValue, forKey: "parity")
        d.set(flow.rawValue, forKey: "flow")

        configWork?.cancel()
        guard link == .connected else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let port = self.port else { return }
            let config = self.config
            port.update(config: config) { [weak self] error in
                DispatchQueue.main.async {
                    if let error {
                        self?.note("无法应用新参数：\(error.localizedDescription)", severity: .error)
                    } else {
                        self?.note("已切换为 \(config.summary)")
                    }
                }
            }
        }
        configWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: 端口列表

    private func portsChanged(_ found: [PortInfo]) {
        var list = found
        if demoPlugged {
            let index = list.firstIndex { $0.kind == .system } ?? list.endIndex
            list.insert(DemoDevice.info, at: index)
        }
        let hadUSB = Set(ports.filter { $0.kind == .usb }.map(\.id))
        ports = list

        let selected = list.first { $0.id == selectedPort }
        let newUSB = list.first { $0.kind == .usb && !hadUSB.contains($0.id) }
        if link == .idle {
            if selected == nil || selected?.kind == .demo || selected?.kind == .system, let usb = newUSB {
                selectedPort = usb.id
            } else if selected == nil, let first = list.first {
                selectedPort = first.id
            }
        }

        switch link {
        case .connected where selected == nil:
            deviceLost()
        case .lost where selected != nil:
            scheduleReconnect(after: 0.4)
        default:
            break
        }
    }

    private func refreshPorts() {
        portsChanged(PortScanner.scan())
    }

    // MARK: 连接

    func toggleLink() {
        switch link {
        case .idle:
            Haptics.tick()
            connect()
        default:
            Haptics.tick()
            let wasConnected = link == .connected
            let name = selectedName
            generation += 1
            retryWork?.cancel()
            closeCurrent()
            link = .idle
            lastError = nil
            failCount = 0
            if !demoPlugged {
                demoPlugged = true
                refreshPorts()
            }
            if wasConnected { note("已断开 \(name)") }
            updateMood()
        }
    }

    var selectedName: String {
        if isDemoSelected { return DemoDevice.info.name }
        return ports.first { $0.id == selectedPort }?.name ?? URL(fileURLWithPath: selectedPort).lastPathComponent
    }

    private func connect(note: String? = nil) {
        guard !selectedPort.isEmpty else { return }
        generation += 1
        let token = generation
        let target = selectedPort
        let config = config
        let wasLost = link == .lost
        let started = Date()
        if !wasLost { link = .connecting }
        lastError = nil
        updateMood()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var device: DemoDevice?
            var path = target
            if target == DemoDevice.portID {
                device = DemoDevice()
                path = device?.path ?? "/dev/null"
            }
            let outcome = Result { try SerialPort(path: path, config: config) }
            // 留一点时间，让开关转圈的动画能被看见
            let delay = max(0, 0.42 - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let self, token == self.generation else {
                    if case let .success(port) = outcome { port.close() }
                    device?.stop()
                    return
                }
                switch outcome {
                case let .success(port):
                    self.didOpen(port, device: device, note: note)
                case let .failure(error):
                    device?.stop()
                    self.didFail(error, wasLost: wasLost)
                }
            }
        }
    }

    private func didOpen(_ opened: SerialPort, device: DemoDevice?, note text: String?) {
        port = opened
        demo = device
        failCount = 0
        lastError = nil
        connectedAt = Date()
        lastRxAt = .distantPast
        pipe.async { [self] in
            assembler = LineAssembler()
            pipeLines.removeAll()
            pipeBytes = 0
        }
        opened.onData = { [weak self] data in
            guard let self else { return }
            self.pipe.async { self.receive(data) }
        }
        opened.onDisconnect = { [weak self, weak opened] in
            DispatchQueue.main.async {
                guard let self, let opened, self.port === opened else { return }
                self.deviceLost()
            }
        }
        opened.start()
        device?.start()

        link = .connected
        note((text ?? "已连接") + " \(selectedName) · \(config.summary)")
        Haptics.bump()
        mood.flash(.link, for: 1.8)
    }

    private func didFail(_ error: Error, wasLost: Bool) {
        let message = error.localizedDescription
        if wasLost {
            scheduleReconnect(after: 1.5)
            return
        }
        link = .idle
        lastError = message
        failCount += 1
        note("连接 \(selectedName) 失败：\(message)", severity: .error)
        Haptics.bump()
        mood.flash(failCount >= 3 ? .failx : .fail, for: 3)
    }

    private func deviceLost() {
        let name = selectedName
        closeCurrent()
        link = .lost
        flooding = false
        note("设备意外断开 \(name)，插回后会自动重连", severity: .error)
        Haptics.bump()
        mood.flash(.unplug, for: 4)
        scheduleReconnect(after: 1)
    }

    private func scheduleReconnect(after delay: TimeInterval) {
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.link == .lost, self.ports.contains(where: { $0.id == self.selectedPort }) else { return }
            self.connect(note: "已自动重连")
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func closeCurrent() {
        stopTimer()
        multi.stop()
        port?.onData = nil
        port?.onDisconnect = nil
        port?.close()
        port = nil
        demo?.stop()
        demo = nil
        flooding = false
    }

    // MARK: 演示设备

    func demoUnplug() {
        guard isDemoConnected, let device = demo else { return }
        demoPlugged = false
        device.stop()
        demo = nil
        refreshPorts()
    }

    func demoPlugBack() {
        demoPlugged = true
        refreshPorts()
    }

    func demoToggleFlood() {
        demoSetFlood(flooding ? 0 : 800_000)
    }

    func demoSetFlood(_ bytesPerSecond: Int) {
        guard let device = demo else { return }
        flooding = bytesPerSecond > 0
        device.setFlood(bytesPerSecond: bytesPerSecond)
    }

    // MARK: 接收管线

    private func startPipeline() {
        let timer = DispatchSource.makeTimerSource(queue: pipe)
        timer.schedule(deadline: .now() + 0.033, repeating: 0.033, leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in self?.pipeTick() }
        timer.resume()
        pipeTimer = timer
    }

    private func receive(_ data: Data) {
        pipeBytes += data.count
        pipeLastData = Date()
        let now = pipeLastData
        for line in assembler.feed(data) {
            pipeLines.append(LogEntry(.rx, bytes: line, time: now))
        }
    }

    private func pipeTick() {
        if assembler.hasPartial, Date().timeIntervalSince(pipeLastData) > 0.1, let rest = assembler.flush() {
            pipeLines.append(LogEntry(.rx, bytes: rest))
        }
        guard !pipeInFlight, pipeBytes > 0 || !pipeLines.isEmpty else { return }
        let lines = pipeLines
        let bytes = pipeBytes
        pipeLines.removeAll(keepingCapacity: true)
        pipeBytes = 0
        pipeInFlight = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if bytes > 0 {
                self.stats.addRx(bytes)
                self.lastRxAt = Date()
            }
            self.log.append(lines)
            self.pipe.async { self.pipeInFlight = false }
        }
    }

    // MARK: 发送

    func submit() {
        let text = input
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard transmitInput() else { return }
        if history.last != text { history.append(text) }
        historyIndex = nil
        if !timerOn { input = "" }
        sendTick += 1
        mood.flash(.send, for: 1.2)
    }

    func sendQuick(_ command: String) {
        if let problem = transmit(command, hex: false) {
            if problem != .offline { note("没有发送 \(command)：\(problem.message)", severity: .error) }
            return
        }
        sendTick += 1
        mood.flash(.send, for: 1.2)
    }

    func sendRow(_ item: SendItem) {
        if multi.sendOne(item) {
            sendTick += 1
            mood.flash(.send, for: 1.2)
        } else if multi.failure != nil {
            Haptics.tick()
            mood.flash(.hex, for: 2)
        }
    }

    private func makeFrame(_ text: String, hex: Bool) -> Result<OutgoingFrame, SendProblem> {
        Codec.frame(text, hex: hex, encoding: encoding, ending: ending, checksum: checksum)
    }

    /// 发出一帧。返回 nil 表示已发出，否则是没能发出的原因。
    private func transmit(_ text: String, hex: Bool) -> SendProblem? {
        guard link == .connected, let port else { return .offline }
        switch makeFrame(text, hex: hex) {
        case let .failure(problem):
            return problem
        case let .success(frame):
            let data = frame.bytes
            port.write(data)
            stats.addTx(data.count)
            log.append([LogEntry(.tx, bytes: data, trailer: frame.trailerRange)])
            return nil
        }
    }

    private func transmitInput() -> Bool {
        guard let problem = transmit(input, hex: sendHex) else { return true }
        if problem != .offline {
            inputProblem = problem
            Haptics.tick()
            mood.flash(.hex, for: 2)
        }
        return false
    }

    func historyUp() {
        guard !history.isEmpty else { return }
        let index = historyIndex.map { max(0, $0 - 1) } ?? history.count - 1
        historyIndex = index
        input = history[index]
    }

    func historyDown() {
        guard let index = historyIndex else { return }
        if index + 1 < history.count {
            historyIndex = index + 1
            input = history[index + 1]
        } else {
            historyIndex = nil
            input = ""
        }
    }

    func toggleTimer() {
        if timerOn {
            stopTimer()
            return
        }
        multi.stop()
        guard transmitInput() else { return }
        timerOn = true
        startTimer()
    }

    private func startTimer() {
        sendTimer?.cancel()
        let ms = max(10, Int(timerMs) ?? 1000)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(ms), repeating: .milliseconds(ms))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if !self.transmitInput() { self.stopTimer() }
        }
        timer.resume()
        sendTimer = timer
    }

    private func stopTimer() {
        sendTimer?.cancel()
        sendTimer = nil
        if timerOn { timerOn = false }
    }

    func addQuickFromInput() {
        let command = input.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty, !quick.contains(command) else { return }
        quick.append(command)
    }

    func removeQuick(_ command: String) {
        quick.removeAll { $0 == command }
    }

    // MARK: 工具栏动作

    func note(_ text: String, severity: LogEntry.Severity = .info) {
        log.append([LogEntry(note: text, severity: severity)])
    }

    func scrollSidebarToEnd() {
        sidebarScrollTick += 1
    }

    func togglePause() {
        log.setPaused(!log.paused)
    }

    func clearLog() {
        log.clear()
        stats.rx = 0
        stats.tx = 0
        lastRxTotal = 0
    }

    func focusSearch() {
        searchFocusTick += 1
    }

    func saveLog() {
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "Baud-\(formatter.string(from: Date())).log"
        panel.allowedContentTypes = [.plainText, .log]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try log.exportText().write(to: url, atomically: true, encoding: .utf8)
            note("日志已保存到 \(url.path)")
        } catch {
            note("保存失败：\(error.localizedDescription)", severity: .error)
        }
    }

    // MARK: 心情

    private func everySecond() {
        let total = stats.rx
        let rate = max(0, total - lastRxTotal)
        lastRxTotal = total
        if stats.rate != rate { stats.rate = rate }
        updateMood()
    }

    private func updateMood() {
        switch link {
        case .idle:
            mood.setAmbient(.peek)
        case .connecting:
            mood.setAmbient(.wait)
        case .lost:
            mood.setAmbient(.unplug)
        case .connected:
            let quiet = Date().timeIntervalSince(max(lastRxAt, connectedAt))
            // 进入和退出用不同的阈值，速率在边界附近时表情不会来回跳
            floodMood = stats.rate > (floodMood ? 20_000 : 30_000)
            if floodMood {
                mood.setAmbient(.flood)
            } else if quiet < 2 {
                mood.setAmbient(.read)
            } else if quiet < 20 {
                mood.setAmbient(.cool)
            } else if quiet < 180 {
                mood.setAmbient(.wait)
            } else {
                mood.setAmbient(.doze)
            }
        }
    }
}

extension UTType {
    fileprivate static let log = UTType(filenameExtension: "log") ?? .plainText
}
