import FixtureKit
import Foundation

/// Builds the whole synthetic timeline in memory. Nothing here touches the database.
final class Planner {
  var rng: Rng
  var msgs: [Msg] = []
  var atts: [AttDef] = []
  var chats: [ChatDef] = []
  /// Tapback targets whose net reaction state the README documents.
  var netTargets: [(key: String, msg: Int)] = []
  var genericPhotoCount = 0

  static let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = fixtureTimeZone
    return c
  }()

  /// Generic conversations start on this day and stop before the scripted final scenes.
  static let genericStart = (2025, 9, 1)
  static let genericDays = 427  // through 2026-11-01
  /// Photos before this date are iCloud-offloaded (no file on disk).
  static var offloadCutoff: Int64 = 0

  init(seed: UInt64) {
    rng = Rng(seed: seed)
    Planner.offloadCutoff = Planner.nsLocal(2026, 1, 1, 0, 0, 0)
    chats = makeChats()
    rileyAdded = at("2026-02-10 20:00:00")
    chrisRemoved = at("2026-05-22 18:30:00")
    rileyLeft = at("2026-08-30 22:15:00")
  }

  // MARK: time

  static func nsLocal(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Int64 {
    let date = cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    return (Int64(date.timeIntervalSince1970) - appleEpochOffset) * 1_000_000_000
  }

  /// Parses "yyyy-MM-dd HH:mm:ss" in fixture local time and adds microsecond jitter.
  func at(_ s: String) -> Int64 {
    let p = s.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" }).map { Int($0)! }
    return Planner.nsLocal(p[0], p[1], p[2], p[3], p[4], p[5]) + Int64(rng.int(0, 999_999)) * 1000
  }

  static func sec(_ n: Int) -> Int64 { Int64(n) * 1_000_000_000 }

  // MARK: cast

  private func makeChats() -> [ChatDef] {
    func gid() -> String { rng.uuid() }
    let familyRoom = "chat" + rng.digits(18)
    let friendsRoom = "chat" + rng.digits(18)
    return [
      ChatDef(rowid: 2, key: "self", guid: "any;-;\(Cast.myPhone)", style: 45, identifier: Cast.myPhone,
              service: .iMessage, roomName: nil, displayName: "", label: "You (self-chat)",
              currentMembers: ["me"], callerID: Cast.myPhone, readReceipts: false, groupID: gid()),
      ChatDef(rowid: 7, key: "mom", guid: "any;-;+14155550101", style: 45, identifier: "+14155550101",
              service: .iMessage, roomName: nil, displayName: "", label: "Mom",
              currentMembers: ["mom", "mom_sms"], callerID: Cast.myPhone, readReceipts: true, groupID: gid()),
      ChatDef(rowid: 9, key: "dad", guid: "any;-;+14155550102", style: 45, identifier: "+14155550102",
              service: .iMessage, roomName: nil, displayName: "", label: "Dad",
              currentMembers: ["dad"], callerID: Cast.myPhone, readReceipts: false, groupID: gid()),
      ChatDef(rowid: 12, key: "family", guid: "any;+;\(familyRoom)", style: 43, identifier: familyRoom,
              service: .iMessage, roomName: familyRoom, displayName: "Family 🏡", label: "Family 🏡",
              currentMembers: ["mom", "dad", "priya", "arjun"], callerID: Cast.myPhone, readReceipts: false, groupID: gid()),
      ChatDef(rowid: 19, key: "friends", guid: "any;+;\(friendsRoom)", style: 43, identifier: friendsRoom,
              service: .iMessage, roomName: friendsRoom, displayName: "", label: "unnamed group",
              currentMembers: ["jordan", "taylor"], callerID: Cast.myPhone, readReceipts: false, groupID: gid()),
      ChatDef(rowid: 23, key: "jordan", guid: "any;-;jordan.kim@example.com", style: 45, identifier: "jordan.kim@example.com",
              service: .iMessage, roomName: nil, displayName: "", label: "Jordan Kim (email handle)",
              currentMembers: ["jordan"], callerID: Cast.myEmail, readReceipts: true, groupID: gid()),
      ChatDef(rowid: 31, key: "sam", guid: "any;-;+16505550142", style: 45, identifier: "+16505550142",
              service: .RCS, roomName: nil, displayName: "", label: "Sam Lee (RCS)",
              currentMembers: ["sam"], callerID: Cast.myPhone, readReceipts: true, groupID: gid()),
      ChatDef(rowid: 56, key: "marco", guid: "any;-;+15105550163", style: 45, identifier: "+15105550163",
              service: .SMS, roomName: nil, displayName: "", label: "+1 (510) 555-0163 (SMS, no contact)",
              currentMembers: ["marco"], callerID: Cast.myPhone, readReceipts: false, groupID: gid()),
    ]
  }

  func chat(_ key: String) -> ChatDef { chats.first { $0.key == key }! }

  /// The other party in a direct chat.
  func otherParty(_ chatKey: String) -> String {
    switch chatKey {
    case "self": return "me"
    default: return chat(chatKey).currentMembers[0]
    }
  }

  // MARK: friends group membership timeline

  var rileyAdded: Int64 = 0
  var chrisRemoved: Int64 = 0
  var rileyLeft: Int64 = 0

  func activeMembers(_ chatKey: String, _ ns: Int64) -> [String] {
    switch chatKey {
    case "family": return ["mom", "dad", "priya", "arjun"]
    case "friends":
      var m = ["jordan", "taylor"]
      if ns < chrisRemoved { m.append("chris") }
      if ns >= rileyAdded && ns < rileyLeft { m.append("riley") }
      return m
    default: return [otherParty(chatKey)]
    }
  }

  // MARK: builders

  @discardableResult
  func add(_ chatKey: String, _ who: Who, _ ns: Int64, _ parts: [Part], keys: [String] = [],
           _ configure: (inout Msg) -> Void = { _ in }) -> Int {
    var m = Msg(index: msgs.count, chat: chatKey, who: who, dateNs: ns, parts: parts)
    m.guid = rng.uuid()
    m.edgeKeys = keys
    m.immutableArchive = rng.chance(0.15)
    m.textColumn = chatKey == "marco" ? rng.chance(0.5) : rng.chance(0.05)
    configure(&m)
    for p in parts {
      if let a = p.attachment { atts[a].messageIndex = m.index }
    }
    msgs.append(m)
    return m.index
  }

  @discardableResult
  func text(_ chatKey: String, _ who: Who, _ when: String, _ body: String, keys: [String] = [],
            _ configure: (inout Msg) -> Void = { _ in }) -> Int {
    add(chatKey, who, at(when), [.t(body)], keys: keys, configure)
  }

  func addAttachment(_ kind: AttKind, _ name: String, onDisk: Bool, outgoing: Bool,
                     claimed: Int, size: (Int, Int)? = nil, transcript: String? = nil) -> Int {
    let uti: String
    let mime: String
    switch kind {
    case .photo, .sticker: (uti, mime) = ("public.heic", "image/heic")
    case .pdf: (uti, mime) = ("com.adobe.pdf", "application/pdf")
    case .voice: (uti, mime) = ("com.apple.coreaudio-format", "audio/x-caf")
    case .video: (uti, mime) = ("com.apple.quicktime-movie", "video/quicktime")
    }
    var a = AttDef(
      index: atts.count, guid: rng.uuid(), kind: kind, transferName: name, uti: uti, mime: mime,
      onDisk: onDisk, fileData: nil, claimedBytes: claimed, width: size?.0, height: size?.1,
      transcript: transcript, isSticker: kind == .sticker, isOutgoing: outgoing,
      dirA: rng.hex(2), dirB: String(format: "%02d", rng.int(0, 15)))
    if onDisk {
      switch kind {
      case .photo:
        let portrait = (size?.1 ?? 0) > (size?.0 ?? 0)
        a.fileData = Media.heic(width: portrait ? 48 : 64, height: portrait ? 64 : 48, seed: rng.next())
      case .sticker: a.fileData = Media.heic(width: 48, height: 48, seed: rng.next(), sticker: true)
      case .pdf: a.fileData = Media.pdf(title: name)
      case .voice: a.fileData = Media.caf(seconds: 4, seed: rng.next())
      case .video: a.fileData = nil
      }
    }
    atts.append(a)
    return a.index
  }

  @discardableResult
  func tapback(_ chatKey: String, _ who: Who, _ ns: Int64, target: Int, type: Int, part: Int = 0,
               emoji: String? = nil, keys: [String] = []) -> Int {
    let body = Planner.tapbackText(type: type, emoji: emoji, target: msgs[target], part: part, atts: atts)
    return add(chatKey, who, ns, [.t(body)], keys: keys) { m in
      m.kind = .tapback(type: type, target: target, part: part, emoji: emoji)
      m.textColumn = false
    }
  }

  static func tapbackText(type: Int, emoji: String?, target: Msg, part: Int, atts: [AttDef]) -> String {
    let e = emoji ?? ""
    let verb: String
    switch type {
    case 2000: verb = "Loved "
    case 2001: verb = "Liked "
    case 2002: verb = "Disliked "
    case 2003: verb = "Laughed at "
    case 2004: verb = "Emphasized "
    case 2005: verb = "Questioned "
    case 2006: verb = "Reacted \(e) to "
    case 3000: verb = "Removed a heart from "
    case 3001: verb = "Removed a like from "
    case 3002: verb = "Removed a dislike from "
    case 3003: verb = "Removed a laugh from "
    case 3004: verb = "Removed an exclamation from "
    case 3005: verb = "Removed a question mark from "
    case 3006: verb = "Removed \(e) from "
    default: verb = "Reacted to "
    }
    if case .linkBalloon(let url, _, _, _) = target.kind { return verb + "“\(url)”" }
    let p = target.parts[min(part, target.parts.count - 1)]
    if let a = p.attachment {
      switch atts[a].kind {
      case .photo: return verb + "an image"
      case .sticker: return verb + "a sticker"
      default: return verb + "an attachment"
      }
    }
    return verb + "“\(p.text ?? "")”"
  }

  // MARK: generic conversations

  struct GenericSpec {
    let chat: String
    let target: Int
    let scripts: [Exchange]
    let fillers: [String]
    let hours: (Int, Int)
    let photos: Bool
    let threadReplies: Bool
  }

  func generic(_ spec: GenericSpec) {
    var produced = 0
    while produced < spec.target {
      // Recent months get more sessions, like a real phone.
      let fromEnd = pow(rng.unit(), 1.25) * Double(Planner.genericDays)
      let dayIndex = max(0, Planner.genericDays - 1 - Int(fromEnd))
      let base = Planner.cal.date(from: DateComponents(
        year: Planner.genericStart.0, month: Planner.genericStart.1, day: Planner.genericStart.2))!
      let day = Planner.cal.date(byAdding: .day, value: dayIndex, to: base)!
      let c = Planner.cal.dateComponents([.year, .month, .day], from: day)
      var ns = Planner.nsLocal(c.year!, c.month!, c.day!, rng.int(spec.hours.0, spec.hours.1),
                               rng.int(0, 59), rng.int(0, 59)) + Int64(rng.int(0, 999_999)) * 1000

      let exchange = rng.pick(spec.scripts)
      let roles = roleMap(spec.chat, ns)
      var sessionMsgs: [Int] = []
      var speakers: [Who] = []
      for (i, line) in exchange.enumerated() {
        if i > 0 { ns += gap() }
        let who = roles[line.0] ?? .me
        let body = Slots.fill(line.1, &rng)
        let idx = add(spec.chat, who, ns, [.t(body)])
        if spec.threadReplies, i > 0, rng.chance(0.04),
           let parent = sessionMsgs.last(where: { msgs[$0].who != who }) {
          msgs[idx].threadTarget = (parent, 0)
        }
        sessionMsgs.append(idx)
        speakers.append(who)
        produced += 1
        if rng.chance(0.015) {
          // Becomes a ROWID gap: inserted, then deleted the way Messages deletes.
          add(spec.chat, who, ns + Planner.sec(rng.int(2, 20)), [.t(rng.pick(spec.fillers))]) { $0.gapFiller = true }
        }
        if i == 0, spec.photos, genericPhotoCount < 16, rng.chance(0.07) {
          ns += gap()
          let onDisk = ns >= Planner.offloadCutoff
          let name = "IMG_\(rng.int(1000, 9899)).HEIC"
          let a = addAttachment(.photo, name, onDisk: onDisk, outgoing: who == .me,
                                claimed: rng.int(900_000, 3_400_000), size: (4032, 3024))
          let pidx = add(spec.chat, who, ns, [.a(a)], keys: onDisk ? ["photo_generic"] : ["offloaded_photo"])
          sessionMsgs.append(pidx)
          genericPhotoCount += 1
          produced += 1
        }
      }
      if rng.chance(0.25), !speakers.isEmpty {
        let who = rng.pick(speakers)
        ns += gap()
        add(spec.chat, who, ns, [.t(rng.pick(spec.fillers))])
        produced += 1
      }
    }
  }

  private func gap() -> Int64 {
    let r = rng.unit()
    if r < 0.70 { return Planner.sec(rng.int(8, 180)) }
    if r < 0.95 { return Planner.sec(rng.int(180, 1200)) }
    return Planner.sec(rng.int(1800, 5400))
  }

  private func roleMap(_ chatKey: String, _ ns: Int64) -> [String: Who] {
    switch chatKey {
    case "family":
      return ["mom": .person("mom"), "dad": .person("dad"), "priya": .person("priya"), "arjun": .person("arjun"), "me": .me]
    case "friends":
      let m = rng.shuffled(activeMembers(chatKey, ns))
      return ["a": .person(m[0]), "b": .person(m[1 % m.count]), "c": .person(m[2 % m.count]), "me": .me]
    case "self":
      return ["me": .me]
    default:
      return ["them": .person(otherParty(chatKey)), "me": .me]
    }
  }

  /// Sprinkles tapbacks over generic messages. Scripted scenes add their own.
  func randomTapbacks(upTo limit: Int) {
    for i in 0..<limit {
      let m = msgs[i]
      guard case .normal = m.kind, !m.gapFiller, m.edgeKeys.isEmpty, m.chat != "self", m.chat != "marco" else { continue }
      let c = chat(m.chat)
      guard rng.chance(c.isGroup ? 0.07 : 0.035) else { continue }
      var candidates: [Who] = activeMembers(m.chat, m.dateNs).map { .person($0) } + [.me]
      candidates.removeAll { $0 == m.who }
      guard !candidates.isEmpty else { continue }
      let reactor = rng.pick(candidates)
      let type = rng.weighted([(2000, 0.35), (2003, 0.35), (2001, 0.15), (2004, 0.10), (2005, 0.03), (2002, 0.02)])
      tapback(m.chat, reactor, m.dateNs + Planner.sec(rng.int(20, 7200)), target: i, type: type)
    }
  }
}

