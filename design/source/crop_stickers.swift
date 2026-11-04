import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// 用法: swift crop_stickers.swift <表情图> <输出目录>
let args = CommandLine.arguments
let src = URL(fileURLWithPath: args[1]) as CFURL
let out = URL(fileURLWithPath: args[2], isDirectory: true)

guard let isrc = CGImageSourceCreateWithURL(src, nil),
      let sheet = CGImageSourceCreateImageAtIndex(isrc, 0, nil) else {
    fatalError("无法读取图片")
}

let w = sheet.width, h = sheet.height
var data = [UInt8](repeating: 0, count: w * h * 4)
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(sheet, in: CGRect(x: 0, y: 0, width: w, height: h))

func isWhite(_ x: Int, _ y: Int) -> Bool {
    let i = (y * w + x) * 4
    return data[i] > 238 && data[i + 1] > 238 && data[i + 2] > 238
}

// 统计每行、每列的白色占比，找出格子之间的缝隙
func bands(_ count: Int, _ cross: Int, _ white: (Int, Int) -> Bool, _ threshold: Double) -> [(Int, Int)] {
    var result: [(Int, Int)] = []
    var start = -1
    for a in 0..<count {
        var n = 0
        for b in 0..<cross where white(a, b) { n += 1 }
        let gap = Double(n) / Double(cross) >= threshold
        if !gap && start < 0 { start = a }
        if gap && start >= 0 { result.append((start, a)); start = -1 }
    }
    if start >= 0 { result.append((start, count)) }
    return result
}

let rows = bands(h, w, { y, x in isWhite(x, y) }, 0.93)
let cols = bands(w, h, { x, y in isWhite(x, y) }, 0.93)
print("检测到的行:", rows)
print("检测到的列:", cols)

// 在 [lo, hi] 里找白色占比最高的位置，作为两格之间的切线
func bestCut(_ lo: Int, _ hi: Int, _ cross: ClosedRange<Int>, _ white: (Int, Int) -> Bool) -> Int {
    var best = lo, bestN = -1
    for a in lo...hi {
        var n = 0
        for b in cross where white(a, b) { n += 1 }
        let center = (lo + hi) / 2
        if n > bestN || (n == bestN && abs(a - center) < abs(best - center)) { bestN = n; best = a }
    }
    return best
}

let cellW = w / 6, cellH = h / 4
// 窗口和擦除坐标都以 1280 宽的表情图为基准，按实际宽度缩放
let scale = Double(w) / 1280
let rowWin = Int(26 * scale), colWin = Int(28 * scale)
var rowCuts = [0]
for r in 1..<4 {
    rowCuts.append(bestCut(r * cellH - rowWin, r * cellH + rowWin, 0...(w - 1), { y, x in isWhite(x, y) }))
}
rowCuts.append(h)
print("行切线:", rowCuts)

for r in 0..<4 {
    let top = rowCuts[r], bottom = rowCuts[r + 1]
    var colCuts = [0]
    for c in 1..<6 {
        colCuts.append(bestCut(c * cellW - colWin, c * cellW + colWin, top...(bottom - 1), { x, y in isWhite(x, y) }))
    }
    colCuts.append(w)
    print("第 \(r + 1) 行列切线:", colCuts)
    for c in 0..<6 {
        let rect = CGRect(x: colCuts[c], y: top, width: colCuts[c + 1] - colCuts[c], height: bottom - top)
        guard let raw = sheet.cropping(to: rect) else { continue }
        let name = String(format: "r%dc%d.png", r + 1, c + 1)
        // 擦掉混进来的相邻表情符号，坐标相对于本格左上角
        let erase: [String: [CGRect]] = [
            "r1c2.png": [CGRect(x: 192, y: 16, width: 40, height: 52)],
            "r1c3.png": [CGRect(x: 0, y: 16, width: 15, height: 48), CGRect(x: 92, y: 212, width: 30, height: 8)],
            "r4c5.png": [CGRect(x: 208, y: 12, width: 20, height: 78)],
            "r1c5.png": [CGRect(x: 0, y: 20, width: 12, height: 75)],
            "r3c1.png": [CGRect(x: 214, y: 14, width: 20, height: 32), CGRect(x: 100, y: 202, width: 65, height: 6)],
        ]
        let pw = raw.width, ph = raw.height
        let pctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                             space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        pctx.draw(raw, in: CGRect(x: 0, y: 0, width: pw, height: ph))
        let s = CGFloat(scale)
        pctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        for e in erase[name] ?? [] {
            pctx.fill(CGRect(x: e.minX * s, y: CGFloat(ph) - e.maxY * s, width: e.width * s, height: e.height * s))
        }
        let piece = pctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL,
                                                   UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, piece, nil)
        CGImageDestinationFinalize(dest)
    }
}
print("完成")
