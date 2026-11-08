import XCTest

/// Guards the rules a fake can't observe: what the live code is allowed to call, and that the release-test switch
/// exists only at compile time. Reads the IMUI sources as text.
final class SourceGuardTests: XCTestCase {
    static let sourceDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/IMUI")

    /// (file name, code lines with whole-line comments dropped).
    func codeLines() throws -> [(String, [String])] {
        let files = try FileManager.default.contentsOfDirectory(at: Self.sourceDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        return try files.map { url in
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            return (url.lastPathComponent, lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") })
        }
    }

    func testNoForbiddenMechanismsInCode() throws {
        // Item 3 and item 5: no imessage:// URL, no Window > Messages press, no System Events, no other script
        // runner, no synthetic input, no launchd or TCC tools.
        let forbidden = ["imessage:", "System Events", "osascript", "NSAppleScript", "CGEvent", "launchctl",
                         "lsregister", "tccutil", "Library/Messages", "activate(", "NSWorkspace.shared.open",
                         "openApplication", "kAXRaiseAction", "\"AXRaise\"", "AXUIElementPostKeyboardEvent",
                         "fatalError("]
        for (file, lines) in try codeLines() {
            for line in lines {
                for word in forbidden {
                    XCTAssertFalse(line.contains(word), "\(file): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
    }

    func testOnlyAXPressAndNamedActionsArePerformed() throws {
        // Every AXUIElementPerformAction passes either "AXPress" or a full name found on the element.
        for (file, lines) in try codeLines() {
            for line in lines where line.contains("AXUIElementPerformAction(") {
                XCTAssertTrue(line.contains("\"AXPress\" as CFString") || line.contains("full as CFString"),
                              "\(file): \(line)")
            }
            for line in lines where line.contains("AXUIElementSetAttributeValue(") {
                XCTAssertTrue(line.contains("\"AXValue\""), "\(file): only value writes: \(line)")
            }
        }
    }

    /// The body of the `func` whose declaration line contains `declaration`: the lines after it up to the closing
    /// brace at the declaration's indent.
    func body(of declaration: String, in lines: [String]) -> [String] {
        guard let start = lines.firstIndex(where: { $0.contains(declaration) }) else { return [] }
        let indent = String(lines[start].prefix { $0 == " " })
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { $0 == indent + "}" } ?? lines.endIndex
        return Array(lines[(start + 1)..<end])
    }

    func testLiveReadsHandFailuresToAXRead() throws {
        // Section 4 foreground step 1 and every pre-press check need reads that can fail loudly: a failed read,
        // a timeout included, must never stand in for "" or for no children.
        let ax = try codeLines().first { $0.0 == "AX.swift" }!.1
        let made = ax.filter { $0.contains("FieldInfo(ref:") }
        XCTAssertEqual(made.count, 1, "one place makes a FieldInfo: \(made)")
        XCTAssertTrue(made.allSatisfy { $0.contains("try Self.fieldValue(") }, "\(made)")
        XCTAssertTrue(body(of: "func fieldValue(_ field: AXUIElement)", in: ax).joined().contains("AXRead.fieldValue("))
        XCTAssertTrue(body(of: "public func readValue(of field: AXRef)", in: ax).joined().contains("Self.fieldValue("))
        XCTAssertTrue(body(of: "func attribute(_ element: AXUIElement", in: ax).joined().contains("AXRead.optional("))
        XCTAssertTrue(body(of: "func children(of element: AXUIElement)", in: ax).joined().contains("AXRead.present("))
        XCTAssertTrue(body(of: "func walkAXTree<Node>", in: ax).joined().contains("AXRead.present("))
        for line in ax { XCTAssertFalse(line.contains("== .success ? value : nil"), line) }
    }

    func testLaunchUsesOpenHidden() throws {
        let app = try codeLines().first { $0.0 == "MessagesApp.swift" }!.1.joined(separator: "\n")
        XCTAssertTrue(app.contains("Self.runOpen([\"-g\", \"-j\", \"-b\", bundleID])"))
        XCTAssertTrue(app.contains("URL(fileURLWithPath: \"/usr/bin/open\")"))
        XCTAssertTrue(app.contains("scripts.call(.quitMessages, arguments: [])"))
        // The caller holds the queue, so the wait for `open` is bounded.
        XCTAssertFalse(app.contains("waitUntilExit()"))
        XCTAssertTrue(app.contains("exited.wait(timeout: .now() + openTimeout)"))
    }

    func testActivationDoesNotWaitForOpenToExit() throws {
        // Section 4 step 3: `t_front` comes from polling the front app while `open -b` runs.
        let lines = try codeLines().first { $0.0 == "MessagesApp.swift" }!.1
        let body = body(of: "public func activateForeground()", in: lines).joined()
        XCTAssertTrue(body.contains("activation.start(Self.openURL, [\"-b\", bundleID])"), body)
        XCTAssertFalse(body.contains("runOpen"), body)
        let start = self.body(of: "func start(_ executable: URL, _ arguments: [String])", in: lines).joined()
        XCTAssertTrue(start.contains("LiveMessagesApp.startProcess(executable, arguments)"), start)
        // The late-activation watch stops that same `open` when it ends.
        let end = self.body(of: "public func endActivation()", in: lines).joined()
        XCTAssertTrue(end.contains("activation.end()"), end)
    }

    func testLiveWindowCountsOnEverySpaceUseTheSizeFloor() throws {
        // The full window list holds four menu bar strips for every app with windows, so the count on every Space and
        // the earlier front app's hasWindows both go through the size-floor filter `realWindowCount`.
        let lines = try codeLines().first { $0.0 == "MessagesApp.swift" }!.1
        let state = body(of: "public func state() -> MessagesAppState", in: lines).joined()
        XCTAssertTrue(state.contains("let allWindows = Self.allWindows()"), state)
        XCTAssertTrue(state.contains("allSpacesWindowCount = Self.realWindowCount(pid: pid, in: allWindows)"), state)
        // The Space count reads the same list, so the two counts describe one moment.
        XCTAssertTrue(state.contains(
            "spaceWindowCount = Self.spaceWindowCount(pid: pid, in: allWindows, spaces: WindowSpaces.count(of:))"), state)
        XCTAssertTrue(state.contains("spaceWindowCount: spaceWindowCount,"), state)
        // The lock is read before the not-running return, so a quit Messages on a locked screen isn't launched
        // (docs/BUILD-PLAN.md entry 52), and both returns carry it.
        XCTAssertTrue(state.trimmingCharacters(in: .whitespaces).hasPrefix("let screenLocked = ScreenLock.isLocked()"), state)
        XCTAssertTrue(state.contains("state.isScreenLocked = screenLocked"), state)
        XCTAssertTrue(state.contains("isScreenLocked: screenLocked)"), state)
        let normal = body(of: "private static func hasNormalWindow(pid: pid_t)", in: lines).joined()
        XCTAssertTrue(normal.contains("realWindowCount(pid: pid, in: allWindows()) > 0"), normal)
        XCTAssertFalse(normal.contains("CGWindowListCopyWindowInfo"), normal)
        let all = body(of: "private static func allWindows()", in: lines).joined()
        XCTAssertTrue(all.contains("CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)"), all)
    }

    func testTheLiveStateSamplesHiddenAndFrontmostAfterTheWindowReads() throws {
        // The state is the window rules check inside a hidden action's final check and inside the row press, so the
        // reads that can block (the AX count, with its 2 s timeout, and both window lists) come first, and `isHidden`
        // and frontmost are sampled last.
        let lines = try codeLines().first { $0.0 == "MessagesApp.swift" }!.1
        let state = body(of: "public func state() -> MessagesAppState", in: lines).joined(separator: "\n")
        func position(_ text: String) throws -> String.Index {
            XCTAssertEqual(state.components(separatedBy: text).count, 2, "\(text) once in state()")
            return try XCTUnwrap(state.range(of: text)?.lowerBound, text)
        }
        let reads = try ["Self.axWindowCount(pid: pid)", "Self.onScreenWindowCount(pid: pid)", "Self.allWindows()"]
            .map(position)
        let samples = try ["running.isHidden", "NSWorkspace.shared.frontmostApplication?.processIdentifier"]
            .map(position)
        XCTAssertLessThan(try XCTUnwrap(reads.max()), try XCTUnwrap(samples.min()), state)
    }

    func testTheRowPressFillsAnUnknownAXCountAsTheManagerDoes() throws {
        // `HiddenWindowManager.state(of:countWindows:)` takes the state again after its fallback AX read, which the
        // fakes check. The live row press must use it too, since its own AX read can't run in a test.
        let ax = try codeLines().first { $0.0 == "AX.swift" }!.1
        let press = body(of: "public func press(row: AXRef, finalCheck: AXFinalCheck) throws {", in: ax).joined()
        XCTAssertTrue(press.contains("try Self.requireHiddenWindow(hiddenWindowState())"), press)
        let state = body(of: "private func hiddenWindowState() -> MessagesAppState", in: ax).joined()
        XCTAssertTrue(state.contains("HiddenWindowManager.state(of: app, countWindows: { try windows().count })"), state)
        XCTAssertFalse(state.contains("app.state()"), state)
    }

    func testTheLiveFrontmostReadReadsNoAXAndNoWindowList() throws {
        // The ownership check and the foreground polls use it inside the 1 s and 3 s windows.
        let lines = try codeLines().first { $0.0 == "MessagesApp.swift" }!.1
        let front = body(of: "public func isFrontmost() -> Bool", in: lines).joined()
        XCTAssertTrue(front.contains("NSWorkspace.shared.frontmostApplication?.processIdentifier == pid"), front)
        for word in ["AX", "CGWindowList", "state()", "WindowCount"] {
            XCTAssertFalse(front.contains(word), "\(word) in \(front)")
        }
    }

    func testEditFieldNeverPicksOneOfSeveral() throws {
        let ax = try codeLines().first { $0.0 == "AX.swift" }!.1
        XCTAssertTrue(body(of: "public func editField()", in: ax).joined().contains("Self.onlyEditField("))
        let walk = body(of: "func walkAXTree<Node>", in: ax).joined()
        XCTAssertTrue(walk.contains("guard visited < maxNodes else { throw AXDriveError.walkLimit }"), walk)
    }

    func testReleaseTestConditionIsCompileTimeOnly() throws {
        var uses = 0
        for (file, lines) in try codeLines() {
            for line in lines where line.contains("IMESSAGE_RELEASE_TESTS") {
                uses += 1
                XCTAssertTrue(line.trimmingCharacters(in: .whitespaces).hasPrefix("#if"), "\(file): \(line)")
            }
            let text = lines.joined(separator: "\n")
            if file == "Capabilities.swift" {
                XCTAssertFalse(text.contains("ProcessInfo.processInfo.environment"), "no run-time switch")
                XCTAssertFalse(text.contains("CommandLine"), "no run-time switch")
                XCTAssertFalse(text.contains("UserDefaults"), "no run-time switch")
            }
        }
        XCTAssertGreaterThan(uses, 0)
    }

    func testEveryAXMutationRunsTheFinalCheckRightBeforeIt() throws {
        // `AXFinalCheck`: in the live driver, each press and write is directly preceded by `try finalCheck()`, with
        // no AX read between them, and each mutation runs its caller's check exactly once.
        let ax = try codeLines().first { $0.0 == "AX.swift" }!.1
        let code = ax.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let mutations = code.indices.filter {
            code[$0].contains("AXUIElementPerformAction(") || code[$0].contains("AXUIElementSetAttributeValue(")
        }
        XCTAssertEqual(mutations.count, 4, "row press, bubble action, menu item press, value write")
        for index in mutations {
            let line = code[index]
            XCTAssertGreaterThan(index, 0)
            XCTAssertEqual(code[index - 1], "try finalCheck()", "not directly after the final check: \(line)")
            XCTAssertEqual(line.components(separatedBy: "AXUIElement").count, 2, "an AX call inside: \(line)")
            XCTAssertEqual(line.components(separatedBy: "Self.").count, 2, "a read inside: \(line)")
            XCTAssertTrue(line.hasPrefix("try Self.check(AXUIElement"), "\(line)")
        }
        XCTAssertEqual(code.filter { $0.contains("finalCheck()") }.count, 4, "the final check runs only there")
        for declaration in ["public func press(row: AXRef, finalCheck: AXFinalCheck) throws {",
                            "public func perform(action: String, on bubble: AXRef, finalCheck: AXFinalCheck) throws {",
                            "public func press(menuItem: AXRef, finalCheck: AXFinalCheck) throws {",
                            "public func setValue(_ value: String, of field: AXRef, finalCheck: AXFinalCheck) throws {"] {
            let lines = body(of: declaration, in: ax)
            XCTAssertEqual(lines.filter { $0.contains("try finalCheck()") }.count, 1, declaration)
            let check = lines.firstIndex { $0.contains("try finalCheck()") } ?? lines.endIndex
            let effect = lines.firstIndex {
                $0.contains("AXUIElementPerformAction(") || $0.contains("AXUIElementSetAttributeValue(")
            }
            XCTAssertEqual(effect, check + 1, declaration)
        }
    }
}
