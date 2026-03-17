#!/usr/bin/env swift

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Configuration

let baseSize = 1024
let outputDir = "Sources/EnviousWispr/Resources"
let iconsetDir = "/tmp/AppIcon.iconset"
let icnsOutput = "\(outputDir)/AppIcon.icns"

// Colors
let deepPurple: (r: CGFloat, g: CGFloat, b: CGFloat) = (0x5B / 255.0, 0x2C / 255.0, 0x8E / 255.0)
let electricBlue: (r: CGFloat, g: CGFloat, b: CGFloat) = (0x21 / 255.0, 0x96 / 255.0, 0xF3 / 255.0)

// MARK: - Drawing

func createBaseIcon(size: Int) -> CGContext? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        print("Failed to create CGContext")
        return nil
    }

    let s = CGFloat(size)

    // Clear background (transparent)
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // --- Rounded rectangle background with gradient ---
    let cornerRadius = s * 0.22
    let inset = s * 0.0 // full bleed
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // Draw gradient (top-left purple to bottom-right blue)
    let gradientColors = [
        CGColor(red: deepPurple.r, green: deepPurple.g, blue: deepPurple.b, alpha: 1.0),
        CGColor(red: electricBlue.r, green: electricBlue.g, blue: electricBlue.b, alpha: 1.0)
    ] as CFArray
    let locations: [CGFloat] = [0.0, 1.0]

    if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: locations) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: s),       // top-left (CG coords: y is flipped)
            end: CGPoint(x: s, y: 0),          // bottom-right
            options: []
        )
    }
    ctx.restoreGState()

    // --- Subtle inner shadow / edge highlight ---
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // Light overlay at top for depth
    let overlayColors = [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.15),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
    ] as CFArray
    if let overlay = CGGradient(colorsSpace: colorSpace, colors: overlayColors, locations: locations) {
        ctx.drawLinearGradient(
            overlay,
            start: CGPoint(x: s / 2, y: s),
            end: CGPoint(x: s / 2, y: s * 0.5),
            options: []
        )
    }
    ctx.restoreGState()

    // --- Draw microphone ---
    drawMicrophone(ctx: ctx, size: s)

    return ctx
}

func drawMicrophone(ctx: CGContext, size s: CGFloat) {
    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 0.95)

    ctx.saveGState()
    ctx.setFillColor(white)
    ctx.setStrokeColor(white)

    // Microphone body (rounded rectangle) - centered
    let micWidth = s * 0.18
    let micHeight = s * 0.28
    let micX = (s - micWidth) / 2
    let micY = s * 0.43 // position from bottom (CG coords)
    let micCorner = micWidth * 0.45

    let micRect = CGRect(x: micX, y: micY, width: micWidth, height: micHeight)
    let micPath = CGPath(roundedRect: micRect, cornerWidth: micCorner, cornerHeight: micCorner, transform: nil)
    ctx.addPath(micPath)
    ctx.fillPath()

    // Microphone head (semicircle on top)
    let headRadius = micWidth / 2
    let headCenterX = s / 2
    let headCenterY = micY + micHeight
    ctx.addArc(center: CGPoint(x: headCenterX, y: headCenterY), radius: headRadius, startAngle: 0, endAngle: .pi, clockwise: false)
    ctx.fillPath()

    // Microphone cradle / arc (U-shape around mic)
    let cradleWidth = s * 0.04
    let cradleRadius = s * 0.16
    let cradleCenterX = s / 2
    let cradleCenterY = micY + micHeight * 0.45

    ctx.setLineWidth(cradleWidth)
    ctx.setLineCap(.round)
    ctx.addArc(
        center: CGPoint(x: cradleCenterX, y: cradleCenterY),
        radius: cradleRadius,
        startAngle: .pi * 0.15,   // right side
        endAngle: .pi * 0.85,     // left side
        clockwise: true            // draw the bottom arc (U-shape)
    )
    ctx.strokePath()

    // Stand (vertical line from cradle bottom)
    let standWidth = s * 0.035
    let standTop = cradleCenterY - cradleRadius * sin(.pi * 0.15) // bottom of cradle arc
    let standBottom = s * 0.24
    let standX = s / 2

    ctx.setLineWidth(standWidth)
    ctx.move(to: CGPoint(x: standX, y: standTop))
    ctx.addLine(to: CGPoint(x: standX, y: standBottom))
    ctx.strokePath()

    // Base (horizontal line at bottom)
    let baseWidth = s * 0.18
    let baseThickness = s * 0.035
    ctx.setLineWidth(baseThickness)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: standX - baseWidth / 2, y: standBottom))
    ctx.addLine(to: CGPoint(x: standX + baseWidth / 2, y: standBottom))
    ctx.strokePath()

    ctx.restoreGState()
}

// MARK: - PNG Export

func savePNG(context: CGContext, to path: String) -> Bool {
    guard let image = context.makeImage() else {
        print("Failed to make CGImage")
        return false
    }
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
        print("Failed to create image destination at \(path)")
        return false
    }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

// MARK: - Main

func main() {
    let fileManager = FileManager.default

    // Ensure output directory exists
    try? fileManager.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

    // Create iconset directory
    try? fileManager.removeItem(atPath: iconsetDir)
    try? fileManager.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

    // Save 1024x1024 base
    let basePath = "/tmp/AppIcon_base_1024.png"
    guard let baseCtx = createBaseIcon(size: baseSize) else {
        print("ERROR: Failed to create base icon")
        exit(1)
    }
    guard savePNG(context: baseCtx, to: basePath) else {
        print("ERROR: Failed to save base PNG")
        exit(1)
    }
    print("Created base icon: \(basePath)")

    // Required icon sizes: (name, pixel size)
    let sizes: [(String, Int)] = [
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

    // For each size, render directly at that resolution for crisp results
    for (name, pixels) in sizes {
        let destPath = "\(iconsetDir)/\(name)"
        if pixels == 1024 {
            // Just copy the base
            try? fileManager.copyItem(atPath: basePath, toPath: destPath)
        } else {
            // Render at target size for sharpness
            guard let ctx = createBaseIcon(size: pixels) else {
                print("ERROR: Failed to create icon at \(pixels)px")
                exit(1)
            }
            guard savePNG(context: ctx, to: destPath) else {
                print("ERROR: Failed to save \(name)")
                exit(1)
            }
        }
        print("  \(name) (\(pixels)x\(pixels))")
    }

    print("\nIconset ready at \(iconsetDir)")
    print("Run: iconutil --convert icns \(iconsetDir) -o \(icnsOutput)")
}

main()
