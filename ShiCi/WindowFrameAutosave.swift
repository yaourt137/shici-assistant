import AppKit
import SwiftUI

/// 主窗口尺寸：默认值、下限，以及供「设置」读取与调整。尺寸均指内容区。
@MainActor
enum MainWindowSize {
    static let autosaveName = "MainWindow"
    static let defaultSize = CGSize(width: 1400, height: 900)
    /// 侧栏 + 编辑区（最小 380）+ 检查器，合计约 1200。
    static let minimumSize = CGSize(width: 1200, height: 640)

    private static var window: NSWindow? {
        NSApp.windows.first { $0.frameAutosaveName == autosaveName }
    }

    /// 当前内容区大小；主窗口未打开时为 nil。
    static func current() -> CGSize? {
        window.map { $0.contentRect(forFrameRect: $0.frame).size }
    }

    /// 调整内容区大小并保持左上角位置，限制在下限与屏幕可见区域之间；返回实际应用的大小，主窗口未打开时为 nil。
    @discardableResult
    static func apply(_ requested: CGSize) -> CGSize? {
        guard let window else { return nil }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        let maximum = visible.map { window.contentRect(forFrameRect: $0).size }
            ?? CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let size = CGSize(width: min(max(requested.width, minimumSize.width), max(maximum.width, minimumSize.width)),
                          height: min(max(requested.height, minimumSize.height), max(maximum.height, minimumSize.height)))
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let visible {
            // 超出屏幕右侧或底部时移回可见区域。
            frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
            frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
        }
        window.setFrame(frame, display: true, animate: true)
        return size
    }
}

/// 让所在窗口把位置与大小存入 UserDefaults，下次启动时恢复。
/// 不依赖系统「退出 App 时关闭窗口」设置下的状态恢复；尚未保存过时沿用场景的 defaultSize。
struct WindowFrameAutosave: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView { AutosaveView(name: name) }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class AutosaveView: NSView {
        private let name: String

        init(name: String) {
            self.name = name
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.frameAutosaveName != name else { return }
            // 同名只给第一个窗口使用；其余窗口（如新开的第二个）保持默认，避免与第一个重叠。
            let nameInUse = NSApp.windows.contains { $0 !== window && $0.frameAutosaveName == name }
            guard !nameInUse else { return }
            window.setFrameUsingName(name)
            window.setFrameAutosaveName(name)
        }
    }
}
