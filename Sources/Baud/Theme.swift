import AppKit
import SwiftUI

/// 象牙白、橘色、深咖啡。深色模式是一间开着台灯的可可色房间。
enum Palette {
    static let paperNS = dynamic(0xFFF8EC, 0x211915)
    static let panelNS = dynamic(0xFBF0DD, 0x2A201A)
    static let raisedNS = dynamic(0xFFFDF8, 0x352921)
    static let inkNS = dynamic(0x4A342A, 0xF3E6D6)
    static let subNS = dynamic(0x6F5848, 0xC8B4A0)
    static let faintNS = dynamic(0x7F6A5A, 0xA8937F)
    static let lineNS = dynamic(0xEBDCC4, 0x46382E)
    static let clayNS = dynamic(0xD77757, 0xE58B68)
    static let txNS = dynamic(0xB0532F, 0xF4A583)
    static let honeyNS = dynamic(0xF2C36B, 0xE9B65C)
    static let hitNS = dynamic(0xF9DFA6, 0x6E5420)
    static let okNS = dynamic(0x2E8B57, 0x6FCF97)
    static let badNS = dynamic(0xC9402E, 0xFF8A75)
    static let selectionNS = dynamic(0xF6D9C6, 0x5A3C2C)

    static let paper = Color(nsColor: paperNS)
    static let panel = Color(nsColor: panelNS)
    static let raised = Color(nsColor: raisedNS)
    static let ink = Color(nsColor: inkNS)
    static let sub = Color(nsColor: subNS)
    static let faint = Color(nsColor: faintNS)
    static let line = Color(nsColor: lineNS)
    static let clay = Color(nsColor: clayNS)
    static let tx = Color(nsColor: txNS)
    static let honey = Color(nsColor: honeyNS)
    static let ok = Color(nsColor: okNS)
    static let bad = Color(nsColor: badNS)
    static let selected = Color(nsColor: selectionNS)
    static let onClay = Color(red: 0.16, green: 0.09, blue: 0.05)

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light)
        }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// 代替 `@State`。新版 SDK 里 `@State` 是宏，它的插件只随完整的 Xcode 提供，只装命令行工具时无法编译。
@propertyWrapper
struct Local<Value>: DynamicProperty {
    private var storage: SwiftUI.State<Value>

    init(wrappedValue: Value) {
        storage = SwiftUI.State(initialValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}

enum Motion {
    /// 通用的弹性过渡。
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.68)
    /// 按压反馈，要快。
    static let snap = Animation.spring(response: 0.24, dampingFraction: 0.7)
    /// 向日葵开关，弹得明显一些。
    static let flower = Animation.spring(response: 0.56, dampingFraction: 0.58)
    /// 贴纸松手回弹。
    static let release = Animation.spring(response: 0.5, dampingFraction: 0.5)
}

enum Haptics {
    static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    static func bump() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
