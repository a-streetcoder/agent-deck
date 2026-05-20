#!/usr/bin/env swift
// Generates background.png (800x400) and background@2x.png (1600x800)
// for the Agent Deck DMG installer.
//
// Run from the repo root:
//   swift scripts/dmg/generate-background.swift
//
// The output PNGs are committed; CI does not regenerate them.
// Replace with a real designed background by overwriting the PNGs.

import Foundation
import AppKit
import CoreText

let baseSize = CGSize(width: 800, height: 400)

struct Layout {
    static let appCenter = CGPoint(x: 180, y: 160)   // matches create-dmg --icon position
    static let dropCenter = CGPoint(x: 620, y: 160)  // matches create-dmg --app-drop-link position
}

func renderBackground(scale: CGFloat, to url: URL) throws {
    let pixelSize = CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: Int(pixelSize.width),
        height: Int(pixelSize.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "dmg-bg", code: 1)
    }

    ctx.scaleBy(x: scale, y: scale)

    // Soft vertical gradient — top slightly lighter than bottom.
    let topColor   = CGColor(red: 0.13, green: 0.13, blue: 0.16, alpha: 1)
    let bottomColor = CGColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)
    let gradient = CGGradient(
        colorsSpace: cs,
        colors: [topColor, bottomColor] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: baseSize.height),
        end: CGPoint(x: 0, y: 0),
        options: []
    )

    // Subtle accent halo behind the app slot.
    let halo = CGMutablePath()
    halo.addArc(
        center: Layout.appCenter,
        radius: 110,
        startAngle: 0,
        endAngle: .pi * 2,
        clockwise: false
    )
    ctx.saveGState()
    ctx.addPath(halo)
    ctx.clip()
    let haloGrad = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 0.45, green: 0.55, blue: 0.95, alpha: 0.18),
            CGColor(red: 0.45, green: 0.55, blue: 0.95, alpha: 0.0)
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        haloGrad,
        startCenter: Layout.appCenter, startRadius: 0,
        endCenter: Layout.appCenter, endRadius: 110,
        options: []
    )
    ctx.restoreGState()

    // Wordmark — "Agent Deck" centred near the top.
    let wordmarkText = NSAttributedString(
        string: "Agent Deck",
        attributes: [
            .font: NSFont.systemFont(ofSize: 30, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.95),
            .kern: 1.4
        ]
    )
    drawText(wordmarkText, in: ctx, center: CGPoint(x: baseSize.width / 2, y: baseSize.height - 60))

    // Instruction text below the wordmark.
    let hintText = NSAttributedString(
        string: "Drag to Applications to install",
        attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.7),
            .kern: 0.3
        ]
    )
    drawText(hintText, in: ctx, center: CGPoint(x: baseSize.width / 2, y: baseSize.height - 95))

    // Arrow from app slot to Applications slot.
    drawArrow(
        from: CGPoint(x: Layout.appCenter.x + 80, y: Layout.appCenter.y),
        to: CGPoint(x: Layout.dropCenter.x - 80, y: Layout.dropCenter.y),
        in: ctx
    )

    guard let cgImage = ctx.makeImage() else {
        throw NSError(domain: "dmg-bg", code: 2)
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = baseSize
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "dmg-bg", code: 3)
    }
    try data.write(to: url)
}

func drawText(_ string: NSAttributedString, in ctx: CGContext, center: CGPoint) {
    let line = CTLineCreateWithAttributedString(string)
    let bounds = CTLineGetImageBounds(line, ctx)
    let origin = CGPoint(
        x: center.x - bounds.width / 2 - bounds.origin.x,
        y: center.y - bounds.height / 2 - bounds.origin.y
    )
    ctx.textPosition = origin
    CTLineDraw(line, ctx)
}

func drawArrow(from start: CGPoint, to end: CGPoint, in ctx: CGContext) {
    let lineColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.45)
    ctx.setStrokeColor(lineColor)
    ctx.setFillColor(lineColor)
    ctx.setLineWidth(2)
    ctx.setLineCap(.round)

    // Dashed shaft, stops 12pt before the head so it joins cleanly.
    ctx.saveGState()
    ctx.setLineDash(phase: 0, lengths: [4, 6])
    ctx.move(to: start)
    let shaftEnd = CGPoint(x: end.x - 12, y: end.y)
    ctx.addLine(to: shaftEnd)
    ctx.strokePath()
    ctx.restoreGState()

    // Solid filled arrowhead.
    let headSize: CGFloat = 14
    ctx.beginPath()
    ctx.move(to: end)
    ctx.addLine(to: CGPoint(x: end.x - headSize, y: end.y + headSize * 0.55))
    ctx.addLine(to: CGPoint(x: end.x - headSize, y: end.y - headSize * 0.55))
    ctx.closePath()
    ctx.fillPath()
}

// MARK: - Entry point

let outputDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("scripts/dmg")

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

try renderBackground(scale: 1, to: outputDir.appendingPathComponent("background.png"))
try renderBackground(scale: 2, to: outputDir.appendingPathComponent("background@2x.png"))

print("Wrote background.png and background@2x.png to scripts/dmg/")
