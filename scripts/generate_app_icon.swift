#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvasSize = 1024
let outputURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/AppIconSource.png")
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    let red = CGFloat((hex >> 16) & 0xff) / 255
    let green = CGFloat((hex >> 8) & 0xff) / 255
    let blue = CGFloat(hex & 0xff) / 255
    return CGColor(colorSpace: colorSpace, components: [red, green, blue, alpha])!
}

func gradient(_ colors: [CGColor], locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
}

guard let context = CGContext(
    data: nil,
    width: canvasSize,
    height: canvasSize,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Unable to create sRGB bitmap context")
}

context.interpolationQuality = .high
context.clear(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))

let tileRect = CGRect(x: 52, y: 52, width: 920, height: 920)
let tilePath = CGPath(
    roundedRect: tileRect,
    cornerWidth: 216,
    cornerHeight: 216,
    transform: nil
)

context.saveGState()
context.addPath(tilePath)
context.clip()
context.drawLinearGradient(
    gradient([color(0x14191d), color(0x343a3f)], locations: [0, 1]),
    start: CGPoint(x: 512, y: 52),
    end: CGPoint(x: 512, y: 972),
    options: []
)

// A restrained highlight gives the graphite tile depth without adding fine detail.
context.drawLinearGradient(
    gradient([color(0xffffff, alpha: 0), color(0xffffff, alpha: 0.085)], locations: [0.35, 1]),
    start: CGPoint(x: 190, y: 180),
    end: CGPoint(x: 860, y: 930),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
)
context.restoreGState()

let rimPath = CGPath(
    roundedRect: tileRect.insetBy(dx: 9, dy: 9),
    cornerWidth: 207,
    cornerHeight: 207,
    transform: nil
)
context.addPath(rimPath)
context.setStrokeColor(color(0xffffff, alpha: 0.10))
context.setLineWidth(9)
context.strokePath()

let parcelRect = CGRect(x: 214, y: 232, width: 596, height: 500)
let parcelPath = CGPath(
    roundedRect: parcelRect,
    cornerWidth: 112,
    cornerHeight: 112,
    transform: nil
)

context.saveGState()
context.setShadow(
    offset: CGSize(width: 0, height: -24),
    blur: 42,
    color: color(0x000000, alpha: 0.42)
)
context.addPath(parcelPath)
context.setFillColor(color(0x007e77))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(parcelPath)
context.clip()
context.drawLinearGradient(
    gradient([color(0x008f84), color(0x20c9b0)], locations: [0, 1]),
    start: CGPoint(x: 512, y: 232),
    end: CGPoint(x: 512, y: 732),
    options: []
)

let lidRect = CGRect(x: parcelRect.minX, y: 586, width: parcelRect.width, height: 164)
context.drawLinearGradient(
    gradient([color(0x1ab9a5), color(0x43ddc0)], locations: [0, 1]),
    start: CGPoint(x: 512, y: lidRect.minY),
    end: CGPoint(x: 512, y: lidRect.maxY),
    options: []
)

context.setStrokeColor(color(0x006d69, alpha: 0.72))
context.setLineWidth(12)
context.move(to: CGPoint(x: 226, y: 586))
context.addLine(to: CGPoint(x: 798, y: 586))
context.strokePath()
context.restoreGState()

context.addPath(parcelPath)
context.setStrokeColor(color(0x5ce6d0, alpha: 0.48))
context.setLineWidth(10)
context.strokePath()

let arrow = CGMutablePath()
arrow.move(to: CGPoint(x: 512, y: 754))
arrow.addQuadCurve(to: CGPoint(x: 330, y: 574), control: CGPoint(x: 506, y: 748))
arrow.addQuadCurve(to: CGPoint(x: 354, y: 546), control: CGPoint(x: 324, y: 558))
arrow.addLine(to: CGPoint(x: 424, y: 546))
arrow.addLine(to: CGPoint(x: 424, y: 390))
arrow.addQuadCurve(to: CGPoint(x: 458, y: 356), control: CGPoint(x: 424, y: 356))
arrow.addLine(to: CGPoint(x: 566, y: 356))
arrow.addQuadCurve(to: CGPoint(x: 600, y: 390), control: CGPoint(x: 600, y: 356))
arrow.addLine(to: CGPoint(x: 600, y: 546))
arrow.addLine(to: CGPoint(x: 670, y: 546))
arrow.addQuadCurve(to: CGPoint(x: 694, y: 574), control: CGPoint(x: 700, y: 558))
arrow.addQuadCurve(to: CGPoint(x: 512, y: 754), control: CGPoint(x: 518, y: 748))
arrow.closeSubpath()

context.saveGState()
context.setShadow(
    offset: CGSize(width: 0, height: -12),
    blur: 18,
    color: color(0x005a55, alpha: 0.40)
)
context.addPath(arrow)
context.setFillColor(color(0xf7fbfa))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(arrow)
context.clip()
context.drawLinearGradient(
    gradient([color(0xddebe8), color(0xffffff)], locations: [0, 0.72]),
    start: CGPoint(x: 512, y: 350),
    end: CGPoint(x: 512, y: 760),
    options: []
)
context.restoreGState()

let accentCenter = CGPoint(x: 742, y: 666)
context.saveGState()
context.setShadow(
    offset: CGSize(width: 0, height: -6),
    blur: 12,
    color: color(0x6a4211, alpha: 0.45)
)
context.setFillColor(color(0xf2b84b))
context.fillEllipse(in: CGRect(x: accentCenter.x - 43, y: accentCenter.y - 43, width: 86, height: 86))
context.restoreGState()

context.setFillColor(color(0xffe39b, alpha: 0.78))
context.fillEllipse(in: CGRect(x: accentCenter.x - 18, y: accentCenter.y + 8, width: 31, height: 21))

guard let image = context.makeImage() else {
    fatalError("Unable to create icon image")
}

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
guard let destination = CGImageDestinationCreateWithURL(
    outputURL as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
) else {
    fatalError("Unable to create PNG destination")
}

CGImageDestinationAddImage(destination, image, [
    kCGImagePropertyDPIWidth: 144,
    kCGImagePropertyDPIHeight: 144,
    kCGImagePropertyColorModel: kCGImagePropertyColorModelRGB
] as CFDictionary)

guard CGImageDestinationFinalize(destination) else {
    fatalError("Unable to write icon PNG")
}

print(outputURL.path)
