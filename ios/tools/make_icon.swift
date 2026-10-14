// Renders the iOS app icon (1024x1024, opaque) with CoreGraphics:
//   swift ios/tools/make_icon.swift ios/Assets.xcassets/AppIcon.appiconset/icon-1024.png
// Original artwork in the app's setup-screen palette; no game or EA assets.
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                    bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
  CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
          blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Background: teal (top left) to deep navy (bottom right), like the setup screen.
let background = CGGradient(colorsSpace: space,
                            colors: [rgb(0x3F8F86), rgb(0x22495A), rgb(0x141F33)] as CFArray,
                            locations: [0, 0.55, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0),
                       options: [])
// Soft light from the top left.
let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 260, y: 820), startRadius: 0,
                       endCenter: CGPoint(x: 260, y: 820), endRadius: 620, options: [])

// Skateboard deck seen from below, tilted, with trucks and wheels.
ctx.saveGState()
ctx.translateBy(x: size / 2 - 40, y: size / 2)
ctx.rotate(by: -.pi / 5)
let deckW: CGFloat = 300, deckH: CGFloat = 900
let deck = CGRect(x: -deckW / 2, y: -deckH / 2, width: deckW, height: deckH)
let deckPath = CGPath(roundedRect: deck, cornerWidth: deckW / 2, cornerHeight: deckW / 2,
                      transform: nil)
ctx.setShadow(offset: CGSize(width: 18, height: -26), blur: 40, color: rgb(0x000000, 0.45))
ctx.addPath(deckPath)
ctx.setFillColor(rgb(0xD4EB0C))
ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)
// Darker kick bands at nose and tail.
ctx.saveGState()
ctx.addPath(deckPath)
ctx.clip()
for y in [deck.minY, deck.maxY - 130] {
  ctx.setFillColor(rgb(0xA9BC00))
  ctx.fill(CGRect(x: deck.minX, y: y, width: deckW, height: 130))
}
ctx.restoreGState()
// Trucks and wheels.
for truckY in [-deckH * 0.3, deckH * 0.3] {
  ctx.setFillColor(rgb(0x1C2430))
  ctx.fill(CGRect(x: -deckW * 0.62, y: truckY - 22, width: deckW * 1.24, height: 44))
  for side: CGFloat in [-1, 1] {
    let wheel = CGRect(x: side * deckW * 0.62 - 42, y: truckY - 52, width: 84, height: 104)
    ctx.addPath(CGPath(roundedRect: wheel, cornerWidth: 30, cornerHeight: 30, transform: nil))
    ctx.setFillColor(rgb(0xF4EFE3))
    ctx.fillPath()
  }
}
ctx.restoreGState()

// The "3".
let font = NSFont.systemFont(ofSize: 640, weight: .black)
let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
let text = NSAttributedString(string: "3", attributes: [
  .font: italic, .foregroundColor: NSColor.white,
])
let line = CTLineCreateWithAttributedString(text)
let bounds = CTLineGetImageBounds(line, ctx)
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgb(0x000000, 0.5))
ctx.textPosition = CGPoint(x: size / 2 - bounds.midX + 40, y: size / 2 - bounds.midY - 10)
CTLineDraw(line, ctx)

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
