#if DEBUG
import AppKit
import SwiftUI

/// 把一个 SwiftUI 面板渲染成 PNG,给自动化验收看界面用(无需屏幕录制权限)。
@MainActor
enum PanelSnapshot {
    static func write(_ view: some View, height: CGFloat, to path: String) {
        let renderer = ImageRenderer(content: view.frame(height: height))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
#endif
