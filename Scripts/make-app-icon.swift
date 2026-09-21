#!/usr/bin/env swift
//
//  make-app-icon.swift — Claude Cockpit app icon generator
//
//  Draws the whole icon programmatically (AppKit / NSBezierPath, no bitmap
//  assets) and writes icon_16/32/64/128/256/512/1024.png into
//  ClaudeCockpit/Resources/Assets.xcassets/AppIcon.appiconset/.
//
//  Motif: a cockpit gauge. A 240° segmented ring sits on a graphite squircle;
//  the first 70 % of the sweep burns in Claude's warm terracotta, the tail of
//  the arc turns emerald (the RTK savings), and a slim needle points at the
//  70 % mark from a glowing hub.
//
//  Usage: ./Scripts/make-app-icon.swift
//
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Palette
// ─────────────────────────────────────────────────────────────────────────────

func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha)
}

let bgTop = hex(0x2A2833)
let bgBottom = hex(0x1C1B22)
let accentDeep = hex(0xC85F3C)   // start of the warm sweep
let accent = hex(0xD97757)       // Claude terracotta
let accentHi = hex(0xF0A080)     // highlight end of the sweep
let emerald = hex(0x2FBF8F)
let emeraldHi = hex(0x5BD8AC)
let trackColor = hex(0x433F4E)

func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    let t = min(max(t, 0), 1)
    let ca = a.usingColorSpace(.sRGB)!, cb = b.usingColorSpace(.sRGB)!
    return NSColor(srgbRed: ca.redComponent + (cb.redComponent - ca.redComponent) * t,
                   green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * t,
                   blue: ca.blueComponent + (cb.blueComponent - ca.blueComponent) * t,
                   alpha: ca.alphaComponent + (cb.alphaComponent - ca.alphaComponent) * t)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Geometry
// ─────────────────────────────────────────────────────────────────────────────

/// Gauge parameterisation: a single mapping from progress `t` ∈ [0, 1] to the
/// angle on the dial, shared by the arc segments, the needle and the tick — so
/// the needle can never drift away from the mark it points at.
let gaugeStartDeg: CGFloat = 210     // lower-left end of the sweep
let gaugeSweepDeg: CGFloat = 240     // clockwise, over the top
func gaugeAngle(_ t: CGFloat) -> CGFloat { gaugeStartDeg - gaugeSweepDeg * t }

let fillEnd: CGFloat = 0.70          // where the warm sweep stops (needle mark)
let emeraldStart: CGFloat = 0.855    // savings segment at the tail of the dial

func point(_ center: NSPoint, _ radius: CGFloat, _ degrees: CGFloat) -> NSPoint {
    let r = degrees * .pi / 180
    return NSPoint(x: center.x + cos(r) * radius, y: center.y + sin(r) * radius)
}

/// Continuous-curvature squircle (superellipse) — visually the macOS Big Sur
/// icon mask, softer than `NSBezierPath(roundedRect:)`'s circular corners.
func squircle(in rect: NSRect, samples: Int = 512) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let n: CGFloat = 5.0
    let e = 2 / n
    for i in 0..<samples {
        let theta = CGFloat(i) / CGFloat(samples) * 2 * .pi
        let ct = cos(theta), st = sin(theta)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), e)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), e)
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

/// Strokes the dial between two progress values, colouring each small segment
/// from `colorAt` — an angular gradient approximated by interpolation.
/// Segments are opaque, butt-capped and overlap slightly so no seam shows.
func strokeDial(center: NSPoint, radius: CGFloat, width: CGFloat,
                from t0: CGFloat, to t1: CGFloat, steps: Int,
                colorAt: (CGFloat) -> NSColor) {
    let steps = max(steps, 1)
    for i in 0..<steps {
        let tA = t0 + (t1 - t0) * CGFloat(i) / CGFloat(steps)
        let tB = t0 + (t1 - t0) * CGFloat(i + 1) / CGFloat(steps)
        let overlap: CGFloat = (i == steps - 1) ? 0 : 0.7
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius,
                       startAngle: gaugeAngle(tA),
                       endAngle: gaugeAngle(tB) - overlap,
                       clockwise: true)
        path.lineWidth = width
        path.lineCapStyle = .butt
        colorAt((tA + tB) / 2).setStroke()
        path.stroke()
    }
    // Round the two ends with discs rather than round caps on every segment
    // (round caps would double-darken at each join).
    for (t, c) in [(t0, colorAt(t0)), (t1, colorAt(t1))] {
        let p = point(center, radius, gaugeAngle(t))
        c.setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - width / 2, y: p.y - width / 2,
                                    width: width, height: width)).fill()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Render
// ─────────────────────────────────────────────────────────────────────────────

func render(_ size: Int) -> Data {
    let s = CGFloat(size)

    // Draw into a bitmap of EXACTLY `size`×`size` pixels. NSImage.lockFocus()
    // would render at the screen's backing scale (2× on Retina) and double
    // every icon, which the asset catalog rejects.
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: s, height: s)   // 1 point == 1 pixel

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // Level of detail. Below 48 px the fine work turns to mud, so the icon
    // simplifies: flat arc colours, no vignette, no hairline ring, no glow.
    let rich = size >= 128          // glow, edge highlight
    let detailed = size >= 64       // vignette, hairline ring, angular gradient

    // The rounded square fills 82 % of the canvas; the margin holds the shadow.
    let side = s * 0.82
    let square = NSRect(x: (s - side) / 2, y: (s - side) / 2, width: side, height: side)
    let body = squircle(in: square)

    // 1 ─ Soft drop shadow, kept inside the transparent margin.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = side * 0.045
    shadow.shadowOffset = NSSize(width: 0, height: -side * 0.018)  // y-up context
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.set()
    bgBottom.setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 2 ─ Graphite background gradient.
    NSGradient(colors: [bgBottom, bgTop])!.draw(in: body, angle: 90)

    // Dropped below the geometric centre: the 240° sweep reaches a full radius
    // up and only half a radius down, so the dial's bounding box needs the
    // offset to sit optically centred in the square.
    let center = NSPoint(x: square.midX, y: square.midY - side * 0.065)
    let radius = side * 0.315
    let arcWidth = (size <= 32 ? 0.140 : 0.105) * side

    NSGraphicsContext.saveGraphicsState()
    body.addClip()

    // 3 ─ Radial vignette for depth.
    if detailed {
        NSGradient(colors: [NSColor.black.withAlphaComponent(0.0),
                            NSColor.black.withAlphaComponent(0.34)])!
            .draw(fromCenter: center, radius: side * 0.26,
                  toCenter: center, radius: side * 0.66,
                  options: .drawsAfterEndingLocation)
    }

    // 4 ─ Faint concentric hairline inside the dial.
    if detailed {
        let ringRadius = radius - arcWidth * 0.5 - side * 0.050
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - ringRadius, y: center.y - ringRadius,
                                               width: ringRadius * 2, height: ringRadius * 2))
        ring.lineWidth = max(side * 0.006, 0.75)
        NSColor.white.withAlphaComponent(0.085).setStroke()
        ring.stroke()
    }

    // 5 ─ Dim track: the whole 240° sweep.
    strokeDial(center: center, radius: radius, width: arcWidth,
               from: 0, to: 1, steps: 1) { _ in trackColor }

    // 6 ─ Warm glow bleeding under the lit part of the dial.
    if rich {
        let glow = NSBezierPath()
        glow.appendArc(withCenter: center, radius: radius,
                       startAngle: gaugeAngle(0), endAngle: gaugeAngle(fillEnd), clockwise: true)
        glow.lineWidth = arcWidth * 1.15
        glow.lineCapStyle = .round
        NSGraphicsContext.saveGraphicsState()
        let g = NSShadow()
        g.shadowBlurRadius = side * 0.045
        g.shadowOffset = .zero
        g.shadowColor = accent.withAlphaComponent(0.50)
        g.set()
        accent.withAlphaComponent(0.12).setStroke()
        glow.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    // 7 ─ The lit sweep: deep terracotta warming into the highlight.
    if detailed {
        strokeDial(center: center, radius: radius, width: arcWidth,
                   from: 0, to: fillEnd, steps: 96) { t in
            mix(accentDeep, accentHi, min(t / fillEnd, 1))
        }
    } else {
        strokeDial(center: center, radius: radius, width: arcWidth,
                   from: 0, to: fillEnd, steps: 1) { _ in accent }
    }

    // 8 ─ Emerald tail: the savings headroom at the end of the dial.
    if detailed {
        strokeDial(center: center, radius: radius, width: arcWidth,
                   from: emeraldStart, to: 1, steps: 16) { t in
            mix(emerald, emeraldHi, (t - emeraldStart) / (1 - emeraldStart))
        }
    } else {
        strokeDial(center: center, radius: radius, width: arcWidth,
                   from: emeraldStart, to: 1, steps: 1) { _ in emerald }
    }

    // 9 ─ Needle, pointing exactly at the 70 % mark.
    let theta = gaugeAngle(fillEnd)
    let rad = theta * .pi / 180
    let dir = NSPoint(x: cos(rad), y: sin(rad))
    let perp = NSPoint(x: -sin(rad), y: cos(rad))
    let needleLength = radius - arcWidth * (size <= 32 ? 0.55 : 0.68)
    let needleHalf = max(side * 0.023, size <= 16 ? 0.70 : 0.55)
    let tailLength = side * 0.050

    func offset(_ p: NSPoint, _ v: NSPoint, _ k: CGFloat) -> NSPoint {
        NSPoint(x: p.x + v.x * k, y: p.y + v.y * k)
    }

    let needle = NSBezierPath()
    needle.move(to: offset(center, dir, needleLength))
    needle.line(to: offset(offset(center, dir, side * 0.02), perp, needleHalf))
    needle.line(to: offset(center, dir, -tailLength))
    needle.line(to: offset(offset(center, dir, side * 0.02), perp, -needleHalf))
    needle.close()
    if detailed {
        NSGradient(colors: [hex(0xFFE9DC), accentHi])!.draw(in: needle, angle: theta + 90)
    } else {
        hex(0xFFE9DC).setFill()
        needle.fill()
    }

    // 10 ─ Glowing hub.
    // The floor keeps the hub from vanishing, the cap keeps it from swallowing
    // the dial. At 16 px the cap is tighter still: a hub big enough to see
    // would absorb the needle, and the needle is the better cue to keep.
    let hubR = min(max(side * 0.048, 0.9), radius * (size <= 16 ? 0.16 : 0.24))
    if rich {
        NSGradient(colors: [accentHi.withAlphaComponent(0.38),
                            accentHi.withAlphaComponent(0.0)])!
            .draw(fromCenter: center, radius: hubR * 0.7,
                  toCenter: center, radius: hubR * 3.0, options: [])
    }
    let hubRect = NSRect(x: center.x - hubR, y: center.y - hubR, width: hubR * 2, height: hubR * 2)
    let hub = NSBezierPath(ovalIn: hubRect)
    if detailed {
        // Dark rim so the hub reads as a separate part from the needle.
        bgBottom.setFill()
        NSBezierPath(ovalIn: hubRect.insetBy(dx: -max(side * 0.010, 0.6),
                                             dy: -max(side * 0.010, 0.6))).fill()
    }
    if detailed {
        NSGraphicsContext.saveGraphicsState()
        hub.addClip()
        NSGradient(colors: [accent, hex(0xFFEFE4)])!.draw(in: hub, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
    } else {
        accentHi.setFill()
        hub.fill()
    }

    NSGraphicsContext.restoreGraphicsState()   // end body clip

    // 11 ─ Inner highlight along the top edge of the square.
    if rich {
        let lw = max(side * 0.010, 1)
        let ringPath = NSBezierPath()
        ringPath.append(squircle(in: square))
        ringPath.append(squircle(in: square.insetBy(dx: lw, dy: lw)))
        ringPath.windingRule = .evenOdd
        NSGraphicsContext.saveGraphicsState()
        ringPath.addClip()
        let topBand = NSRect(x: square.minX, y: square.maxY - side * 0.34,
                             width: side, height: side * 0.34)
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.0),
                            NSColor.white.withAlphaComponent(0.26)])!
            .draw(in: topBand, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Output
// ─────────────────────────────────────────────────────────────────────────────

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("ClaudeCockpit/Resources/Assets.xcassets/AppIcon.appiconset")

let expectedSuffix = "ClaudeCockpit/Resources/Assets.xcassets/AppIcon.appiconset"
guard assets.path.hasSuffix(expectedSuffix),
      FileManager.default.fileExists(atPath: assets.path) else {
    FileHandle.standardError.write(Data("✗ appiconset not found at \(assets.path)\n".utf8))
    exit(1)
}
print("→ \(assets.path)")

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let url = assets.appendingPathComponent("icon_\(size).png")
    try! render(size).write(to: url)
    print("wrote \(url.lastPathComponent)")
}
print("✅ Claude Cockpit icon set generated")
