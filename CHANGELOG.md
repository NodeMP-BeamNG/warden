# Changelog

## 0.2.0 — 2026-09-22

The panel's controls and window structure now mirror the CobaltEssentials
Interface (CEI); the fixed key is gone. Node-Server ≥ 1.4.1; panel protocol 2
(the server streams the matching panel, nothing to update on the players'
side).

### Controls

- **Shown by default** for staff (`players.view`): the window is up when
  they join, until they hide it. Hidden / shown and the **UI scale** are
  remembered per player on the server (`data/ui.json`, bounded like the
  guest records) through the new ops `ui.get` / `ui.set { shown?, scale? }`
  -- the caller's own record only, the scale clamped to 0.75..1.5, through
  `registry.run` like every other op.
- **`/warden`** toggles the panel (`/wd` stays as the alias); so does the
  window's X, and the console's `nodemp_wd.toggle()`.
- **A bindable game action**, "Toggle Warden panel", in its own Controls
  category *Warden*, with **no default key**. The game reads input actions
  from files only, so the action ships as `content/warden.zip` (the action
  JSON and a mod script for the category), which the server's `content/`
  folder hands to the players through the launcher; the panel registers the
  category at runtime too. See `docs/dev.md` for why a streamed file cannot
  declare the action itself (filed as NodeMP #49).
- The **F9 polling is removed** (`im.IsKeyPressed` is not called any more)
  and the config key `ui.key` is gone; new keys `ui.default_shown`,
  `ui.welcome` (one chat line for staff at their first hello, with the
  toggle hint and the keybind note) and `ui.theme` (`cobalt` -- the
  translucent blue style, default -- or `game`), all runtime.
- `/help` no longer names a key.

### Layout (CEI's, improved where it made sense)

- One window `Warden vX.Y.Z`: a **QuickInfo** bar (server name, players and
  cars out of their limits, your group, the status chips `Spawn` /
  `Whitelist` / `Guests` / `Vote` as `>>`, `X` or `//` with the seconds
  left), the **UI scale** input with Reset, the language picker, then the
  tabs **Players / Config / Environment / Database**.
- **Players**: a quick-actions row (Disable / Enable spawning, Whitelist
  on / off, Announce; Freeze all / Unfreeze all and Remote stop / start all
  greyed with a tooltip naming server #58 / #89), then a **collapsing header
  per player** coloured by group tier, with the small-button row Vote kick,
  Kick, Ban, TempBan, Mute / Unmute, Whitelist / Unwhitelist, Warn, Focus,
  Teleport To / From (greyed, server #53); the Reason and Duration fields
  under it (Ban and TempBan ask for a second click); the tree nodes
  `vehicles` (the client mod's list, Delete one or all; Freeze / Remote
  start greyed), `info` and `permissions` (a picker of the groups below your
  level with Apply / Remove).
- **Config**: `Warden` (the groups table with an **editor** for
  `perms.manage` -- name, level, inherits, permissions, cars, under the same
  rules the server enforces; the whitelist on / off / add / remove; the panel
  settings; the runtime settings table), `Server` (read-only, runtime edits
  need server #39), `Interface` (theme, scale, language).
- **Environment**: a placeholder until server #52; shows the game's own
  time of day.
- **Database**: Bans with Unban, the mutes in force with Unmute (new op
  `mod.mutes`), the whitelist entries with Remove, the audit tail with N and
  Refresh.
- **Focus** is client-side: the camera onto one of the player's vehicles
  through the client mod (as its own spectate helper does), cycling on
  repeated clicks, refused in a strict session.
- The vote banner stays its own small window.

### Server

- `spawn.enabled` (runtime): a server-wide vehicle spawn switch that vetoes
  `vehicleSpawnRequest` for players without `car.cap.bypass`; the panel's
  quick action flips it.
- `car.delete { pid, vid? }` deletes one vehicle of the target by its global
  id (the id must be the target's own).
- Player rows carry `muted` and `whitelisted`; the hello carries
  `default_group`, `ui`, `server` and `status`; a new push `status` to every
  panel (coalesced) on joins, leaves, vehicle spawns and deletes and the
  status keys' changes.
- `sys.hello` and `players.subscribe` run under `xpcall`: an exception is a
  reply, not a timeout.

### Tests and tooling

- `tests/unit/client_test.lua` rewritten for the layout and the toggle paths
  (the fake `ui_imgui` grew child windows, collapsing headers, tree nodes,
  style pushes, hover / tooltips); server unit tests for `ui.*`, the bounded
  store, `mod.mutes`, `car.delete vid`, `spawn.enabled`, the welcome line and
  the status push; the smoke and protocol gates cover protocol 2, `/warden`,
  `ui.get` / `ui.set`, `mod.mutes`, `spawn.enabled`.
- `tools/pack.*` build `content/warden.zip` into the release archive;
  `luacheck` covers `content/`.

### Upgrading from 0.1.0

Unzip over the old install; `ui.key` in `resource.toml` is no longer read.
Keep the new `content/warden.zip` in the server's `content/` folder for the
bindable key.

## 0.1.0 — 2026-09-22

First release (P0). Node-Server ≥ 1.4.1 (plugin ABI 2.3); GPL-3.0-or-later.

### Features

- Groups with levels, inheritance, named permissions and vehicle caps
  (`data/groups.json`, five shipped groups: `default`, `trusted`, `mod`,
  `admin`, `owner`); the owner comes from `owner_ids` or the directory's
  `ADM` role, never from a command. The rank rule everywhere: an action
  against a player needs a strictly higher level.
- Player records keyed by account id or, for guests, by IP
  (`data/players.json`): names seen, joins, warnings, mute, language.
- Kick, ban, temp-ban (with expiry), unban, mute (advisory until server
  #43), warn, whitelist (`acct:` / `ip:` / `name:` entries), `allow_guests`;
  a per-group vehicle cap on spawn; `/car delete`.
- Vote-kick (off by default): threshold, minimum players, window, cooldown,
  immunity level; votes weigh by identity and the cooldowns survive a
  restart.
- Chat commands from the `chat` resource's bus event (or `chat:send` with
  `chat_fallback`), answers in English or Russian per player (`/lang`),
  `/help` per group, one rate limit per player.
- The in-game panel (**F9**, `ui.key`, or `/wd` in the chat), streamed to
  every player as `client/warden/*.lua` and drawn with the game's Dear ImGui
  — nothing to install on the player's side: Players with the moderation
  actions and an inline form (reason, duration, group), Groups, Settings
  with typed inputs and Reset, Audit, Bans with Unban, and the vote-kick
  banner with Yes / No / Cancel. Buttons the rank rule would refuse are
  greyed; the server checks every request again. English and Russian from
  the same dictionaries as the chat lines (`client/warden/lang.lua` is
  generated by `tools/lang-gen.lua`).
- `wd:req` / `wd:reply` / `wd:event` protocol between the panel and the
  server, versioned (`sys.hello` refuses an outdated panel) and rate-limited
  per client; pushes for the player list, groups, settings, the vote and
  notices.
- Runtime settings (`/settings`, the Settings tab; `data/settings.json`),
  audit log (`data/audit/YYYY-MM-DD.jsonl`, pruned after
  `audit.retain_days`), atomic JSON storage with `.bak` copies.
- Bus API for other resources: `warden:getGroup`, `warden:hasPerm`,
  `warden:groupChanged`, `warden:groupsChanged`, `warden:ready`.
- Unit tests (Lua 5.4 against a `node` stub; the panel against a recording
  `ui_imgui` fake) and four gate tests against the released Node-Server
  1.4.1; `tools/pack.*` builds the release archive with `LICENSE`, `NOTICE`,
  the READMEs, `CHANGELOG.md` and `docs/` at its root.

### Security review (PR #1)

Findings of the P0 review, all fixed before this release:

- Group editing cannot escalate: a group's parents and its effective
  permissions are bounded by the editor's own level and permissions, and
  `*` cannot be inherited in.
- The rank of an offline target is computed from live `owner_ids`, the
  directory flag and the level remembered on the record; `ip:` keys must be
  address literals; an address ranks as the highest player behind it; owners
  are never moved by a group change.
- A name resolves only when it is not in doubt: exact and case-insensitive,
  a connected signed-in player wins, several candidates are refused as
  `ambiguous`; `/group` and `/whitelist add` refuse a guest's name; a `name:`
  whitelist entry admits a signed-in account only. Permissions are checked
  before the target is looked up, so a refusal reveals nothing about who
  exists.
- Audit rows carry the declared fields only, are capped in size, buffered
  and written into bounded part files.
- Vote-kick weighs votes by identity, is off by default, keeps its cooldowns
  on disk and does not kick a target who became immune during the vote.
- No prefix matching for commands that change something.
- Addresses (IPs and `ip:` keys) are shown to `mod.ban` and up only; masked
  elsewhere, in the panel and the audit alike.
- A change a read-only store refused is answered (`err.store_readonly`) and
  logged; guest records are bounded; the test hooks are never loaded by the
  shipped `main.lua`.

### Known limitations

- Mute is advisory until the platform has a cancellable chat event (server
  #43); `chat_veto_event` is the hook for it.
- A text field of the panel does not take the keyboard from the vehicle
  action maps yet: stop before typing (planned for 0.1.1).
- `node.bans.add` has no expiry (server #88): temp-bans are lifted by
  warden's own 30 s timer from `bans_meta.json`.
- No console input for resources (server #38): commands are chat and panel
  only.
- Guests are their address: a ban or a whitelist entry for a guest affects
  everyone behind that IP, and a guest from a new address is a new player
  (see "Caveats" in the README).
