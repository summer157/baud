import AppKit
import BaudCore
import Combine

struct LogEntry {
    enum Direction { case rx, tx, sys }
    /// 系统事件的轻重：主动断开这类正常操作是 info，意外掉线和失败才是 error。
    enum Severity { case info, error }

    let direction: Direction
    let time: Date
    let bytes: Data
    let note: String
    let severity: Severity
    /// 校验字节在 bytes 里的位置。校验值多半不是可显示的文字，文本视图里要单独写出来。
    let trailer: Range<Int>?

    init(_ direction: Direction, bytes: Data, time: Date = Date(), trailer: Range<Int>? = nil) {
        self.direction = direction
        self.time = time
        self.bytes = bytes
        self.trailer = trailer
        note = ""
        severity = .info
    }

    init(note: String, severity: Severity = .info) {
        direction = .sys
        time = Date()
        bytes = Data()
        self.note = note
        self.severity = severity
        trailer = nil
    }
}

enum ViewMode: String { case text, hex }

/// 用户正在操作日志视图的范围：键盘、鼠标（含拖选的跟踪循环）、滚轮、自动滚动和滚动条拖动。
private final class LogNavigationScope {
    private var depth = 0
    var liveScrolling = false { didSet { leftBottom = false } }
    /// 这次操作已经离开过底部。TextKit 可能在同一次操作里再挪一下视图，不能因此又恢复跟随。
    var leftBottom = false
    var onTextSelected: (() -> Void)?

    var isActive: Bool { depth > 0 || liveScrolling }

    func during(_ body: () -> Void) {
        if depth == 0 { leftBottom = false }
        depth += 1
        defer { depth -= 1 }
        body()
    }
}

private final class LogNSTextView: NSTextView {
    var navigation: LogNavigationScope?

    override func keyDown(with event: NSEvent) {
        scoped { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        scoped { super.mouseDown(with: event) }
        // 选中文字多半是要复制，留在这里，不被新数据带走
        if selectedRange().length > 0 { navigation?.onTextSelected?() }
    }

    override func autoscroll(with event: NSEvent) -> Bool {
        var moved = false
        scoped { moved = super.autoscroll(with: event) }
        return moved
    }

    private func scoped(_ body: () -> Void) {
        if let navigation { navigation.during(body) } else { body() }
    }
}

private final class LogNSScrollView: NSScrollView {
    var navigation: LogNavigationScope?

    /// 小幅滚动的位移可能在事件返回后才动画执行，所以直接按滚轮方向判断意图，不等位置变化。
    var onWheel: ((_ up: Bool) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaY != 0 { onWheel?(event.scrollingDeltaY > 0) }
        if let navigation {
            navigation.during { super.scrollWheel(with: event) }
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// 日志区。保存全部记录，屏幕上只保留最近一部分，并按批次追加，高速收数据时也不拖慢界面。
final class LogController: NSObject, ObservableObject {
    @Published private(set) var atBottom = true
    @Published private(set) var isEmpty = true
    @Published private(set) var pending = 0
    @Published private(set) var shownCount = 0
    @Published private(set) var paused = false

    let scrollView: NSScrollView
    private let textView: NSTextView

    private static let maxStored = 200_000
    private static let maxShown = 20_000
    private static let trimStep = 2_000
    /// 单次刷新最多追加的行数，超出的部分仍会保存，只是不逐行显示。
    private static let maxPerFlush = 1_500

    private var entries: [LogEntry] = []
    private var pauseIndex = 0
    private var lineLengths: [Int] = []
    private var programmaticDepth = 0
    private var lastClip = NSRect.zero
    private var followScheduled = false
    private let navigation = LogNavigationScope()

    private var view = ViewMode.text
    private var showTime = true
    private var query = ""
    private var encoding = TextEncodingChoice.utf8

    private let perfLogging = ProcessInfo.processInfo.environment["BAUD_PERF"] != nil
    private var cachedSecond = -1
    private var cachedPrefix = ""
    private let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 19
        style.maximumLineHeight = 19
        style.lineBreakMode = .byCharWrapping
        return style
    }()
    private let systemParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 19
        style.maximumLineHeight = 19
        style.lineBreakMode = .byCharWrapping
        style.paragraphSpacingBefore = 5
        style.paragraphSpacing = 5
        return style
    }()
    private let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    private let systemFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)

    override init() {
        // 明确使用 TextKit 1：可以开启非连续布局，几万行也能流畅滚动
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        layout.backgroundLayoutEnabled = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let logTextView = LogNSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        logTextView.navigation = navigation
        textView = logTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.usesFindBar = false
        textView.selectedTextAttributes = [.backgroundColor: Palette.selectionNS]

        let logScrollView = LogNSScrollView()
        logScrollView.navigation = navigation
        scrollView = logScrollView
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed

        super.init()

        navigation.onTextSelected = { [weak self] in
            if self?.atBottom == true { self?.atBottom = false }
        }
        logScrollView.onWheel = { [weak self] up in
            guard let self else { return }
            let clip = self.scrollView.contentView.bounds
            let distance = (self.scrollView.documentView?.frame.height ?? 0) - clip.maxY
            if up {
                // 内容不足一屏时没有地方可翻，不算离开
                if self.atBottom, clip.origin.y > 0 { self.atBottom = false }
            } else if distance < 30, !self.atBottom {
                self.atBottom = true
            }
        }

        let center = NotificationCenter.default
        scrollView.contentView.postsBoundsChangedNotifications = true
        center.addObserver(self, selector: #selector(boundsChanged),
                           name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        scrollView.contentView.postsFrameChangedNotifications = true
        center.addObserver(self, selector: #selector(viewportResized),
                           name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        center.addObserver(self, selector: #selector(liveScrollStarted),
                           name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        center.addObserver(self, selector: #selector(liveScrollEnded),
                           name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
    }

    var allEntries: [LogEntry] { entries }

    // MARK: 追加

    func append(_ new: [LogEntry]) {
        guard !new.isEmpty else { return }
        entries.append(contentsOf: new)
        if entries.count > Self.maxStored + Self.trimStep * 10 {
            let drop = entries.count - Self.maxStored
            entries.removeFirst(drop)
            pauseIndex = max(0, pauseIndex - drop)
        }
        if paused {
            pending = entries.count - pauseIndex
            return
        }
        render(new)
    }

    private func render(_ list: [LogEntry]) {
        let started = perfLogging ? CFAbsoluteTimeGetCurrent() : 0
        var visible = list
        if !query.isEmpty { visible = visible.filter { body(of: $0).range(of: query, options: .caseInsensitive) != nil } }
        var skipped = 0
        if visible.count > Self.maxPerFlush {
            skipped = visible.count - Self.maxPerFlush
            visible = Array(visible.suffix(Self.maxPerFlush))
        }
        if skipped > 0 { visible.insert(LogEntry(note: "数据太快，这里略过 \(skipped) 行显示，保存日志时仍会包含"), at: 0) }
        guard !visible.isEmpty else { return }

        let (text, lengths) = build(visible)
        programmatic {
            let storage = textView.textStorage!
            var trimmed = 0
            let selection = textView.selectedRange()
            let anchor = atBottom ? nil : topAnchor()
            storage.beginEditing()
            storage.append(text)
            lineLengths.append(contentsOf: lengths)
            if lineLengths.count > Self.maxShown + Self.trimStep {
                let removal = lineLengths.count - Self.maxShown
                trimmed = lineLengths.prefix(removal).reduce(0, +)
                lineLengths.removeFirst(removal)
                storage.deleteCharacters(in: NSRange(location: 0, length: trimmed))
            }
            storage.endEditing()
            if trimmed > 0 {
                // 顶部被裁掉后，让正在看的内容和选中的文字留在原处
                if selection.length > 0 {
                    let start = max(0, selection.location - trimmed)
                    let end = max(start, selection.location + selection.length - trimmed)
                    textView.setSelectedRange(NSRange(location: start, length: end - start))
                }
                if let anchor { restore(anchor, trimmed: trimmed) }
            }
            // 按住鼠标（可能正在拖选）时先不滚，松手后的下一批再跟上
            if atBottom, NSEvent.pressedMouseButtons & 1 == 0 { textView.scrollToEndOfDocument(nil) }
        }

        updateCounts()
        if perfLogging {
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            FileHandle.standardError.write(Data(String(format: "flush lines=%d shown=%d ms=%.2f\n", list.count, lineLengths.count, ms).utf8))
        }
    }

    /// 选项改变后，从保存的记录重新生成屏幕内容。
    private func rebuild() {
        let limit = paused ? pauseIndex : entries.count
        var picked: [LogEntry] = []
        var index = limit - 1
        while index >= 0, picked.count < Self.maxShown {
            let entry = entries[index]
            if query.isEmpty || body(of: entry).range(of: query, options: .caseInsensitive) != nil { picked.append(entry) }
            index -= 1
        }
        picked.reverse()
        let (text, lengths) = build(picked)
        programmatic {
            textView.textStorage!.setAttributedString(text)
            lineLengths = lengths
            if atBottom { textView.scrollToEndOfDocument(nil) }
        }
        updateCounts()
    }

    /// 当前视图顶部那一行的字符位置，以及视图相对这一行顶端的偏移。
    private func topAnchor() -> (character: Int, offset: CGFloat)? {
        guard let layout = textView.layoutManager, let container = textView.textContainer,
              layout.numberOfGlyphs > 0 else { return nil }
        var rect = scrollView.contentView.bounds
        rect.origin.y -= textView.textContainerOrigin.y
        rect.size.height = 1
        let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
        guard glyphs.location < layout.numberOfGlyphs else { return nil }
        let line = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        return (layout.characterIndexForGlyph(at: glyphs.location), rect.minY - line.minY)
    }

    private func restore(_ anchor: (character: Int, offset: CGFloat), trimmed: Int) {
        guard let layout = textView.layoutManager, textView.textStorage!.length > 0 else { return }
        let stillThere = anchor.character >= trimmed
        let character = stillThere ? anchor.character - trimmed : 0
        layout.ensureLayout(forCharacterRange: NSRange(location: character, length: 1))
        let glyph = layout.glyphIndexForCharacter(at: character)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let y = line.minY + textView.textContainerOrigin.y + (stillThere ? anchor.offset : 0)
        let clip = scrollView.contentView
        clip.setBoundsOrigin(NSPoint(x: 0, y: max(0, y)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// 视图顶部那一行的文字，自检用来确认内容没有被带走。
    var topVisibleLine: String {
        guard let anchor = topAnchor() else { return "" }
        let text = textView.string as NSString
        return text.substring(with: text.lineRange(for: NSRange(location: anchor.character, length: 0)))
    }

    /// 标记这段是程序自己在改内容或滚动位置，不代表用户想离开底部。
    private func programmatic(_ body: () -> Void) {
        programmaticDepth += 1
        body()
        programmaticDepth -= 1
        lastClip = scrollView.contentView.bounds
    }

    private func updateCounts() {
        let count = lineLengths.count
        if shownCount != count { shownCount = count }
        let empty = count == 0
        if isEmpty != empty { isEmpty = empty }
    }

    private func build(_ list: [LogEntry]) -> (NSAttributedString, [Int]) {
        var string = ""
        string.reserveCapacity(list.count * 72)
        var lengths: [Int] = []
        lengths.reserveCapacity(list.count)
        var spans: [(NSRange, NSColor)] = []
        var systemText: [NSRange] = []
        var systemLines: [NSRange] = []
        var hits: [NSRange] = []
        var cursor = 0

        for entry in list {
            let start = cursor
            if showTime {
                let stamp = timestamp(entry.time) + "  "
                string += stamp
                let n = stamp.utf16.count
                spans.append((NSRange(location: cursor, length: n), Palette.faintNS))
                cursor += n
            }
            let arrow: String
            switch entry.direction {
            case .rx: arrow = "←  "
            case .tx: arrow = "→  "
            case .sys: arrow = entry.severity == .error ? "!  " : "·  "
            }
            string += arrow
            let systemColor = entry.severity == .error ? Palette.badNS : Palette.subNS
            let arrowColor: NSColor
            switch entry.direction {
            case .rx: arrowColor = Palette.faintNS
            case .tx: arrowColor = Palette.txNS
            case .sys: arrowColor = systemColor
            }
            spans.append((NSRange(location: cursor, length: 3), arrowColor))
            cursor += 3

            let text = body(of: entry)
            let textLength = text.utf16.count
            string += text
            if entry.direction == .tx {
                spans.append((NSRange(location: cursor, length: textLength), Palette.txNS))
            } else if entry.direction == .sys {
                spans.append((NSRange(location: cursor, length: textLength), systemColor))
                systemText.append(NSRange(location: cursor, length: textLength))
            }
            if !query.isEmpty {
                let ns = text as NSString
                var search = NSRange(location: 0, length: ns.length)
                while search.length > 0 {
                    let found = ns.range(of: query, options: .caseInsensitive, range: search)
                    if found.location == NSNotFound { break }
                    hits.append(NSRange(location: cursor + found.location, length: found.length))
                    let next = found.location + max(found.length, 1)
                    search = NSRange(location: next, length: ns.length - next)
                }
            }
            cursor += textLength

            string += "\n"
            cursor += 1
            lengths.append(cursor - start)
            if entry.direction == .sys { systemLines.append(NSRange(location: start, length: cursor - start)) }
        }

        let result = NSMutableAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: Palette.inkNS, .paragraphStyle: paragraph,
        ])
        for (range, color) in spans { result.addAttribute(.foregroundColor, value: color, range: range) }
        for range in systemText { result.addAttribute(.font, value: systemFont, range: range) }
        for range in systemLines { result.addAttribute(.paragraphStyle, value: systemParagraph, range: range) }
        for range in hits { result.addAttribute(.backgroundColor, value: Palette.hitNS, range: range) }
        return (result, lengths)
    }

    private func body(of entry: LogEntry) -> String {
        if entry.direction == .sys { return entry.note }
        if view == .hex { return Codec.hexString(entry.bytes) }
        let end = entry.trailer?.lowerBound ?? entry.bytes.count
        var content = Codec.displayText(entry.bytes.subdata(in: 0..<end), encoding: encoding)
        // 发出去的全是控制字符时，文本视图不能留一行空白，看不出发了什么
        if entry.direction == .tx, content.isEmpty { content = Codec.hexString(entry.bytes.subdata(in: 0..<end)) }
        guard let trailer = entry.trailer else { return content }
        return content + "  [校验 " + Codec.hexString(entry.bytes.subdata(in: trailer)) + "]"
    }

    private func timestamp(_ date: Date) -> String {
        let interval = date.timeIntervalSince1970
        let second = Int(interval)
        if second != cachedSecond {
            cachedSecond = second
            var t = time_t(second)
            var parts = tm()
            localtime_r(&t, &parts)
            cachedPrefix = String(format: "%02d:%02d:%02d", parts.tm_hour, parts.tm_min, parts.tm_sec)
        }
        let millis = min(999, Int((interval - Double(second)) * 1000))
        let digits = String(millis)
        return cachedPrefix + "." + String(repeating: "0", count: 3 - digits.count) + digits
    }

    // MARK: 选项

    func configure(view: ViewMode? = nil, showTime: Bool? = nil, query: String? = nil, encoding: TextEncodingChoice? = nil) {
        if let view { self.view = view }
        if let showTime { self.showTime = showTime }
        if let query { self.query = query }
        if let encoding { self.encoding = encoding }
        rebuild()
    }

    func setPaused(_ value: Bool) {
        guard value != paused else { return }
        paused = value
        if value {
            pauseIndex = entries.count
            pending = 0
        } else {
            let backlog = Array(entries[pauseIndex...])
            pending = 0
            atBottom = true
            render(backlog)
            programmatic { textView.scrollToEndOfDocument(nil) }
        }
    }

    func clear() {
        entries.removeAll()
        lineLengths.removeAll()
        pauseIndex = 0
        pending = 0
        paused = false
        atBottom = true
        programmatic { textView.textStorage!.setAttributedString(NSAttributedString()) }
        updateCounts()
    }

    func jumpToEnd() {
        atBottom = true
        programmatic { textView.scrollToEndOfDocument(nil) }
    }

    func exportText() -> String {
        var out = ""
        out.reserveCapacity(entries.count * 64)
        for entry in entries {
            if showTime { out += timestamp(entry.time) + "  " }
            switch entry.direction {
            case .rx: out += "RX  "
            case .tx: out += "TX  "
            case .sys: out += "--  "
            }
            out += body(of: entry) + "\n"
        }
        return out
    }

    /// TextKit 的后台排版和窗口重排也会改滚动位置，单看位移分不清是不是用户。
    /// 所以只有发生在用户交互作用域内的变化才更新跟随意图，其余变化都保持原来的意图。
    @objc private func boundsChanged() {
        let clip = scrollView.contentView.bounds
        let previous = lastClip
        lastClip = clip
        guard programmaticDepth == 0 else { return }
        guard navigation.isActive else {
            if atBottom { scheduleFollow() }
            return
        }
        guard clip.size == previous.size, let document = scrollView.documentView else { return }
        let distance = document.frame.height - clip.maxY
        if clip.origin.y < previous.origin.y - 0.5, distance > 1 {
            navigation.leftBottom = true
            if atBottom { atBottom = false }
        } else if clip.origin.y > previous.origin.y + 0.5, distance < 30, !navigation.leftBottom, !atBottom {
            atBottom = true
        }
    }

    /// 排版把视图移开时，跟随状态下要回到底部。排版过程中不能直接滚动，放到下一轮执行。
    private func scheduleFollow() {
        guard !followScheduled else { return }
        followScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.followScheduled = false
            guard self.atBottom, NSEvent.pressedMouseButtons & 1 == 0 else { return }
            self.programmatic { self.textView.scrollToEndOfDocument(nil) }
        }
    }

    @objc private func liveScrollStarted() { navigation.liveScrolling = true }
    @objc private func liveScrollEnded() {
        navigation.liveScrolling = false
        // 同一次手势里先上后下，最后停在底部时恢复跟随
        guard let document = scrollView.documentView else { return }
        if document.frame.height - scrollView.contentView.bounds.maxY <= 1, !atBottom { atBottom = true }
    }

    @objc private func viewportResized() {
        // 窗口变窄时让文字跟着重新排版，并保持左边距和跟随状态
        programmatic {
            let clip = scrollView.contentView
            if textView.frame.width != clip.bounds.width {
                textView.setFrameSize(NSSize(width: clip.bounds.width, height: textView.frame.height))
            }
            if clip.bounds.origin.x != 0 {
                clip.setBoundsOrigin(NSPoint(x: 0, y: clip.bounds.origin.y))
                scrollView.reflectScrolledClipView(clip)
            }
            if atBottom { textView.scrollToEndOfDocument(nil) }
        }
    }
}
