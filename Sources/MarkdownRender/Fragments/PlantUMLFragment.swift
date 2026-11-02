import AppKit

/// The Mac host supplies the local worker. Finder extensions leave this nil
/// and retain readable code; the shared renderer never starts a process.
public protocol PlantUMLRendering: AnyObject {
    func cachedImage(source: String, dark: Bool) -> NSImage?
    func hasFailed(source: String, dark: Bool) -> Bool
    func render(source: String, dark: Bool, completion: @escaping @MainActor () -> Void)
}

public enum PlantUMLFence {
    public static func accepts(_ language: String?) -> Bool {
        guard let name = language?.lowercased().split(whereSeparator: \.isWhitespace).first else { return false }
        return name == "plantuml" || name == "puml"
    }
}

final class PlantUMLFragment: DownrightFragment {
    private var requested = false
    override var suppressesText: Bool { true }

    private var image: NSImage? {
        guard let loader = context?.plantUMLRenderer, let style = styleSheet else { return nil }
        let dark = StyleSheet.relativeLuminance(style.background) < 0.5
        if let image = loader.cachedImage(source: payload.detail, dark: dark) { return image }
        guard !loader.hasFailed(source: payload.detail, dark: dark) else { return nil }
        guard !requested else { return nil }
        requested = true
        let payload = payload
        let generation = context?.textView?.updateGeneration
        loader.render(source: payload.detail, dark: dark) { [weak self, weak view = context?.textView] in
            // A retained fragment may outlive its cached image. Permit a new
            // request after eviction, but never repair another source revision.
            self?.requested = false
            guard let generation else { return }
            view?.plantUMLDidRender(in: payload.sourceRange, generation: generation)
        }
        return nil
    }

    private func fittedSize(_ image: NSImage) -> CGSize {
        let ratio = min(1, contentWidth / max(1, image.size.width))
        return CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
    }

    private var placeholder: FailedObject {
        guard let loader = context?.plantUMLRenderer, let style = styleSheet else {
            return FailedObject(label: "PlantUML preview unavailable", source: payload.detail)
        }
        let dark = StyleSheet.relativeLuminance(style.background) < 0.5
        let label = loader.hasFailed(source: payload.detail, dark: dark)
            ? "PlantUML could not be rendered" : "Rendering PlantUML…"
        return FailedObject(label: label, source: payload.detail)
    }

    override var overrideHeight: CGFloat? {
        guard isFirstParagraphOfBlock else { return 0 }
        guard let style = styleSheet else { return nil }
        if let image {
            return RenderMetrics.snap(fittedSize(image).height + style.lineHeight, grid: style.baselineGrid)
        }
        return failedObjectHeight(placeholder, style: style) + style.lineHeight
    }

    override func drawObject(at point: CGPoint, in cg: CGContext) {
        guard isFirstParagraphOfBlock, let style = styleSheet else { return }
        if let image {
            let size = fittedSize(image)
            draw(image: image, in: CGRect(
                x: point.x + max(0, (contentWidth - size.width) / 2),
                y: point.y + max(0, (layoutFragmentFrame.height - size.height) / 2),
                width: size.width, height: size.height), in: cg)
        } else {
            drawFailedObject(placeholder, in: CGRect(
                x: point.x, y: point.y, width: contentWidth,
                height: failedObjectHeight(placeholder, style: style)), style: style, in: cg)
        }
    }
}
