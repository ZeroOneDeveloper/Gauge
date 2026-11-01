import AppKit

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let dimension = CGFloat(pixels)
        let inset = dimension * 0.05
        let rect = NSRect(x: inset, y: inset, width: dimension - 2 * inset, height: dimension - 2 * inset)
        let background = NSBezierPath(roundedRect: rect, xRadius: dimension * 0.215, yRadius: dimension * 0.215)
        let gradient = NSGradient(starting: NSColor(srgbRed: 0.92, green: 0.61, blue: 0.39, alpha: 1), ending: NSColor(srgbRed: 0.82, green: 0.40, blue: 0.25, alpha: 1))!
        gradient.draw(in: background, angle: -65)
        let center = NSPoint(x: dimension * 0.5, y: dimension * 0.43)
        let radius = dimension * 0.275
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 15, endAngle: 165, clockwise: false)
        arc.lineWidth = dimension * 0.048
        arc.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.9).setStroke()
        arc.stroke()
        for degree in [15.0, 52.5, 90, 127.5, 165] {
            let radians = degree * .pi / 180
            let location = NSPoint(x: center.x + cos(radians) * radius * 0.73, y: center.y + sin(radians) * radius * 0.73)
            let dotSize = dimension * 0.022
            NSColor.white.withAlphaComponent(0.6).setFill()
            NSBezierPath(ovalIn: NSRect(x: location.x - dotSize / 2, y: location.y - dotSize / 2, width: dotSize, height: dotSize)).fill()
        }
        let needle = NSBezierPath()
        needle.move(to: NSPoint(x: center.x - dimension * 0.03, y: center.y - dimension * 0.015))
        needle.line(to: NSPoint(x: center.x + dimension * 0.165, y: center.y + dimension * 0.185))
        needle.lineWidth = dimension * 0.037
        needle.lineCapStyle = .round
        NSColor.white.setStroke()
        needle.stroke()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - dimension * 0.042, y: center.y - dimension * 0.042, width: dimension * 0.084, height: dimension * 0.084)).fill()
        let line = NSBezierPath(roundedRect: NSRect(x: dimension * 0.35, y: dimension * 0.30, width: dimension * 0.30, height: dimension * 0.026), xRadius: dimension * 0.013, yRadius: dimension * 0.013)
        NSColor.white.withAlphaComponent(0.6).setFill()
        line.fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination).appendingPathComponent(filename))
    }
}
