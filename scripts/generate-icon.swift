#!/usr/bin/env swift
// Renders the app icon PNGs into the asset catalog.
// Usage: swift scripts/generate-icon.swift MDViewer/Resources/Assets.xcassets/AppIcon.appiconset

import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Background squircle.
    let inset = 100 * s
    let background = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let backgroundPath = NSBezierPath(roundedRect: background, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 20 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    shadow.set()
    NSGradient(
        starting: NSColor(srgbRed: 0.29, green: 0.47, blue: 0.98, alpha: 1),
        ending: NSColor(srgbRed: 0.36, green: 0.25, blue: 0.84, alpha: 1)
    )!.draw(in: backgroundPath, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // Page with folded corner.
    let page = NSRect(x: 262 * s, y: 196 * s, width: 500 * s, height: 632 * s)
    let fold = 130 * s
    let pagePath = NSBezierPath()
    pagePath.move(to: NSPoint(x: page.minX, y: page.minY))
    pagePath.line(to: NSPoint(x: page.maxX, y: page.minY))
    pagePath.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
    pagePath.line(to: NSPoint(x: page.maxX - fold, y: page.maxY))
    pagePath.line(to: NSPoint(x: page.minX, y: page.maxY))
    pagePath.close()
    NSColor(white: 1, alpha: 0.97).setFill()
    pagePath.fill()

    let foldPath = NSBezierPath()
    foldPath.move(to: NSPoint(x: page.maxX - fold, y: page.maxY))
    foldPath.line(to: NSPoint(x: page.maxX - fold, y: page.maxY - fold))
    foldPath.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
    foldPath.close()
    NSColor(srgbRed: 0.78, green: 0.82, blue: 0.95, alpha: 1).setFill()
    foldPath.fill()

    // "M↓" mark.
    let ink = NSColor(srgbRed: 0.24, green: 0.28, blue: 0.62, alpha: 1)
    let font = NSFont.systemFont(ofSize: 250 * s, weight: .heavy)
    let mark = NSAttributedString(string: "M", attributes: [.font: font, .foregroundColor: ink])
    let markSize = mark.size()
    mark.draw(at: NSPoint(x: page.minX + 58 * s, y: page.minY + 90 * s))

    let arrow = NSBezierPath()
    let ax = page.minX + 58 * s + markSize.width + 70 * s
    let top = page.minY + 330 * s
    let bottom = page.minY + 110 * s
    arrow.lineWidth = 42 * s
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: ax, y: top))
    arrow.line(to: NSPoint(x: ax, y: bottom + 20 * s))
    arrow.move(to: NSPoint(x: ax - 62 * s, y: bottom + 86 * s))
    arrow.line(to: NSPoint(x: ax, y: bottom + 20 * s))
    arrow.line(to: NSPoint(x: ax + 62 * s, y: bottom + 86 * s))
    ink.setStroke()
    arrow.stroke()

    // Text lines above the mark.
    NSColor(srgbRed: 0.72, green: 0.76, blue: 0.9, alpha: 1).setFill()
    for (index, width) in [300.0, 380.0].enumerated() {
        let y = page.maxY - 150 * s - CGFloat(index) * 72 * s
        NSBezierPath(roundedRect: NSRect(x: page.minX + 60 * s, y: y, width: CGFloat(width) * s, height: 34 * s), xRadius: 17 * s, yRadius: 17 * s).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = drawIcon(size: CGFloat(size))
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: outputDirectory.appendingPathComponent("icon_\(size).png"))
}
print("Wrote icons to \(outputDirectory.path)")
