import BaudCore
import Foundation
import SwiftUI

struct SendItem: Identifiable, Codable, Equatable {
    var id = UUID()
    /// 是否参与“依次发送”。没勾上的条目仍然可以单独点发送。
    var enabled = true
    var hex = false
    var text = ""
    var note = ""
    /// 发完这条后等多久再发下一条，单位毫秒。
    var delay = "1000"

    var isBlank: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }
    var delayMs: Int { max(Self.minDelay, Int(delay) ?? 1000) }

    static let minDelay = 10
}

/// 多条发送。单独放一个模型，循环发送时刷新进度不会让整个界面重算。
final class MultiSendModel: ObservableObject {
    @Published var items: [SendItem] {
        didSet {
            if failure != nil { failure = nil }
            if running { relocateCursor(from: oldValue) }
            if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: "multiSend") }
        }
    }
    @Published var loop: Bool { didSet { defaults.set(loop, forKey: "multiSendLoop") } }
    @Published private(set) var running = false
    @Published private(set) var currentID: UUID?
    @Published private(set) var round = 1
    @Published private(set) var failure: (id: UUID, problem: SendProblem)?

    /// 由 AppModel 提供：check 只检查不发送，send 真正发出去。都返回 nil 表示没问题。
    var check: (SendItem) -> SendProblem? = { _ in nil }
    var send: (SendItem) -> SendProblem? = { _ in .offline }
    var onStart: () -> Void = {}

    private let defaults: UserDefaults
    private var work: DispatchWorkItem?
    private var cursor = Cursor.beginning
    private var rounds = 1
    private var lastShown = Date.distantPast

    /// 依次发送走到了哪里。按 ID 记，发送途中排序、增删条目时不会错位。
    private enum Cursor {
        case beginning
        case after(UUID)
        case before(UUID)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        loop = defaults.bool(forKey: "multiSendLoop")
        if let data = defaults.data(forKey: "multiSend"), let saved = try? JSONDecoder().decode([SendItem].self, from: data) {
            items = saved
        } else {
            items = ["AT", "AT+GMR", "status"].map { SendItem(text: $0) }
        }
    }

    /// 会参与依次发送的条目。
    var queue: [SendItem] { items.filter { $0.enabled && !$0.isBlank } }

    var progress: (index: Int, total: Int)? {
        let list = queue
        guard running, let currentID, let index = list.firstIndex(where: { $0.id == currentID }) else { return nil }
        return (index + 1, list.count)
    }

    func add() -> UUID {
        let item = SendItem(delay: items.last?.delay ?? "1000")
        items.append(item)
        return item.id
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    /// 上移或下移一位，到头了就不动。
    func move(_ id: UUID, by offset: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }), items.indices.contains(index + offset) else { return }
        items.swapAt(index, index + offset)
    }

    /// 单独发一条，返回是否发出。
    @discardableResult
    func sendOne(_ item: SendItem) -> Bool {
        guard !item.isBlank else { return false }
        failure = nil
        if let problem = send(item) {
            if problem != .offline { failure = (item.id, problem) }
            return false
        }
        return true
    }

    func toggleRun() {
        if running { stop() } else { start() }
    }

    func start() {
        guard !running else { return }
        // 先把要发的都检查一遍，不要发到一半才发现后面有一条写错了
        let list = queue
        failure = nil
        for item in list {
            if let problem = check(item) {
                failure = (item.id, problem)
                return
            }
        }
        guard !list.isEmpty else { return }
        onStart()
        running = true
        cursor = .beginning
        rounds = 1
        round = 1
        lastShown = .distantPast
        tick()
    }

    func stop() {
        work?.cancel()
        work = nil
        guard running else { return }
        running = false
        currentID = nil
    }

    private func tick() {
        // 发送途中可以改列表，所以每一步都按当前的列表找下一条
        guard running, let (item, wrapped) = next(wrapping: loop) else {
            stop()
            return
        }
        if let problem = send(item) {
            stop()
            if problem != .offline { failure = (item.id, problem) }
            return
        }
        cursor = .after(item.id)
        if wrapped { rounds += 1 }

        // 间隔很短时高亮不必每条都刷新，眼睛也跟不上
        let now = Date()
        if now.timeIntervalSince(lastShown) > 0.06 {
            lastShown = now
            currentID = item.id
            if round != rounds { round = rounds }
        }

        guard loop || next(wrapping: false) != nil else {
            stop()
            return
        }
        let step = DispatchWorkItem { [weak self] in self?.tick() }
        work = step
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(item.delayMs), execute: step)
    }

    /// 只查看下一条，不改变任何状态。wrapped 表示这一条是回到开头开始新的一轮。
    private func next(wrapping: Bool) -> (item: SendItem, wrapped: Bool)? {
        let start: Int
        switch cursor {
        case .beginning:
            start = 0
        case let .after(id):
            start = items.firstIndex { $0.id == id }.map { $0 + 1 } ?? 0
        case let .before(id):
            start = items.firstIndex { $0.id == id } ?? 0
        }
        if let later = items[start...].first(where: { $0.enabled && !$0.isBlank }) { return (later, false) }
        guard wrapping, let first = queue.first else { return nil }
        return (first, true)
    }

    /// 游标指向的条目被删了：接着发它后面还在的那条；后面没有了就贴到前面还在的那条之后，这样新加到末尾的条目不会被漏掉。
    private func relocateCursor(from old: [SendItem]) {
        let id: UUID
        switch cursor {
        case .beginning: return
        case let .after(value), let .before(value): id = value
        }
        let alive = Set(items.map(\.id))
        guard !alive.contains(id), let index = old.firstIndex(where: { $0.id == id }) else { return }
        if let successor = old[(index + 1)...].first(where: { alive.contains($0.id) }) {
            cursor = .before(successor.id)
        } else if let predecessor = old[..<index].last(where: { alive.contains($0.id) }) {
            cursor = .after(predecessor.id)
        } else {
            cursor = .beginning
        }
    }
}
