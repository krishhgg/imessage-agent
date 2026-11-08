import FixtureKit
import Foundation

/// Scripted scenes at fixed dates. Each edge case gets a key so the README can list its ROWIDs.
extension Planner {
  func buildAll() {
    momScenes()
    dadScenes()
    samScenes()
    marcoScenes()
    familyScenes()
    friendsScenes()
    jordanScenes()
    selfScenes()

    let scriptedEnd = msgs.count
    generic(GenericSpec(chat: "mom", target: 282, scripts: Scripts.mom, fillers: Scripts.familyFillers,
                        hours: (7, 22), photos: true, threadReplies: false))
    generic(GenericSpec(chat: "dad", target: 142, scripts: Scripts.dad, fillers: Scripts.familyFillers,
                        hours: (8, 21), photos: true, threadReplies: false))
    generic(GenericSpec(chat: "sam", target: 138, scripts: Scripts.sam, fillers: Scripts.friendFillers,
                        hours: (11, 23), photos: true, threadReplies: false))
    generic(GenericSpec(chat: "marco", target: 78, scripts: Scripts.marco, fillers: Scripts.landlordFillers,
                        hours: (9, 19), photos: false, threadReplies: false))
    generic(GenericSpec(chat: "family", target: 366, scripts: Scripts.family, fillers: Scripts.familyFillers,
                        hours: (8, 23), photos: true, threadReplies: true))
    generic(GenericSpec(chat: "friends", target: 186, scripts: Scripts.friends, fillers: Scripts.friendFillers,
                        hours: (11, 23), photos: true, threadReplies: true))
    generic(GenericSpec(chat: "jordan", target: 99, scripts: Scripts.jordan, fillers: Scripts.friendFillers,
                        hours: (9, 23), photos: false, threadReplies: false))
    selfGeneric(target: 38)
    _ = scriptedEnd
    randomTapbacks(upTo: msgs.count)
  }

  // MARK: Mom, chat 7

  private func momScenes() {
    let old = addAttachment(.photo, "IMG_2291.HEIC", onDisk: false, outgoing: false, claimed: 2_431_882, size: (4032, 3024))
    add("mom", .person("mom"), at("2025-09-20 12:14:03"), [.a(old)], keys: ["offloaded_photo", "offloaded_photo_scripted"])
    text("mom", .person("mom"), "2025-09-20 12:14:40", "From the temple this morning")

    text("mom", .person("mom"), "2025-12-02 07:41:09", "Phone not working on wifi, sending as text",
         keys: ["sms_fallback_in_imessage_chat"]) { $0.service = .SMS; $0.handleKey = "mom_sms" }
    text("mom", .me, "2025-12-02 07:45:30", "Ok got it", keys: ["sms_fallback_in_imessage_chat"]) {
      $0.service = .SMS; $0.handleKey = "mom_sms"
    }
    text("mom", .person("mom"), "2025-12-02 07:46:02", "Will call later",
         keys: ["sms_fallback_in_imessage_chat"]) { $0.service = .SMS; $0.handleKey = "mom_sms" }

    text("mom", .me, "2026-02-02 21:10:14", "Can you send me the dal makhani recipe")
    text("mom", .person("mom"), "2026-02-02 21:32:51", Scripts.momRecipe, keys: ["long_body", "multiline_body"])

    let voice = addAttachment(.voice, "Audio Message.caf", onDisk: true, outgoing: false, claimed: 11_734,
                              transcript: "Hi beta, call me when you get a chance, it is about Sunday. Papa wants to know if you are bringing the car.")
    let v = add("mom", .person("mom"), at("2026-03-14 18:20:11"), [.a(voice)], keys: ["voice_with_transcript"]) {
      $0.isAudio = true; $0.played = true; $0.textColumn = false
    }
    _ = v
    text("mom", .me, "2026-03-14 18:27:40", "Calling now")

    let photo = addAttachment(.photo, "IMG_4420.HEIC", onDisk: true, outgoing: false, claimed: 2_204_318, size: (4032, 3024))
    let p = add("mom", .person("mom"), at("2026-05-10 10:02:44"), [.a(photo)], keys: ["photo_heic"])
    tapback("mom", .me, at("2026-05-10 10:05:02"), target: p, type: 2000, keys: ["tapback_on_attachment"])
    text("mom", .me, "2026-05-10 10:05:30", "So pretty! Where is this?")
    text("mom", .person("mom"), "2026-05-10 10:09:12", "The rose garden near the library 🌹")

    let e = text("mom", .me, "2026-06-21 16:40:00", "I'll be there at 7", keys: ["edited_once"])
    msgs[e].editHistory = [(msgs[e].dateNs, "I'll be there at 6"), (at("2026-06-21 16:41:30"), "I'll be there at 7")]
    text("mom", .person("mom"), "2026-06-21 16:45:10", "Ok 👍🏽")

    text("mom", .me, "2026-08-19 14:02:20", "Leaving now, will be there in 20")
    add("mom", .person("mom"), Planner.nsLocal(2026, 8, 19, 14, 3, 5) + 120_000_000, [.t("ok")],
        keys: ["duplicate_same_minute"]) { $0.textColumn = false; $0.immutableArchive = false }
    add("mom", .person("mom"), Planner.nsLocal(2026, 8, 19, 14, 3, 41) + 870_000_000, [.t("ok")],
        keys: ["duplicate_same_minute"]) { $0.textColumn = false; $0.immutableArchive = false }

    text("mom", .person("mom"), "2026-09-09 13:00:31", "खाना खा लिया? 🍛", keys: ["non_latin_devanagari"])
    text("mom", .me, "2026-09-09 13:20:02", "हाँ माँ")

    text("mom", .person("mom"), "2026-11-05 20:41:17", "Are you coming for dinner Sunday? Papa is making biryani",
         keys: ["unread", "reply_to_mom_target"]) { $0.unread = true }
    text("mom", .person("mom"), "2026-11-05 20:42:02", "Also call Nani, she was asking about you",
         keys: ["unread"]) { $0.unread = true }
  }

  // MARK: Dad, chat 9

  private func dadScenes() {
    let pdf = addAttachment(.pdf, "Insurance_Renewal_2026.pdf", onDisk: true, outgoing: false, claimed: 348_211)
    add("dad", .person("dad"), at("2026-04-08 09:15:22"),
        [.a(pdf), .t("Car insurance renewal, check page 2 and sign")], keys: ["pdf_with_caption", "multipart"])
    text("dad", .me, "2026-04-08 09:40:00", "Will sign tonight")

    text("dad", .person("dad"), "2026-06-03 18:02:44",
         "Old office address was 88 Harbor Point Blvd, Suite 210, Oakland, CA 94607. They are moving soon.",
         keys: ["address_decoy_june"]) { $0.dataDetected = true }

    text("dad", .me, "2026-07-11 21:04:10", "Did you talk to Uncle Ramesh about the loan?",
         keys: ["unsent_modern_outgoing"]) { [self] m in m.unsend = .modern(at: at("2026-07-11 21:05:02")) }
    text("dad", .me, "2026-07-11 21:05:30", "Never mind, will ask in person")

    text("dad", .me, "2026-09-02 22:48:31", "Landed, will call you from the car",
         keys: ["failed_send", "duplicate_text_after_failure"]) { $0.failed = true; $0.textColumn = false }
    text("dad", .me, "2026-09-02 22:49:15", "Landed, will call you from the car",
         keys: ["duplicate_text_after_failure"]) { $0.textColumn = false }

    text("dad", .me, "2026-10-14 19:05:48", "What's the address for Sunday?")
    text("dad", .person("dad"), "2026-10-14 19:12:05",
         "The address for Sunday is 2219 Juniper Hollow Rd, Santa Rosa, CA 95404. Park on the street, not in the driveway.",
         keys: ["address_last_month"]) { $0.dataDetected = true; $0.textColumn = false }
    text("dad", .me, "2026-10-14 19:13:20", "Got it, thanks")

    text("dad", .person("dad"), "2026-11-04 08:30:12", "Did you book the car service?")
    let y = text("dad", .me, "2026-11-04 08:44:51", "Yes, Thursday at 10")
    tapback("dad", .person("dad"), at("2026-11-04 08:50:03"), target: y, type: 2001, keys: ["tapback_on_my_message"])
  }

  // MARK: Sam, chat 31 (RCS)

  private func samScenes() {
    let top = text("sam", .me, "2026-07-19 15:22:40", "made it to the top 🧗")
    tapback("sam", .person("sam"), at("2026-07-19 15:23:10"), target: top, type: 2000, keys: ["rcs_tapback"])
    text("sam", .person("sam"), "2026-11-05 10:02:33", "are we still on for 7?", keys: ["unread"]) { $0.unread = true }
  }

  // MARK: Marco, chat 56 (SMS, not in contacts)

  private func marcoScenes() {
    text("marco", .me, "2025-09-05 10:12:00", "Hi Marco, this is the tenant in unit 4. Is this the right number for maintenance?",
         keys: ["sms_outgoing_no_delivery_date"])
    text("marco", .person("marco"), "2025-09-05 10:40:31", "Yes this is Marco. Text anytime.")
    text("marco", .person("marco"), "2026-11-04 16:20:05", "Water shut off Thursday 9am to 1pm, sorry for the short notice",
         keys: ["unread"]) { $0.unread = true }
  }

  // MARK: Family 🏡, chat 12

  private func familyScenes() {
    add("family", .person("mom"), at("2025-09-03 19:00:00"), [], keys: ["group_rename"]) {
      $0.kind = .groupEvent(itemType: 2, action: 0, other: nil, title: "Fam")
    }
    add("family", .person("priya"), at("2026-01-15 20:11:40"), [], keys: ["group_rename"]) {
      $0.kind = .groupEvent(itemType: 2, action: 0, other: nil, title: "Family 🏡")
    }

    let st = addAttachment(.sticker, "sticker.heic", onDisk: true, outgoing: false, claimed: 61_442, size: (300, 300))
    add("family", .person("priya"), at("2026-03-02 12:30:18"), [.a(st)], keys: ["sticker"])

    text("family", .person("mom"), "2026-04-17 00:00:12", "Happy birthday Arjun!! 🎂🎉", keys: ["expressive_effect"]) {
      $0.effect = "com.apple.messages.effect.CKConfettiEffect"
    }
    text("family", .person("arjun"), "2026-04-17 07:31:02", "thank you mom ❤️")

    let f1 = addAttachment(.photo, "IMG_5101.HEIC", onDisk: true, outgoing: false, claimed: 1_987_004, size: (4032, 3024))
    let f2 = addAttachment(.photo, "IMG_5102.HEIC", onDisk: true, outgoing: false, claimed: 2_310_771, size: (3024, 4032))
    add("family", .person("dad"), at("2026-07-04 21:45:09"), [.a(f1), .a(f2)], keys: ["two_photos_one_message", "multipart"])
    text("family", .person("dad"), "2026-07-04 21:45:30", "Fireworks from the hill")

    add("family", .person("mom"), at("2026-08-08 09:12:40"), [{
      var p = Part.t("Priya can you bring the folding chairs on Saturday")
      p.mentions = [("Priya", "+14155550103")]
      return p
    }()], keys: ["mention"])
    add("family", .person("priya"), at("2026-08-08 09:20:15"), [{
      var p = Part.t("Reminder: bring your own water bottles, the park has no fountains")
      p.bold = ["Reminder"]
      return p
    }()], keys: ["bold_text"])

    let cut = addAttachment(.photo, "IMG_6230.HEIC", onDisk: true, outgoing: false, claimed: 1_640_093, size: (3024, 4032))
    add("family", .person("arjun"), at("2026-09-14 11:02:05"), [.a(cut), .t("rate my new haircut")],
        keys: ["unsent_partial", "multipart"]) { [self] m in
      m.unsend = .partial(at: at("2026-09-14 11:03:10"), parts: [1])
    }

    text("family", .person("priya"), "2026-09-20 17:30:00", Scripts.priyaTripPlan, keys: ["long_body"])

    // Diwali planning, 2026-10-20.
    let root = text("family", .person("mom"), "2026-10-20 18:02:11", "Who is coming Sunday for Diwali dinner?",
                    keys: ["thread_root"])
    let obviously = text("family", .person("dad"), "2026-10-20 18:05:40", "Me obviously", keys: ["tapback_target_a"])
    text("family", .person("priya"), "2026-10-20 18:06:02", "I can come after 2, have a shift in the morning",
         keys: ["thread_reply"]) { $0.threadTarget = (root, 0) }
    tapback("family", .person("mom"), at("2026-10-20 18:06:30"), target: obviously, type: 2000)
    tapback("family", .person("priya"), at("2026-10-20 18:07:00"), target: obviously, type: 2003)
    tapback("family", .person("arjun"), at("2026-10-20 18:07:20"), target: obviously, type: 2001)
    text("family", .person("arjun"), "2026-10-20 18:08:44", "I'll be there by 5", keys: ["thread_reply"]) {
      $0.threadTarget = (root, 0)
    }
    tapback("family", .person("arjun"), at("2026-10-20 18:09:00"), target: obviously, type: 3001, keys: ["tapback_remove"])
    text("family", .person("mom"), "2026-10-20 18:10:05", "Ok, come straight from work", keys: ["thread_reply"]) {
      $0.threadTarget = (root, 0)
    }
    tapback("family", .me, at("2026-10-20 18:12:00"), target: obviously, type: 2004)
    netTargets.append(("tapback_target_a", obviously))

    let edit = text("family", .person("mom"), "2026-10-20 18:21:30", "Get kaju katli and 2 boxes of jalebi",
                    keys: ["edited_once"])
    msgs[edit].editHistory = [(msgs[edit].dateNs, "Get kaju katli and 1 box of jalebi"),
                              (at("2026-10-20 18:23:05"), "Get kaju katli and 2 boxes of jalebi")]

    let rangoli = addAttachment(.photo, "IMG_7781.HEIC", onDisk: true, outgoing: false, claimed: 2_288_960, size: (4032, 3024))
    let multi = add("family", .person("priya"), at("2026-10-20 18:24:00"),
                    [.a(rangoli), .t("Rangoli practice from last year lol")],
                    keys: ["photo_with_caption", "multipart", "tapback_target_multipart"])
    tapback("family", .person("mom"), at("2026-10-20 18:25:10"), target: multi, type: 2000, part: 0, keys: ["tapback_part_0"])
    tapback("family", .person("arjun"), at("2026-10-20 18:26:02"), target: multi, type: 2003, part: 1, keys: ["tapback_part_1"])
    tapback("family", .person("dad"), at("2026-10-20 18:27:40"), target: multi, type: 2004, part: 1, keys: ["tapback_part_1"])
    netTargets.append(("tapback_target_multipart", multi))
    text("family", .person("arjun"), "2026-10-20 18:29:15", "the 2024 one was better", keys: ["thread_reply_to_part_1"]) {
      $0.threadTarget = (multi, 1)
    }
    text("family", .person("mom"), "2026-10-20 19:06:51", "Already getting jalebi, no gulab jamun")

    let url = "https://www.example.com/food/diwali-sweets-guide"
    let link = add("family", .person("arjun"), at("2026-10-20 21:03:12"), [.t(url)], keys: ["link_preview_single_row"]) {
      $0.kind = .linkBalloon(url: url, title: "A Guide to Diwali Sweets, From Barfi to Jalebi",
                             summary: "Twelve sweets to make or buy this year", site: "example.com")
      $0.textColumn = false
    }
    tapback("family", .person("priya"), at("2026-10-20 21:10:40"), target: link, type: 2000, keys: ["tapback_bp_prefix"])

    let placed = addAttachment(.sticker, "sticker-placed.heic", onDisk: true, outgoing: false, claimed: 58_120, size: (300, 300))
    add("family", .person("arjun"), at("2026-10-20 21:15:33"), [.a(placed)], keys: ["placed_sticker"]) {
      $0.kind = .placedSticker(target: root, part: 0)
      $0.textColumn = false
    }

    // Tapback add and remove coverage, 2026-10-24.
    let puja = text("family", .person("dad"), "2026-10-24 10:00:20", "Should we do the puja at 6 or 7?",
                    keys: ["tapback_target_b"])
    tapback("family", .person("priya"), at("2026-10-24 10:01:00"), target: puja, type: 2005)
    tapback("family", .person("mom"), at("2026-10-24 10:01:30"), target: puja, type: 2002)
    tapback("family", .person("priya"), at("2026-10-24 10:02:10"), target: puja, type: 3005, keys: ["tapback_remove"])
    tapback("family", .person("mom"), at("2026-10-24 10:03:00"), target: puja, type: 3002, keys: ["tapback_remove"])
    tapback("family", .person("mom"), at("2026-10-24 10:03:05"), target: puja, type: 2001)
    netTargets.append(("tapback_target_b", puja))

    let gj = text("family", .person("arjun"), "2026-10-24 10:30:45", "I'm bringing gulab jamun anyway",
                  keys: ["tapback_target_c"])
    tapback("family", .person("priya"), at("2026-10-24 10:31:00"), target: gj, type: 2006, emoji: "🎉", keys: ["tapback_emoji"])
    tapback("family", .person("priya"), at("2026-10-24 10:31:40"), target: gj, type: 3006, emoji: "🎉",
            keys: ["tapback_emoji", "tapback_remove"])
    tapback("family", .person("priya"), at("2026-10-24 10:31:44"), target: gj, type: 2006, emoji: "🪔", keys: ["tapback_emoji"])
    tapback("family", .me, at("2026-10-24 10:35:02"), target: gj, type: 2006, emoji: "🎉", keys: ["tapback_emoji"])
    netTargets.append(("tapback_target_c", gj))

    let sweets = text("family", .person("priya"), "2026-10-24 11:00:03", "Mom said no more sweets",
                      keys: ["tapback_target_d"])
    tapback("family", .person("arjun"), at("2026-10-24 11:00:30"), target: sweets, type: 2000)
    tapback("family", .me, at("2026-10-24 11:00:50"), target: sweets, type: 2003)
    tapback("family", .person("dad"), at("2026-10-24 11:01:15"), target: sweets, type: 2004)
    tapback("family", .person("arjun"), at("2026-10-24 11:02:00"), target: sweets, type: 3000, keys: ["tapback_remove"])
    tapback("family", .me, at("2026-10-24 11:02:30"), target: sweets, type: 3003, keys: ["tapback_remove"])
    tapback("family", .person("dad"), at("2026-10-24 11:03:00"), target: sweets, type: 3004, keys: ["tapback_remove"])
    netTargets.append(("tapback_target_d", sweets))

    text("family", .person("dad"), "2026-10-25 11:15:00", "Wrong group, ignore", keys: ["unsent_modern_incoming"]) {
      [self] m in m.unsend = .modern(at: at("2026-10-25 11:15:40"))
    }

    add("family", .me, Planner.nsLocal(2026, 10, 25, 18, 5, 10) + 331_000_000, [.t("On my way")],
        keys: ["duplicate_same_minute"]) { $0.textColumn = false; $0.immutableArchive = false }
    add("family", .me, Planner.nsLocal(2026, 10, 25, 18, 5, 12) + 9_000_000, [.t("On my way")],
        keys: ["duplicate_same_minute"]) { $0.textColumn = false; $0.immutableArchive = false }

    text("family", .person("mom"), "2026-10-26 08:00:41", "👨‍👩‍👧‍👦❤️🇮🇳", keys: ["emoji_zwj_flag"])

    text("family", .person("arjun"), "2026-10-28 13:40:09", "ignore my last text, wrong chat", keys: ["recently_deleted"]) {
      $0.recentlyDeleted = true
    }

    text("family", .person("priya"), "2026-11-05 11:50:20", "Did everyone see the photos from Sunday?")
    text("family", .person("arjun"), "2026-11-05 12:10:02", "Yes. And I'm bringing gulab jamun again next time",
         keys: ["unread"]) { $0.unread = true }
    text("family", .person("mom"), "2026-11-05 12:30:44", "Arjun no! 😂", keys: ["unread"]) { $0.unread = true }
    text("family", .person("priya"), "2026-11-05 12:31:09", "Sending the group photo tonight", keys: ["unread"]) {
      $0.unread = true
    }
  }

  // MARK: unnamed group, chat 19

  private func friendsScenes() {
    add("friends", .person("jordan"), rileyAdded, [], keys: ["group_add"]) {
      $0.kind = .groupEvent(itemType: 1, action: 0, other: "riley", title: nil)
    }
    text("friends", .person("riley"), "2026-02-10 20:01:12", "hi everyone! thanks for the add",
         keys: ["sender_not_in_contacts"])

    text("friends", .person("chris"), "2026-03-07 13:14:50", "¡Qué bueno! Nos vemos el sábado 🙌", keys: ["non_latin_accents"])

    let url = "https://blog.example.org/posts/cabin-checklist"
    text("friends", .person("jordan"), "2026-04-03 19:20:00", "you have to read this before the trip \(url)",
         keys: ["link_preview_two_rows"])
    add("friends", .person("jordan"), at("2026-04-03 19:20:01"), [.t(url)], keys: ["link_preview_two_rows"]) {
      $0.kind = .linkBalloon(url: url, title: "The Cabin Checklist: 31 Things to Pack",
                             summary: "A printable list for a long weekend in the mountains", site: "blog.example.org")
      $0.textColumn = false
    }

    add("friends", .me, chrisRemoved, [], keys: ["group_remove"]) {
      $0.kind = .groupEvent(itemType: 1, action: 1, other: "chris", title: nil)
    }

    let q = text("friends", .person("taylor"), "2026-06-12 19:40:30", "who's driving to the cabin?")
    text("friends", .person("jordan"), "2026-06-12 19:44:02", "I can take 3 people", keys: ["thread_reply"]) {
      $0.threadTarget = (q, 0)
    }

    text("friends", .person("riley"), "2026-07-04 16:00:41", "Cảm ơn nhé, vui quá!", keys: ["non_latin_vietnamese"])

    add("friends", .person("riley"), rileyLeft, [], keys: ["group_leave"]) {
      $0.kind = .groupEvent(itemType: 3, action: 0, other: nil, title: nil)
    }

    text("friends", .person("taylor"), "2026-11-05 21:00:18", "trivia next thursday?", keys: ["unread"]) { $0.unread = true }
  }

  // MARK: Jordan, chat 23 (email handle)

  private func jordanScenes() {
    text("jordan", .person("jordan"), "2026-03-20 22:41:07", Scripts.jordanRant, keys: ["long_body"])

    let e = text("jordan", .me, "2026-05-05 12:30:00", "Lunch at 12:30 at the dumpling place?", keys: ["edited_twice"])
    msgs[e].editHistory = [(msgs[e].dateNs, "Lunch at 12 at the noodle place?"),
                           (at("2026-05-05 12:31:10"), "Lunch at 12:30 at the noodle place?"),
                           (at("2026-05-05 12:33:42"), "Lunch at 12:30 at the dumpling place?")]
    text("jordan", .person("jordan"), "2026-05-05 12:35:00", "yes!! see you there")

    text("jordan", .person("jordan"), "2026-06-18 23:02:10", "lol forget I said that", keys: ["unsent_legacy"]) {
      [self] m in m.unsend = .legacy(at: at("2026-06-18 23:02:55"))
    }

    text("jordan", .person("jordan"), "2026-07-22 18:15:33", "대박 ㅋㅋㅋ 진짜?", keys: ["non_latin_hangul"])

    text("jordan", .me, "2026-08-14 12:01:44", "Meet at the cafe\u{0301} on 5th?", keys: ["nfd_text"]) { $0.textColumn = false }
    text("jordan", .person("jordan"), "2026-08-14 12:03:02", "the café with the blue door? yes", keys: ["nfc_text"]) {
      $0.textColumn = false
    }

    text("jordan", .me, "2026-11-05 22:58:40", "did you get home ok?", keys: ["sent_not_delivered", "last_message_overall"]) {
      $0.notDelivered = true
    }
  }

  // MARK: self-chat, chat 2

  private func selfScenes() {
    text("self", .me, "2026-06-30 23:10:05", Scripts.longNote(), keys: ["long_body_over_8kb"]) { $0.textColumn = false }
    text("self", .me, "2026-07-02 08:12:40", "https://www.example.com/recipes/palak-paneer", keys: ["link_without_preview"])
  }

  /// Notes to self. About 40% get an echo row, the assumed second copy of a self-sent message.
  func selfGeneric(target: Int) {
    var produced = 0
    while produced < target {
      let fromEnd = pow(rng.unit(), 1.25) * Double(Planner.genericDays)
      let dayIndex = max(0, Planner.genericDays - 1 - Int(fromEnd))
      let base = Planner.cal.date(from: DateComponents(year: 2025, month: 9, day: 1))!
      let day = Planner.cal.date(byAdding: .day, value: dayIndex, to: base)!
      let c = Planner.cal.dateComponents([.year, .month, .day], from: day)
      let ns = Planner.nsLocal(c.year!, c.month!, c.day!, rng.int(8, 23), rng.int(0, 59), rng.int(0, 59))
        + Int64(rng.int(0, 999_999)) * 1000
      let body = Slots.fill(rng.pick(Scripts.selfNotes), &rng)
      let original = add("self", .me, ns, [.t(body)])
      produced += 1
      if rng.chance(0.4) {
        let imm = msgs[original].immutableArchive
        add("self", .me, ns + Int64(rng.int(300, 1500)) * 1_000_000, [.t(body)], keys: ["self_echo_assumed"]) {
          $0.echo = true; $0.immutableArchive = imm; $0.textColumn = false
        }
        msgs[original].edgeKeys.append("self_echo_original")
      }
    }
  }
}
