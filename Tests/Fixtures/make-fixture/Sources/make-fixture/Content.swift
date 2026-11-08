import Foundation

// Every name, number, address and message below is invented. Phone numbers use the
// 555-01xx fiction range and emails use example.com.

enum Cast {
  static let myPhone = "+14155550100"
  static let myEmail = "alex@example.com"

  static let people: [Person] = [
    Person(key: "me", first: "You", last: nil, nickname: nil, inContacts: true),
    Person(key: "mom", first: "Meera", last: "Desai", nickname: "Mom", inContacts: true),
    Person(key: "dad", first: "Sunil", last: "Desai", nickname: "Dad", inContacts: true),
    Person(key: "priya", first: "Priya", last: "Desai", nickname: nil, inContacts: true),
    Person(key: "arjun", first: "Arjun", last: "Desai", nickname: nil, inContacts: true),
    Person(key: "sam", first: "Sam", last: "Lee", nickname: nil, inContacts: true),
    Person(key: "marco", first: "Marco", last: "Bianchi", nickname: nil, inContacts: false),
    Person(key: "jordan", first: "Jordan", last: "Kim", nickname: nil, inContacts: true),
    Person(key: "taylor", first: "Taylor", last: "Brooks", nickname: nil, inContacts: true),
    Person(key: "chris", first: "Chris", last: "Ortega", nickname: nil, inContacts: true),
    Person(key: "riley", first: "Riley", last: "Nguyen", nickname: nil, inContacts: false),
  ]

  /// Handle keys are person keys, plus "mom_sms" for Mom's SMS handle on the same number.
  static let handles: [(key: String, def: HandleDef)] = [
    ("me", HandleDef(rowid: 1, id: myPhone, service: .iMessage, country: "us", uncanonicalized: nil, person: "me")),
    ("mom", HandleDef(rowid: 3, id: "+14155550101", service: .iMessage, country: "us", uncanonicalized: nil, person: "mom")),
    ("dad", HandleDef(rowid: 4, id: "+14155550102", service: .iMessage, country: "us", uncanonicalized: nil, person: "dad")),
    ("priya", HandleDef(rowid: 5, id: "+14155550103", service: .iMessage, country: "us", uncanonicalized: nil, person: "priya")),
    ("arjun", HandleDef(rowid: 6, id: "+14155550104", service: .iMessage, country: "us", uncanonicalized: nil, person: "arjun")),
    ("mom_sms", HandleDef(rowid: 8, id: "+14155550101", service: .SMS, country: "us", uncanonicalized: "4155550101", person: "mom")),
    ("sam", HandleDef(rowid: 11, id: "+16505550142", service: .RCS, country: "us", uncanonicalized: "(650) 555-0142", person: "sam")),
    ("marco", HandleDef(rowid: 14, id: "+15105550163", service: .SMS, country: "us", uncanonicalized: "5105550163", person: "marco")),
    ("jordan", HandleDef(rowid: 16, id: "jordan.kim@example.com", service: .iMessage, country: nil, uncanonicalized: nil, person: "jordan")),
    ("taylor", HandleDef(rowid: 17, id: "+12125550188", service: .iMessage, country: "us", uncanonicalized: nil, person: "taylor")),
    ("chris", HandleDef(rowid: 18, id: "+13105550119", service: .iMessage, country: "us", uncanonicalized: nil, person: "chris")),
    ("riley", HandleDef(rowid: 22, id: "+17075550131", service: .iMessage, country: "us", uncanonicalized: nil, person: "riley")),
  ]

  static func person(_ key: String) -> Person { people.first { $0.key == key }! }
  static func handle(_ key: String) -> HandleDef { handles.first { $0.key == key }!.def }
}

enum Slots {
  static let pools: [String: [String]] = [
    "food": ["dal and rice", "pasta", "a burrito", "leftover biryani", "poke", "ramen", "a salad", "pizza", "pho", "masala dosa"],
    "snack": ["chips", "coffee", "cookies", "instant noodles"],
    "time": ["6", "6:30", "7", "7:30", "8", "noon", "2", "4:15", "9"],
    "day": ["Saturday", "Sunday", "tomorrow", "Friday", "next week", "tonight", "Monday"],
    "item": ["the big serving spoon", "your laptop charger", "a jacket", "the folding chairs", "dessert", "the cooler"],
    "festival": ["Diwali", "Holi", "New Year", "Thanksgiving"],
    "dish": ["dal makhani", "rajma", "chole", "kheer", "biryani", "aloo paratha"],
    "appliance": ["dishwasher", "fridge", "washing machine", "microwave"],
    "place": ["Lake Tahoe", "the farmers market", "Costco", "Monterey", "Napa", "the temple"],
    "num": ["40", "65", "120", "35", "200", "18", "75"],
    "show": ["Night Harbor", "The Glass Orchard", "Low Tide"],
    "gym": ["Granite Room", "the bouldering gym", "Crux House"],
    "month": ["January", "March", "July", "October"],
    "thing": ["Costco membership", "pizza", "ski cabin", "cricket tickets"],
    "movie": ["Paper Moons", "The Last Ferry", "Signal Fire"],
    "game": ["Catan", "Codenames", "Wingspan"],
    "book": ["Piranesi", "The Overstory", "Project Hail Mary"],
    "groceries": ["milk, eggs, spinach, coffee", "rice, lentils, onions, ginger", "bananas, yogurt, bread, paneer"],
    "slug": ["palak-paneer", "lemon-rice", "masala-chai"],
  ]

  static func fill(_ template: String, _ rng: inout Rng) -> String {
    var out = ""
    var rest = Substring(template)
    while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
      out += rest[..<open]
      let name = String(rest[rest.index(after: open)..<close])
      out += pools[name].map { rng.pick($0) } ?? "{\(name)}"
      rest = rest[rest.index(after: close)...]
    }
    return out + rest
  }
}

typealias Exchange = [(String, String)]

enum Scripts {
  static let mom: [Exchange] = [
    [("them", "Did you eat?"), ("me", "Yes ma, had {food}"), ("them", "Good. Eat properly, not just {snack}"), ("me", "😂 ok")],
    [("them", "Call me when you are free"), ("me", "In a meeting, will call at {time}"), ("them", "Ok beta")],
    [("them", "Are you coming {day}?"), ("me", "Yes, should be there by {time}"), ("them", "Bring {item}"), ("me", "Will do")],
    [("them", "Did you see the photos Priya sent"), ("me", "Yes! So cute"), ("them", "❤️❤️")],
    [("them", "Your Dad wants to know if you renewed the car registration"), ("me", "Not yet, doing it this week"), ("them", "Don't forget, the late fee is {num} dollars")],
    [("them", "खाना खा लिया?"), ("me", "हाँ माँ, अभी खाया"), ("them", "👍🏽")],
    [("them", "The {appliance} is making that noise again"), ("me", "Did you try turning it off and on"), ("them", "Yes. Still noise"), ("me", "I'll look at it {day}")],
    [("them", "How was the interview"), ("me", "Went well I think"), ("them", "So proud of you beta 🙏")],
    [("them", "Weather says rain {day}, take an umbrella"), ("me", "Ok ma")],
    [("me", "Can you send me the {dish} recipe"), ("them", "Will send tonight, remind me if I forget")],
    [("them", "Aunty Kavita is visiting next week"), ("me", "Oh nice, for how long"), ("them", "{num} days. She is asking about you"), ("me", "Tell her hi!")],
    [("them", "Did you get the package"), ("me", "Yes got it today, thank you!"), ("them", "Wear the sweater, it is getting cold")],
    [("them", "Good morning ☀️"), ("me", "Morning!")],
    [("them", "Doctor appointment went fine, nothing to worry"), ("me", "Oh good, thanks for telling me")],
    [("me", "Running 10 min late"), ("them", "No problem, drive safe")],
    [("them", "Papa and I are going to {place} {day}"), ("me", "Have fun! Send pics"), ("them", "Will do")],
    [("them", "Did you call Nani?"), ("me", "Yes yesterday, she sounded happy"), ("them", "She told me 😊")],
    [("me", "What time is puja"), ("them", "{time}, come early"), ("me", "👍")],
  ]

  static let dad: [Exchange] = [
    [("them", "Did you check the tire pressure"), ("me", "Yes last week"), ("them", "Good. Winter is coming")],
    [("them", "Score?"), ("me", "India won by {num} runs!"), ("them", "🇮🇳🇮🇳🇮🇳")],
    [("them", "Call me when free"), ("me", "Calling in 5")],
    [("them", "Tax documents are ready, sign them when you come home"), ("me", "Ok will do {day}")],
    [("them", "Good luck tomorrow"), ("me", "Thanks Dad")],
    [("them", "Your mother says you are not calling enough"), ("me", "😅 I'll call tonight")],
    [("them", "Market is down today, don't panic"), ("me", "Not panicking lol"), ("them", "Good. Long term")],
    [("me", "Can you pick me up from the airport {day}"), ("them", "What time"), ("me", "Flight lands {time}"), ("them", "Ok. Text me when you land")],
    [("them", "Did you change the furnace filter"), ("me", "Doing it this weekend"), ("them", "👍")],
    [("them", "Read the article I sent about the {thing}"), ("me", "Will read later"), ("them", "It is important")],
    [("them", "Happy {festival}!"), ("me", "Happy {festival} Papa!")],
    [("me", "Is the garage door fixed?"), ("them", "Yes, the guy came {day}. {num} dollars"), ("me", "Not bad")],
  ]

  static let sam: [Exchange] = [
    [("them", "climbing {day}?"), ("me", "yes! {time}?"), ("them", "perfect, see you at {gym}")],
    [("them", "did you watch {show}"), ("me", "not yet no spoilers"), ("them", "🤐")],
    [("me", "want to get {food} tonight"), ("them", "always"), ("them", "{place} at {time}?"), ("me", "👍")],
    [("them", "my phone is dying, text you later")],
    [("them", "run tomorrow? 6am"), ("me", "6am is a crime"), ("them", "7 then"), ("me", "fine")],
    [("me", "did you get home ok"), ("them", "yep, thanks for driving")],
    [("them", "sending you the photos from the hike"), ("me", "🙌")],
    [("them", "can you send me your share of the tickets, {num}"), ("me", "sent!"), ("them", "got it ty")],
    [("them", "new gym opens {day}, want to check it out"), ("me", "sure, after work?"), ("them", "{time} works")],
  ]

  static let marco: [Exchange] = [
    [("them", "Hi, this is Marco. The plumber will come {day} between {time} and noon."), ("me", "Thanks, I'll be home")],
    [("me", "Hi Marco, rent is sent via Zelle"), ("them", "Received, thank you")],
    [("them", "Reminder: building water will be off {day} from 9am to 1pm")],
    [("me", "The kitchen faucet is leaking again"), ("them", "I'll send someone {day}"), ("me", "Thank you")],
    [("them", "A package for you was left in the lobby")],
    [("them", "Fire alarm testing {day} morning, sorry for the noise")],
    [("me", "Hi, is it ok if I get a parking permit for a second car"), ("them", "Yes, $40 per month, I'll add it to rent")],
    [("them", "Gardeners will be here {day}, please move your car from the side lot")],
  ]

  static let family: [Exchange] = [
    [("mom", "Who is coming {day} for dinner?"), ("dad", "Me obviously"), ("priya", "I can come after {time}"), ("arjun", "👍"), ("me", "Me too")],
    [("arjun", "who took my charger"), ("priya", "not me"), ("dad", "Check the car")],
    [("priya", "Mom can you send the {dish} recipe again"), ("mom", "Sending tonight"), ("me", "Send me too")],
    [("arjun", "flight lands at {time}"), ("dad", "I'll pick you up"), ("arjun", "thanks dad")],
    [("mom", "Don't forget Nani's birthday is {day}"), ("priya", "Already ordered flowers 💐"), ("me", "Calling her in the morning")],
    [("priya", "Group call {day} at {time}?"), ("me", "works for me"), ("arjun", "I'll be 10 min late"), ("mom", "Ok")],
    [("dad", "Who wants to split a {thing}"), ("arjun", "how much"), ("dad", "{num} each"), ("priya", "pass 😂")],
    [("mom", "Good morning everyone 🌸"), ("priya", "morning!"), ("dad", "🙏")],
    [("arjun", "lol look at this"), ("priya", "😂😂😂"), ("me", "dying")],
    [("mom", "Papa is making {dish} {day}"), ("arjun", "say less"), ("priya", "I'm in"), ("me", "coming!")],
    [("priya", "ありがとう！ for the gift Mom"), ("mom", "Welcome beta ❤️")],
    [("dad", "Reminder to everyone: car insurance renews next month"), ("me", "noted"), ("arjun", "what car insurance")],
    [("me", "Anyone up for {movie} {day}?"), ("priya", "yes!"), ("arjun", "maybe"), ("mom", "You kids go")],
    [("arjun", "traffic is crazy, running late"), ("mom", "Drive slowly")],
    [("mom", "👨‍👩‍👧‍👦❤️"), ("priya", "🥹")],
  ]

  static let friends: [Exchange] = [
    [("a", "trivia {day}?"), ("b", "in"), ("c", "in"), ("me", "in!")],
    [("b", "who is bringing snacks"), ("me", "I'll bring {food}"), ("a", "legend")],
    [("a", "booked the cabin for {month}"), ("b", "how much each"), ("a", "{num} each"), ("me", "sending now")],
    [("b", "game night at mine {day}"), ("c", "what time"), ("b", "{time}"), ("me", "I'll bring {game}")],
    [("a", "ㅋㅋㅋ that was so bad"), ("me", "never again"), ("b", "we said that last time")],
    [("c", "running 5 late sorry"), ("a", "np")],
    [("me", "anyone have a ladder I can borrow"), ("b", "yes, come grab it {day}")],
    [("a", "who won last week"), ("b", "me obviously"), ("c", "we don't talk about it")],
    [("a", "happy friday 🎉"), ("b", "🍻")],
  ]

  static let jordan: [Exchange] = [
    [("them", "lunch {day}?"), ("me", "sure, {place}?"), ("them", "see you at {time}")],
    [("them", "can you review my doc when you get a sec"), ("me", "sending comments tonight"), ("them", "you're the best")],
    [("me", "how was the conference"), ("them", "exhausting but good"), ("them", "I'll tell you about it at lunch")],
    [("them", "대박 did you see the news"), ("me", "yes!! wild")],
    [("them", "are you free for a call"), ("me", "in 10?"), ("them", "👍")],
    [("me", "thanks for today"), ("them", "anytime 💛")],
    [("them", "recommend a book?"), ("me", "{book}"), ("them", "adding it to the list")],
  ]

  static let selfNotes: [String] = [
    "Buy: {groceries}",
    "Parking level 3, spot C14",
    "Book dentist cleaning",
    "Call insurance about the claim",
    "Gift ideas for Mom: scarf, {item}",
    "Return library books by {day}",
    "Idea: weekly family call on Sundays",
    "Cabin check-in after 4pm, lockbox on the porch",
    "Flight confirmation XK7P2Q",
  ]

  static let familyFillers = ["ok", "Ok", "👍", "❤️", "haha", "😂", "Yes", "Ok beta", "Thank you", "lol", "🙏", "Love you", "Sure"]
  static let friendFillers = ["lol", "lmao", "ok", "same", "😂", "omg", "wait what", "true", "yep", "nope", "haha", "👀", "sounds good", "bet"]
  static let landlordFillers = ["Thank you", "Ok", "Sounds good", "Thanks Marco"]

  // Long bodies, all over 400 characters.

  static let momRecipe = """
    Dal makhani recipe like you asked:
    1. Soak 1 cup whole urad dal and 1/4 cup rajma overnight. Rinse 3 times.
    2. Pressure cook with 4 cups water and salt for 8 whistles, then simmer 20 min.
    3. In a heavy pan heat 2 tbsp butter and 1 tbsp oil. Add 1 tsp cumin, then 1 chopped onion. Fry till golden, not brown.
    4. Add 1 tbsp ginger garlic paste, cook 2 min. Add 2 pureed tomatoes, 1 tsp kashmiri chili, 1/2 tsp garam masala.
    5. Cook till the oil separates, around 10 min. Add the dal with its water.
    6. Simmer on LOW for at least 45 min, stir every 10 min so it doesn't stick. The longer the better, Nani did 2 hours.
    7. Add 1/2 cup cream and 1 tbsp kasuri methi crushed between your palms. Salt to taste.
    Don't skip the overnight soak. Call me if it gets too thick, just add hot water. ❤️
    """

  static let jordanRant = """
    ok I need to vent for a sec. The offsite was supposed to be "light planning" and instead we spent six hours re-litigating the roadmap we agreed on in March. \
    Every time someone said "just to play devil's advocate" I lost a year of my life. Then the projector died, so we did the last two hours on someone's laptop \
    with everyone squinting, and the catering was a single sad tray of wraps. The good news is the team actually agreed to cut two projects, which I've been \
    asking for since spring, so maybe it was worth it? Anyway I am going to sleep for 12 hours. Lunch this week so I can tell you the rest?
    """

  static let priyaTripPlan = """
    Ok here is the plan for the Tahoe weekend: we leave Friday at 3 to beat traffic, Arjun and I drive up together, Mom and Dad come Saturday morning. \
    The cabin has 3 bedrooms so Mom and Dad get the big one, Arjun gets the couch (sorry not sorry). Saturday is the lake and a short hike, Sunday brunch \
    at that pancake place Dad likes and then we head back by 2. I made a shared list for groceries, please add what you want. Budget is about 180 each \
    including gas. Say yes or no by Wednesday so I can confirm the booking!!
    """

  /// A pasted note of roughly 9,000 characters, for testing body truncation and `show` limits.
  static func longNote() -> String {
    var out = "Notes from the apartment search, pasted from my laptop\n\n"
    let sections = [
      "Unit on Alder St", "Unit on Birch Ave", "Unit on Cedar Ct", "Unit on Dogwood Ln", "Unit on Elm Row",
      "Unit on Fir Way", "Unit on Gum Tree Pl", "Unit on Hazel St", "Unit on Ivy Ter", "Unit on Juniper Rd",
      "Unit on Kauri Ct", "Unit on Linden Ave", "Unit on Maple Dr", "Unit on Nutmeg Ln", "Unit on Oak Bluff",
      "Unit on Pine Crest", "Unit on Quince St", "Unit on Redwood Pl", "Unit on Spruce Ave", "Unit on Tamarack Ct",
    ]
    for (i, name) in sections.enumerated() {
      out += "\(i + 1). \(name)\n"
      out += "Rent \(2400 + i * 35) per month, deposit one month. Laundry in unit: \(i % 3 == 0 ? "yes" : "no"). "
      out += "Parking: \(i % 2 == 0 ? "one assigned spot" : "street only"). Commute about \(18 + i) minutes by bike. "
      out += "Light is good in the afternoon, kitchen is small but has a gas stove. The landlord answered within a day. "
      out += "Noise from the street was \(i % 4 == 0 ? "noticeable" : "fine") during the visit. Pets allowed with a deposit. "
      out += "Follow up: ask about the lease length, utilities, and whether the second bedroom fits a desk.\n\n"
    }
    return out
  }
}
