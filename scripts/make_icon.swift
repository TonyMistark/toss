import AppKit
import Foundation

// 用法：swift scripts/make_icon.swift [输出目录]
// 默认输出到 macos/Resources/AppIcon.iconset，再用 iconutil 生成 .icns。

let outputDir = URL(
    fileURLWithPath: CommandLine.arguments.count > 1
        ? CommandLine.arguments[1]
        : "macos/Resources/AppIcon.iconset"
)

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

func drawIcon(pixels: Int) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.setShouldAntialias(true)

    let s = CGFloat(pixels) / 1024
    let bounds = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(
        roundedRect: bounds,
        xRadius: 186 * s,
        yRadius: 186 * s
    )

    // 背景：蓝 → 靛紫，斜向渐变。
    let background = NSGradient(colors: [color(0x4F8CFF), color(0x4B32D9)])!
    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    background.draw(
        from: NSPoint(x: bounds.minX, y: bounds.maxY),
        to: NSPoint(x: bounds.maxX, y: bounds.minY),
        options: []
    )

    // 顶部一层很淡的白色高光，让图标有一点体积感。
    let sheen = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.18),
        NSColor.white.withAlphaComponent(0),
    ])!
    sheen.draw(
        from: NSPoint(x: bounds.minX, y: bounds.maxY),
        to: NSPoint(x: bounds.minX, y: bounds.midY),
        options: []
    )
    NSGraphicsContext.current?.restoreGraphicsState()

    // 外沿一道细高光。
    color(0xFFFFFF).withAlphaComponent(0.16).setStroke()
    squircle.lineWidth = 2 * s
    squircle.stroke()

    // 标记：一上一下两支箭头，代表发送与拉取。
    let upArrow = NSBezierPath(
        roundedRect: NSRect(x: 352 * s, y: 384 * s, width: 84 * s, height: 308 * s),
        xRadius: 42 * s,
        yRadius: 42 * s
    )
    let upHead = NSBezierPath()
    upHead.move(to: NSPoint(x: 296 * s, y: 668 * s))
    upHead.line(to: NSPoint(x: 488 * s, y: 668 * s))
    upHead.line(to: NSPoint(x: 392 * s, y: 788 * s))
    upHead.close()

    let downArrow = NSBezierPath(
        roundedRect: NSRect(x: 588 * s, y: 332 * s, width: 84 * s, height: 308 * s),
        xRadius: 42 * s,
        yRadius: 42 * s
    )
    let downHead = NSBezierPath()
    downHead.move(to: NSPoint(x: 536 * s, y: 356 * s))
    downHead.line(to: NSPoint(x: 728 * s, y: 356 * s))
    downHead.line(to: NSPoint(x: 632 * s, y: 236 * s))
    downHead.close()

    NSColor.white.setFill()
    upArrow.fill()
    upHead.fill()
    downArrow.fill()
    downHead.fill()

    return rep
}

try FileManager.default.createDirectory(
    at: outputDir,
    withIntermediateDirectories: true
)

for item in sizes {
    guard let rep = drawIcon(pixels: item.pixels),
          let png = rep.representation(using: .png, properties: [:])
    else {
        fputs("✗ 无法生成 \(item.name)\n", stderr)
        exit(1)
    }
    try png.write(to: outputDir.appendingPathComponent(item.name))
}

print("✓ 已生成 \(sizes.count) 张图标 → \(outputDir.path)")
