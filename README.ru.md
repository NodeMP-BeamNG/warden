# warden

Администрирование сервера [NodeMP](https://docs.nodemp.com): группы с
уровнями и именованными правами, кик / бан / временный бан / белый список /
мьют / предупреждения, лимит машин на группу, голосование за кик, чат-команды
на русском и английском, журнал аудита и протокол `wd:req`, на котором
работает игровая панель [warden-ui](https://github.com/NodeMP-BeamNG/warden-ui).
Все решения принимает сервер; панель только показывает и просит.

[English](README.md) · Лицензия: GPL-3.0-or-later ([LICENSE](LICENSE), [NOTICE](NOTICE))

## Установка

1. Скачайте `warden-<version>.zip` из релизов и распакуйте в корень сервера
   (папка с `Node-Server`): появится `resources/warden/`.
2. Рядом поставьте ресурс `chat` (`examples/chat` из архива сервера): warden
   берёт команды из его события на шине и отвечает через него. Без ресурса
   chat включите `chat_fallback = true`.
3. По желанию панель: распакуйте `warden-ui-<version>.zip` в тот же корень.
   Она добавит `resources/warden/client/warden/*.lua` (уходит каждому
   входящему игроку) и `content/warden-ui.zip` (UI-приложения BeamNG).
   Открывается на F9.
4. Впишите id своего аккаунта directory в `owner_ids` в
   `resources/warden/resource.toml` или положитесь на
   `directory_admin_is_owner` (администратор directory `ADM` — владелец).
   Запустите сервер; в логе будет `warden 0.1.0 ready: 5 group(s), ...`.

На сервере без `[Directory]` все игроки — гости с ключом по IP; владельца
тогда назначают правкой `data/players.json`
(`"ip:1.2.3.4": { "group": "admin" }`) — сама группа `owner` никогда не
хранится, только задаётся в конфиге.

## Группы и права

Игрок состоит в одной группе (`data/players.json`, иначе `default_group`).
У группы (`data/groups.json`) есть `level`, список `inherits` (от кого
наследует), список `perms` и `caps` (`vehicles`: сколько машин сразу, `-1`
без лимита). Пять групп из коробки:

| Группа | Уровень | Права (свои; остальные наследуются) | Машин |
|---|---|---|---|
| `default` | 0 | `votekick.vote` | 1 |
| `trusted` | 10 | `votekick.start` | 3 |
| `mod` | 50 | `players.view mod.kick mod.tempban mod.mute mod.warn car.delete audit.view votekick.cancel` | 5 |
| `admin` | 90 | `mod.ban mod.whitelist perms.set settings.read settings.write server.announce car.cap.bypass` | без лимита |
| `owner` | 100 | `*` | без лимита |

Правила, которые действуют везде (чат, панель): для действия нужно право;
действие над игроком требует **строго большего уровня**, чем у цели; группу
можно выдать только ниже своего уровня; `owner` берётся из `owner_ids` /
directory и никогда не назначается командой; `perms.manage` (правка групп,
по умолчанию только у владельца) не может выдать `*` или право, которого нет
у самого редактирующего. `mod.*` в `perms` группы — маска по префиксу.

`groups.json` можно править руками: файл перечитывается в течение секунды
(файл, который не разбирается, не трогается, об этом пишется в лог).

## Команды

Пишутся в чат. `<player>` — имя (без учёта регистра или уникальное начало
имени, которое сервер уже видел), `#<id>` для игрока в сети или ключ
`acct:<id>` / `ip:<addr>`. Длительности — `30m`, `2h`, `7d`.

| Команда | Право | Что делает |
|---|---|---|
| `/help`, `/version`, `/whoami`, `/lang en\|ru` | — | Ваши команды, версия, ваша запись, ваш язык |
| `/players` | `players.view` | Кто в сети, с группой и уровнем |
| `/kick <player> [reason]` | `mod.kick` | Отключает с причиной |
| `/ban <player> [reason]` | `mod.ban` | Постоянный бан (аккаунт, если он подтверждён, и всегда IP) через список банов сервера |
| `/tempban <player> <duration> [reason]` | `mod.tempban` | Бан, который снимется сам |
| `/unban <player\|key>`, `/bans` | `mod.ban` | Снять бан; список банов |
| `/mute <player> [duration] [reason]`, `/unmute <player>` | `mod.mute` | Мьют (см. примечание) |
| `/warn <player> <reason>` | `mod.warn` | Предупреждение в записи; игроку сообщается |
| `/whitelist add\|remove <player> \| list \| on \| off` | `mod.whitelist` | Кому можно заходить |
| `/group <player> <group>`, `/groups` | `perms.set` / — | Перевести игрока; список групп |
| `/car delete [player]` | свои: — / чужие: `car.delete` | Удалить машины |
| `/votekick <player> [reason]`, `/vote yes\|no\|cancel` | `votekick.start` / `votekick.vote` / `votekick.cancel` | Голосование за кик |
| `/settings list \| get <key> \| set <key> <value> \| reset <key>` | `settings.read` / `settings.write` | Настройки на лету |
| `/audit [n]` | `audit.view` | Последние записи аудита |
| `/announce <text>` | `server.announce` | Строка всем |
| `/reload` | `server.reload` | Перезагрузить ресурс |

Мьют пока только предупреждающий: у платформы нет отменяемого события чата
(задача сервера #43), и warden не может остановить ресурс `chat` от
пересылки строки — поэтому замьюченному на каждую строку сообщается, что
он замьючен. Когда событие появится, впишите его имя в `chat_veto_event`, и
строки будут глушиться.

## Конфигурация

`resources/warden/resource.toml`, секция `[config]`. Все ключи необязательны.
Ключи «на лету» меняются командой `/settings set` (хранятся в
`data/settings.json`, который тогда важнее файла).

<!-- config-doc:begin -->
| Ключ | Тип | По умолчанию | На лету | Описание |
|---|---|---|---|---|
| `language` | string (en / ru) | `"en"` | yes | Язык сообщений сервера (`en` / `ru`); игрок выбирает свой командой `/lang`. |
| `owner_ids` | list<int> | `[]` |  | Id аккаунтов directory, которые являются владельцами независимо от записей. |
| `directory_admin_is_owner` | bool | `true` |  | Администратор directory (роль `ADM`) — владелец. |
| `allow_guests` | bool | `true` | yes | Пускать игроков без аккаунта directory (ключ — IP). |
| `role_tag` | bool | `true` | yes | Показывать группу тегом рядом с ником. |
| `default_group` | string | `"default"` |  | Группа, в которую попадает новый игрок. |
| `chat_fallback` | bool | `false` |  | Читать `chat:send` напрямую вместо события шины ресурса `chat` (когда ресурс chat не установлен). |
| `chat_veto_event` | string | `""` |  | Имя отменяемого события чата, когда платформа его выпустит (server #43); мьют тогда глушит строки. |
| `whitelist.enabled` | bool | `false` | yes | Пускать только игроков из `data/whitelist.json`. |
| `votekick.enabled` | bool | `true` | yes | Голосование за кик включено. |
| `votekick.threshold` | number 0.5..1.0 | `0.6` | yes | Доля голосующих, которые должны сказать «да» (0.6 = 60 %). |
| `votekick.min_players` | int 2..200 | `4` | yes | Нет голосования, если игроков меньше. |
| `votekick.window_sec` | int 15..600 | `60` | yes | Сколько секунд длится голосование. |
| `votekick.cooldown_sec` | int 0..86400 | `300` | yes | Секунд до следующего голосования против той же цели или от того же инициатора. |
| `votekick.immune_level` | int 0..1000 | `50` | yes | Игроков этого уровня и выше нельзя кикнуть голосованием. |
| `limits.commands_per_10s` | int 1..100 | `8` |  | Сколько чат-команд игрок может выполнить за 10 с. |
| `limits.ui_per_sec` | int 1..100 | `10` |  | Сколько кадров `wd:req` клиент может послать в секунду. |
| `limits.ui_per_min` | int 1..5000 | `120` |  | Сколько кадров `wd:req` клиент может послать в минуту. |
| `audit.enabled` | bool | `true` |  | Писать `data/audit/YYYY-MM-DD.jsonl`. |
| `audit.retain_days` | int 1..3650 | `90` |  | Файлы аудита старше этого удаляются при старте. |
| `ui.key` | string | `"F9"` |  | Клавиша, на которую warden-ui вешает панель (справочно: биндинг лежит в content-zip). |
<!-- config-doc:end -->

## Хранилище

Всё — JSON в `resources/warden/data/`, пишется атомарно (временный файл +
переименование, предыдущая версия остаётся как `.bak`) и не чаще раза в
секунду на файл:

| Файл | Содержимое |
|---|---|
| `groups.json` | Группы (можно править) |
| `players.json` | Запись на ключ игрока: группа, имена, входы, первый/последний визит, предупреждения, мьют, язык |
| `whitelist.json` | Записи белого списка (`acct:`, `ip:` или `name:` для ещё не виденного игрока) |
| `bans_meta.json` | Кто забанил, почему, до когда; сами баны — серверные (`bans.json`) |
| `settings.json` | Переопределения настроек |
| `audit/YYYY-MM-DD.jsonl` | Объект JSON на каждое действие или отказ; старше `audit.retain_days` удаляются |

## Другим ресурсам

Через шину сервера (`node.bus`), JSON: спросите `warden:getGroup
{ pid | key, tag? }` и получите `warden:group { key, group, level, perms, tag }`;
спросите `warden:hasPerm { pid | key, perm, tag? }` и получите `warden:perm { ok, ... }`.
warden публикует `warden:ready`, `warden:groupChanged { key, group, pid? }` и
`warden:groupsChanged`.

## Обновление

Распакуйте новый релиз поверх старого. `data/` в архив никогда не входит.
Новая версия может добавить группы или права в значения по умолчанию;
существующий `groups.json` не меняется — `/groups` и панель показывают то,
что у вас есть.

## Разработка

`docs/dev.md`. CI описан в `.github/workflows/ci.yml`; GitHub Actions у
организации сейчас заблокирован по биллингу, поэтому проверки запускаются
локально: `luacheck resources tests tools`, `lua tests/unit/run.lua`,
`lua tools/lang-check.lua`, `tools/get-server.ps1` и
`python tests/gate/<name>_test.py`.
