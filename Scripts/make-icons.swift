#!/usr/bin/env swift
// Draws the project's icons with AppKit so they can be regenerated without design tools:
//
//   swift Scripts/make-icons.swift
//
// Outputs:
//   Examples/Calculator/assets/icon.png   1024×1024 Calculator app icon
//   Examples/ChessResults/assets/icon.png 1024×1024 Chess Results app icon
//   Resources/AppIcon.icns                JApp Runtime application icon
//   Resources/JAppDocument.icns           generic .japp document icon
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()

// MARK: Helpers

func render(size: Int, _ draw: (CGFloat) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    // Draw in a 1024-point design space regardless of output size.
    let scale = CGFloat(size) / 1024
    NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
    draw(scale)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path)")
}

func writeICNS(name: String, _ draw: @escaping (CGFloat) -> Void) {
    let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).iconset")
    try? FileManager.default.removeItem(at: iconset)
    try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        try! render(size: base, draw).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
        try! render(size: base * 2, draw).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    let output = root.appendingPathComponent("Resources/\(name).icns")
    try! FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
    try! process.run()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0, "iconutil failed")
    print("wrote \(output.path)")
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The macOS icon body: an 824-point rounded square centred on the 1024 canvas, with a soft shadow.
func iconBody(fill: NSGradient, highlight: Bool = true) -> NSBezierPath {
    let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    color(0x000000).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    fill.draw(in: path, angle: -90)
    if highlight {
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
            .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }
    return path
}

func drawText(_ text: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight, color textColor: NSColor, alignment: NSTextAlignment = .center) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor, .paragraphStyle: paragraph]
    let height = (text as NSString).size(withAttributes: attributes).height
    let centered = NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
    (text as NSString).draw(in: centered, withAttributes: attributes)
}

// MARK: Calculator

func drawCalculator(_ scale: CGFloat) {
    _ = iconBody(fill: NSGradient(starting: color(0x48484C), ending: color(0x1C1C1E))!)

    // Display
    let display = NSRect(x: 170, y: 690, width: 684, height: 164)
    color(0x0B0B0C).setFill()
    NSBezierPath(roundedRect: display, xRadius: 44, yRadius: 44).fill()
    drawText("42", in: display.insetBy(dx: 40, dy: 0), size: 130, weight: .light, color: .white, alignment: .right)

    // Keys: 4 × 4
    let labels = [["AC", "±", "%", "÷"], ["7", "8", "9", "×"], ["4", "5", "6", "−"], ["1", "2", "3", "+"]]
    let columns = 4, rows = 4
    let area = NSRect(x: 170, y: 170, width: 684, height: 490)
    let gap: CGFloat = 22
    let keyWidth = (area.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
    let keyHeight = (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
    for row in 0..<rows {
        for column in 0..<columns {
            let x = area.minX + CGFloat(column) * (keyWidth + gap)
            let y = area.maxY - CGFloat(row + 1) * keyHeight - CGFloat(row) * gap
            let key = NSRect(x: x, y: y, width: keyWidth, height: keyHeight)
            let isOperator = column == columns - 1
            let isFunction = row == 0 && !isOperator
            let fill = isOperator ? color(0xFF9F0A) : (isFunction ? color(0xA5A5AA) : color(0x5A5A5E))
            fill.setFill()
            NSBezierPath(roundedRect: key, xRadius: 40, yRadius: 40).fill()
            let text = isFunction ? color(0x1C1C1E) : NSColor.white
            drawText(labels[row][column], in: key, size: isOperator ? 70 : (isFunction ? 48 : 58), weight: .medium, color: text)
        }
    }
}

// MARK: JApp Runtime

/// A page with a window's traffic lights and lines of code: "an app that is a document".
func drawAppDocumentGlyph(in rect: NSRect, pageColor: NSColor, lineColor: NSColor) {
    let fold = rect.width * 0.24
    let page = NSBezierPath()
    page.move(to: NSPoint(x: rect.minX + 36, y: rect.minY))
    page.line(to: NSPoint(x: rect.maxX - 36, y: rect.minY))
    page.curve(to: NSPoint(x: rect.maxX, y: rect.minY + 36), controlPoint1: NSPoint(x: rect.maxX - 16, y: rect.minY), controlPoint2: NSPoint(x: rect.maxX, y: rect.minY + 16))
    page.line(to: NSPoint(x: rect.maxX, y: rect.maxY - fold))
    page.line(to: NSPoint(x: rect.maxX - fold, y: rect.maxY))
    page.line(to: NSPoint(x: rect.minX + 36, y: rect.maxY))
    page.curve(to: NSPoint(x: rect.minX, y: rect.maxY - 36), controlPoint1: NSPoint(x: rect.minX + 16, y: rect.maxY), controlPoint2: NSPoint(x: rect.minX, y: rect.maxY - 16))
    page.line(to: NSPoint(x: rect.minX, y: rect.minY + 36))
    page.curve(to: NSPoint(x: rect.minX + 36, y: rect.minY), controlPoint1: NSPoint(x: rect.minX, y: rect.minY + 16), controlPoint2: NSPoint(x: rect.minX + 16, y: rect.minY))
    page.close()
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.shadowBlurRadius = 18
    shadow.set()
    pageColor.setFill()
    page.fill()
    NSGraphicsContext.restoreGraphicsState()

    let corner = NSBezierPath()
    corner.move(to: NSPoint(x: rect.maxX - fold, y: rect.maxY))
    corner.line(to: NSPoint(x: rect.maxX - fold, y: rect.maxY - fold + 24))
    corner.curve(to: NSPoint(x: rect.maxX - fold + 24, y: rect.maxY - fold), controlPoint1: NSPoint(x: rect.maxX - fold, y: rect.maxY - fold + 8), controlPoint2: NSPoint(x: rect.maxX - fold + 8, y: rect.maxY - fold))
    corner.line(to: NSPoint(x: rect.maxX, y: rect.maxY - fold))
    corner.close()
    lineColor.withAlphaComponent(0.25).setFill()
    corner.fill()

    // Traffic lights
    let dot = rect.width * 0.085
    let dotsY = rect.maxY - fold * 0.62 - dot / 2
    for (index, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        color(UInt32(hex)).setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + rect.width * 0.14 + CGFloat(index) * dot * 1.45, y: dotsY, width: dot, height: dot)).fill()
    }
    // Code lines
    let widths: [CGFloat] = [0.58, 0.42, 0.66, 0.36, 0.52]
    let lineHeight = rect.height * 0.05
    for (index, width) in widths.enumerated() {
        let y = dotsY - rect.height * 0.13 - CGFloat(index) * lineHeight * 2.05
        let indent: CGFloat = (index == 1 || index == 2) ? rect.width * 0.1 : 0
        lineColor.withAlphaComponent(index == 2 ? 1 : 0.75).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX + rect.width * 0.14 + indent, y: y, width: rect.width * width, height: lineHeight),
                     xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
    }
}

func drawRuntime(_ scale: CGFloat) {
    _ = iconBody(fill: NSGradient(starting: color(0x7C5CFF), ending: color(0x3B2BB8))!)
    drawAppDocumentGlyph(in: NSRect(x: 292, y: 232, width: 440, height: 560), pageColor: .white, lineColor: color(0x5B47E0))
}

// MARK: .japp document

func drawDocument(_ scale: CGFloat) {
    drawAppDocumentGlyph(in: NSRect(x: 212, y: 80, width: 600, height: 864), pageColor: color(0xFBFBFD), lineColor: color(0x6E56F8))
    drawText("JAPP", in: NSRect(x: 212, y: 150, width: 600, height: 120), size: 96, weight: .heavy, color: color(0x6E56F8))
}

// MARK: Chess Results

func drawChessResults(_ scale: CGFloat) {
    let body = iconBody(fill: NSGradient(starting: color(0x2FA36B), ending: color(0x135A3A))!)

    // A faint chessboard inside the icon body.
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    let square: CGFloat = 824 / 8
    for row in 0..<8 {
        for column in 0..<8 where (row + column) % 2 == 0 {
            NSColor.white.withAlphaComponent(0.07).setFill()
            NSRect(x: 100 + CGFloat(column) * square, y: 100 + CGFloat(row) * square, width: square, height: square).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()

    // The knight, with a soft shadow.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.shadowBlurRadius = 24
    shadow.set()
    drawText("\u{265E}", in: NSRect(x: 150, y: 210, width: 724, height: 640), size: 600, weight: .regular, color: NSColor(white: 0.98, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()

    // A results badge: three bars, like a standings table.
    let badge = NSRect(x: 600, y: 160, width: 250, height: 190)
    NSGraphicsContext.saveGraphicsState()
    let badgeShadow = NSShadow()
    badgeShadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    badgeShadow.shadowOffset = NSSize(width: 0, height: -6)
    badgeShadow.shadowBlurRadius = 14
    badgeShadow.set()
    color(0xFFFFFF).setFill()
    NSBezierPath(roundedRect: badge, xRadius: 38, yRadius: 38).fill()
    NSGraphicsContext.restoreGraphicsState()
    for (index, width) in [CGFloat(170), 130, 95].enumerated() {
        let y = badge.maxY - 52 - CGFloat(index) * 46
        color(index == 0 ? 0xE0A43A : 0x1F8A5B, index == 0 ? 1 : 0.8).setFill()
        NSBezierPath(roundedRect: NSRect(x: badge.minX + 40, y: y, width: width, height: 26), xRadius: 13, yRadius: 13).fill()
    }
}

writePNG(render(size: 1024, drawCalculator), to: root.appendingPathComponent("Examples/Calculator/assets/icon.png"))
writePNG(render(size: 1024, drawChessResults), to: root.appendingPathComponent("Examples/ChessResults/assets/icon.png"))
writePNG(render(size: 1024, drawRuntime), to: root.appendingPathComponent("Resources/AppIcon.png"))
writeICNS(name: "AppIcon", drawRuntime)
writeICNS(name: "JAppDocument", drawDocument)
