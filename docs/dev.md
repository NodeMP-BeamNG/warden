# warden -- developer handbook

How the resource is built, how it is tested, and the rules that keep it
safe to extend. Read this before changing anything under `resources/`.

## Layout

```
resources/warden/
  resource.toml            manifest + [config] defaults (documented in place)
  lang/en.json ru.json     every line the server says, by code, plus the panel's ui.* labels
  client/warden/           the panel, streamed to every joining player (see "The client half")
    bridge.lua             wd:req / wd:reply / wd:event, hello with retry, the request ids
    i18n.lua               t(code, params) in the player's language
    lang.lua               GENERATED from lang/*.json by tools/lang-gen.lua (ui.* + err.*)
    state.lua              the model: session, perms, players, groups, settings, bans, audit, vote;
                           the actions and the wd:req they build
    panel.lua              Dear ImGui drawing (ui_imgui): the window, the tabs, the vote banner, F9
  server/
    main.lua               load order, the engine events, the shutdown flush
    core/                  config (schema), settings (runtime overlay), store (JSON files),
                           audit (JSONL), limiter, i18n, say (a line to a player), log, util
    identity/identity.lua  the player key (acct:<id> | ip:<addr>) and data/players.json
    perms/groups.lua       data/groups.json: level, inherits, perms, caps
    perms/perms.lua        group_of / has / outranks / set_group / the owner bootstrap
    moderation/            bans (node.bans + bans_meta.json), whitelist, mutes (+ warns)
    vehicles/caps.lua      the vehicleSpawnRequest cap
    votekick/votekick.lua  one vote at a time, all rules server-side
    commands/registry.lua  THE one path every action takes (see below)
    commands/builtin.lua   the kinds
    commands/parser.lua    words and quotes of a chat line
    commands/chat.lua      /commands -> kinds, answers in the player's language
    ui/protocol.lua        wd:req / wd:reply / wd:event envelope + limiter
    ui/ops.lua             op name -> kind (what client/warden/state.lua mirrors)
    ui/push.lua            players.changed / groups.changed / settings.changed / vote.state / notice
    integration/bus.lua    warden:getGroup / warden:hasPerm / warden:groupChanged
tests/unit                 lua tests/unit/run.lua  (Lua 5.4, the `node` stub in stubs/node.lua; the client
                           files against stubs/game.lua, a recording ui_imgui)
tests/gate                 python tests/gate/<name>_test.py  (the released server, see below)
tools/                     config-doc, lang-check, lang-gen, pack, get-server
```

## The one path: `commands.registry.run(actor, kind, data)`

Every action -- a chat line, a `wd:req` frame, later a console line -- is
turned into a *kind* plus a data table and goes through `registry.run`,
which does, in this order:

1. the kind exists;
2. the actor has `spec.perm` (`perms.has`), unless the kind has `self = true`
   and the target is the actor;
3. the target resolves: `data.pid` (connected), `data.key`, or `data.target`
   (a `#pid`, a name, a key) -- `target = "player"` kinds need a connected one;
4. the rank rule when `spec.rank`: `level(actor) > level(target)`;
5. the data has the shape (`spec.shape`: type, bounds, enum, optional);
6. `spec.fn(ctx)` in `xpcall`; a string return is a refusal code;
7. the audit row (success and refusal alike, unless `audit = false`);
8. the `registry.after` listeners (`ui.push` uses them).

A new feature is a new kind in `builtin.lua`, a chat command in `chat.lua`
that builds its data, an op in `ui/ops.lua`, an entry in the panel's
`state.ACTIONS` (or a tab) with its button in `panel.lua`, lines in both
dictionaries, and `lua tools/lang-gen.lua`.
Never check a permission anywhere else; never act on the client's word.

## Identity

`identity.key(player)` is `acct:<accountId>` for a verified account and
`ip:<addr>` otherwise (a guest, or every player of a server without a
directory). Persist by key; never by name. Names are kept as a history on
the record so `/ban <name>` works for an offline player.

## Storage

`core.store.open(name, default)` gives a table under `data/<name>.json`.
Edit `s.data`, call `s:mark()`; the write happens within a second (many
marks, one write), as `tmp` + `rename` with the previous file kept as `.bak`.
A file that does not parse is never overwritten: the store runs read-only
on the `.bak` or the default until a reload succeeds. `node.fs.watch`
re-reads a file someone else changed. `store.flush_all()` runs at shutdown
and unload.

## Messages

Every line the server says has a code in `lang/en.json` and `lang/ru.json`
(`tools/lang-check.lua` enforces parity). Use `say.tell(player, code,
params)`; the player's language comes from `/lang` (on the record), else
the server's `language`. Plain text is only ever interpolated as `{name}`;
nothing from a player is ever executed.

## Tests

**Unit** (`lua tests/unit/run.lua`): plain Lua 5.4 against `stubs/node.lua`
-- a virtual clock (`node._advance(ms)`), fake players (`node._join`),
in-memory files (`node._files`), recorded sends/tells/bans/bus. `boot.lua`
runs the real `main.lua`, so the tests exercise the wiring, not mocks of it.
`client_test.lua` loads `client/warden/*.lua` through `stubs/game.lua` the
way the client mod does (one environment, a `require` that resolves the
sibling files) with a fake `ui_imgui` that records every call, checks the
Begin/End, table, tab and PushID balance of each frame, and takes scripted
input -- `im.click("Kick")`, `im.type("##reason", "spam")`,
`im.pick("##duration", 1)`, `im.press(im.Key_F9)` -- so a test drives the
panel and asserts the exact `wd:req` frame it sends. The client files stay
Lua 5.1 (LuaJIT): no `//`, no `math.tointeger`, no `utf8`, no `goto`.

**Gate** (`python tests/gate/<name>_test.py`): the published Node-Server
(`tools/get-server.ps1` / `.sh`, sha256-verified, under `.server/`) with
warden and the `chat` example resource in a scratch home, driven by fake
clients (`tests/gate/lib`, vendored from the server repository -- see
`SYNC.md`). Every client comes from its own loopback address so it has its
own record. `WD_TEST_HOOKS=1` copies `tests/gate/hooks/dev/test_hooks.lua`
in: probes for the tests, chiefly `group.set` because a directory-less
server has no owner. A release archive never carries it.

Run before every push: `luacheck resources tests tools`, the unit tests,
`lua tools/lang-check.lua`, `lua tools/lang-gen.lua --check`,
`lua tools/config-doc.lua --check README.md en` (and `README.ru.md ru`), the
gates.

## Protocol (`wd:req`)

```
client -> server  wd:req    { id, op, data }
server -> client  wd:reply  { id, ok: true, data } | { id, ok: false, error: { code, params } }
server -> client  wd:event  { ev, data }      ev: players.changed | groups.changed | settings.changed
                                                 | vote.state | notice | panel
```

`ui/ops.lua` is the list of ops; `ui.protocol.PROTOCOL` is bumped on an
incompatible change and `sys.hello` refuses a panel that does not match
(`ui_outdated`). Frames are rate-limited per player
(`limits.ui_per_sec`, `limits.ui_per_min`); junk counts. `panel
{ toggle = true }` is what the chat command `/wd` sends to its own player
(`commands/chat.lua`): the client half toggles the window.

## The client half

Everything under `client/` is streamed to the player at join by the server
(`[client]` in `resource.toml`, every `.lua` under the folder, `light`
obfuscation), compiled by the NodeMP client mod and run inside the game's
Lua state. There is no content zip and nothing the player installs. The
panel is drawn with the game's Dear ImGui binding, `ui_imgui`, the way the
original CobaltEssentials Interface was; a Vue/CEF panel would have needed
a mod zip on every client and a bridge between three languages for the
same buttons.

### How a streamed file runs (client mod 1.5.16, `origin/main`)

`lua/ge/extensions/nodemp/net/resources.lua` receives the resource as
`Content/ResourceChunk` packets, base64-decodes each `ge` file, compiles it
under the chunk name `node/warden/<path>` with `setfenv` into one
environment per resource (`__index = _G`, `__newindex = _G`: reads and
writes of anything but `node` and `require` go to the game's globals), and
`require`s every file once in delivery order. Two things matter to us:

- **The per-frame hook exists.** A file whose returned table has `on*`
  functions is registered with `newExtensionProxy(nil, "node_warden_<path>")`
  + `proxy:submitEventSinks({ wrapper })` (`registerExtension`), which makes
  it a virtual extension in the game's `extensions` module -- so
  `extensions.hook("onUpdate", dt)` reaches it like any other extension
  (`lua/common/extensions.lua`: `ExtensionProxy:_updateHooks` -> `refreshInternal`
  -> `resolvedModules`). `bridge.lua` uses `onUpdate` for the request
  timeouts and the hello retry, `panel.lua` for the key and the drawing.
  `onExtensionLoaded` / `onInit` run once at registration,
  `onExtensionUnloaded` when the player leaves (`clearAll`). No NodeMP
  change or issue was needed for this. The wrapper is *not* `pcall`ed, so an
  error in our `onUpdate` would surface in the game's hook loop every frame:
  `panel.onUpdate` guards the frame itself and closes the window after
  `MAX_DRAW_ERRORS` failures in a row.
- **The node table.** `node.on(name, fn)` is one handler per event name per
  resource (`node.res/warden` is the source; a second `node.on` for the same
  name replaces the first), which is why `bridge.lua` owns both `wd:reply`
  and `wd:event` and fans them out to `state.lua` and `panel.lua` with its
  own listener list. `node.emitServer(name, text)` sends `tostring(text)`,
  so the frame is `jsonEncode`d here and `node.json.decode`d on the server.
  `NodeMP.*` (the mod SDK) is available too but not needed: the panel
  learns everything from the server.

The request/reply correlation follows the roleplay tablet's `bridge.lua`
(`roleplay/resources/roleplay/client/roleplay/bridge.lua`): a counter id
per `wd:req`, a `pending[id] = { cb, op, at }` table, `wd:reply` answers by
id, a sweep every half second turns a request older than `TIMEOUT_S` into
`{ code = "timeout" }`, and `sys.hello` is retried every `HELLO_RETRY_S`
while it times out (the server's join transaction may still be running, or
the server has no warden). `players.subscribe` goes out as soon as the
record says `players.view`; the other tabs load when first shown.

### Dear ImGui in the game (BeamNG.drive 0.39.4.0)

The binding is `lua/common/extensions/ui/imgui.lua` (`ui_imgui`), a thin
Lua layer (`imgui_luaintf.lua`, 2194 lines, generated from `imgui_api.h`;
`imgui_custom_luaintf.lua` for the pointer helpers) over `Engine.imgui`. The
version string is only available at run time (`im.GetVersion()`); the API
surface says **1.89.7 -- 1.89.9**: `SetNextItemAllowOverlap`,
`SetItemTooltip` / `BeginItemTooltip` and the `ImGuiMouseSource` enum are
there (added in 1.89.7 / 1.89.5), while `ShowStackToolWindow` has not yet
become `ShowIDStackToolWindow`, there is no `ImGuiChildFlags`, no
`Key_F13`..`F24` and no `Key_AppBack` (all 1.90). Notes for the drawing code:

- Pointers are Lua tables indexed at `[0]`: `im.BoolPtr(false)`,
  `im.IntPtr(0)`, `im.FloatPtr(0)`; `im.Begin(name, p_open, flags)` writes
  the close box into `p_open[0]`. `im.ArrayChar(len, text)` is a
  `string.buffer`; read it with `ffi.string(buf)`, write it with
  `ffi.copy(buf, text)` (what `core/ropeVisualTest.lua` and NodeMP's own
  chat do). `Combo1` takes a plain 1-based Lua table of strings.
- The named keys API is in: `im.Key_F1`..`im.Key_F12`, `im.Key_Insert`,
  ... (`imgui.enum.ImGuiKey_*`), `im.IsKeyPressed(key, repeat)`,
  `im.IsKeyDown`; the editor's `mainToolbar.lua` polls
  `im.IsKeyPressed(im.Key_Escape)` the same way, so the engine feeds
  keyboard state to ImGui. **F9 is therefore read from Lua** without an
  action map: `panel.onUpdate` polls `im.IsKeyPressed(im["Key_" .. key], false)`
  with `key` from the hello record (`ui.key`, default `F9`; an unknown name
  falls back to F9). What has not been verified without a running game is
  whether an F-key that another mod bound as an action still reaches ImGui;
  `/wd` (server `chat.lua` -> `wd:event panel`) and the console
  (`nodemp_wd.toggle()`) are the documented fallbacks.
- `im.Text*` take a format string: pass server text as
  `im.TextUnformatted(s)` or `im.Text("%s", s)`, never as the format.
  `im.BeginDisabled(bool)` / `im.EndDisabled()` grey a widget; `flags` add
  (`+`) since the enums are distinct bits.
- The whole tree of `im.Begin`/`im.End`, `BeginTable`/`EndTable`,
  `BeginTabBar`/`EndTabBar`, `PushID1`/`PopID` has to balance in every
  frame even when a branch returns early -- the fake in `stubs/game.lua`
  fails a test on an imbalance.
- Not done yet: a focused text field does not take the keyboard from the
  vehicle (the game's chat disables the vehicle action maps while typing --
  the same pairing would go into `panel.lua`).

### i18n

The panel's labels are `ui.*` codes in `lang/en.json` / `lang/ru.json`, next
to the server's lines, and the refusals it prints are the server's `err.*`
codes with their `params`. Since the server streams only `.lua`,
`tools/lang-gen.lua` writes the two subsets into `client/warden/lang.lua`
(committed; `--check` in CI). The language is the hello record's `lang`
(the player's `/lang`, else the server default), and the header's EN/RU
picker sends `me.lang`.

## Releases

`tools/pack.ps1` / `tools/pack.sh` build `dist/warden-<version>.zip` from
`resources/warden` -- the server half and `client/` -- (without `data/` and
`server/dev/`), the READMEs and `docs/` (without this file). Tag
`v<version>` matching `resource.toml`. One archive, unzipped at the server
root, is the whole install; the `warden-ui` repository is the retired
Vue/CEF attempt and ships nothing since 0.1.0.

## Platform gaps this version works around

- No cancellable chat event: mutes are advisory (`chat_veto_event` is the
  hook for server #43).
- `node.bans.add` has no expiry (server #88): temp-bans keep their `until`
  in `bans_meta.json` and a 30 s timer lifts them.
- No console input for resources (server #38): commands are chat and panel
  only; `perms.CONSOLE` is the actor the console path will use.
- No directory lookup by name (server #90): `/ban <name>` for an offline
  player uses the name history.
- No "queue" verdict on `playerConnectRequest` (server #87): a full server
  is a refusal, not a waiting list.
- No allowed controller call for the ignition (server #89): there is no
  "engine off" action yet.
- Per-viewer nametag hiding (server #69): not in P0.
