# Grok CLI research for a shared iMessage agent repo

Date: 2026-11-05.

## How to read this report

Each claim carries a tag in square brackets with its status and source.

- verified means I ran it or read it directly on this machine, and the output is saved under /tmp/gbim-research/grokcli/out/.
- reported means a document says so, but I did not test it.
- inferred means it is my conclusion from the evidence, and it has not been tested.

I tested in isolation. Every grok command ran with HOME=/tmp/gbim-research/grokcli/fakehome and GROK_HOME=/tmp/gbim-research/grokcli/fakehome/.grok. GROK_DISABLE_AUTOUPDATER=1 was set, and each run used an `env -i` environment. The test projects were /tmp/gbim-research/grokcli/layout-test and /tmp/gbim-research/grokcli/mkt-test. I made no model calls and did not touch ~/.grok. A check after the tests found no file in ~/.grok newer than the start of testing [verified: `find ~/.grok -newer ...`, output empty]. I did not read ~/.grok/auth.json, ~/Library/Messages or any credential file.

Versions:

- grok CLI: Grok Build 1.0.70. ~/.grok/bin/grok is a symlink to ~/.grok/downloads/grok-1.0.70-macos-aarch64, a 179 MB Rust binary [verified: `ls -la`, `grok inspect --json` reports `"grokVersion": "1.0.70"`].
- Grok Bot app: 0.79.2, with bundle id com.anysphere.sand. It is an Electron app whose package.json has homepage https://cursor.com [verified: /Applications/Grok Bot.app/Contents/Info.plist, /tmp/gbim-research/grokbot/app/package.json].

## Summary

- The grok CLI discovers more locations than any other harness. It reads AGENTS.md and CLAUDE.md. It reads skills from `.agents/skills`, `.grok/skills`, `.claude/skills` and `.cursor/skills` at both project and user level. It reads MCP servers from `.grok/config.toml`, `.mcp.json` and `~/.claude.json` [verified: inspect runs below].
- Folder trust gates every project-level source except MCP listing. Headless runs need `--trust` or a saved grant. `--trust` is a hidden top-level flag that does not appear in `--help` [verified].
- One repo can serve grok CLI, Claude Code, Codex and the Grok Bot app. It needs one canonical skill folder, symlinks for Claude Code, a plugin in a subfolder, and user-level MCP registration done by an install script. The proposed layout is at the end.
- The grok CLI and the Grok Bot app do not share config or a marketplace. They overlap only on skill folders: Grok Bot scans `.agents/skills` and `.grok/skills`, among others [verified: Grok Bot bundle strings].
- The grok sandbox is off by default, so the grok layer blocks nothing. macOS privacy controls (TCC) still apply to whichever process launches grok [reported: 18-sandbox.md; inferred for TCC].

## 1. Discovery and install in the grok CLI

### Project instructions

- Grok loads files named Agents.md, Claude.md, CLAUDE.md, CLAUDE.local.md, AGENT.md and AGENTS.md. It also loads `.claude/CLAUDE.md` and `.claude/CLAUDE.local.md`, and rule folders `.grok/rules`, `.claude/rules` and `.cursor/rules` [reported: ~/.grok/docs/user-guide/12-project-rules.md].
- Every matching file in a directory loads. Grok walks from the repo root down to the cwd, and global files load from ~/.grok [reported: 12-project-rules.md, ~/.grok/README.md].
- In the test project, which had both AGENTS.md and CLAUDE.md, grok loaded both. inspect reported 17 approximate tokens for the 69-byte AGENTS.md and 8 tokens for the 32-byte CLAUDE.md [verified: /tmp/gbim-research/grokcli/out/inspect-trusted.json].
  - The cost is about 4 bytes per token, and a duplicated CLAUDE.md doubles the cost in grok [inferred].
- Untrusted folders load no project instructions. `projectInstructions` was `[]` when the folder was untrusted [verified: /tmp/gbim-research/grokcli/out/inspect-untrusted.json].
- The size cap is contradictory.
  - 12-project-rules.md says "Grok loads each project instruction file in full; there is no character cap and no truncation" [reported].
  - The README says each file is capped at 10,000 characters [reported: ~/.grok/README.md].
  - Both texts are embedded in the 1.0.70 binary [verified: /tmp/gbim-research/grokcli/out/strings.txt lines 5977 and 27426].
  - The user-guide text is likely the newer one, because the README conflicts with the user guide on other points too [inferred].
- 12-project-rules.md does not mention `@path` import expansion, so a CLAUDE.md that contains only `@AGENTS.md` probably reaches grok as a few literal tokens [inferred].

### Skills

- Skill format is a folder that holds SKILL.md with YAML frontmatter. `name` falls back to the folder name, and `description` falls back to the first paragraph.
  - Optional keys are when-to-use, allowed-tools, argument-hint, user-invocable, disable-model-invocation, model, effort, license, compatibility and metadata.
  - Inline `` !`cmd` `` text does not execute.
  - [reported: ~/.grok/docs/user-guide/08-skills.md]
- Project tier. In a trusted folder, grok found `.grok/skills/grok-only`, `.agents/skills/imessage` and `.claude/skills/claude-only`. It tagged the Claude one `"vendor": "claude"`. A root-level `skills/` folder was not read in project mode [verified: inspect-trusted.json].
- User tier. Grok found `~/.grok/skills`, `~/.agents/skills` and `~/.claude/skills` without any folder trust [verified: inspect run from /tmp/gbim-research/grokcli/emptycwd with skills in the fake home].
- Grok removes duplicates by name. A skill named imessage in both `.agents/skills` and `.claude/skills` showed once, from the `.agents/skills` path. This held for a symlink and for a plain copy [verified: inspect-symlink.json, inspect-copy.json].
- Grok follows a symlinked skill folder. `~/.agents/skills/linked-skill` and `~/.claude/skills/linked-skill`, both symlinks to one target, produced one entry [verified: inspect run in the fake home].
- Grok inlines a skill body up to 25,000 tokens, the same cap as read_file [reported: 08-skills.md].
- A plugin skill and a native skill with the same name both appear. The plugin one is reached as `/plugin:name`. With the test plugin installed and the repo as cwd, inspect listed imessage twice, once as `project` and once as `plugin` [verified: inspect-flagtrust.json; reported: 08-skills.md].
- Toggles are `[compat.claude] skills = false` and GROK_CLAUDE_SKILLS_ENABLED [reported: 08-skills.md].

### Plugins and marketplaces

- A plugin folder holds any of `skills/`, `commands/`, `agents/`, `hooks/hooks.json`, `.mcp.json` and `.lsp.json`. Its optional manifest is `.grok-plugin/plugin.json` or `.claude-plugin/plugin.json` [reported: 09-plugins.md].
- `grok plugin validate .` passed on a folder that had only `.claude-plugin/plugin.json`. It reported "1 skill dir(s) ... MCP servers" [verified].
- The binary prints "No plugin.json found. Grok discovers skills, agents, and hooks automatically from standard directories" when no manifest exists [verified: strings.txt].
- `grok plugin install <path>` without `--trust` stops with "Installing from directory ... requires confirmation" [verified].
- With `--trust`, install copies the whole folder, including `.git`, into `$GROK_HOME/installed-plugins/<name>-<hash>/`. It also adds the name to `[plugins] enabled` in config.toml [verified: /tmp/gbim-research/grokcli/fakehome/.grok].
- An installed plugin contributed its root `skills/` and its `.mcp.json`. Its AGENTS.md and CLAUDE.md were not loaded as instructions [verified: inspect-plugin.json].
- A manifest key `"skills": "./.agents/skills/"` replaced the default `skills/` folder in grok. With the key set, the plugin exposed only the `.agents/skills` skill [verified: inspect-plugin2.json].
  - Claude Code adds to the default `skills/` scan instead of replacing it [reported: https://code.claude.com/docs/en/plugins-reference].
  - The two harnesses behave differently when both folders exist [inferred].
- A plugin `.mcp.json` command of `${CLAUDE_PLUGIN_ROOT}/bin/imsg-mcp` expanded to the installed path, `.../installed-plugins/layout-test-13b8ec2f/bin/imsg-mcp` [verified: inspect-pluginroot.json].
- In a project `.mcp.json`, `${CLAUDE_PLUGIN_ROOT:-/opt/fallback}` expanded to the fallback. A relative command `./bin/imsg-mcp` stayed relative [verified: inspect-projroot.json].
- A local marketplace whose index is `.claude-plugin/marketplace.json` worked when the plugin sat in a subfolder (`"source": "./plugins/subplug"`). `grok plugin install subplug --trust` installed it [verified: /tmp/gbim-research/grokcli/mkt-test].
- A marketplace entry that points at the marketplace root itself (`"source": "./"`, or `{"type": "local", "path": "./"}`) was dropped without any message. It was missing from `plugin list --json --available`, and install by name failed with "No marketplace plugin named ..." [verified: layout-test and mkt-test runs].
  - The planning-with-files repo uses that root form for Claude Code [verified: ~/.grok/marketplace-cache/a50e79b44374dcad/.claude-plugin/marketplace.json].
  - Grok 1.0.70 does not accept it [verified].
- Marketplace commands:
  - `grok plugin marketplace add owner/repo|git-url|./path`, with list, update and remove.
  - `grok plugin install <name|owner/repo[@ref]|url|path> --trust`.
  - `grok plugin list [--json] [--available]`, plus uninstall, enable, disable, details, validate and tag.
  - [verified: /tmp/gbim-research/grokcli/out/help-plugin*.txt; reported: 09-plugins.md]
- Plugins are off until enabled through `[plugins] enabled`. `~/.grok/plugins/` is auto-trusted, and project `.grok/plugins/` needs trust [reported: 09-plugins.md].
- A default config registers the "xAI Official" marketplace (https://github.com/xai-org/plugin-marketplace.git) [verified].
- ~/.grok/marketplace-cache can also hold clones of Claude Code marketplaces listed in ~/.claude/plugins/known_marketplaces.json [verified].
  - So grok imports Claude Code marketplaces [inferred; the README lists known_marketplaces.json as a compat source, reported].
- No plugins are installed in the real ~/.grok. `installed-plugins` holds only registry.lock [verified].

### MCP servers

- Config keys are `[mcp_servers.<name>]` with command, args, env, url, headers, enabled, startup_timeout_sec (default 30), tool_timeout_sec and tool_timeouts [reported: ~/.grok/docs/user-guide/07-mcp-servers.md].
- `${VAR}` and `${VAR:-default}` expand in the command, args, env and headers [reported: 07-mcp-servers.md; verified for default expansion].
- `grok mcp add imessage --scope project -e IMSG_DB=/dev/null -- /usr/bin/true --flag` wrote `[mcp_servers.imessage]` with `enabled = true` and an `[mcp_servers.imessage.env]` table to `./.grok/config.toml` [verified].
  - Without `--scope`, it wrote to `$GROK_HOME/config.toml` [verified].
- Merge priority is config.toml first, then ~/.claude.json, then Cursor, then `.mcp.json` [reported: 07-mcp-servers.md].
  - In the test, a plugin's `.mcp.json` server replaced a project `.mcp.json` server with the same name [verified: inspect-flagtrust.json].
- inspect lists project `.mcp.json` and `.grok/config.toml` servers even in an untrusted folder [verified: inspect-untrusted.json].
  - The docs say project MCP servers do not start until the folder is trusted [reported: 10-hooks.md, strings.txt line 4957].
- The model reaches MCP tools only through two meta-tools, `search_tool` and `use_tool`. Their catalog keys look like `server__tool` [reported: 07-mcp-servers.md].
  - Unused MCP tool schemas cost no prompt tokens, but every call needs a search step first [inferred].
- A tool can be missing on the first prompt while its handshake is still running [reported: 07-mcp-servers.md line 458].
- Server stderr goes to `~/.grok/logs/mcp/<server>.stderr.log` [reported: 07-mcp-servers.md].
- Server names must start with a letter or underscore, and tool names must match `[A-Za-z0-9_-]` [reported: 07-mcp-servers.md].

### Hooks

- Hook sources are:
  - ~/.grok/hooks/*.json
  - ~/.claude/settings.json and ~/.claude/settings.local.json
  - ~/.cursor/hooks.json
  - <project>/.grok/hooks/*.json
  - <project>/.claude/settings.json and <project>/.claude/settings.local.json
  - <project>/.cursor/hooks.json
  - config.toml
  - plugin hooks/hooks.json
  - [reported: ~/.grok/docs/user-guide/10-hooks.md]
- Folder trust gates all of these. A headless run counts the folder as trusted for user hooks only [reported: 10-hooks.md, strings.txt line 4956].
- Grok differs from Claude Code on context injection.
  - SessionStart and other observe-only events read only a top-level `systemMessage` [reported: 10-hooks.md line 528].
  - For UserPromptSubmit, "an allowing hook's stdout / additionalContext is discarded rather than added as context" [reported: 10-hooks.md line 689].
  - PreToolUse and PostToolUse can send `additionalContext`, clipped at 10,000 characters. PostToolUse can also replace the tool output with `updatedToolOutput` [reported: 10-hooks.md lines 410 to 463].
- So a hook cannot push new iMessage text into the model at session start or on a prompt in grok [inferred]. The watcher has to put the message in the prompt itself.
- The Claude fields `async`, `shell` and `statusMessage` are ignored. `Bash` maps to `run_terminal_command`. Hooks fail open [reported: 10-hooks.md].

### Folder trust

- A `--trust` or `/hooks-trust` grant trusts the folder for MCP, LSP, hooks, project instructions and project skills together [reported: strings.txt line 4957, 10-hooks.md].
- `grok --trust inspect --json` set `projectTrusted: true`. It wrote `[folders."/private/tmp/gbim-research/grokcli/layout-test"] trusted = true` to `$GROK_HOME/trusted_folders.toml` [verified].
- `--trust` is missing from `grok --help` and from the long help. Only `grok plugin install` lists it [verified: help.txt, help-long.txt, help-plugin-install.txt].
- GROK_FOLDER_TRUST=0 turned the gate off. inspect then reported `projectTrusted: true` [verified: inspect-trusted.json].
- The real ~/.grok has no trusted_folders.toml, so no folder on this machine is trusted yet [verified].
- "Headless startup with these sources requires --trust or a prior grant" [reported: 22-permissions-and-safety.md].

## 2. What Claude Code compatibility covers

The README compat table lists these sources [reported: ~/.grok/README.md]:

- Skills: `.claude/skills`, `~/.claude/skills`. Both are verified above.
- Agents: `.claude/agents`, `~/.claude/agents`.
- Plugins: `.claude/plugins`, `~/.claude/plugins`, plus `~/.claude/plugins/installed_plugins.json` and `known_marketplaces.json`.
- MCP: `~/.claude.json`, `.mcp.json`. `.mcp.json` is verified above.
- Rules: `CLAUDE.md`, `.claude/CLAUDE.md`. CLAUDE.md is verified above.
- Permissions: `.claude/settings.json` and `settings.local.json`, used as a fallback.
- Hooks: `~/.claude/settings.json` and the project `.claude/settings.json`.

Other compat details:

- Claude plugin manifests at `.claude-plugin/plugin.json` and marketplace indexes at `.claude-plugin/marketplace.json` are accepted [verified: validate and mkt-test runs].
- Plugin hooks receive CLAUDE_PLUGIN_ROOT and CLAUDE_PLUGIN_DATA as aliases of GROK_PLUGIN_ROOT and GROK_PLUGIN_DATA [reported: 09-plugins.md line 448].
- inspect reports compat cells for cursor and claude covering skills, rules, agents, mcps, hooks and sessions, all enabled by default. Codex gets only a `sessions` cell [verified: inspect-untrusted.json].
  - 26-config-reference.md lists `compat.codex.skills` and `compat.codex.hooks` as scanning Codex sources [reported].
  - The binary does not expose either cell, so grok does not read `~/.codex` skills or hooks [inferred].
- `.mcp.json` loads "unless you have imported or dismissed the Claude import prompt" [reported: 07-mcp-servers.md]. I did not test this.
- The README's compat table does not cover the Claude Code `channels` manifest key or the `bin/` folder on PATH [inferred].

## 3. Sandbox and macOS

- The sandbox is off by default. Profiles are workspace, devbox, read-only and strict, and custom profiles live in `~/.grok/sandbox.toml` or `.grok/sandbox.toml` [reported: ~/.grok/docs/user-guide/18-sandbox.md].
- Reading ~/Library/Messages:
  - The default profile, off, does not block it [reported].
  - workspace, read-only and devbox allow reads everywhere [reported: 18-sandbox.md lines 26 to 46].
  - strict allows reads only in the CWD, system paths and ~/.grok, so it blocks chat.db [reported: 18-sandbox.md line 48].
  - A custom `deny` list blocks reads at the kernel level [reported].
- SQLite in WAL mode normally writes `chat.db-shm`. Under workspace or read-only, that write to ~/Library/Messages is denied, so a reader must open with `mode=ro` or `immutable=1` [inferred; not tested, and I did not touch the real files]. chat.db is reported to use WAL journal mode, but the schema file at research/chatdb-schema.sql does not itself contain a journal-mode line [reported; verified: grep of the schema file].
- Running osascript:
  - With the sandbox off, nothing at the grok layer blocks it [inferred].
  - One embedded Seatbelt profile has a bare `(allow mach-lookup)`. It denies mach lookups to com.apple.SecurityServer, securityd, security.keychaind, secd and security.agent [verified: strings.txt].
  - So Apple Events probably work under the built-in profiles, and keychain access does not [inferred].
  - Other embedded profiles start from `(deny default)` with a short mach allow list [verified: strings.txt]. I could not tell which profile name maps to which text [inferred].
- osascript is not on the list of read-only commands that are approved automatically [reported: 22-permissions-and-safety.md].
  - Headless runs refuse tools that need approval unless `--always-approve` or a `[permission] allow` rule such as `Bash(osascript:*)` is set [reported: 14-headless-mode.md].
- LaunchAgent:
  - Writing `~/Library/LaunchAgents/*.plist` is blocked under workspace, read-only and strict, because writes are limited to the CWD, ~/.grok and temp folders [reported: 18-sandbox.md line 42; inferred for this path].
  - `launchctl bootstrap` is a mach call, and the permissive profile allows mach calls [inferred].
  - The installer should run outside any grok sandbox [inferred].
- Child-process network blocking is a no-op on macOS [reported: 18-sandbox.md line 34].
- A resumed session keeps its sandbox profile [reported: 18-sandbox.md, strings.txt line 113].
- TCC is a separate OS layer. Full Disk Access for chat.db and Automation consent for Messages attach to the responsible process, such as the terminal app, the LaunchAgent job's program or the Grok Bot app, not to grok's sandbox setting [inferred].

## 4. Waking an agent from a watcher

### Headless mode

- The main flags are:
  - `-p/--single`, `--prompt-file` and `--prompt-json` for the prompt.
  - `-r/--resume <id|title>`, `-c/--continue` for the latest session in the cwd, and `-s/--session-id <new uuid>`.
  - `--output-format plain|json|streaming-json|streaming-messages-json`.
  - `--always-approve` or `--yolo`, `--permission-mode`, `--allow` and `--deny`.
  - `--max-turns`, `--rules`, `--tools` and `--disallowed-tools`.
  - `--cwd`, `--sandbox`, `--no-auto-update` and `--json-schema`.
  - [verified: help-long.txt; reported: ~/.grok/docs/user-guide/14-headless-mode.md]
- `-s` creates a new session only. The long help says it "Does not resume existing sessions, use --resume / --continue instead" [verified: help-long.txt]. The README still describes `-s` as create-or-resume, which is out of date [reported: README.md].
- The json output has `text`, `stopReason`, `sessionId` and `requestId`. It also has usage with input_tokens, cache_read_input_tokens, output_tokens, reasoning_tokens and total_tokens, plus num_turns, modelUsage and total_cost_usd [reported: 14-headless-mode.md].
- Stdin is not read into the prompt [reported: 14-headless-mode.md].
- Headless waits up to 10 minutes for background work. `--no-wait-for-background` skips the wait [reported].
- Exit codes are 0, 1, 130 and 143. A refused approval still exits 0 [reported].
- Each headless run starts its own daemon on the daemon route [reported: 14-headless-mode.md line 643].
- MCP servers start fresh on every run. The startup timeout defaults to 30 seconds, and a tool can be missing from the first prompt while its server starts [reported: 07-mcp-servers.md].
- Auto-update is suppressed by GROK_DISABLE_AUTOUPDATER=1, `--no-auto-update` or a non-TTY stderr [reported: 14-headless-mode.md].
- A large repo as the cwd slows startup, so `--cwd` should point at a small folder [reported: 14-headless-mode.md line 701].
- `grok inspect --json` finished in 0.02 seconds of wall time [verified: `/usr/bin/time -p`]. That shows config discovery is cheap. It does not measure model or MCP startup [inferred].
- A watcher command could look like this [inferred]:

```sh
grok -p "$EVENT_TEXT" -r "$SESSION_ID" --cwd "$HOME/.grokbot-imessage/work" \
  --output-format json --always-approve --no-auto-update
```

- The first run uses `-c`, or captures `.sessionId` from the json output. The trust grant must already exist for `--cwd`, which `grok --trust` sets once, or the run must add `--trust` [inferred from the verified trust behavior].

### ACP agent mode

- `grok agent stdio` speaks Agent Client Protocol as JSON-RPC over stdio. `grok agent serve --bind 127.0.0.1:2419 --secret` serves it over the network [verified: help-agent*.txt; reported: ~/.grok/docs/user-guide/15-agent-mode.md].
- Methods are `initialize`, `session/new` with `_meta` keys yoloMode, autoMode, rules, systemPromptOverride and agentProfile, `session/load`, `session/prompt`, `session/update` notifications and `session/set_config_option`. `x.ai/*` extensions are also available [reported: 15-agent-mode.md lines 19 to 207].
- A long-lived ACP process keeps MCP servers warm across messages, which avoids the cold start of `grok -p` [inferred]. It needs a supervising process, and the session ends if that process dies [inferred].
- `--plugin-dir` on `grok agent` and `_meta.pluginDirs` on `session/new` load a plugin folder without installing it, and grok trusts it automatically [reported: 09-plugins.md].

## 5. Tool output truncation and token cost

- Bash output is capped by `[toolset.bash] output_byte_limit`.
  - The config reference says the default is 20000 bytes [reported: 05-configuration.md, 26-config-reference.md; verified as embedded text "default: 20000" at strings.txt line 3412].
  - The README says 65536 [reported: README.md; verified as embedded text at strings.txt line 27289].
  - 20000 is likely current [inferred].
- Truncated bash output carries the marker "... (output truncated; full output at <path>" [verified: strings.txt line 29628].
- MCP results are capped at 20,000 bytes by default, and the full payload is saved under the session `mcp/` folder [reported: 07-mcp-servers.md].
  - The marker is "[MCP output truncated: showing first N bytes" [verified: strings.txt line 30874].
  - Override with GROK_MAX_MCP_OUTPUT_BYTES, MAX_MCP_OUTPUT_BYTES or `[mcp] max_output_bytes`. A project file can set the last one once the folder is trusted [reported].
- read_file and skill bodies stop at 25,000 tokens [reported: 08-skills.md line 235].
- Hook `additionalContext` stops at 10,000 characters [reported: 10-hooks.md line 463].
- Auto-compaction runs at 85 percent of the context window by default [reported: 05-configuration.md line 103].
- What this means for the iMessage server [inferred]:
  - Each MCP result should stay well under 20 KB.
  - Results should be compact JSON with paging.
  - The SKILL.md should stay short and point to sibling reference files.

## 6. Grok CLI and the Grok Bot app

| Area | grok CLI | Grok Bot app | Shared |
| :- | :- | :- | :- |
| Skill folders | `.agents/skills`, `.grok/skills`, `.claude/skills`, `.cursor/skills`, project and user tier [verified] | `.cursor/skills`, `.claude/skills`, `.codex/skills`, `.grok/skills`, `.agents/skills`, plus built-in `.cursor/skills-cursor`, project and user tier [verified: `Dw` array in /tmp/gbim-research/grokbot/app/dist/local-exec-daemon/main.cjs] | Yes, for `.agents/skills`, `.grok/skills` and `.claude/skills` |
| Third-party skill flag | none | `.claude`, `.codex` and `.grok` are flagged `thirdParty: true`. `.cursor` and `.agents` are first-party [verified: same file] | Only `.agents/skills` loads in Grok Bot with no third-party flag |
| Marketplace index | `.grok-plugin/marketplace.json` or `.claude-plugin/marketplace.json` in a git repo [verified] | `.cursor-plugin/marketplace.json` or `.claude-plugin/marketplace.json`, with GitHub `owner/repo` sources and a 40-character sha [verified: `Q0` array and `Dcr` schema in local-exec-daemon/main.cjs] | The file name `.claude-plugin/marketplace.json` |
| Official catalog | git clone of xai-org/plugin-marketplace [verified] | server-side catalog with PluginStatus.APPROVED, isPublished and curatedCategoryKeys fields [verified: electron-main/main-app.cjs] | No |
| MCP config | config.toml, `.mcp.json`, ~/.claude.json [verified] | account config provider, "box" servers, built-ins and plugin install folders [verified: class `nZ` in main-app.cjs]. No hit for `~/.grok/config.toml` or `.mcp.json` [verified: grep] | No [inferred] |
| Import from other tools | reads Claude and Cursor live | a "discover-ai-tool" scan of ~/.claude, ~/.claude.json and ~/.codex only, for onboarding [verified: function `HJe` in local-exec-daemon/main.cjs] | No |
| iMessage | none built in | ships `local-exec-daemon/messages-worker.cjs`, which references `chat.db` and the `@anysphere/messages-mac` package [verified: grep in /tmp/gbim-research/grokbot/app/dist] | n/a |

- Grok Bot does not ship or launch the grok CLI binary. Its Resources folder holds app.asar plus two native helpers, and the bundle has no "bin/grok" or "grok agent" string [verified].
- One Grok Bot regex matches project folders under `~/.grok/agent-host-daemon/projects/`. That folder does not exist on this machine, and the grok 1.0.70 binary does not contain the string [verified]. A later build may share session storage there [inferred].
- Both products share Cursor lineage. grok's daemon route uses Cursor tool names such as Shell, StrReplace and CallMcpTool [reported: 14-headless-mode.md line 54]. `grok worker` is described as "Run this machine as a Cursor private worker" [verified: help-worker.txt].
- Conclusion: the two do not share config or marketplace on this machine. A skill in `.agents/skills` reaches both, and so does a plugin listed in `.claude-plugin/marketplace.json` [inferred].

## 7. Facts about Codex and Claude Code used for the layout

- Codex skills load from `$CWD/.agents/skills`, parent folders up to the repo root, `$HOME/.agents/skills` and `/etc/codex/skills` [reported: https://learn.chatgpt.com/docs/build-skills].
- Codex reads AGENTS.override.md or AGENTS.md from ~/.codex, then one file per folder from the repo root to the cwd. The default cap is 32 KiB in `project_doc_max_bytes`. It does not read CLAUDE.md unless the file is added to `project_doc_fallback_filenames` [reported: https://learn.chatgpt.com/docs/agent-configuration/agents-md].
- Codex MCP config is `[mcp_servers.<name>]` with command, args, env, env_vars and cwd in ~/.codex/config.toml. A project `.codex/config.toml` works only in trusted projects. The add command is `codex mcp add <name> --env K=V -- <cmd>` [reported: https://learn.chatgpt.com/docs/extend/mcp?surface=cli].
- Codex plugins use a root `plugin.json` or the compat file `.codex-plugin/plugin.json`. The repo marketplace lives at `$REPO_ROOT/.agents/plugins/marketplace.json` [reported: https://developers.openai.com/plugins/build/plugins].
  - Installing a local plugin goes through the ChatGPT desktop app, not the CLI [reported: same page].
- Claude Code skills load from `.claude/skills` from the cwd up to the repo root, and from `~/.claude/skills` [reported: https://code.claude.com/docs/en/skills].
  - The documented locations do not include `.agents/skills` [reported].
  - Symlinked skill folders are followed and loaded once [reported].
  - The description listing is cut at 1,536 characters [reported].
- Claude Code reads AGENTS.md directly when no CLAUDE.md exists in the cwd or above it, from v2.1.277 [reported: https://code.claude.com/docs/en/memory].
  - If a CLAUDE.md exists, Claude Code reads only CLAUDE.md, unless that file imports `@AGENTS.md` [reported].
- Claude Code plugin.json `skills` adds to the default `skills/` scan. `mcpServers` merges with `.mcp.json`. `${CLAUDE_PLUGIN_ROOT}` resolves in MCP command, args and env. A root CLAUDE.md in a plugin is not loaded. A `channels` key binds a message channel to a plugin MCP server [reported: https://code.claude.com/docs/en/plugins-reference].

## 8. Proposed layout for one repo that serves all four

Design rules, each from the findings above [inferred]:

- Keep one real copy of the skill. Put it inside the plugin folder, because grok skips plugin skills that symlink outside the plugin folder [reported: 09-plugins.md]. Point every other location at it with symlinks.
- Keep the plugin in a subfolder, because grok 1.0.70 drops a marketplace entry whose source is the repo root [verified].
- Do not ship a root `.mcp.json`. A root `.mcp.json` triggers project-approval prompts in Claude Code and folder-trust gating in grok. The install script registers MCP at user level with absolute paths instead.
- Ship AGENTS.md as the only instruction file. Add a one-line CLAUDE.md only to support Claude Code older than v2.1.277.

```text
grokbotimessages/
├── AGENTS.md
├── CLAUDE.md
├── .claude-plugin/
│   └── marketplace.json
├── .agents/
│   ├── plugins/
│   │   └── marketplace.json
│   └── skills/
│       └── imessage -> ../../plugins/imessage/skills/imessage
├── .claude/
│   └── skills/
│       └── imessage -> ../../plugins/imessage/skills/imessage
├── plugins/
│   └── imessage/
│       ├── .claude-plugin/
│       │   └── plugin.json
│       ├── .codex-plugin/
│       │   └── plugin.json
│       ├── .mcp.json
│       ├── bin/
│       │   └── imessage-mcp
│       └── skills/
│           └── imessage/
│               ├── SKILL.md
│               └── reference/
│                   ├── tools.md
│                   └── troubleshooting.md
├── watcher/
│   ├── imessage-watch
│   └── com.grokbot.imessage-watch.plist.template
└── scripts/
    ├── install.sh
    └── uninstall.sh
```

Who reads each path:

| Path | grok CLI | Claude Code | Codex | Grok Bot app |
| :- | :- | :- | :- | :- |
| `AGENTS.md` | yes [verified] | yes from v2.1.277 when no CLAUDE.md [reported] | yes [reported] | unknown, the bundle has no AGENTS.md string [verified] |
| `CLAUDE.md` with `@AGENTS.md` | yes, as about 3 literal tokens [inferred] | yes, and it expands the import [reported] | no [reported] | unknown |
| `.agents/skills/imessage` | yes, project tier [verified] | no [reported] | yes [reported] | yes, first-party [verified] |
| `.claude/skills/imessage` | removed as a duplicate [verified] | yes [reported] | no | only with the third-party flag [verified] |
| `.claude-plugin/marketplace.json` with `"source": "./plugins/imessage"` | yes [verified with mkt-test] | yes [reported] | no | probably, if the repo sits on GitHub [inferred from the `Dcr` schema] |
| `.agents/plugins/marketplace.json` | no | no | yes [reported] | no |
| `plugins/imessage/.claude-plugin/plugin.json` | yes [verified] | yes [reported] | no | unknown |
| `plugins/imessage/.codex-plugin/plugin.json` | no | no | yes [reported] | no |
| `plugins/imessage/.mcp.json` using `${CLAUDE_PLUGIN_ROOT}` | yes, it expands [verified] | yes [reported] | unknown whether the variable expands | unknown |

File contents sketch [inferred]:

- `plugins/imessage/.claude-plugin/plugin.json` has `{"name": "imessage", "version": "0.1.0", "description": "..."}`. It needs no `skills` key, because the default `skills/` folder works in both grok and Claude Code.
- `plugins/imessage/.mcp.json` has `{"mcpServers": {"imessage": {"command": "${CLAUDE_PLUGIN_ROOT}/bin/imessage-mcp", "args": []}}}`.
- `plugins/imessage/.codex-plugin/plugin.json` has `{"name": "imessage", "skills": "./skills/", "mcpServers": "./.mcp.json"}`.
- `.claude-plugin/marketplace.json` has `{"name": "grokbot-imessage", "owner": {"name": "..."}, "plugins": [{"name": "imessage", "source": "./plugins/imessage"}]}`.
- `.agents/plugins/marketplace.json` has `{"plugins": [{"name": "imessage", "source": {"source": "local", "path": "./plugins/imessage"}}]}`.

`scripts/install.sh` does the user-level install that every harness can see without folder trust. Each step lists its evidence.

1. Link the skill into the user skill folders:
   - `ln -sfn "$REPO/plugins/imessage/skills/imessage" ~/.agents/skills/imessage` covers grok CLI user tier [verified], Codex user tier [reported] and Grok Bot user tier [verified].
   - `ln -sfn "$REPO/plugins/imessage/skills/imessage" ~/.claude/skills/imessage` covers Claude Code. grok removes it as a duplicate [verified].
2. Register MCP at user scope with absolute paths, using each CLI that is present:
   - `grok mcp add imessage -- "$REPO/plugins/imessage/bin/imessage-mcp"` writes ~/.grok/config.toml [verified format].
   - `claude mcp add --scope user imessage -- "$REPO/plugins/imessage/bin/imessage-mcp"` [reported]. grok also reads ~/.claude.json, and the same name is removed as a duplicate [reported].
   - `codex mcp add imessage -- "$REPO/plugins/imessage/bin/imessage-mcp"` [reported].
   - For Grok Bot, the user adds the server through the app, or the installer prints the step [inferred, open question].
3. Run `grok --trust` once in the watcher's work folder so headless runs load project sources. Or keep that folder empty of project sources, so trust does not matter [verified flag behavior].
4. Copy the plist template to `~/Library/LaunchAgents/` and load it with `launchctl bootstrap gui/$(id -u)`. Run this outside any grok sandbox [inferred].
5. Do not also run `grok plugin install` for the same repo. If the plugin is installed and the repo is the cwd, grok lists the skill twice [verified].
   - The plugin route is for people who add the repo as a marketplace instead of running the script [inferred].

## 9. Contradictions inside the grok docs

| Topic | One source | Other source | Likely current |
| :- | :- | :- | :- |
| AGENTS.md size cap | README: capped at 10,000 characters | 12-project-rules.md: no cap | no cap [inferred] |
| Bash output cap | README: 65536 bytes | 05-configuration.md and 26-config-reference.md: 20000 bytes | 20000 [inferred] |
| `-s` flag | README: create or resume | `--help`: new UUID only | new UUID only [verified] |
| Codex compat | 26-config-reference.md lists codex skills and hooks cells | inspect shows only a codex sessions cell, and 05-configuration.md calls them inert | sessions only [verified] |
| `--trust` | docs mention it often | missing from `--help` | the flag works [verified] |

## 10. Open questions

- Does the Grok Bot app read AGENTS.md or `.mcp.json` from a project? Its bundle has no such strings, so its agent backend may handle rules on the server side. I did not test this.
- How does Grok Bot register a local stdio MCP server? The bundle shows account-level MCP config and plugin install folders, but I did not find a local config file path.
- Does Grok Bot accept a `.claude-plugin/marketplace.json` from a local path, or only from GitHub? The `Dcr` schema shows a GitHub source with an optional sha.
- Does Codex expand `${CLAUDE_PLUGIN_ROOT}` in a plugin `.mcp.json`? If it does not, the Codex manifest needs its own MCP file or a user-level registration.
- How many tokens and seconds does a cold `grok -p` cost? I could not measure it without spending model quota. A single authenticated test run would answer it, and `usage.input_tokens` in the json output would show the system prompt size.
- Does a built-in grok sandbox profile allow osascript Apple Events to Messages? The mach-lookup evidence comes from embedded strings only.
- Will a SQLite reader on chat.db work under the workspace profile, which denies writes to `chat.db-shm`? This needs a test on a copy of a WAL database, not the real one.
- Why did a local marketplace entry with source `"./"` get dropped without a message? It may be a 1.0.70 limit that a later version lifts.
