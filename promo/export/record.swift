// 逐帧渲染宣传短片并编码成 MP4。
// 用法：record <页面.html> <宽> <高> <码率> <输出.mp4>
//       record <页面.html> <宽> <高> stills <秒,秒,…> <输出目录>
//       record verify <视频.mp4> <秒,秒,…> <输出目录>
import AVFoundation
import AppKit
import WebKit

let fps = 30

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func savePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

@MainActor
final class Loader: NSObject, WKNavigationDelegate {
    var done: CheckedContinuation<Void, Error>?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        done?.resume(); done = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        done?.resume(throwing: error); done = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        done?.resume(throwing: error); done = nil
    }
}

@MainActor
final class Stage {
    let window: NSWindow
    let web: WKWebView
    let loader = Loader()
    let width: Int
    let height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        let config = WKWebViewConfiguration()
        config.preferences.inactiveSchedulingPolicy = .none
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        web = WKWebView(frame: frame, configuration: config)
        // 放在屏幕外，录制时不打扰正在用电脑的人
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.ignoresMouseEvents = true
        window.contentView = web
        window.orderFrontRegardless()
    }

    func load(_ page: URL) async throws {
        let root = page.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loader.done = c
            web.navigationDelegate = loader
            web.loadFileURL(page, allowingReadAccessTo: root)
        }
        let fonts = try await web.callAsyncJavaScript("return await __film.ready()", contentWorld: .page) as? Bool
        print("字体就绪：\(fonts == true)")
    }

    func step(_ dt: Double) async throws {
        _ = try await web.callAsyncJavaScript("await __film.step(d)", arguments: ["d": dt], contentWorld: .page)
    }

    func snapshot() async throws -> CGImage {
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        let image: NSImage = try await web.takeSnapshot(configuration: config)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fail("截图失败") }
        return cg
    }
}

func parseTimes(_ text: String) -> [Double] { text.split(separator: ",").compactMap { Double($0) } }

@MainActor
func stills(page: URL, width: Int, height: Int, times: [Double], dir: URL) async throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let stage = Stage(width: width, height: height)
    try await stage.load(page)
    var frame = 0
    for time in times.sorted() {
        while Double(frame) / Double(fps) < time {
            try await stage.step(1 / Double(fps))
            frame += 1
        }
        savePNG(try await stage.snapshot(), to: dir.appendingPathComponent(String(format: "t%05.1f.png", time)))
    }
}

@MainActor
func record(page: URL, width: Int, height: Int, bitrate: Int, output: URL) async throws {
    try? FileManager.default.removeItem(at: output)
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let stage = Stage(width: width, height: height)
    try await stage.load(page)
    let duration = try await stage.web.evaluateJavaScript("__film.duration") as? Double ?? 60

    let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2
        ]
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height
    ])
    writer.add(input)
    guard writer.startWriting() else { fail("无法开始写入：\(String(describing: writer.error))") }
    writer.startSession(atSourceTime: .zero)

    let total = Int(duration * Double(fps))
    let started = Date()
    for frame in 0..<total {
        if frame > 0 { try await stage.step(1 / Double(fps)) }
        let image = try await stage.snapshot()
        guard let pool = adaptor.pixelBufferPool else { fail("没有像素缓冲池") }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let pixels = buffer else { fail("无法创建像素缓冲") }
        CVPixelBufferLockBaseAddress(pixels, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.interpolationQuality = .high
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
        guard adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))) else {
            fail("写入第 \(frame) 帧失败：\(String(describing: writer.error))")
        }
        if frame % 150 == 0 {
            print("\(output.lastPathComponent)：\(frame)/\(total) 帧，已用 \(Int(Date().timeIntervalSince(started))) 秒")
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { fail("编码失败：\(String(describing: writer.error))") }
    print("完成：\(output.path)，用时 \(Int(Date().timeIntervalSince(started))) 秒")
}

func verify(video: URL, times: [Double], dir: URL) async throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let asset = AVURLAsset(url: video)
    let duration = try await asset.load(.duration).seconds
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { fail("没有视频轨") }
    let size = try await track.load(.naturalSize)
    let rate = try await track.load(.nominalFrameRate)
    let bits = try await track.load(.estimatedDataRate)
    print("\(video.lastPathComponent)：\(duration) 秒，\(Int(size.width))×\(Int(size.height))，\(rate) fps，\(Int(bits / 1000)) kbps")
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    for time in times {
        let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
        savePNG(image, to: dir.appendingPathComponent(String(format: "v%05.1f.png", time)))
    }
}

let args = CommandLine.arguments
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

Task { @MainActor in
    do {
        if args.count == 5, args[1] == "verify" {
            try await verify(video: URL(fileURLWithPath: args[2]), times: parseTimes(args[3]), dir: URL(fileURLWithPath: args[4]))
        } else if args.count == 7, args[4] == "stills" {
            try await stills(page: URL(fileURLWithPath: args[1]), width: Int(args[2])!, height: Int(args[3])!,
                             times: parseTimes(args[5]), dir: URL(fileURLWithPath: args[6]))
        } else if args.count == 6 {
            try await record(page: URL(fileURLWithPath: args[1]), width: Int(args[2])!, height: Int(args[3])!,
                             bitrate: Int(args[4])!, output: URL(fileURLWithPath: args[5]))
        } else {
            fail("参数不对")
        }
        exit(0)
    } catch {
        fail("出错：\(error)")
    }
}
app.run()
