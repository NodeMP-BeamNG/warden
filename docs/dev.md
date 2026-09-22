# warden -- developer handbook

How the resource is built, how it is tested, and the rules that keep it
safe to extend. Read this before changing anything under `resources/`.

## Layout

```
resources/warden/
  resource.toml            manifest + [config] defaults (documented in place)
  lang/en.json ru.json     every line the server says, by code
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
    ui/ops.lua             op name -> kind (what warden-ui mirrors)
    ui/push.lua            players.changed / groups.changed / settings.changed / vote.state / notice
    integration/bus.lua    warden:getGroup / warden:hasPerm / warden:groupChanged
tests/unit                 lua tests/unit/run.lua  (Lua 5.4, the `node` stub in stubs/node.lua)
tests/gate                 python tests/gate/<name>_test.py  (the released server, see below)
tools/                     config-doc, lang-check, pack, get-server
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
that builds its data, an op in `ui/ops.lua`, and lines in both dictionaries.
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

**Gate** (`python tests/gate/<name>_test.py`): the published Node-Server
(`tools/get-server.ps1` / `.sh`, sha256-verified, under `.server/`) with
warden and the `chat` example resource in a scratch home, driven by fake
clients (`tests/gate/lib`, vendored from the server repository -- see
`SYNC.md`). Every client comes from its own loopback address so it has its
own record. `WD_TEST_HOOKS=1` copies `tests/gate/hooks/dev/test_hooks.lua`
in: probes for the tests, chiefly `group.set` because a directory-less
server has no owner. A release archive never carries it.

Run before every push: `luacheck resources tests tools`, the unit tests,
`lua tools/lang-check.lua`, `lua tools/config-doc.lua --check README.md en`
(and `README.ru.md ru`), the gates.

## Protocol (`wd:req`)

```
client -> server  wd:req    { id, op, data }
server -> client  wd:reply  { id, ok: true, data } | { id, ok: false, error: { code, params } }
server -> client  wd:event  { ev, data }      ev: players.changed | groups.changed | settings.changed
                                                 | vote.state | notice
```

`ui/ops.lua` is the list of ops; `ui.protocol.PROTOCOL` is bumped on an
incompatible change and `sys.hello` refuses a panel that does not match
(`ui_outdated`). Frames are rate-limited per player
(`limits.ui_per_sec`, `limits.ui_per_min`); junk counts.

## Releases

`tools/pack.ps1` / `tools/pack.sh` build `dist/warden-<version>.zip` from
`resources/warden` (without `data/` and `server/dev/`), the READMEs and
`docs/` (without this file). Tag `v<version>` matching `resource.toml`.
The client half is the `warden-ui` repository's own release; both archives
unzip at the server root.

## Platform gaps this version works around

- No cancellable chat event: mutes are advisory (`chat_veto_event` is the
  hook for server #43).
- `node.bans.add` has no expiry: temp-bans keep their `until` in
  `bans_meta.json` and a 30 s timer lifts them.
- No console input for resources (server #38): commands are chat and panel
  only; `perms.CONSOLE` is the actor the console path will use.
- No directory lookup by name: `/ban <name>` for an offline player uses the
  name history.
