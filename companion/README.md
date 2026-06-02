# ConLogs companion

Desktop helper that **live-streams** your WoW 3.3.5 combat log to
[epoglogs](https://epoglogs.com) while you raid, and **auto-uploads your gear**
(EpogArmory) when the session ends. No more exporting files by hand.

## Setup

1. **Get a companion token.** Sign in at https://epoglogs.com, open your account
   page, and create a *Companion token*. Copy it (it is shown only once).
2. **Run the app once** to generate `companion.json` next to the executable, then
   edit it:
   ```json
   {
     "server_url": "https://epoglogs.com",
     "upload_token": "PASTE_YOUR_TOKEN_HERE",
     "wow_dir": "",
     "log_name": "",
     "is_pug": false
   }
   ```
   - `wow_dir` — leave blank to auto-detect a standard Ascension/Project Epoch
     install. If detection fails, set it to your WoW client folder (the one that
     contains the `Logs` and `WTF` folders).
3. **Enable combat logging in-game.** Turn on *Advanced Combat Logging*
   (Interface → Network) and type `/combatlog` before you pull.
4. **Run the app** and raid. It streams new combat as it happens; ~5 minutes after
   combat stops it finalizes the upload and pushes your EpogArmory gear data.

## How it works

- Tails `Logs/WoWCombatLog.txt`, sending only newly appended lines (never splits a
  line across requests).
- Opens a live session on first combat (`POST /api/logs/live/start`), streams
  chunks (`/append`), and finalizes on idle or exit (`/finish`) — which produces
  exactly the same result as a manual whole-file upload.
- After finalizing, uploads the newest `WTF/Account/*/SavedVariables/EpogArmory.lua`.

## Build

Pure Go standard library, no external dependencies:

```sh
go build -o conlogs-companion.exe .
```

(Plain `go build` only — do not obfuscate; that triggers AV false positives.)
