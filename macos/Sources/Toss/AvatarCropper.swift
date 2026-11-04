import AppKit
import SwiftUI

/// 包一层，让 `NSImage` 能塞进 `.sheet(item:)`。
struct CroppingImage: Identifiable {
    let id = UUID()
    let image: NSImage
}

/// 选完图片后的方形裁剪面板：拖动定位、滑块缩放，确认后交回一张 512 px 的方图。
struct AvatarCropView: View {
    let image: NSImage
    let onCancel: () -> Void
    let onApply: (NSImage) -> Void

    private let viewport: CGFloat = 320
    private let minZoom: CGFloat = 1
    private let maxZoom: CGFloat = 4

    @State private var zoom: CGFloat = 1
    @State private var zoomStart: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    var body: some View {
        VStack(spacing: 16) {
            Text(t("Crop Avatar"))
                .font(.title2)
                .bold()

            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.85))
                cropPreview
            }
            .frame(width: viewport, height: viewport)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            .contentShape(Circle())
            .gesture(panGesture)
            .simultaneousGesture(magnificationGesture)

            HStack(spacing: 10) {
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Slider(value: $zoom, in: minZoom...maxZoom)
                    .onChange(of: zoom) { _ in
                        offset = clampedOffset(offset)
                    }
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(.secondary)
            }

            Text(t("Drag the picture to reposition it."))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(t("Cancel")) {
                    onCancel()
                }
                Button(t("Use Picture")) {
                    if let cropped = croppedImage() {
                        onApply(cropped)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private var cropPreview: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: viewport, height: viewport)
            .scaleEffect(zoom)
            .offset(offset)
            .frame(width: viewport, height: viewport)
            .clipped()
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = clampedOffset(CGSize(
                    width: dragStart.width + value.translation.width,
                    height: dragStart.height + value.translation.height
                ))
            }
            .onEnded { _ in
                dragStart = offset
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = min(max(zoomStart * value, minZoom), maxZoom)
                offset = clampedOffset(offset)
            }
            .onEnded { _ in
                zoomStart = zoom
            }
    }

    /// 把图片的位移限制在「裁切圆内始终有内容」的范围内。
    private func clampedOffset(_ value: CGSize) -> CGSize {
        let iw = image.size.width
        let ih = image.size.height
        guard iw > 0, ih > 0 else { return .zero }

        let scale = baseScale * zoom
        let maxX = max(0, (iw * scale - viewport) / 2)
        let maxY = max(0, (ih * scale - viewport) / 2)
        return CGSize(
            width: min(max(value.width, -maxX), maxX),
            height: min(max(value.height, -maxY), maxY)
        )
    }

    private var baseScale: CGFloat {
        let iw = image.size.width
        let ih = image.size.height
        guard iw > 0, ih > 0 else { return 1 }
        return max(viewport / iw, viewport / ih)
    }

    /// 按当前缩放与位移，从原图取中心方形，重绘成 512 px。
    private func croppedImage() -> NSImage? {
        let iw = image.size.width
        let ih = image.size.height
        guard iw > 0, ih > 0 else { return nil }

        let scale = baseScale * zoom
        let cropSide = viewport / scale

        let centerX = iw / 2 - offset.width / scale
        let centerY = ih / 2 - offset.height / scale

        let x = min(max(centerX - cropSide / 2, 0), max(0, iw - cropSide))
        let topY = min(max(centerY - cropSide / 2, 0), max(0, ih - cropSide))
        // NSImage.draw 的源坐标原点在左下角，把自上而下的 y 翻过来。
        let y = ih - topY - cropSide

        let side = ProfileStore.avatarSide
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(side),
            pixelsHigh: Int(side),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        rep.size = NSSize(width: side, height: side)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: side, height: side),
            from: NSRect(x: x, y: y, width: cropSide, height: cropSide),
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let tiff = rep.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }

        return NSImage(data: png)
    }
}
