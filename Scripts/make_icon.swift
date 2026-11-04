import AppKit

// 用法: swift make_icon.swift <贴纸图片> <输出 PNG>
let args = CommandLine.arguments
guard let source = NSImage(contentsOfFile: args[1]),
      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else {
    fatalError("无法读取贴纸")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor.white.setFill()
path.fill()
NSGraphicsContext.restoreGraphicsState()

path.addClip()
let size = source.size
let scale = max(tile.width / size.width, tile.height / size.height)
let drawn = NSSize(width: size.width * scale, height: size.height * scale)
source.draw(in: NSRect(x: tile.midX - drawn.width / 2, y: tile.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: args[2]))
