import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MarkdownRender

@Suite("Bounded native image playback", .serialized)
@MainActor
struct AnimatedImageSourceTests {
    static func gif() -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 3, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 2]] as CFDictionary)
        for color in [NSColor.red, .blue, .green] {
            let image = NSImage(size: NSSize(width: 80, height: 40), flipped: false) { rect in color.setFill(); rect.fill(); return true }
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
    @Test func metadataAndDecodedFramesStayBounded() throws {
        let animation = try #require(AnimatedImageSource(data: Self.gif()))
        #expect(animation.frameCount == 3)
        #expect(animation.loopCount == 2)
        #expect(animation.delays.allSatisfy { abs($0 - 0.1) < 0.001 })
        let source = try #require(animation.makeImageSource())
        let frame = try #require(AnimatedImageSource.frame(1, of: source, maxPixelDimension: 16))
        #expect(frame.width <= 16 && frame.height <= 16)
    }
    @Test func malformedTimingsNeverScheduleAnInvalidTimer() {
        #expect(AnimatedImageSource.normalized(0) == 0.1)
        #expect(AnimatedImageSource.normalized(.nan) == 0.1)
        #expect(AnimatedImageSource.normalized(.infinity) == 0.1)
        #expect(AnimatedImageSource.normalized(0.2) == 0.2)
    }
    @Test func playbackStartsPausedAndHasAnAccessibleControl() throws {
        let animation = try #require(AnimatedImageSource(data: Self.gif()))
        let view = AnimatedImagePlaybackView(image: NSImage(size: NSSize(width: 80, height: 40)), animation: animation, background: .white)
        #expect(!view.wantsPlayback)
        let button = try #require(view.subviews.compactMap { $0 as? NSButton }.first)
        #expect(button.accessibilityLabel() == "Play image")
    }
    @Test func finitePlaybackCanReplayEveryAuthoredLoop() {
        var cycle = AnimatedImagePlaybackCycle()
        for _ in 0..<2 {
            #expect(cycle.nextFrame(after: 0, frameCount: 3, loopCount: 2) == 1)
            #expect(cycle.nextFrame(after: 1, frameCount: 3, loopCount: 2) == 2)
            #expect(cycle.nextFrame(after: 2, frameCount: 3, loopCount: 2) == 0)
            #expect(cycle.nextFrame(after: 0, frameCount: 3, loopCount: 2) == 1)
            #expect(cycle.nextFrame(after: 1, frameCount: 3, loopCount: 2) == 2)
            #expect(cycle.nextFrame(after: 2, frameCount: 3, loopCount: 2) == nil)
            #expect(cycle.nextFrame(after: 2, frameCount: 3, loopCount: 2) == 0)
        }
    }
    @Test func playbackButtonReceivesHitTestsInsideTheTextView() throws {
        let animation = try #require(AnimatedImageSource(data: Self.gif()))
        let storage = NSTextStorage(string: "A document")
        let textView = MarkdownTextView(frame: .zero, storage: storage)
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        textView.frame = parent.bounds
        parent.addSubview(textView)
        let view = AnimatedImagePlaybackView(image: NSImage(size: NSSize(width: 80, height: 40)), animation: animation, background: .white)
        view.frame = NSRect(x: 100, y: 100, width: 80, height: 40)
        textView.addSubview(view)
        view.layout()
        let button = try #require(view.subviews.compactMap { $0 as? NSButton }.first)
        let point = view.convert(NSPoint(x: view.bounds.maxX - 10, y: 10), to: textView)
        #expect(view.hitTest(point) === button)
        #expect(parent.hitTest(textView.convert(point, to: parent)) === button)
    }

    @Test func svgRasterizationIsBounded() throws {
        let data = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="10000" height="2000"><rect width="10000" height="2000" fill="blue"/></svg>"#.utf8)
        let image = try #require(SVGImageDecoder.decode(data, maxPixelDimension: 200))
        #expect(image.size == CGSize(width: 200, height: 40))
    }
}
