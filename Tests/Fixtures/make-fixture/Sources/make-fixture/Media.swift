import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Tiny but valid media files, so conversion code (HEIC to JPEG, CAF to M4A) can run on them.
enum Media {
  static func heic(width: Int, height: Int, seed: UInt64, sticker: Bool = false) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let r = CGFloat(seed & 0xFF) / 255, g = CGFloat((seed >> 8) & 0xFF) / 255, b = CGFloat((seed >> 16) & 0xFF) / 255
    if sticker {
      ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
      ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
      ctx.fillEllipse(in: CGRect(x: 4, y: 4, width: width - 8, height: height - 8))
    } else {
      ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
      ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
      ctx.setFillColor(CGColor(srgbRed: 1 - r, green: 1 - g, blue: 1 - b, alpha: 1))
      ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 3))
    }
    let image = ctx.makeImage()!
    let out = NSMutableData()
    let dst = CGImageDestinationCreateWithData(out, UTType.heic.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, image, [kCGImageDestinationLossyCompressionQuality: 0.5] as CFDictionary)
    precondition(CGImageDestinationFinalize(dst), "HEIC encoding failed")
    return out as Data
  }

  /// A one-page PDF written by hand so the bytes never depend on a creation date.
  static func pdf(title: String) -> Data {
    let text = "Synthetic fixture document: \(title)"
    let stream = "BT /F1 14 Tf 40 100 Td (\(text)) Tj ET"
    let objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 420 200] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
      "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    var out = "%PDF-1.4\n"
    var offsets: [Int] = []
    for (i, body) in objects.enumerated() {
      offsets.append(out.utf8.count)
      out += "\(i + 1) 0 obj\n\(body)\nendobj\n"
    }
    let xref = out.utf8.count
    out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    for o in offsets { out += String(format: "%010d 00000 n \n", o) }
    out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    return Data(out.utf8)
  }

  /// Core Audio Format file, 8 kHz mono 16-bit linear PCM, a short two-tone hum.
  static func caf(seconds: Int, seed: UInt64) -> Data {
    let rate = 8000.0
    var d = Data()
    func be<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("caff".utf8)); be(UInt16(1)); be(UInt16(0))
    d.append(contentsOf: Array("desc".utf8)); be(Int64(32))
    be(rate.bitPattern)
    d.append(contentsOf: Array("lpcm".utf8))
    be(UInt32(2))  // little-endian samples
    be(UInt32(2)); be(UInt32(1)); be(UInt32(1)); be(UInt32(16))
    let frames = Int(rate) * seconds
    d.append(contentsOf: Array("data".utf8)); be(Int64(4 + frames * 2))
    be(UInt32(0))  // edit count
    let f1 = 180.0 + Double(seed % 60), f2 = f1 * 1.5
    for i in 0..<frames {
      let t = Double(i) / rate
      let env = min(1, t * 8) * min(1, (Double(seconds) - t) * 8)
      let v = (sin(2 * .pi * f1 * t) * 0.25 + sin(2 * .pi * f2 * t) * 0.1) * env
      let s = Int16(max(-1, min(1, v)) * 32767)
      withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) }
    }
    return d
  }
}
