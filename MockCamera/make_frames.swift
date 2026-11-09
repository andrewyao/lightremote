// Generates the mock camera's live view frames: swift MockCamera/make_frames.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "MockCamera/frames")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let w = 640, h = 424, count = 24
for i in 0..<count {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let t = Double(i) / Double(count)
    ctx.setFillColor(CGColor(red: 0.12, green: 0.16 + 0.1 * t, blue: 0.24, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    // Horizon + a moving "sun" so motion is obvious.
    ctx.setFillColor(CGColor(red: 0.2, green: 0.35, blue: 0.2, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 3))
    let x = 40 + Double(w - 80) * t
    ctx.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.3, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: x - 30, y: Double(h) * 0.6, width: 60, height: 60))
    // Rule-of-thirds grid.
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.25))
    for k in 1...2 {
        ctx.stroke(CGRect(x: w * k / 3, y: 0, width: 0, height: h))
        ctx.stroke(CGRect(x: 0, y: h * k / 3, width: w, height: 0))
    }
    let url = outDir.appendingPathComponent(String(format: "frame%02d.jpg", i))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
    CGImageDestinationFinalize(dest)
}
print("wrote \(count) frames to \(outDir.path)")
