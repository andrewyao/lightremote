// Draws the app icon: an A7-style full-frame mirrorless body (no brand marks) with Wi-Fi arcs.
//   swift Design/make_icon.swift LightRemote/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png")
let S = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Work in top-left coordinates.
ctx.translateBy(x: 0, y: CGFloat(S)); ctx.scaleBy(x: 1, y: -1)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r / 255, g / 255, b / 255, a])! }
func linear(_ colors: [CGColor], _ from: CGPoint, _ to: CGPoint, clip: CGPath) {
    ctx.saveGState(); ctx.addPath(clip); ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [])
    ctx.restoreGState()
}
func radial(_ colors: [CGColor], _ c: CGPoint, _ r: CGFloat, clip: CGPath) {
    ctx.saveGState(); ctx.addPath(clip); ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}
func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil) }
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }

let full = CGPath(rect: CGRect(x: 0, y: 0, width: S, height: S), transform: nil)
// Background: warm dark gradient with an orange glow behind the lens.
linear([rgb(38, 36, 40), rgb(14, 13, 16)], CGPoint(x: 0, y: 0), CGPoint(x: 0, y: CGFloat(S)), clip: full)
radial([rgb(255, 149, 0, 0.35), rgb(255, 149, 0, 0)], CGPoint(x: 540, y: 600), 470, clip: full)

let bodyColor = [rgb(70, 70, 76), rgb(36, 36, 40)]

// Viewfinder hump (centred, flat top, angled sides) — the A7 silhouette.
let hump = CGMutablePath()
hump.move(to: CGPoint(x: 372, y: 392)); hump.addLine(to: CGPoint(x: 432, y: 262))
hump.addLine(to: CGPoint(x: 612, y: 262)); hump.addLine(to: CGPoint(x: 672, y: 392)); hump.closeSubpath()
linear(bodyColor, CGPoint(x: 0, y: 262), CGPoint(x: 0, y: 400), clip: hump)
ctx.setFillColor(rgb(110, 110, 118)); ctx.fill(CGRect(x: 436, y: 262, width: 172, height: 8)) // top highlight

// Top plate controls: shutter button on the grip, dials on the right.
linear([rgb(150, 150, 158), rgb(80, 80, 88)], CGPoint(x: 0, y: 330), CGPoint(x: 0, y: 372),
       clip: rounded(CGRect(x: 196, y: 334, width: 92, height: 50), 14))
linear([rgb(255, 170, 60), rgb(220, 110, 0)], CGPoint(x: 0, y: 318), CGPoint(x: 0, y: 340),
       clip: rounded(CGRect(x: 214, y: 318, width: 56, height: 24), 10))   // shutter button (orange accent)
linear([rgb(130, 130, 138), rgb(70, 70, 78)], CGPoint(x: 0, y: 340), CGPoint(x: 0, y: 392),
       clip: rounded(CGRect(x: 712, y: 344, width: 112, height: 50), 12))   // mode dial
for i in 0..<9 { ctx.setFillColor(rgb(40, 40, 44)); ctx.fill(CGRect(x: 720 + i * 12, y: 348, width: 4, height: 42)) }

// Body.
let body = rounded(CGRect(x: 150, y: 384, width: 724, height: 370), 54)
linear(bodyColor, CGPoint(x: 0, y: 384), CGPoint(x: 0, y: 754), clip: body)
ctx.saveGState(); ctx.addPath(body); ctx.setStrokeColor(rgb(120, 120, 128, 0.6)); ctx.setLineWidth(4); ctx.strokePath(); ctx.restoreGState()

// Grip (viewer's left on the front), textured.
let grip = rounded(CGRect(x: 150, y: 384, width: 168, height: 370), 54)
linear([rgb(30, 30, 33), rgb(18, 18, 20)], CGPoint(x: 150, y: 0), CGPoint(x: 318, y: 0), clip: grip)
ctx.saveGState(); ctx.addPath(grip); ctx.clip()
ctx.setStrokeColor(rgb(255, 255, 255, 0.05)); ctx.setLineWidth(3)
for y in stride(from: 400, to: 760, by: 14) { ctx.move(to: CGPoint(x: 150, y: y)); ctx.addLine(to: CGPoint(x: 318, y: y + 20)) }
ctx.strokePath(); ctx.restoreGState()

// Lens: mount ring, barrel, focus ring ridges, orange accent, glass.
let c = CGPoint(x: 560, y: 572)
radial([rgb(200, 200, 206), rgb(110, 110, 118)], CGPoint(x: c.x - 60, y: c.y - 80), 300, clip: circle(c, 232))  // mount
linear([rgb(48, 48, 52), rgb(16, 16, 18)], CGPoint(x: 0, y: c.y - 214), CGPoint(x: 0, y: c.y + 214), clip: circle(c, 214))
ctx.saveGState(); ctx.addPath(circle(c, 206)); ctx.addPath(circle(c, 176)); ctx.clip(using: .evenOdd)
ctx.setStrokeColor(rgb(255, 255, 255, 0.10)); ctx.setLineWidth(5)
for k in 0..<72 {
    let a = CGFloat(k) / 72 * 2 * .pi
    ctx.move(to: CGPoint(x: c.x + cos(a) * 176, y: c.y + sin(a) * 176))
    ctx.addLine(to: CGPoint(x: c.x + cos(a) * 206, y: c.y + sin(a) * 206))
}
ctx.strokePath(); ctx.restoreGState()
ctx.saveGState(); ctx.addPath(circle(c, 170)); ctx.setStrokeColor(rgb(255, 149, 0)); ctx.setLineWidth(8); ctx.strokePath(); ctx.restoreGState()
radial([rgb(70, 60, 140), rgb(20, 24, 60), rgb(6, 6, 12)], CGPoint(x: c.x + 30, y: c.y + 40), 160, clip: circle(c, 150))  // glass
radial([rgb(255, 255, 255, 0.55), rgb(255, 255, 255, 0)], CGPoint(x: c.x - 55, y: c.y - 60), 60, clip: circle(c, 150))   // reflection
radial([rgb(120, 220, 255, 0.35), rgb(120, 220, 255, 0)], CGPoint(x: c.x + 60, y: c.y + 65), 40, clip: circle(c, 150))
ctx.saveGState(); ctx.addPath(circle(c, 92)); ctx.setStrokeColor(rgb(255, 255, 255, 0.08)); ctx.setLineWidth(4); ctx.strokePath(); ctx.restoreGState()

// Wi-Fi arcs above the camera: "remote".
ctx.saveGState()
ctx.setStrokeColor(rgb(255, 149, 0)); ctx.setLineCap(.round)
let w = CGPoint(x: 800, y: 270)
for (i, r) in [44.0, 84.0, 124.0].enumerated() {
    ctx.setLineWidth(22 - CGFloat(i) * 2)
    ctx.addArc(center: w, radius: r, startAngle: -.pi * 0.78, endAngle: -.pi * 0.22, clockwise: false)
    ctx.strokePath()
}
ctx.setFillColor(rgb(255, 149, 0)); ctx.addPath(circle(w, 16)); ctx.fillPath()
ctx.restoreGState()

try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path)")
