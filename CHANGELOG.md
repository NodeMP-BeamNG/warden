# Changelog

## 0.1.0

First release (P0).

- Groups with levels, inheritance, named permissions and vehicle caps
  (`data/groups.json`, five shipped groups); the owner from `owner_ids` or
  the directory's `ADM` role.
- Player records keyed by account id or IP (`data/players.json`): names,
  joins, warnings, mute, language.
- Kick, ban, temp-ban (with expiry), unban, mute (advisory until server
  #43), warn, whitelist, `allow_guests`; per-group vehicle cap on spawn;
  `/car delete`.
- Vote-kick: threshold, minimum players, window, cooldown, immunity level.
- Chat commands from the `chat` resource's bus event (or `chat:send` with
  `chat_fallback`), answers in English or Russian, `/help` per group.
- The in-game panel (F9 or `/wd`), streamed to every player as
  `client/warden/*.lua` and drawn with the game's Dear ImGui: Players with
  the moderation actions and an inline form, Groups, Settings with typed
  inputs, Audit, Bans, and the vote-kick banner; English and Russian from
  the same dictionaries as the chat lines.
- `wd:req` / `wd:reply` / `wd:event` protocol between the panel and the
  server; pushes for the player list, groups, settings, the vote and
  notices.
- Runtime settings (`/settings`), audit log (`data/audit/*.jsonl`),
  rate limits on commands and frames.
- Bus API for other resources: `warden:getGroup`, `warden:hasPerm`,
  `warden:groupChanged`, `warden:groupsChanged`, `warden:ready`.
- Unit tests (Lua 5.4 + a `node` stub; the panel against a recording
  `ui_imgui` fake) and gate tests against the released Node-Server 1.4.1.
