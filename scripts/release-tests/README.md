# Release tests

These scripts run the release tests in DESIGN.md ("Release tests", 1 to 8) on the maintainer's Mac before each tag. Passing capabilities go into `packaging/release-evidence.json`, and `scripts/build.sh` copies that file into the app at the next build. A capability with no record for the running macOS major.minor stays off in `caps`.

Nothing here runs in CI. The tests send real iMessages to your own Apple ID, and you click the approval dialogs yourself.

## Files

| File | What it does |
| --- | --- |
| `run.sh` | Runs the tests in order, prints a summary and the tag check, and writes the evidence |
| `lib.sh` | Helpers the tests share |
| `t1-bridge.sh` to `t8-files-groups.sh` | One script per release test. `t6-fullscreen.sh` takes `a` or `b` |
| `sampler.swift` | Records every on-screen Messages window, the front app and HID input every 10 ms, as its own process |
| `hid-inject.swift` | Posts synthetic input at the HID tap for test 5 |
| `write-evidence.swift` | Turns a run's outcomes into evidence records |

The Swift tools compile on first use into the run's `bin/` folder with `swiftc` from the Xcode Command Line Tools. Every action goes through the `imessage` CLI, so the bridge performs it under its own grants.

## Before you run

1. Build both apps with the signing variables `scripts/build.sh` describes:
   ```sh
   scripts/build.sh
   scripts/build.sh --release-tests
   ```
2. Install the release from `out/`, then turn on the grants:
   ```sh
   IMESSAGE_AGENT_TARBALL="$PWD/out/imessage-agent-<version>.tar.gz" bash out/install.sh
   ~/.local/bin/imessage setup
   ~/.local/bin/imessage doctor --ui
   ```
3. Swap in the release-test build:
   ```sh
   rsync -a --delete "out/release-tests/iMessage Agent.app/" "$HOME/Applications/iMessage Agent.app/"
   cp out/release-tests/imessage "$HOME/.local/bin/imessage"
   launchctl kickstart -k "gui/$(id -u)/io.github.krishhgg.imessage-agent"
   ```
   It has the same bundle id and signing identity, so the grants carry over. `imessage caps` now says "release-test build" and reports every capability as supported. `run.sh` refuses to start without that header.
4. For test 5 only, give your terminal app Accessibility in System Settings, Privacy & Security, so `hid-inject` can post events. Turn it off after the run.
5. Set the environment variables below.

When you're done, run the `install.sh` command from step 2 again and check that `imessage caps` no longer says "release-test build". The release-test build turns on actions that have no evidence, so don't keep using it.

## Environment variables

| Variable | Used by | Meaning |
| --- | --- | --- |
| `IMSG_TEST_HANDLE` | all, required | Your own Apple ID email or +phone. The tests send only to it, plus the opt-in chats below |
| `IMSG_TEST_CONSENT=1` | opt-in cases | Everyone in the chats below agreed to get test messages, tapbacks and replies |
| `IMSG_TEST_PEER` | 2, 4, 6b, 8 | A person who sends you messages during the run: an incoming Heart, threaded replies, a HEIC photo |
| `IMSG_TEST_GROUP` | 3, 8 | A group chat number from `imessage chats` |
| `IMSG_TEST_TWIN_A`, `IMSG_TEST_TWIN_B` | 3 | Two 1:1 chats whose contacts share a display name |
| `IMSG_TEST_SIG_A`, `IMSG_TEST_SIG_B` | 3 | Two 1:1 chats you can give identical newest messages |
| `IMSG_TEST_OLD_CHAT` | 3 | A 1:1 chat whose newest message is from an earlier day |
| `IMSG_TEST_MERGED` | 3 | A contact with both an iMessage and an SMS chat |
| `IMSG_TEST_EMOJI` | 2 | One emoji from the recent list in Messages' tapback menu |
| `IMSG_TEST_HEIC` | 8 | A HEIC photo of at least 2 MB to send to yourself |
| `IMSG_CLI` | all | The CLI to drive. Defaults to `~/.local/bin/imessage` |
| `NEAR_LEAD` | 5, 6b | Seconds before an edit window closes that you click Allow for a timed edit. Defaults to 3 and adapts |

Cases whose variables aren't set are skipped, and the capabilities they cover stay off. Without consenting people, that means targeting, the incoming-message Heart, threaded replies, `att` conversion and group sends.

## Running

Run test 7 first (below), then the main run with its outcome file, and the foreground tests on another day:

```sh
export IMSG_TEST_HANDLE=you@example.com
scripts/release-tests/run.sh --with-t7 /Users/Shared/imessage-agent-t7.txt   # tests 1, 2, 3, 6a and 8, plus 7
scripts/release-tests/run.sh --foreground --only t4,t5,t6b                    # foreground tests, on another day
```

`--with-t7` adds test 7's outcome to that run. It doesn't run anything more. `--only` takes any of `t1 t2 t3 t4 t5 t6a t6b t8`, and `t4`, `t5` and `t6b` need `--foreground`. `--no-evidence` leaves `packaging/release-evidence.json` alone.

Test 7 runs on a fresh macOS user account, on the same macOS major.minor. From the repo in your own account, copy this folder and `out/`:

```sh
mkdir -p /Users/Shared/imessage-agent-t7
cp -R scripts/release-tests out /Users/Shared/imessage-agent-t7/
```

Log in as the new user, then:

```sh
cd /Users/Shared/imessage-agent-t7
IMESSAGE_AGENT_TARBALL="$PWD/out/imessage-agent-<version>.tar.gz" bash out/install.sh
IMSG_TEST_HANDLE=you@example.com release-tests/t7-fresh-account.sh
```

Its log goes to `~/imessage-agent-release-tests/` in that account. It writes `/Users/Shared/imessage-agent-t7.txt`, which holds only its outcome lines. It never writes over a file that is already there, so delete an older copy first from the account that made it. Back in your own account, pass the file with `--with-t7`.

What to expect:
- The bridge allows 30 sends per chat in 24 hours. A run without `--foreground` sends about 15 messages to your own chat, and tests 4, 5 and 6b send about 22 more, so run them on different days.
- After 3 sends in a row to a chat with no incoming message in between, each send asks for approval. Your own chat has no incoming messages, so expect a dialog for most sends. Click Allow once, never Always allow.
- Sends are spaced 21 s apart for the bridge's 20 s per-chat limit.
- Test 5 sends 12 messages and waits for their 15-minute edit windows to close one by one, so expect it to take 45 minutes or more. Test 6b waits for one such window, about 20 minutes.
- The tests ask you to click Finder, quit or hide Messages, and touch nothing during sampled cases. Input in the 1 s before a sampled change turns a failure into a rerun. A sample that starts with Messages in front or with a Messages window on screen is invalid and runs again.

## Outcomes and evidence

Each run writes `outcomes.txt` with one line per result:

```
cap <pass|fail|skip|rerun> <capability> <test> <detail>
gate <pass|fail|skip|rerun> <name> <test> <detail>
case <status> t<n>-<name> <test> <detail>
env macos <major.minor> bridge <version>
```

`cap` lines feed `write-evidence`. For each capability on this macOS version, any fail removes its records, so `caps` turns it off. Passes for every test it needs write one record per test. Anything else leaves its records as they were. Capabilities and the tests they need:

| Capability | Tests |
| --- | --- |
| `tapback.heart` | 1 and 2 |
| `unsend`, `hidden-chat-switch` | 1 |
| `tapback.like`, `.dislike`, `.laugh`, `.emphasize`, `.question`, `.emoji`, `.incoming` | 2 |
| `targeting` | 3 |
| `edit`, `threaded-reply` | 4 and 6 |
| `foreground-mode` | 5 and 6 |
| `image-send`, `attachment-conversion`, `group-send` | 8 |

`gate` lines decide the tag. The tag is blocked unless these passed: `cold-text-send`, `cold-file-send`, `cold-ui-action`, `warm-text-send`, `no-window-relaunch`, `other-space-busy` and `fullscreen-space-busy` (test 1), `fullscreen-panel` (6a) and `fresh-account` (7). The last two test 1 gates check that a hidden action answers busy, and doesn't quit Messages, while Messages has a window on another Space or full screen in its own Space. A failed `image-send` or `group-send` gate (test 8) also blocks it, because a send showed Messages or changed the front app. If Messages keeps a closed window in the window server's list, `no-window-relaunch` passes only when the first try is busy with the hide fix and, after Command-H, the second try relaunches Messages and presses. A run with `--only` reports the gates it skipped as "not run", so the tag check needs the full run's summary too.

`case` lines record single cases in tests 3 and 5 and don't feed the evidence.

After a run, commit `packaging/release-evidence.json`, rebuild with `scripts/build.sh`, and add the macOS version to the README's tested list only when its release tests passed.

## Bridge markers

Tests 4, 5 and 6b time the foreground steps from lines the release-test build writes to `~/Library/Application Support/iMessage Agent/bridge.log` right before each step:

```
release-test <unix ms> <event> [detail]
```

Events: `phase <name>` for each foreground phase (`idleGate`, `preconditions`, `activationCheck`, `activating`, `lateActivationWatch`, `front`, `beforeReturn`, `takeover`, `bridgeOwnedCleanup`, `finishing`, `verifying`, `done`), plus `field-set`, `field-restore`, `field-reset`, `key return`, `key escape`, `hide` and `focus-restore`. A normal build writes none. Without them, test 4's timing check fails and test 5 reports a rerun.

Test 4 measures from the sampler's first sample with Messages frontmost to the `key return` marker, and passes only when that is 3 s or less. It gives the `phase front` marker's offset from that sample in its detail only as a cross-check, because the bridge writes that marker from its own record of `t_front`.

The tests read each marker as "this step's ownership check passed and its effect comes next". Test 5 aims its input right after a marker and counts any `key`, `hide` or `focus-restore` marker more than 15 ms after the input as the bridge acting after a takeover, so the takeover reset must not write a `key` marker. Test 5 also checks the sampler for a Messages hide or a front-app change more than 100 ms after the input, which doesn't depend on the markers.

## Results stay on this Mac

Each run writes to `results/<macOS>-<date>/`, mode 0700, which `.gitignore` excludes. It holds `outcomes.txt`, `env.txt`, the samples (pids, window bounds, layers, bundle ids and input times, never window titles) and logs of every CLI call. The logs include the text of your test messages and of anything the tests read from a consenting person's chat. Don't upload them or attach them to issues.
