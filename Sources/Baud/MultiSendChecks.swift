import Foundation

/// 依次发送途中改列表时的发送顺序。只用模型和假的发送函数，不需要窗口和设备，由自检调用。
@MainActor
enum MultiSendChecks {
    private static let suite = "local.summer.baud.multisendchecks"

    static func run(_ check: (Bool, String) -> Void) async {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        // 不循环：结束后核对完整的发送序列
        func sequence(_ name: String, _ rows: [String], expect: [String], change: (Run) async -> Void) async {
            let run = Run(rows)
            run.model.start()
            await change(run)
            await run.waitUntilStopped()
            check(run.sent == expect && !run.model.running, "\(name)：\(run.sent.joined(separator: " "))")
        }

        await sequence("普通顺序", ["A", "B", "C"], expect: ["A", "B", "C"]) { _ in }
        await sequence("发完最后一条立刻停", ["A"], expect: ["A"]) { run in
            check(!run.model.running, "只有一条时发完不再等待")
        }
        await sequence("删掉当前条目，接着发它的后继", ["A", "B", "C"], expect: ["A", "B", "C"]) { run in
            run.remove("A")
        }
        await sequence("先删更早的再删当前条目", ["A", "B", "C", "D"], expect: ["A", "B", "C", "D"]) { run in
            await run.waitFor(3)
            run.remove("A")
            run.remove("C")
        }
        await sequence("连续删当前条目和它的后继", ["A", "B", "C"], expect: ["A", "C"]) { run in
            run.remove("A")
            run.remove("B")
        }
        await sequence("一次赋值删掉当前条目和后继", ["A", "B", "C", "D"], expect: ["A", "C", "D"]) { run in
            run.model.items.removeAll { ["A", "B"].contains($0.text) }
        }
        await sequence("后继被移走后，游标跟着后继", ["A", "B", "C", "D"], expect: ["A", "B", "C"]) { run in
            run.remove("A")
            run.model.move(from: IndexSet(integer: 2), to: 0)
        }
        await sequence("排序后再删当前条目", ["A", "B", "C", "D"], expect: ["A", "C", "B", "D"]) { run in
            run.model.move(from: IndexSet(integer: 2), to: 1)
            run.remove("A")
        }
        await sequence("删掉当前条目后，末尾新加的会发", ["A", "B", "C"], expect: ["A", "B", "D"]) { run in
            await run.waitFor(2)
            run.remove("B")
            run.remove("C")
            run.model.items.append(SendItem(text: "D", delay: Run.delay))
        }
        await sequence("全部删光后加一条，从新条目继续", ["A", "B"], expect: ["A", "C"]) { run in
            run.remove("A")
            run.remove("B")
            run.model.items.append(SendItem(text: "C", delay: Run.delay))
        }
        await sequence("删光后正常停止", ["A", "B"], expect: ["A"]) { run in
            run.model.items = []
        }
        await sequence("整表换成新条目，从新列表第一条继续", ["A", "B"], expect: ["A", "X", "Y"]) { run in
            run.model.items = ["X", "Y"].map { SendItem(text: $0, delay: Run.delay) }
        }
        await sequence("取消勾选待发的条目", ["A", "B", "C"], expect: ["A", "C"]) { run in
            run.model.items[1].enabled = false
        }
        await sequence("在当前条目后面插入", ["A", "C"], expect: ["A", "B", "C"]) { run in
            run.model.items.insert(SendItem(text: "B", delay: Run.delay), at: 1)
        }
        await sequence("发送前改内容，发的是新内容", ["A", "B"], expect: ["A", "B2"]) { run in
            run.model.items[1].text = "B2"
        }

        // 循环：查看下一条不能推进轮数，每回到开头只加一轮
        let plain = Run(["A", "B"], loop: true)
        plain.model.start()
        await plain.waitFor(2)
        check(plain.model.round == 1, "循环第一轮发完两条时还是第 1 轮，现在 \(plain.model.round)")
        await plain.waitFor(3)
        check(plain.model.round == 2, "回到开头时变成第 2 轮，现在 \(plain.model.round)")
        await plain.waitFor(5)
        check(plain.model.round == 3, "再回到开头时变成第 3 轮，现在 \(plain.model.round)")
        plain.model.stop()
        check(plain.sent == ["A", "B", "A", "B", "A"], "循环按顺序发送：\(plain.sent.joined(separator: " "))")

        let single = Run(["A"], loop: true)
        single.model.start()
        await single.waitFor(3)
        check(single.model.round == 3, "只有一条时每发一次算一轮，发了 3 次是第 \(single.model.round) 轮")
        single.model.stop()

        let tail = Run(["A", "B", "C"], loop: true)
        tail.model.start()
        await tail.waitFor(3)
        tail.remove("C")
        await tail.waitFor(4)
        check(tail.model.round == 2, "循环时删掉最后一条，回到开头只加一轮，现在第 \(tail.model.round) 轮")
        await tail.waitFor(5)
        check(tail.model.round == 2, "同一轮里继续发时轮数不变，现在第 \(tail.model.round) 轮")
        await tail.waitFor(6)
        tail.model.stop()
        check(tail.sent == ["A", "B", "C", "A", "B", "A"], "循环时删掉最后一条的序列：\(tail.sent.joined(separator: " "))")

        let first = Run(["A", "B", "C"], loop: true)
        first.model.start()
        first.remove("A")
        await first.waitFor(4)
        first.model.stop()
        check(first.sent == ["A", "B", "C", "B"] && first.model.round == 2, "循环时删掉第一条的序列：\(first.sent.joined(separator: " "))")

        // 停止后不再发送
        let stopped = Run(["A", "B"])
        stopped.model.start()
        stopped.model.stop()
        stopped.remove("A")
        try? await Task.sleep(nanoseconds: 200_000_000)
        check(stopped.sent == ["A"], "停止后不再发送，也不受之后改列表影响")
    }

    @MainActor
    private final class Run {
        /// 比高亮刷新的节流（60 ms）长，每一步的轮数都能读到。
        static let delay = "70"

        let model: MultiSendModel
        var sent: [String] = []

        init(_ rows: [String], loop: Bool = false) {
            model = MultiSendModel(defaults: UserDefaults(suiteName: MultiSendChecks.suite)!)
            model.loop = loop
            model.items = rows.map { SendItem(text: $0, delay: Self.delay) }
            model.send = { [weak self] item in
                self?.sent.append(item.text)
                return nil
            }
        }

        func remove(_ text: String) {
            model.items.removeAll { $0.text == text }
        }

        func waitFor(_ count: Int) async {
            for _ in 0..<1500 where sent.count < count {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        func waitUntilStopped() async {
            for _ in 0..<1500 where model.running {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
    }
}
