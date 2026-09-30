// DisplayTuner 应用图标生成器(CoreGraphics,无外部素材依赖)
// 变体 A:显示器 + 调节滑块(主方案)
// 变体 B:像素锐度网格(备选)
// 输出:/tmp/iconA_1024.png /tmp/iconA_32.png /tmp/iconB_1024.png
import Foundation
import CoreGraphics
import ImageIO

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: cs,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            alpha,
        ]
    )!
}

func makeContext(_ s: Int) -> CGContext {
    CGContext(
        data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

func squircle(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(
        roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil
    )
}

func exportPNG(_ ctx: CGContext, _ path: String) {
    let img = ctx.makeImage()!
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(path)")
}

// 画布基准:1024 里留 100 边距,内容 824(苹果图标网格)
let canvas = CGRect(x: 0, y: 0, width: size, height: size)
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)

// ---------- 变体 A:显示器 + 滑块 ----------
func drawVariantA(_ ctx: CGContext) {
    // 底:深灰蓝对角渐变
    ctx.addPath(squircle(canvas, 232))
    ctx.clip()
    let bgGrad = CGGradient(
        colorsSpace: cs,
        colors: [rgb(0x2A3140), rgb(0x12151E)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 1024, y: 0), options: [])

    // 显示器组:柔影
    let bezel = CGRect(x: 212, y: 302, width: 600, height: 420)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 44, color: rgb(0x000000, 0.38))
    ctx.setFillColor(rgb(0x0A0D14))
    ctx.addPath(squircle(bezel, 46))
    ctx.fillPath()
    ctx.restoreGState()

    // 屏幕内衬:青蓝对角渐变 + 顶部光晕
    let screen = bezel.insetBy(dx: 22, dy: 22)
    ctx.saveGState()
    ctx.addPath(squircle(screen, 30))
    ctx.clip()
    let screenGrad = CGGradient(
        colorsSpace: cs,
        colors: [rgb(0x2E7CF6), rgb(0x3AC8C8)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(screenGrad, start: CGPoint(x: screen.minX, y: screen.maxY), end: CGPoint(x: screen.maxX, y: screen.minY), options: [])
    let glow = CGGradient(
        colorsSpace: cs,
        colors: [rgb(0xFFFFFF, 0.20), rgb(0xFFFFFF, 0.0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        glow, startCenter: CGPoint(x: screen.midX, y: screen.maxY - 60), startRadius: 0,
        endCenter: CGPoint(x: screen.midX, y: screen.maxY - 60), endRadius: 420, options: []
    )

    // 滑轨(横向,过屏幕中心)
    let trackY: CGFloat = screen.midY
    let trackRect = CGRect(x: screen.minX + 56, y: trackY - 9, width: screen.width - 112, height: 18)
    ctx.setFillColor(rgb(0xFFFFFF, 0.55))
    ctx.addPath(squircle(trackRect, 9))
    ctx.fillPath()

    // 滑块(偏右,示意"调高到清晰")
    let knobCenter = CGPoint(x: trackRect.maxX - 92, y: trackY)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 26, color: rgb(0x000000, 0.32))
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillEllipse(in: CGRect(x: knobCenter.x - 48, y: knobCenter.y - 48, width: 96, height: 96))
    ctx.restoreGState()
    // 滑块内圈一点屏幕色,避免死白
    ctx.setFillColor(rgb(0x2E7CF6, 0.28))
    ctx.fillEllipse(in: CGRect(x: knobCenter.x - 20, y: knobCenter.y - 20, width: 40, height: 40))
    ctx.restoreGState()

    // 边框细节:面板顶部 1px 高光
    ctx.saveGState()
    ctx.addPath(squircle(bezel, 46))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.12))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()
}

// ---------- 变体 B:像素锐度网格(左上清晰 → 右下发虚) ----------
func drawVariantB(_ ctx: CGContext) {
    ctx.addPath(squircle(canvas, 232))
    ctx.clip()
    let bgGrad = CGGradient(
        colorsSpace: cs,
        colors: [rgb(0x232B3A), rgb(0x101319)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 1024, y: 0), options: [])

    let cell: CGFloat = 236
    let gap: CGFloat = 32
    let total = cell * 3 + gap * 2
    let originX = (1024 - total) / 2
    let originY = (1024 - total) / 2

    // 网格:青→蓝渐变按位置取色;右下最后一格用叠影"发虚"
    for row in 0..<3 {
        for col in 0..<3 {
            let x = originX + CGFloat(col) * (cell + gap)
            let yTop = originY + CGFloat(row) * (cell + gap)
            let rect = CGRect(x: x, y: 1024 - yTop - cell, width: cell, height: cell)
            let t = Double(row + col) / 4.0
            // 青绿(0x36D0C4)→ 蓝(0x2E6FF0)插值
            let r = Int(0x36 + Int(Double(0x2E - 0x36) * t))
            let g = Int(0xD0 + Int(Double(0x6F - 0xD0) * t))
            let b = Int(0xC4 + Int(Double(0xF0 - 0xC4) * t))
            let blurCount = (row == 2 && col == 2) ? 9 : 1
            let alpha: CGFloat = blurCount > 1 ? 0.20 : 1
            for _ in 0..<blurCount {
                let jitter = CGFloat(blurCount) * 3.2
                let dx = CGFloat.random(in: -jitter...jitter)
                let dy = CGFloat.random(in: -jitter...jitter)
                ctx.setFillColor(rgb(UInt32(max(0, r) << 16 | max(0, g) << 8 | max(0, b)), alpha))
                ctx.addPath(squircle(rect.offsetBy(dx: dx, dy: dy), 52))
                ctx.fillPath()
            }
        }
    }
}

let ctxA = makeContext(size)
ctxA.setAllowsAntialiasing(true)
ctxA.setShouldAntialias(true)
drawVariantA(ctxA)
exportPNG(ctxA, "/tmp/iconA_1024.png")

let ctxA32 = makeContext(32)
ctxA32.scaleBy(x: 32.0 / 1024.0, y: 32.0 / 1024.0)
ctxA32.interpolationQuality = .medium
drawVariantA(ctxA32)
exportPNG(ctxA32, "/tmp/iconA_32.png")

let ctxB = makeContext(size)
ctxB.setAllowsAntialiasing(true)
ctxB.setShouldAntialias(true)
drawVariantB(ctxB)
exportPNG(ctxB, "/tmp/iconB_1024.png")
