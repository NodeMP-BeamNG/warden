# warden

Server administration for [NodeMP](https://docs.nodemp.com): groups with
levels and named permissions, kick / ban / temp-ban / whitelist / mute /
warn, a vehicle cap per group, a server-wide spawn switch, vote-kick, chat
commands in English and Russian, an audit log, and an in-game admin panel
drawn with the game's Dear ImGui and streamed to every player by the server
-- nothing to install on the player's side. The panel follows the control
model of the CobaltEssentials Interface: shown by default for staff, `/warden`
in the chat hides and shows it, a key can be bound in the game's Controls.
Everything is decided on the server; the panel only shows and asks.

[Русская версия](README.ru.md) · Licence: GPL-3.0-or-later ([LICENSE](LICENSE), [NOTICE](NOTICE))

## Install

1. Download `warden-<version>.zip` from the
   [releases](https://github.com/NodeMP-BeamNG/warden/releases) and unzip it
   at the server's root (the folder with `Node-Server`): it puts
   `resources/warden/` and `content/warden.zip` in place.
2. Install the `chat` resource (`examples/chat` in the server archive) beside
   it: warden takes its commands from the chat resource's bus event and
   answers through it. Without a chat resource set `chat_fallback = true`.
3. The panel itself needs nothing more: `resources/warden/client/warden/*.lua`
   is in the same archive and the server streams it to every joining player.
   It opens by itself for staff (`players.view`); `/warden` (or `/wd`) in the
   chat hides and shows it, and the choice is remembered per player.
   `content/warden.zip` is the one small client mod the server hands out
   through the launcher: it adds the game action **Toggle Warden panel**
   (Options > Controls > Warden), with no default key -- every player binds
   their own. Leave the zip in the server's `content/` folder (or the folder
   your `[Content] Folder` setting names).
4. Put your directory account id into `owner_ids` in
   `resources/warden/resource.toml`, or rely on `directory_admin_is_owner`
   (a directory `ADM` is an owner). Start the server; the log says
   `warden 0.2.0 ready: 5 group(s), ...`.

On a server without a `[Directory]` every player is a guest keyed by IP; an
owner then has to be made by editing `data/players.json`
(`"ip:1.2.3.4": { "group": "admin" }`) — `owner` itself is never stored, only
configured.

## Groups and permissions

A player is in one group (`data/players.json`, or `default_group`). A group
(`data/groups.json`) has a `level`, the groups it `inherits` from, a list of
`perms` and `caps` (`vehicles`: how many cars at once, `-1` = unlimited). The
five shipped groups:

| Group | Level | Permissions (own; inherits the ones below) | Cars |
|---|---|---|---|
| `default` | 0 | `votekick.vote` | 1 |
| `trusted` | 10 | `votekick.start` | 3 |
| `mod` | 50 | `players.view mod.kick mod.tempban mod.mute mod.warn car.delete audit.view votekick.cancel` | 5 |
| `admin` | 90 | `mod.ban mod.whitelist perms.set settings.read settings.write server.announce car.cap.bypass` | unlimited |
| `owner` | 100 | `*` | unlimited |

Rules that hold everywhere (chat, panel): an action needs the permission;
an action against a player needs a **strictly higher level** than the
target; a group may be assigned only below the actor's own level; `owner`
comes from `owner_ids` / the directory, never from a command; `perms.manage`
(group editing, owner only by default) cannot grant `*` or a permission the
editor does not have. `mod.*` in a group's `perms` is a prefix wildcard.

Edit `groups.json` by hand if you like: it is re-read within a second of the
change (a file that does not parse is left alone and reported in the log).

## Commands

Type them in the chat. `<player>` is a whole name (case-insensitive),
`#<id>` for a connected player, or a key `acct:<id>` / `ip:<addr>` (see
[Caveats](#caveats)). Durations are `30m`, `2h`, `7d`.

| Command | Permission | What it does |
|---|---|---|
| `/help`, `/version`, `/whoami`, `/lang en\|ru` | — | Your commands, the version, your record, your language |
| `/warden`, `/wd` | — | Show or hide the panel (remembered per player; the bound key does the same) |
| `/players` | `players.view` | Who is online, with group and level |
| `/kick <player> [reason]` | `mod.kick` | Disconnects with the reason |
| `/ban <player> [reason]` | `mod.ban` | Permanent ban (account when verified, IP always) via the server's ban list |
| `/tempban <player> <duration> [reason]` | `mod.tempban` | Ban that lifts itself |
| `/unban <player\|key>`, `/bans` | `mod.ban` | Lift a ban; list bans |
| `/mute <player> [duration] [reason]`, `/unmute <player>` | `mod.mute` | Mute (see the note below) |
| `/warn <player> <reason>` | `mod.warn` | A warning on the record; the player is told |
| `/whitelist add\|remove <player> \| list \| on \| off` | `mod.whitelist` | Who may join |
| `/group <player> <group>`, `/groups` | `perms.set` / — | Move a player; list groups |
| `/car delete [player]` | own: — / others: `car.delete` | Delete vehicles |
| `/votekick <player> [reason]`, `/vote yes\|no\|cancel` | `votekick.start` / `votekick.vote` / `votekick.cancel` | Vote-kick |
| `/settings list \| get <key> \| set <key> <value> \| reset <key>` | `settings.read` / `settings.write` | Runtime settings |
| `/audit [n]` | `audit.view` | The last audit rows |
| `/announce <text>` | `server.announce` | A line to everyone |
| `/reload` | `server.reload` | Reload the resource |

Mute is advisory until the platform has a cancellable chat event (server
issue #43): warden cannot stop the `chat` resource from relaying a line, so
a muted player is told they are muted on every line instead. Once the event
exists, set `chat_veto_event` to its name and the lines are dropped.

## The panel

### Controls

- The window `Warden vX.Y.Z` is **shown by default** when a player with
  `players.view` joins (`ui.default_shown`); a plain player's is hidden.
- **`/warden`** (or `/wd`) in the chat hides and shows it. Closing the window
  with its X does the same. The choice is remembered per player on the
  server (`data/ui.json`), together with the UI scale, so it survives a
  rejoin.
- A **key** of your own: Options > Controls > **Warden** > *Toggle Warden
  panel*. No default key ships; the action comes from `content/warden.zip`,
  which the launcher installs for the session. There is no fixed key any
  more (0.1.0's built-in one is gone).
- The console: `nodemp_wd.toggle()`.
- At the first hello of a session staff get one chat line saying so
  (`ui.welcome`).

### Layout

One window, the shape of the CobaltEssentials Interface: a **QuickInfo** bar
(server name, players and cars out of their limits, your group, and the
status chips `Spawn`, `Whitelist`, `Guests`, `Vote` -- `>>` green for open or
allowed, `X` red for off or closed, `//` yellow while a vote runs with the
seconds left), the **UI scale** input with its Reset and the language picker,
then the tabs. What a tab shows follows the player's permissions, and a
button the rank rule would refuse is greyed -- the server checks again on
every request and its refusal is printed under the row. A button the platform
has no call for yet is greyed too, and its tooltip names the server issue.

| Tab | Needs | Shows |
|---|---|---|
| Players | `players.view` | A row of server-wide quick actions (Disable / Enable spawning with `settings.write`, Whitelist on / off with `mod.whitelist`, Announce with `server.announce`; Freeze all / Unfreeze all and Remote stop / start all greyed until server #58 / #89), then a collapsing header per player -- name, group and level, cars, guest / muted / whitelisted -- coloured by group tier. Expanded: the small buttons Vote kick, Kick, Ban, TempBan, Mute or Unmute, Whitelist or Unwhitelist, Warn, Focus (the camera onto the player's vehicle, client side, off in a strict session), Teleport To / From (greyed until server #53); the Reason and Duration (30m / 2h / 1d / 7d / custom) fields the buttons read; Ban and TempBan ask for a second click. The tree nodes `vehicles` (the vehicles the client mod knows, Delete one or all; Freeze and Remote start greyed), `info` (id, account, key, IP, joins, first seen, warnings, limit, mute, names seen, ping, time online) and `permissions` (the group with Apply / Remove for `perms.set`). |
| Config | -- | `Warden`: the groups (a table for all; an editor -- name, level, inherits, permissions, cars -- with `perms.manage`, under the same rules as the server: only below your level, only what you hold yourself), the whitelist (on / off, add, remove), the panel settings (shown by default, welcome line, vehicle spawning) and the runtime settings table with typed inputs and Reset (`settings.read`, `settings.write`). `Server`: name, map, version, max players, max cars -- read-only, runtime edits need server #39. `Interface`: theme (`cobalt` / `game`), UI scale, language. |
| Environment | -- | A placeholder until server #52 (time of day and weather from the server); shows your game's own time of day. |
| Database | any of `mod.ban`, `mod.mute`, `mod.whitelist`, `audit.view` | Bans with Unban, the mutes in force with Unmute, the whitelist entries with Remove, and the last N audit rows. |

A running vote-kick shows a banner at the top of the screen with the count,
the seconds left and Yes / No (`votekick.vote`) or Cancel (`votekick.cancel`)
for everyone with the permission, whether the window is open or not. The
panel speaks the language `/lang` set (or the server's), switchable from the
window; the texts come from the same `lang/*.json` as the chat lines.

The panel is plain Lua drawn with the game's Dear ImGui, streamed at every
join and gone when the player leaves; it never receives code from the
server, only JSON data. A text field of the panel does not take the
keyboard away from the car yet -- stop before typing a reason.

## Caveats

- **A guest is their address.** A player without a directory account is
  keyed by IP: banning or whitelisting a guest affects every player behind
  that address (NAT, a shared host), and a guest who comes back from another
  address is a new player. Reliable identity needs a directory account.
- **A name admits nobody by itself.** `name:` whitelist entries admit
  signed-in accounts only; a guest's name is whatever they typed, so such an
  entry never admits one. Without a directory, whitelist by `#pid` or by
  `ip:` key (`/whitelist add <name>` says so).
- **Vote-kick is off by default.** Votes weigh by identity (all guests
  behind one address are one vote) and the cooldowns survive a restart, but
  puppets from different addresses still count. Turn it on knowingly.
- **Targets are exact.** `/group`, `/whitelist add`, `/ban` and every other
  command that changes something need the whole name, `#pid` or a key; a
  prefix matches nobody. A name a connected guest shares with a known player
  is refused as ambiguous -- use `#pid` or the key.
- **`chat_fallback = true` without the `chat` resource**: `player:tell` has
  nothing to show it, so players without the panel get no answers.
- **Addresses are for `mod.ban` and up.** Lower groups see them masked in
  the panel and in the audit.
- **Mute is advisory** until the server ships a cancellable chat event
  (server #43). **The panel's text fields** do not take the keyboard from the
  vehicle action maps yet.
- **The key needs the content zip.** The game reads input actions from files
  only (NodeMP #49), so the bindable action travels as `content/warden.zip`
  through the launcher; the panel, `/warden` and the console work without
  it. Focus is
  client-side and refused in a strict session; Teleport, Freeze and Remote
  start wait for the server calls (#53, #58, #89).

## Configuration

`resources/warden/resource.toml`, section `[config]`. Every key is optional.
Keys marked runtime can be changed with `/settings set` (kept in
`data/settings.json`, which then wins over the file).

<!-- config-doc:begin -->
| Key | Type | Default | Runtime | Description |
|---|---|---|---|---|
| `language` | string (en / ru) | `"en"` | yes | Language of the server's own lines (`en` / `ru`); a player picks their own with `/lang`. |
| `owner_ids` | list<int> | `[]` |  | Directory account ids that are owners whatever the records say. |
| `directory_admin_is_owner` | bool | `true` |  | A directory administrator (role `ADM`) is an owner. |
| `allow_guests` | bool | `true` | yes | Admit players without a directory account (keyed by IP). |
| `role_tag` | bool | `true` | yes | Show the group as the tag beside the nickname. |
| `default_group` | string | `"default"` |  | The group a first-time player lands in. |
| `chat_fallback` | bool | `false` |  | Read `chat:send` directly instead of the `chat` resource's bus event (no chat resource installed). |
| `chat_veto_event` | string | `""` |  | Name of the cancellable chat event once the platform ships it (server #43); mutes then drop lines. |
| `whitelist.enabled` | bool | `false` | yes | Only players in `data/whitelist.json` may join. |
| `votekick.enabled` | bool | `false` | yes | Vote-kick on or off. |
| `votekick.threshold` | number 0.5..1.0 | `0.6` | yes | Share of eligible voters that must say yes (0.6 = 60 %). |
| `votekick.min_players` | int 2..200 | `4` | yes | No vote with fewer players connected. |
| `votekick.window_sec` | int 15..600 | `60` | yes | Seconds a vote stays open. |
| `votekick.cooldown_sec` | int 0..86400 | `300` | yes | Seconds before the same target or starter can be in a vote again. |
| `votekick.immune_level` | int 0..1000 | `50` | yes | Players at this level or above cannot be vote-kicked. |
| `limits.commands_per_10s` | int 1..100 | `8` |  | Chat commands one player may run per 10 s. |
| `limits.ui_per_sec` | int 1..100 | `10` |  | `wd:req` frames one client may send per second. |
| `limits.ui_per_min` | int 1..5000 | `120` |  | `wd:req` frames one client may send per minute. |
| `audit.enabled` | bool | `true` |  | Write `data/audit/YYYY-MM-DD.jsonl`. |
| `audit.retain_days` | int 1..3650 | `90` |  | Audit files older than this are removed at start. |
| `spawn.enabled` | bool | `true` | yes | Vehicle spawning for players without `car.cap.bypass`; the panel's "Disable spawning" flips it. |
| `ui.default_shown` | bool | `true` | yes | The panel opens by itself when a player with `players.view` joins, until they hide it (remembered per player in `data/ui.json`). |
| `ui.welcome` | bool | `true` | yes | One chat line for staff at their first hello: `/warden` toggles the panel, a key can be bound in Options > Controls > Warden. |
| `ui.theme` | string (cobalt / game) | `"cobalt"` | yes | `cobalt`: the translucent blue window style; `game`: the game's own Dear ImGui colours. |
<!-- config-doc:end -->

## Storage

Everything is JSON under `resources/warden/data/`, written atomically
(temp file + rename, the previous version kept as `.bak`) and at most once a
second per file:

| File | Contents |
|---|---|
| `groups.json` | The groups (editable) |
| `players.json` | One record per player key: group, names seen, joins, first/last seen, warnings, mute, language |
| `whitelist.json` | Whitelist entries (`acct:`, `ip:` or `name:` for a player not seen yet) |
| `bans_meta.json` | Who banned, why, until when; the bans themselves are the server's (`bans.json`) |
| `settings.json` | Runtime overrides |
| `ui.json` | Per player (by key): the panel shown or hidden, the UI scale; bounded, the least recently seen records go first |
| `audit/YYYY-MM-DD.jsonl` | One JSON object per action or refusal; pruned after `audit.retain_days` |

## For other resources

Over the server bus (`node.bus`), JSON payloads: ask `warden:getGroup
{ pid | key, tag? }` and get `warden:group { key, group, level, perms, tag }`;
ask `warden:hasPerm { pid | key, perm, tag? }` and get `warden:perm { ok, ... }`.
warden publishes `warden:ready`, `warden:groupChanged { key, group, pid? }`
and `warden:groupsChanged`.

## Upgrading

Unzip the new release over the old one. `data/` is never in the archive.
A new version may add groups or permissions to the defaults; existing
`groups.json` files are left as they are — `/groups` and the panel show what
you have.

From 0.1.0: the config key `ui.key` is gone (a value left in `resource.toml`
is simply not read); the panel opens by itself for staff
(`ui.default_shown`); `content/warden.zip` is new -- keep it in `content/`
for the bindable key; the panel protocol is 2 (the server streams the
matching panel, nothing to update on the players' side).

## Development

`docs/dev.md`. Continuous integration is described in
`.github/workflows/ci.yml`; GitHub Actions is billing-blocked for the
organisation at the moment, so run the checks locally:
`luacheck resources content tests tools`, `lua tests/unit/run.lua`,
`lua tools/lang-check.lua`, `lua tools/lang-gen.lua --check`,
`tools/get-server.ps1` and `python tests/gate/<name>_test.py`.
