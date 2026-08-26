#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate_app_icon.swift OUTPUT_PNG\n", stderr)
    exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let canvasSize = NSSize(width: 1024, height: 1024)
let image = NSImage(size: canvasSize)

image.lockFocus()

NSColor.clear.setFill()
NSRect(origin: .zero, size: canvasSize).fill()

let iconRect = NSRect(x: 76, y: 76, width: 872, height: 872)
let iconPath = NSBezierPath(roundedRect: iconRect, xRadius: 210, yRadius: 210)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(calibratedWhite: 0.04, alpha: 0.38)
shadow.shadowBlurRadius = 44
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.set()
NSColor(calibratedRed: 0.05, green: 0.16, blue: 0.42, alpha: 1).setFill()
iconPath.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
iconPath.addClip()
let background = NSGradient(colors: [
    NSColor(calibratedRed: 0.06, green: 0.26, blue: 0.72, alpha: 1),
    NSColor(calibratedRed: 0.03, green: 0.62, blue: 0.77, alpha: 1)
])!
background.draw(in: iconRect, angle: -45)

let glowRect = NSRect(x: 210, y: 500, width: 720, height: 620)
let glow = NSGradient(colors: [
    NSColor(calibratedWhite: 1, alpha: 0.24),
    NSColor(calibratedWhite: 1, alpha: 0)
])!
glow.draw(in: NSBezierPath(ovalIn: glowRect), relativeCenterPosition: .zero)
NSGraphicsContext.restoreGraphicsState()

NSColor(calibratedWhite: 1, alpha: 0.18).setStroke()
iconPath.lineWidth = 7
iconPath.stroke()

let glyph = "한" as NSString
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 430, weight: .bold),
    .foregroundColor: NSColor.white,
    .paragraphStyle: paragraph,
    .shadow: {
        let textShadow = NSShadow()
        textShadow.shadowColor = NSColor(calibratedWhite: 0.02, alpha: 0.28)
        textShadow.shadowBlurRadius = 22
        textShadow.shadowOffset = NSSize(width: 0, height: -8)
        return textShadow
    }()
]
let glyphSize = glyph.size(withAttributes: attributes)
let glyphRect = NSRect(
    x: iconRect.midX - glyphSize.width / 2,
    y: iconRect.midY - glyphSize.height / 2 + 14,
    width: glyphSize.width,
    height: glyphSize.height
)
glyph.draw(in: glyphRect, withAttributes: attributes)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("failed to render app icon\n", stderr)
    exit(1)
}

try png.write(to: outputURL, options: .atomic)
