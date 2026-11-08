import FixtureKit
import Foundation
import LinkPresentation

/// Encoders for the blob columns: attributedBody, message_summary_info, payload_data and
/// attachment.user_info.
enum Bodies {
  private static let urlPattern = try! NSRegularExpression(pattern: "https?://[^\\s“”\"]+")

  /// Builds the attributed string Messages would store for the given parts. Part indices are
  /// the original ones, so a partly unsent message keeps index 0 for what is left.
  static func attributed(_ parts: [(index: Int, part: Part)], atts: [AttDef]) -> NSMutableAttributedString {
    let out = NSMutableAttributedString()
    for (index, part) in parts {
      let start = out.length
      let piece = NSMutableAttributedString(string: part.bodyString)
      let all = NSRange(location: 0, length: piece.length)
      piece.addAttribute(IMKey.part, value: NSNumber(value: index), range: all)
      piece.addAttribute(IMKey.writingDirection, value: "-1" as NSString, range: all)
      if let a = part.attachment {
        let att = atts[a]
        piece.addAttribute(IMKey.fileTransfer, value: att.guid as NSString, range: all)
        piece.addAttribute(IMKey.filename, value: att.transferName as NSString, range: all)
        if let w = att.width, let h = att.height {
          piece.addAttribute(IMKey.mediaWidth, value: NSNumber(value: Double(w)), range: all)
          piece.addAttribute(IMKey.mediaHeight, value: NSNumber(value: Double(h)), range: all)
        }
        if let t = att.transcript {
          piece.addAttribute(IMKey.audioTranscription, value: t as NSString, range: all)
        }
      } else if let s = part.text {
        let ns = s as NSString
        for m in urlPattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
          if let url = NSURL(string: ns.substring(with: m.range)) {
            piece.addAttribute(IMKey.link, value: url, range: m.range)
          }
        }
        for mention in part.mentions {
          let r = ns.range(of: mention.text)
          if r.location != NSNotFound { piece.addAttribute(IMKey.mention, value: mention.handle as NSString, range: r) }
        }
        for b in part.bold {
          let r = ns.range(of: b)
          if r.location != NSNotFound { piece.addAttribute(IMKey.bold, value: NSNumber(value: 1), range: r) }
        }
      }
      _ = start
      out.append(piece)
    }
    return out
  }

  /// NSArchiver typedstream. `immutable` archives an NSAttributedString instead of the
  /// NSMutableAttributedString most rows use; real databases contain both class names.
  static func archive(_ s: NSMutableAttributedString, immutable: Bool) -> Data {
    let root: NSAttributedString = immutable ? (s.copy() as! NSAttributedString) : s
    return NSArchiver.archivedData(withRootObject: root)
  }

  static func archiveText(_ text: String, part: Int = 0, immutable: Bool = true) -> Data {
    archive(attributed([(part, .t(text))], atts: []), immutable: immutable)
  }

  static func utf16Length(_ s: String) -> Int { (s as NSString).length }

  private static func plist(_ obj: NSDictionary) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: obj, format: .binary, options: 0)
  }

  private static func ranges(_ lengths: [Int]) -> NSDictionary {
    let otr = NSMutableDictionary()
    var lo = 0
    for (i, le) in lengths.enumerated() {
      let r = NSMutableDictionary()
      r["lo"] = NSNumber(value: lo)
      r["le"] = NSNumber(value: le)
      otr["\(i)"] = r
      lo += le
    }
    return otr
  }

  /// Edit history: `otr` original ranges, `ec` versions of part 0 (oldest first, `d` in Apple
  /// epoch seconds, `t` a typedstream of that version), `ep` edited parts.
  static func editSummary(history: [(ns: Int64, text: String)]) -> Data {
    let root = NSMutableDictionary()
    root["otr"] = ranges([utf16Length(history[0].text)])
    let versions = NSMutableArray()
    for v in history {
      let e = NSMutableDictionary()
      e["d"] = NSNumber(value: v.ns / 1_000_000_000)
      e["t"] = archiveText(v.text) as NSData
      versions.add(e)
    }
    let ec = NSMutableDictionary()
    ec["0"] = versions
    root["ec"] = ec
    root["ep"] = [NSNumber(value: 0)] as NSArray
    return plist(root)
  }

  /// Unsend record: `otr` with every original part, `rp` the retracted part indices.
  static func unsendSummary(partLengths: [Int], retracted: [Int]) -> Data {
    let root = NSMutableDictionary()
    root["otr"] = ranges(partLengths)
    root["rp"] = retracted.map { NSNumber(value: $0) } as NSArray
    return plist(root)
  }

  /// URL balloon payload: an NSKeyedArchiver archive whose root dictionary holds an
  /// LPLinkMetadata under `richLinkMetadata`.
  static func linkPayload(url: String, title: String, summary: String, site: String) -> Data {
    let md = LPLinkMetadata()
    md.originalURL = URL(string: url)
    md.url = URL(string: url)
    md.title = title
    md.setValue(summary, forKey: "summary")
    md.setValue(site, forKey: "siteName")
    let root = NSMutableDictionary()
    root["richLinkMetadata"] = md
    return try! NSKeyedArchiver.archivedData(withRootObject: root.copy(), requiringSecureCoding: false)
  }

  /// attachment.user_info for a voice message. imsg reads the transcript from this key.
  static func audioUserInfo(transcript: String) -> Data {
    let root = NSMutableDictionary()
    root["audio-transcription"] = transcript
    return plist(root)
  }
}
