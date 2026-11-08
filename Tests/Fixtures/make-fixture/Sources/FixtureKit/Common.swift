import CryptoKit
import Foundation

/// Seconds between 1970-01-01 and 2001-01-01 UTC.
public let appleEpochOffset: Int64 = 978_307_200

public enum AppleTime {
  public static func ns(fromUnix seconds: Double) -> Int64 {
    Int64(((seconds - Double(appleEpochOffset)) * 1_000_000_000).rounded())
  }

  public static func unix(fromNs ns: Int64) -> Double {
    Double(ns) / 1_000_000_000 + Double(appleEpochOffset)
  }
}

public func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public let fixtureTimeZone = TimeZone(identifier: "America/Los_Angeles")!

/// Formats an Apple-epoch nanosecond date as local fixture time, for docs.
public func localStamp(_ ns: Int64, _ format: String = "yyyy-MM-dd HH:mm:ss") -> String {
  let f = DateFormatter()
  f.locale = Locale(identifier: "en_US_POSIX")
  f.timeZone = fixtureTimeZone
  f.dateFormat = format
  return f.string(from: Date(timeIntervalSince1970: AppleTime.unix(fromNs: ns)))
}

/// Attribute keys Messages writes into attributedBody.
public enum IMKey {
  public static let part = NSAttributedString.Key("__kIMMessagePartAttributeName")
  public static let writingDirection = NSAttributedString.Key("__kIMBaseWritingDirectionAttributeName")
  public static let fileTransfer = NSAttributedString.Key("__kIMFileTransferGUIDAttributeName")
  public static let filename = NSAttributedString.Key("__kIMFilenameAttributeName")
  public static let mediaWidth = NSAttributedString.Key("__kIMInlineMediaWidthAttributeName")
  public static let mediaHeight = NSAttributedString.Key("__kIMInlineMediaHeightAttributeName")
  public static let link = NSAttributedString.Key("__kIMLinkAttributeName")
  public static let mention = NSAttributedString.Key("__kIMMentionConfirmedMention")
  public static let bold = NSAttributedString.Key("__kIMTextBoldAttributeName")
  public static let audioTranscription = NSAttributedString.Key("IMAudioTranscription")
}
