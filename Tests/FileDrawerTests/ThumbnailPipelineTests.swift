import XCTest
import AppKit
import AVFoundation
import PDFKit
@testable import FileDrawer

/// 图片 / 视频 / PDF 缩略图端到端契约：
/// 真实文件 → ensureThumb（后台解码）→ thumbs 缓存出现可显示的位图。
/// 同时覆盖设置开关：关闭时不生成，重新打开后自动补齐。
@MainActor
final class ThumbnailPipelineTests: XCTestCase {

    private var store: ShelfStore { ShelfStore.shared }
    private var settings: AppSettings { AppSettings.shared }

    override func setUp() {
        super.setUp()
        settings.showThumbnails = true
    }

    override func tearDown() {
        settings.showThumbnails = true
        for item in store.items where item.path.contains("缩略图样本") {
            store.remove(item)
        }
        super.tearDown()
    }

    // MARK: - 样本文件生成

    /// 生成一张真实 PNG（带颜色内容，避免空白帧）
    private func writeSamplePNG(to url: URL) throws {
        let width = 96, height = 64
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        for x in 0..<width {
            for y in 0..<height {
                rep.setColor(
                    NSColor(calibratedRed: Double(x) / Double(width),
                            green: Double(y) / Double(height),
                            blue: 0.4, alpha: 1),
                    atX: x, y: y
                )
            }
        }
        let data = rep.representation(using: .png, properties: [:])!
        try data.write(to: url)
    }

    /// 用 AVAssetWriter 生成一段真实可解码的 mp4（12 帧，1 秒）
    private func writeSampleVideo(to url: URL) throws {
        let width = 96, height = 64
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let finished = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "thumb-test.video")
        var nextFrame = 0
        var ended = false
        input.requestMediaDataWhenReady(on: queue) {
            // 编码器未就绪时硬塞会抛 NSInternalInconsistencyException，必须按就绪节奏喂帧
            while input.isReadyForMoreMediaData {
                guard nextFrame < 12 else {
                    if !ended {
                        ended = true
                        input.markAsFinished()
                        writer.finishWriting { finished.signal() }
                    }
                    return
                }
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32ARGB, nil, &buffer)
                if let buffer {
                    _ = adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(nextFrame), timescale: 12))
                }
                nextFrame += 1
            }
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 10), DispatchTimeoutResult.success, "视频编码应在超时前完成")
        XCTAssertEqual(writer.status, .completed, "样本视频写入失败：\(String(describing: writer.error))")
    }

    /// 生成一份单页真实 PDF
    private func writeSamplePDF(to url: URL) throws {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 60,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.setColor(NSColor(calibratedRed: 0.9, green: 0.2, blue: 0.2, alpha: 1), atX: 40, y: 30)
        let image = NSImage(cgImage: rep.cgImage!, size: NSSize(width: 80, height: 60))
        let page = PDFPage(image: image)!
        let document = PDFDocument()
        document.insert(page, at: 0)
        XCTAssertTrue(document.write(to: url), "样本 PDF 写入失败")
    }

    // MARK: - 等待辅助

    /// 自旋主 RunLoop 等条件成立（后台 Task 完成后经 MainActor 回填 thumbs）
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func addAndTrack(_ url: URL) throws -> ShelfItem {
        store.add(urls: [url])
        return try XCTUnwrap(store.items.last)
    }

    // MARK: - 图片

    func testImageShowsRealThumbnail() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("缩略图样本-\(UUID().uuidString).png")
        try writeSamplePNG(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let added = try addAndTrack(url)
        store.ensureThumb(for: added)

        XCTAssertTrue(waitUntil { self.store.thumbs[added.id] != nil }, "图片应在后台解码后出现缩略图")
        let thumb = try XCTUnwrap(store.thumbs[added.id])
        XCTAssertGreaterThan(thumb.representations.first?.pixelsWide ?? 0, 0, "缩略图应是可显示的位图")
    }

    // MARK: - 视频

    func testVideoShowsRealThumbnail() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("缩略图样本-\(UUID().uuidString).mp4")
        try writeSampleVideo(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let added = try addAndTrack(url)
        store.ensureThumb(for: added)

        XCTAssertTrue(waitUntil { self.store.thumbs[added.id] != nil }, "视频应抽取首帧生成缩略图")
        let thumb = try XCTUnwrap(store.thumbs[added.id])
        XCTAssertGreaterThan(thumb.representations.first?.pixelsWide ?? 0, 0, "视频缩略图应是可显示的位图")
    }

    // MARK: - PDF

    func testPDFShowsFirstPageThumbnail() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("缩略图样本-\(UUID().uuidString).pdf")
        try writeSamplePDF(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let added = try addAndTrack(url)
        store.ensureThumb(for: added)

        XCTAssertTrue(waitUntil { self.store.thumbs[added.id] != nil }, "PDF 应渲染首页缩略图")

        // 首页渲染应自带不透明白底：四角不透明，叠在彩色瓷片上才看得清
        let thumb = try XCTUnwrap(store.thumbs[added.id])
        let rep = try XCTUnwrap(NSBitmapImageRep(data: thumb.tiffRepresentation!))
        let w = rep.pixelsWide, h = rep.pixelsHigh
        XCTAssertGreaterThan(w, 0)
        for point in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)] {
            let alpha = rep.colorAt(x: point.0, y: point.1)?.alphaComponent ?? 0
            XCTAssertGreaterThanOrEqual(alpha, 0.9, "PDF 缩略图应是不透明渲染（角点 (\(point.0),\(point.1)) alpha=\(alpha)）")
        }
    }

    // MARK: - 设置开关

    func testSettingOffBlocksThenReEnableFills() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("缩略图样本-\(UUID().uuidString).png")
        try writeSamplePNG(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let added = try addAndTrack(url)

        // 关闭时请求被拦截
        settings.showThumbnails = false
        store.ensureThumb(for: added)
        XCTAssertFalse(waitUntil(timeout: 0.5) { self.store.thumbs[added.id] != nil }, "关闭缩略图时不应生成")

        // 重新打开：即使错过 onAppear，订阅也会自动补齐
        settings.showThumbnails = true
        XCTAssertTrue(waitUntil { self.store.thumbs[added.id] != nil }, "重新打开缩略图后应自动补齐已显示的行")
    }
}
