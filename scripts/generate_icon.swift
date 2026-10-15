import AppKit
import CoreGraphics

func createIcon() -> NSImage {
    let size = NSSize(width: 1024, height: 1024)
    let image = NSImage(size: size)
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    // Canvas background is transparent.
    // 1. Draw outer squircle with standard macOS icon inset (inset by 96pt -> 832x832).
    let iconRect = CGRect(x: 96, y: 96, width: 832, height: 832)
    let cornerRadius: CGFloat = 185
    let squirclePath = CGPath(roundedRect: iconRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Shadow under the squircle
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 36, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(squirclePath)
    ctx.setFillColor(CGColor(gray: 0.1, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Clip to squircle for internal drawing
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    // Base background gradient: Deep graphite / obsidian to midnight slate
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        CGColor(red: 0.11, green: 0.12, blue: 0.16, alpha: 1.0),
        CGColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1.0)
    ] as CFArray
    let bgLocations: [CGFloat] = [0.0, 1.0]
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: bgLocations) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: iconRect.midX, y: iconRect.maxY),
                               end: CGPoint(x: iconRect.midX, y: iconRect.minY),
                               options: [])
    }

    // Subtle radial glow from the center notch
    let glowColors = [
        CGColor(red: 0.25, green: 0.45, blue: 0.85, alpha: 0.28),
        CGColor(red: 0.45, green: 0.20, blue: 0.70, alpha: 0.12),
        CGColor(red: 0, green: 0, blue: 0, alpha: 0.0)
    ] as CFArray
    let glowLocations: [CGFloat] = [0.0, 0.5, 1.0]
    if let glowGradient = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: glowLocations) {
        ctx.drawRadialGradient(glowGradient,
                               startCenter: CGPoint(x: iconRect.midX, y: iconRect.maxY - 140),
                               startRadius: 20,
                               endCenter: CGPoint(x: iconRect.midX, y: iconRect.maxY - 140),
                               endRadius: 420,
                               options: [])
    }

    // Top screen bezel line
    let bezelY = iconRect.maxY - 40
    ctx.setStrokeColor(CGColor(red: 0.25, green: 0.28, blue: 0.35, alpha: 0.5))
    ctx.setLineWidth(4)
    ctx.move(to: CGPoint(x: iconRect.minX + 30, y: bezelY))
    ctx.addLine(to: CGPoint(x: iconRect.maxX - 30, y: bezelY))
    ctx.strokePath()

    // The Notch Body
    let notchWidth: CGFloat = 360
    let notchHeight: CGFloat = 160
    let notchRect = CGRect(x: iconRect.midX - notchWidth / 2,
                           y: bezelY - notchHeight,
                           width: notchWidth,
                           height: notchHeight)

    // Notch shape with fluid top flare
    let notchPath = CGMutablePath()
    let flareRadius: CGFloat = 28
    let bottomRadius: CGFloat = 24

    notchPath.move(to: CGPoint(x: notchRect.minX - flareRadius, y: bezelY))
    // Left flare curve into the notch
    notchPath.addQuadCurve(to: CGPoint(x: notchRect.minX, y: bezelY - flareRadius),
                          control: CGPoint(x: notchRect.minX, y: bezelY))
    // Left vertical edge
    notchPath.addLine(to: CGPoint(x: notchRect.minX, y: notchRect.minY + bottomRadius))
    // Bottom-left rounded corner
    notchPath.addArc(tangent1End: CGPoint(x: notchRect.minX, y: notchRect.minY),
                     tangent2End: CGPoint(x: notchRect.minX + bottomRadius, y: notchRect.minY),
                     radius: bottomRadius)
    // Bottom edge
    notchPath.addLine(to: CGPoint(x: notchRect.maxX - bottomRadius, y: notchRect.minY))
    // Bottom-right rounded corner
    notchPath.addArc(tangent1End: CGPoint(x: notchRect.maxX, y: notchRect.minY),
                     tangent2End: CGPoint(x: notchRect.maxX, y: notchRect.minY + bottomRadius),
                     radius: bottomRadius)
    // Right vertical edge
    notchPath.addLine(to: CGPoint(x: notchRect.maxX, y: bezelY - flareRadius))
    // Right flare curve
    notchPath.addQuadCurve(to: CGPoint(x: notchRect.maxX + flareRadius, y: bezelY),
                           control: CGPoint(x: notchRect.maxX, y: bezelY))
    notchPath.closeSubpath()

    // Notch shadow & fill (true matte black)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.8))
    ctx.addPath(notchPath)
    ctx.setFillColor(CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Notch subtle rim stroke
    ctx.addPath(notchPath)
    ctx.setStrokeColor(CGColor(red: 0.3, green: 0.35, blue: 0.45, alpha: 0.35))
    ctx.setLineWidth(2.5)
    ctx.strokePath()

    // Camera lens in center of notch
    let camCenter = CGPoint(x: notchRect.midX, y: bezelY - 60)
    let camRadius: CGFloat = 16
    ctx.setFillColor(CGColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1.0))
    ctx.fillEllipse(in: CGRect(x: camCenter.x - camRadius, y: camCenter.y - camRadius, width: camRadius * 2, height: camRadius * 2))

    // Lens reflection ring
    ctx.setStrokeColor(CGColor(red: 0.2, green: 0.35, blue: 0.55, alpha: 0.6))
    ctx.setLineWidth(2)
    ctx.strokeEllipse(in: CGRect(x: camCenter.x - camRadius * 0.65, y: camCenter.y - camRadius * 0.65, width: camRadius * 1.3, height: camRadius * 1.3))

    // Lens glint
    ctx.setFillColor(CGColor(red: 0.5, green: 0.7, blue: 1.0, alpha: 0.8))
    ctx.fillEllipse(in: CGRect(x: camCenter.x - 5, y: camCenter.y + 2, width: 4, height: 4))

    // Green indicator LED dot to the right of camera
    let ledCenter = CGPoint(x: camCenter.x + 48, y: camCenter.y)
    ctx.setFillColor(CGColor(red: 0.2, green: 0.85, blue: 0.4, alpha: 0.95))
    ctx.fillEllipse(in: CGRect(x: ledCenter.x - 4, y: ledCenter.y - 4, width: 8, height: 8))

    // Expanded Floating Dynamic Island Panel below the notch
    let islandRect = CGRect(x: iconRect.midX - 260, y: iconRect.minY + 200, width: 520, height: 260)
    let islandPath = CGPath(roundedRect: islandRect, cornerWidth: 32, cornerHeight: 32, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 32, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.65))
    ctx.addPath(islandPath)
    ctx.setFillColor(CGColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 0.92))
    ctx.fillPath()
    ctx.restoreGState()

    // Island rim border
    ctx.addPath(islandPath)
    ctx.setStrokeColor(CGColor(red: 0.35, green: 0.4, blue: 0.5, alpha: 0.3))
    ctx.setLineWidth(2)
    ctx.strokePath()

    // Inside Island: Audio visualizer waves on left (Music), flame badge & tokens on right (Agents)
    // Left: Audio bars (Cyan / Blue)
    let barHeights: [CGFloat] = [28, 54, 82, 42, 68, 36]
    let startX: CGFloat = islandRect.minX + 48
    let barWidth: CGFloat = 10
    let barSpacing: CGFloat = 16
    let baseY: CGFloat = islandRect.midY

    for (i, h) in barHeights.enumerated() {
        let x = startX + CGFloat(i) * barSpacing
        let barRect = CGRect(x: x, y: baseY - h/2, width: barWidth, height: h)
        let barPath = CGPath(roundedRect: barRect, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.addPath(barPath)
        ctx.setFillColor(CGColor(red: 0.2, green: 0.75, blue: 0.95, alpha: 0.9))
        ctx.fillPath()
    }

    // Divider in Island
    ctx.setStrokeColor(CGColor(red: 0.25, green: 0.28, blue: 0.35, alpha: 0.4))
    ctx.setLineWidth(2)
    ctx.move(to: CGPoint(x: islandRect.midX, y: islandRect.minY + 40))
    ctx.addLine(to: CGPoint(x: islandRect.midX, y: islandRect.maxY - 40))
    ctx.strokePath()

    // Right: Agent flame & progress ring (Vibrant Orange / Amber)
    let agentCenterX = islandRect.midX + 130
    let agentCenterY = islandRect.midY

    // Progress arc
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(red: 1.0, green: 0.45, blue: 0.15, alpha: 0.9))
    ctx.setLineWidth(8)
    ctx.setLineCap(.round)
    ctx.addArc(center: CGPoint(x: agentCenterX, y: agentCenterY),
               radius: 54,
               startAngle: 0.3,
               endAngle: 4.8,
               clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()

    // Flame silhouette in center of circle
    let flamePath = CGMutablePath()
    let fx = agentCenterX
    let fy = agentCenterY - 26
    flamePath.move(to: CGPoint(x: fx, y: fy + 52))
    flamePath.addCurve(to: CGPoint(x: fx + 26, y: fy + 24),
                       control1: CGPoint(x: fx + 16, y: fy + 48),
                       control2: CGPoint(x: fx + 26, y: fy + 38))
    flamePath.addCurve(to: CGPoint(x: fx + 14, y: fy),
                       control1: CGPoint(x: fx + 26, y: fy + 12),
                       control2: CGPoint(x: fx + 20, y: fy + 4))
    flamePath.addCurve(to: CGPoint(x: fx, y: fy + 22),
                       control1: CGPoint(x: fx + 10, y: fy + 14),
                       control2: CGPoint(x: fx + 4, y: fy + 18))
    flamePath.addCurve(to: CGPoint(x: fx - 14, y: fy),
                       control1: CGPoint(x: fx - 4, y: fy + 18),
                       control2: CGPoint(x: fx - 10, y: fy + 14))
    flamePath.addCurve(to: CGPoint(x: fx - 26, y: fy + 24),
                       control1: CGPoint(x: fx - 20, y: fy + 4),
                       control2: CGPoint(x: fx - 26, y: fy + 12))
    flamePath.addCurve(to: CGPoint(x: fx, y: fy + 52),
                       control1: CGPoint(x: fx - 26, y: fy + 38),
                       control2: CGPoint(x: fx - 16, y: fy + 48))
    flamePath.closeSubpath()

    ctx.addPath(flamePath)
    ctx.setFillColor(CGColor(red: 1.0, green: 0.6, blue: 0.1, alpha: 0.95))
    ctx.fillPath()

    // Inner bright core of flame
    let innerFlame = CGMutablePath()
    innerFlame.move(to: CGPoint(x: fx, y: fy + 38))
    innerFlame.addCurve(to: CGPoint(x: fx + 12, y: fy + 18),
                        control1: CGPoint(x: fx + 8, y: fy + 34),
                        control2: CGPoint(x: fx + 12, y: fy + 26))
    innerFlame.addCurve(to: CGPoint(x: fx, y: fy + 8),
                        control1: CGPoint(x: fx + 12, y: fy + 12),
                        control2: CGPoint(x: fx + 4, y: fy + 9))
    innerFlame.addCurve(to: CGPoint(x: fx - 12, y: fy + 18),
                        control1: CGPoint(x: fx - 4, y: fy + 9),
                        control2: CGPoint(x: fx - 12, y: fy + 12))
    innerFlame.addCurve(to: CGPoint(x: fx, y: fy + 38),
                        control1: CGPoint(x: fx - 12, y: fy + 26),
                        control2: CGPoint(x: fx - 8, y: fy + 34))
    innerFlame.closeSubpath()
    ctx.addPath(innerFlame)
    ctx.setFillColor(CGColor(red: 1.0, green: 0.9, blue: 0.4, alpha: 0.98))
    ctx.fillPath()

    // Subtle bottom glass reflection on squircle
    ctx.restoreGState() // Pop clipping

    // Outer subtle border on the whole squircle
    ctx.addPath(squirclePath)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.16))
    ctx.setLineWidth(2.5)
    ctx.strokePath()

    image.unlockFocus()
    return image
}

let baseImage = createIcon()

let iconsetPath = "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let sizes: [(Int, Int, String)] = [
    (16, 1, "icon_16x16.png"),
    (16, 2, "icon_16x16@2x.png"),
    (32, 1, "icon_32x32.png"),
    (32, 2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"),
    (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"),
    (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"),
    (512, 2, "icon_512x512@2x.png"),
]

for (pt, scale, filename) in sizes {
    let px = pt * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: px,
                               pixelsHigh: px,
                               bitsPerSample: 8,
                               samplesPerPixel: 4,
                               hasAlpha: true,
                               isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0,
                               bitsPerPixel: 0)!
    rep.size = NSSize(width: pt, height: pt)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    baseImage.draw(in: NSRect(x: 0, y: 0, width: pt, height: pt),
                   from: NSRect(x: 0, y: 0, width: 1024, height: 1024),
                   operation: .copy,
                   fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    if let pngData = rep.representation(using: .png, properties: [:]) {
        let fileURL = URL(fileURLWithPath: "\(iconsetPath)/\(filename)")
        try? pngData.write(to: fileURL)
    }
}

print("Iconset generated successfully.")
