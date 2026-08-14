import AppKit

@MainActor
enum OrbitStatusBarIcon {
    static let animationDuration: TimeInterval = 9
    static let framesPerSecond: TimeInterval = 12

    private static let frameCount = Int(animationDuration * framesPerSecond)
    private static let animationFrames: [NSImage] = (0..<frameCount).map { frame in
        rasterizedImage(progress: Double(frame) / Double(frameCount))
    }

    private static let imageSize = NSSize(width: 24, height: 24)
    private static let designSize: CGFloat = 512
    // Optical sizing for a tiny menu-bar slot. The centerline ellipse is
    // slightly narrower than the large logo so its much thicker rotated
    // stroke can use nearly the full canvas without clipping.
    private static let ringWidth: CGFloat = 400
    private static let ringHeight: CGFloat = 160
    private static let ringStrokeWidth: CGFloat = 48
    private static let cutStrokeWidth: CGFloat = 30
    private static let coreDiameter: CGFloat = 92
    private static let declaredPathLength: CGFloat = 976
    private static let cutLength: CGFloat = 108
    private static let gapLength: CGFloat = 380
    private static let accent = NSColor(
        calibratedRed: 1.0,
        green: 107.0 / 255.0,
        blue: 53.0 / 255.0,
        alpha: 1
    )

    static func image(progress rawProgress: Double) -> NSImage {
        let progress = rawProgress.isFinite
            ? max(0, rawProgress.truncatingRemainder(dividingBy: 1))
            : 0
        let index = min(frameCount - 1, Int(progress * Double(frameCount)))
        return animationFrames[index]
    }

    private static func vectorImage(progress: Double) -> NSImage {
        let image = NSImage(size: imageSize, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else {
                return false
            }

            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)

            let side = min(rect.width, rect.height)
            let scale = side / designSize
            let ringRect = CGRect(
                x: -ringWidth * scale / 2,
                y: -ringHeight * scale / 2,
                width: ringWidth * scale,
                height: ringHeight * scale
            )
            let perimeter = ellipsePerimeter(
                radiusX: ringRect.width / 2,
                radiusY: ringRect.height / 2
            )
            let pathUnit = perimeter / declaredPathLength
            let dashOn = cutLength * pathUnit
            let dashOff = gapLength * pathUnit
            // Positive phase moves the cutouts clockwise around the menu-bar ring.
            let phase = CGFloat(progress) * (dashOn + dashOff)

            context.saveGState()
            context.translateBy(x: rect.midX, y: rect.midY)

            // Core Graphics uses an upward Y axis here. Positive 25° matches
            // the SVG's visual rotate(-25°) in its downward Y coordinate space.
            context.rotate(by: CGFloat(25.0 * .pi / 180.0))
            context.setStrokeColor(accent.cgColor)
            context.setLineWidth(ringStrokeWidth * scale)
            context.strokeEllipse(in: ringRect)

            // Cut transparent windows into the orange ring. The menu bar then
            // supplies the correct dark, light, or highlighted background.
            context.setBlendMode(.clear)
            context.setLineCap(.round)
            context.setLineWidth(cutStrokeWidth * scale)
            context.setLineDash(phase: phase, lengths: [dashOn, dashOff])
            context.strokeEllipse(in: ringRect)
            context.restoreGState()

            context.setBlendMode(.normal)
            context.setFillColor(accent.cgColor)
            let coreSize = coreDiameter * scale
            context.fillEllipse(in: CGRect(
                x: rect.midX - coreSize / 2,
                y: rect.midY - coreSize / 2,
                width: coreSize,
                height: coreSize
            ))

            return true
        }

        // Preserve Orbit orange instead of letting AppKit convert it to a
        // monochrome template image.
        image.isTemplate = false
        image.size = imageSize
        return image
    }

    private static func rasterizedImage(progress: Double) -> NSImage {
        let logicalSize = imageSize
        let retinaScale = 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(logicalSize.width) * retinaScale,
            pixelsHigh: Int(logicalSize.height) * retinaScale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let bitmapContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return vectorImage(progress: progress)
        }

        bitmap.size = logicalSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = bitmapContext
        bitmapContext.cgContext.clear(CGRect(
            x: 0,
            y: 0,
            width: bitmap.pixelsWide,
            height: bitmap.pixelsHigh
        ))
        bitmapContext.cgContext.scaleBy(
            x: CGFloat(retinaScale),
            y: CGFloat(retinaScale)
        )
        vectorImage(progress: progress).draw(
            in: CGRect(origin: .zero, size: logicalSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        bitmapContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: logicalSize)
        image.addRepresentation(bitmap)
        image.isTemplate = false
        return image
    }

    private static func ellipsePerimeter(radiusX: CGFloat, radiusY: CGFloat) -> CGFloat {
        let sum = radiusX + radiusY
        let h = pow((radiusX - radiusY) / sum, 2)
        return .pi * sum * (1 + ((3 * h) / (10 + sqrt(4 - (3 * h)))))
    }
}
