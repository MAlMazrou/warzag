// Builds the app icon's .iconset for iconutil from App/AppIcon.png (1024x1024, full bleed): the artwork clipped to
// Apple's 1024-point icon grid (an 824-point rounded body with a soft shadow), at every size the .icns needs.
//
//   swift App/make-icon.swift <artwork.png> <AppIcon.iconset>      (App/make-app.sh runs it)
import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <artwork.png> <AppIcon.iconset>\n".utf8))
    exit(2)
}
let artworkURL = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
guard let source = CGImageSourceCreateWithURL(artworkURL as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("make-icon.swift: cannot read \(artworkURL.path)\n".utf8))
    exit(1)
}
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The artwork's own background (its top-left pixel), so transparent edges blend into the body.
func backgroundColor(of image: CGImage) -> CGColor {
    var pixel: [UInt8] = [0, 0, 0, 0]
    let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: -CGFloat(image.height - 1), width: CGFloat(image.width),
                                   height: CGFloat(image.height)))
    return CGColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255,
                   alpha: 1)
}
let background = backgroundColor(of: artwork)

/// One square PNG on Apple's 1024-point icon grid.
func render(pixels: Int) -> Data {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.interpolationQuality = .high

    let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let body = CGPath(roundedRect: bodyRect, cornerWidth: 185, cornerHeight: 185, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, alpha: 0.30))
    context.addPath(body)
    context.setFillColor(background)
    context.fillPath()
    context.restoreGState()

    // The artwork, a little larger than the body (its own margins are generous), clipped to the body.
    context.saveGState()
    context.addPath(body)
    context.clip()
    context.setFillColor(background)
    context.fill(bodyRect)
    let zoom: CGFloat = 1.12
    let side = bodyRect.width * zoom
    context.draw(artwork, in: CGRect(x: bodyRect.midX - side / 2, y: bodyRect.midY - side / 2, width: side, height: side))
    context.restoreGState()

    // A hairline edge so the light body reads on light Docks and desktops.
    context.addPath(body)
    context.setStrokeColor(color(0x000000, alpha: 0.10))
    context.setLineWidth(3)
    context.strokePath()

    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    return bitmap.representation(using: .png, properties: [:])!
}

// iconutil's names: icon_<points>x<points>[@2x].png
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(pixels: points * scale).write(to: output.appending(path: name))
    }
}
