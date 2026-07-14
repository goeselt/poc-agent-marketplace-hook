# PoC -- Plugin Dependencies, Provisioning, and Updates via Hooks

## Question

Can marketplace-plugin **hooks** model plugin dependencies -- "plugin-a requires plugin-b", including
transitive chains (b requires c)? Can a hook not only *detect* a missing plugin but *provision* (install) it?
Can hooks detect available updates? Can hooks verify **MCP servers** and **missing logins**?

Rationale: informs a possible restructuring of a pool-based, multi-provider plugin marketplace (e.g. a
"commons" plugin that other plugins depend on, provisioned automatically).

Verified against **Claude Code CLI 2.1.185** ([marketplace/](marketplace/)) and
**Copilot CLI 1.0.69** ([marketplace-copilot/](marketplace-copilot/)), each with the dependency chain
`hook-a` -> `hook-b` -> `hook-c` plus an MCP fixture plugin `hook-mcp`.

## Findings (Claude CLI)

### F1 -- Plugin hooks fire offline and unauthenticated

A `SessionStart` plugin hook executes even when the CLI aborts with `Not logged in` and has no network. The
whole dependency mechanism below is therefore **hermetically testable** (isolated `CLAUDE_CONFIG_DIR`, no
auth, no model calls) -- see [scripts/verify-claude.sh](scripts/verify-claude.sh).

### F2 -- What a hook sees

- stdin: session JSON -- `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `source`
  (`startup` on a fresh session).
- env: `${CLAUDE_PLUGIN_ROOT}` (the plugin's own directory; usable inside `hooks.json` commands),
  plus the parent session's environment (`CLAUDE_CONFIG_DIR` included).
- cwd: the session's working directory.

### F3 -- Dependency check: yes

A hook can run the CLI **nested**: `claude plugin list --json` works from inside a hook and targets the
correct profile because `CLAUDE_CONFIG_DIR` is inherited. Checking "is `hook-b@poc-hook` installed?" is a
grep away. See [marketplace/plugins/hook-a/scripts/ensure-dep.sh](marketplace/plugins/hook-a/scripts/ensure-dep.sh).

### F4 -- Provisioning: yes, effective next session

`claude plugin install <dep>@<marketplace>` **succeeds from inside a SessionStart hook** (mid-session config
write) and **persists** after the session exits. The freshly installed plugin's own hooks do **not** run in
the installing session -- they first fire in the **next** session.

### F5 -- Transitive chains: converge one level per session

With only `hook-a` installed, `hook-a -> hook-b -> hook-c` resolves as:

| Session | Effect                                                        |
| ------- | ------------------------------------------------------------- |
| 1       | a's hook installs b                                            |
| 2       | b's hook (now active) installs c                               |
| 3       | full chain present; every hook reports `status=present`        |

So dependency provisioning via hooks is **eventually consistent** across sessions, not immediate. A plugin
that *needs* its dependency in the same session must block instead (F7).

### F6 -- Update detection: yes

- Installed state: `claude plugin list --json` (`version` per plugin).
- Available state: the marketplace manifest; its location comes from `claude plugin marketplace list --json`
  (`path` for directory sources). Comparing the two version fields is the update check.
- Applying: `claude plugin update <plugin>@<marketplace>` (the bare plugin name is **not** accepted) updates
  the versioned cache (`plugins/cache/<mp>/<plugin>/<version>/`) and reports
  "Restart to apply changes" -- same next-session semantics as install.

### F7 -- Messaging and enforcement

- **Inform the model:** a `SessionStart` hook's stdout JSON
  (`{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}`) reaches the model --
  verified end-to-end (the session repeated the injected token). A dependency hook can tell the session
  "dependency X missing, installed for next session".
- **SessionStart cannot block:** exit code 2 there is ignored for control flow; the session runs normally.
- **UserPromptSubmit can block:** exit code 2 rejects the prompt **before any model call**; the hook's stderr
  is shown to the user. This is the hard enforcement lever: "this plugin's dependency is missing, run
  `claude plugin install ...`" -- combined with F4 the plugin self-heals by the next session.

### F8 -- Directory marketplaces run hooks from the source (live)

For a directory-source marketplace, `${CLAUDE_PLUGIN_ROOT}` resolves to the **source** directory and edited
hook scripts take effect on the next session **without** a version bump -- even though a versioned cache copy
exists under `plugins/cache/`. Expect the cache to be authoritative for git-based marketplaces instead
(unverified, needs a remote repo).

## Findings (Copilot CLI)

### C1 -- Hooks fire only in authenticated sessions

With every auth source removed, `copilot -p` aborts (`No authentication information found`) **before** any
hook runs -- no marker appears. Unlike Claude (F1), Copilot hook behavior is therefore **not hermetically
testable**; it needs a logged-in session (a real model call).

### C2 -- What a Copilot hook sees

- env: `COPILOT_PLUGIN_ROOT` (plus aliases `PLUGIN_ROOT` and even `CLAUDE_PLUGIN_ROOT`), and a per-plugin
  data directory `COPILOT_PLUGIN_DATA` (`plugin-data/<mp>/<plugin>/`).
- cwd: the **plugin's install directory** (`COPILOT_HOME/installed-plugins/<mp>/<plugin>/`) -- not the
  session cwd (Claude uses the session cwd).
- stdin: `{sessionId, timestamp, cwd, source: "new", initialPrompt}` -- the sessionStart hook even sees the
  user's initial prompt.
- Plugins are **copied** on install; no source-live behavior like Claude's directory marketplaces (F8).

### C3 -- Dependency check, provisioning, and cascade: identical to Claude

Nested `copilot plugin list` (text only, no `--json`) and `copilot plugin install <dep>@<marketplace>` work
from inside a `sessionStart` hook; installs persist; the new plugin's hooks first fire in the **next**
session. The `a -> b -> c` chain converges one level per session, exactly like F4/F5.

### C4 -- Updates

`copilot plugin update <name>` (bare name accepted; no argument updates everything) re-syncs from the
marketplace source and reports `v0.1.0 -> v0.2.0`. Detection is the same version diff as F6, with
`copilot plugin list` (text) as the installed side.

### C5 -- No messaging, no enforcement

Both levers that exist on Claude are **absent** on Copilot (1.0.69):

- `sessionStart` stdout does **not** reach the model (injected-token probe answers "none").
- `userPromptSubmitted` with exit 2 + stderr does **not** block the prompt; the session answers normally.

Copilot hooks are **side-effect-only**: they can check, install, and log (e.g. into
`COPILOT_PLUGIN_DATA`), but cannot inform the session or gate it.

## Findings (Git-Source Marketplaces)

Verified against this repository's own `claude` and `copilot` branches (each branch root is one marketplace,
the layout a release workflow would publish).

### G1 -- Branch-pinned install works on both Claude forms

`claude plugin marketplace add` accepts the branch as a `#<branch>` fragment on **both** forms:
`https://github.com/<owner>/<repo>#claude` and the short `<owner>/<repo>#claude`. (The Copilot CLI needs the
`.git#<branch>` URL form.)

### G2 -- For git sources, the versioned cache is the runtime root

Installed from git, `${CLAUDE_PLUGIN_ROOT}` points into `plugins/cache/<mp>/<plugin>/<version>/` -- the
opposite of the directory-source behavior (F8). Hooks fire offline once installed, and nested installs
resolve against the **local marketplace clone as of its last fetch** -- they do not refresh it.

### G3 -- The update pipeline is three explicit steps

After pushing a new plugin version to the marketplace branch:

1. `claude plugin marketplace update <mp>` -- refreshes the local clone; installed plugins are unaffected.
2. `claude plugin update <plugin>@<mp>` -- materializes the new version into its own cache directory.
3. Next session -- the new version's hooks/content become active.

Installed plugins stay **version-pinned** across marketplace refreshes, and content changes without a version
bump never reach git-source consumers (unlike directory sources, F8). A hook automating updates therefore
needs marketplace update + plugin update, and the detection diff is only as fresh as the last marketplace
refresh (that step needs network).

## Generator Spike -- plugin-config.json

Tests the follow-up idea: author one `plugin-config.json` per plugin and **generate** the provider
manifest plus the dependency hooks from it. JSON over YAML was a deliberate choice: dependencies are plain
lists of objects, JSON needs no new parser (the tooling stays stdlib-only), and comments were YAML's only
real advantage.

Authoring layout ([authoring/](authoring/)), consumed by [src/generate.js](src/generate.js):

```json
{
  "name": "dep-a",
  "version": "0.1.0",
  "description": "Depends on dep-b (own marketplace) and hook-c (external marketplace).",
  "author": { "name": "goeselt" },
  "dependencies": [
    { "plugin": "dep-b" },
    { "plugin": "hook-c", "marketplace": "poc-hook", "source": "goeselt/poc-agent-marketplace-hook#claude" }
  ]
}
```

The generator writes `.claude-plugin/plugin.json` (the config minus `dependencies`), a generated
`scripts/ensure-deps.sh`, and **merges** a `SessionStart` entry into `hooks/hooks.json` -- authored hook
entries are preserved (hooks are additive, so appending is safe).

### S1 -- Verified end to end (hermetic)

[scripts/verify-config-gen.sh](scripts/verify-config-gen.sh) asserts, offline and unauthenticated:

- the generated marketplace passes `claude plugin validate --strict`;
- the authored hook survives the merge and still fires;
- **nested `claude plugin marketplace add` works from inside a hook** -- the generated hook registers the
  external marketplace before installing from it (this was an open question; now answered);
- both dependencies -- own-marketplace and external -- install in **one** session (direct dependencies
  resolve immediately; only *transitive* chains still need one session per level, F5);
- the external dependency's own hooks are active in the next session, and re-runs are clean no-ops.

### S2 -- Modeling and testing external dependencies

- **Model**: `{plugin, marketplace, source}` -- `marketplace` is the dependency's marketplace *name* (must
  match its manifest), `source` is anything `plugin marketplace add` accepts; the git form
  `<owner>/<repo>#<branch>` (G1) is the realistic production shape.
- **Test**: keep the authored `source` in git form, and let the test rewrite it to a **local directory copy**
  of the external marketplace (see the verify script). That keeps the E2E hermetic; G1 separately proves the
  git form resolves.

## MCP Servers And Login Checks

### M1 -- MCP existence: both CLIs, machine-readable

- Claude: `claude plugin list --json` lists each plugin's `mcpServers` config; works offline, nested in a hook.
- Copilot: `copilot mcp list --json` lists all servers **with plugin attribution**
  (`sourcePlugin`, `sourcePluginVersion`, `source: "plugin"`); works offline.

### M2 -- MCP health: only Claude probes

Nested `claude mcp list` performs an **active connection probe** and covers plugin-scoped servers
(`plugin:hook-mcp:poc-http-unreachable ... ✘ Failed to connect`) -- offline and unauthenticated. Note it
exits 0 even when servers fail: parse the output, not the exit code. Copilot's `mcp list --json` is a pure
config view -- the unreachable server is listed without any error; a Copilot hook must probe itself
(`curl` for http, `command -v` for stdio commands).

### M3 -- Login/credential checks: plain shell, presence only

A hook inherits the session environment, so it can verify required **env vars are set** (`POC_REQUIRED_TOKEN
MISSING` in the probe), required **binaries exist**, config files are present, or run its own reachability
probe. Verified offline via [hook-mcp](marketplace/plugins/hook-mcp/scripts/mcp-check.sh).

### M4 -- Limits

- A hook sees only a **fresh, independent probe** -- never the running session's own MCP connection state or
  its auth handshake result. Probing stdio servers spawns them again (duplicate side effects possible).
- **Presence != validity**: whether a token actually works requires calling the real service from the hook
  (network + secret handling in scripts -- weigh carefully).
- OAuth-based MCP logins (Claude's `/mcp` flow) are CLI-internal state; no supported way to verify them from
  a hook beyond fragile config-file heuristics.
- On Copilot, all checks are silent (C5): results can only surface as files/logs, not as session context or
  a block.
- Trust cuts both ways: plugin hooks run arbitrary shell **with the user's full environment** -- a dependency
  mechanism built on hooks is also an execution vector; only curated marketplaces should be installable.

## Answers To The Original Questions

| Question                                  | Claude CLI                                            | Copilot CLI                          |
| ----------------------------------------- | ----------------------------------------------------- | ------------------------------------ |
| Dependency `a requires b` via hooks?      | Yes -- check, provision, inform, enforce (F3/F4/F7)   | Yes, but silent (C3, C5)             |
| Transitive `b requires c`?                | Yes, one level per session (F5)                       | Yes, identical (C3)                  |
| Provide a plugin, not just test for it?   | Yes, active next session (F4)                         | Yes, active next session (C3)        |
| Detect updates?                           | Yes -- version diff + `plugin update <p>@<m>` (F6)    | Yes -- `plugin update <name>` (C4)   |
| Verify MCP servers?                       | Config + active health probe (M1/M2)                  | Config + attribution only (M1/M2)    |
| Verify logins?                            | Presence checks + block/inform (M3, F7)               | Presence checks, silent (M3, C5)     |

## Reproduce

```bash
scripts/verify-claude.sh      # hermetic: F1, F3-F6, M1-M3 (handwritten hook fixtures)
scripts/verify-config-gen.sh  # hermetic: S1 (generated dependency hooks, external marketplace)
```

Both run offline with no auth in an isolated `CLAUDE_CONFIG_DIR` and exit non-zero on any mismatch. F7
(context/blocking) needs one authenticated session each (`claude --plugin-dir <plugin> -p ...`); everything
in the Copilot section needs an authenticated Copilot session and is documented above instead of scripted.

## Open Questions

- **Same-session activation:** no way found to activate a freshly installed plugin without a new session; a
  systematic look at `--resume`/`/clear` semantics (`source` values in F2) might open one.
- **Copilot enforcement:** no blocking or context mechanism found via exit codes/stdout; if a decision
  protocol (JSON output) exists, it is undocumented -- revisit on newer CLI versions.
- **Copilot generator variant:** the generator emits Claude format only; the Copilot adapter would be the
  same mechanical translation (camelCase events, root `hooks.json`, `copilot` CLI in the script), but its
  E2E cannot be hermetic (C1).
