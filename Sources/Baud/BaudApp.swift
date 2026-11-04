import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct BaudApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Baud", id: "main") {
            RootView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("串口") {
                Button(model.link == .idle ? "连接" : "断开", action: model.toggleLink)
                    .keyboardShortcut("k")
                Divider()
                Button("查找", action: model.focusSearch)
                    .keyboardShortcut("f")
                Button(model.log.paused ? "继续显示" : "暂停显示", action: model.togglePause)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("清屏", action: model.clearLog)
                    .keyboardShortcut("l")
                Button("保存日志…", action: model.saveLog)
                    .keyboardShortcut("s")
                Button(model.multiOpen ? "收起多条发送" : "多条发送") {
                    withAnimation(Motion.spring) { model.multiOpen.toggle() }
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                Divider()
                Button(model.focusMode ? "请回看板娘" : "专注模式") {
                    withAnimation(Motion.spring) { model.focusMode.toggle() }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            CommandMenu("演示设备") {
                Button("模拟拔出设备", action: model.demoUnplug)
                    .disabled(!model.isDemoConnected)
                Button("模拟插回设备", action: model.demoPlugBack)
                    .disabled(!model.canPlugDemoBack)
                Divider()
                Button(model.flooding ? "停止高速数据" : "开始高速数据", action: model.demoToggleFlood)
                    .disabled(!model.isDemoConnected)
            }
        }
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
                .zIndex(1)
            Rectangle().fill(Palette.line).frame(width: 1)
            MainPane(model: model)
        }
        // 标题栏的 28pt 会另外算进窗口，这里的 612 对应窗口最小高度 640
        .frame(minWidth: 900, minHeight: 612)
        .foregroundStyle(Palette.ink)
        .tint(Palette.clay)
        .ignoresSafeArea()
        .onAppear { SelfTest.startIfRequested(model) }
    }
}
