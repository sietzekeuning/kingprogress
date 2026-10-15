# Connecting an app to KingProgress

> This page is written to be handed to an LLM, whole, as the brief for connecting another app to
> KingProgress. It has everything needed and nothing else. Raw text:
> <https://raw.githubusercontent.com/sietzekeuning/kingprogress/master/docs/llm.md>

## What KingProgress is

KingProgress is a native macOS menu bar app. It watches GitHub Actions for the signed-in user and shows a
floating card for every workflow run (a build, a deploy) in a stack in a corner of the screen, with a progress
bar based on how long that workflow usually takes. It runs as the logged-in user and has its own GitHub token.

Other apps on the same Mac can connect to it in two ways, independent of each other:

1. **Read the run status** — a JSON file that KingProgress keeps up to date: which runs are queued, running,
   passed or failed, per repository and commit. Use it to find out whether *a specific deploy* is done and
   whether it passed. Read-only.
2. **Put cards in the stack** — a Unix socket where an app sends cards (title, text, avatar, buttons) that
   appear between the run cards, and hears back what the user clicked.

Pick what the app needs: an app or script that waits for or shows a deploy uses (1); an app that wants to
notify the user on screen uses (2); an app can use both.

Rules for the integration:

- Never ask the user for a GitHub token and never call GitHub to learn what KingProgress already knows.
- Never write to the status file, and never create the socket: KingProgress owns both.
- KingProgress may not be running. Both the file and the socket can be missing at any moment; that is a
  normal state, not an error. Degrade quietly ("deploy status unavailable") and try again later.
- Both live in `~/Library/Application Support/KingProgress/`, readable by the current user only. A sandboxed
  app needs a home-relative temporary file exception for `/Library/Application Support/KingProgress/`
  (read-only for the file, read-write for the socket); an unsandboxed app needs nothing.

---

## 1. Run status: `runs.json`

### Where and when

- Path: `~/Library/Application Support/KingProgress/runs.json`.
- Exists only while KingProgress runs, is signed in to GitHub, and the user has **Share run status with other
  apps** switched on (the default). No file means "unknown right now", never "nothing is running".
- Replaced atomically (written next to it, renamed over it) and only when something changes. Always read the
  whole file fresh; never keep a file handle open across changes, and never watch the file's inode (each
  change is a new file). Watch the folder, poll, or use the notification below.
- After every change, and when the file is removed, KingProgress posts the **distributed notification**
  `com.kingprogress.app.runsChanged` (no object, no userInfo). Mac apps observe it with
  `DistributedNotificationCenter` and then re-read the file. Scripts simply poll every few seconds.
- `pid` in the file is KingProgress's process. If that process is not alive (`kill -0 <pid>` fails), the file
  was left behind by a crash: treat it as unknown.
- Freshness: KingProgress polls GitHub every 8 s while a run is active, 15 s when idle. A run that has just
  started can take that long to appear.

### Format

```json
{
  "version": 1,
  "pid": 1893,
  "account": "sietzekeuning",
  "runs": [
    {
      "id": 32376222803,
      "repo": "sietzekeuning/pos",
      "workflow": "production",
      "branch": "master",
      "event": "push",
      "sha": "c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2",
      "commit": "Add refunds to the daily sales export",
      "actor": "sietzekeuning",
      "state": "running",
      "startedAt": 1792070740,
      "expectedDuration": 352,
      "job": "deploy",
      "step": "Run php artisan migrate --force",
      "jobsTotal": 4,
      "jobsCompleted": 3,
      "url": "https://github.com/sietzekeuning/pos/actions/runs/32376222803"
    }
  ]
}
```

Top level: `version` (number, `1`; bumped only for a breaking change), `pid` (number), `account` (string, the
signed-in GitHub login), `runs` (array, newest first by `startedAt`).

Each run. Fields that are unknown are **omitted**, never `null`; ignore fields you do not know.

| Field              | Type   | Present             | Meaning |
| ------------------ | ------ | ------------------- | ------- |
| `id`               | number | always              | GitHub's run id, as in the run's URL. |
| `repo`             | string | always              | `owner/name`. |
| `workflow`         | string | always              | Workflow name, e.g. `Deploy to production`. |
| `branch`           | string | usually             | Branch the run builds. |
| `event`            | string | usually             | `push`, `workflow_dispatch`, `pull_request`, `schedule`, … |
| `sha`              | string | usually             | Full 40-character sha of the commit the run builds. |
| `commit`           | string | usually             | Subject line of that commit. |
| `actor`            | string | usually             | GitHub login of whoever triggered it. |
| `state`            | string | always              | See below. |
| `startedAt`        | number | always              | Unix seconds. When it started (when it left the queue, if KingProgress saw that). |
| `completedAt`      | number | once finished       | Unix seconds. |
| `duration`         | number | once finished       | Seconds it took. |
| `expectedDuration` | number | sometimes           | Seconds this workflow usually takes (median of the last 3 successful runs). |
| `job`, `step`      | string | sometimes           | What is running right now. |
| `jobsTotal`, `jobsCompleted` | number | sometimes | Job counts. |
| `url`              | string | always              | The run on GitHub. |

`state` is one of: `queued`, `running` (not finished) — or `success`, `failure`, `cancelled`, `timed_out`,
`skipped`, `action_required`, `neutral` (final). Treat any other value as final and not a success.

Progress, if wanted: `(now - startedAt) / expectedDuration`, capped below 1 while running. KingProgress does
not write it.

### Which runs are in it

The 5 most recent runs of every repository the user watches in KingProgress, whoever triggered them; plus
older runs that are still going; plus finished runs for an hour after newer ones push them off that list. A
repository the user does not watch is not in the file at all: if the app needs one, tell the user to tick it
in KingProgress's settings.

### Finding "the" deploy

- Identify a deploy by `repo` + `sha` + `workflow`. One push often starts several workflows for the same sha
  (CI and deploy), so the workflow name matters. Make the workflow name configurable in the integrating app.
- Without a sha (e.g. "is production being deployed right now?"): filter on `repo` + `workflow` (+ `branch`)
  and take the first match: the list is newest first.
- With a GitHub run id: match `id`.
- Not found yet is normal for up to ~15 s after a push. Keep waiting, with a timeout the app chooses.

### Recipes

Shell, wait for the deploy of the current commit:

```bash
FILE="$HOME/Library/Application Support/KingProgress/runs.json"
SHA=$(git rev-parse HEAD)
while :; do
  state=$(jq -r --arg sha "$SHA" '[.runs[] | select(.sha == $sha and .workflow == "Deploy")][0].state // empty' "$FILE" 2>/dev/null)
  case ${state:-waiting} in
    waiting|queued|running) sleep 5 ;;
    success) echo "deployed"; break ;;
    *) echo "deploy ended: $state"; exit 1 ;;
  esac
done
```

Swift (macOS app):

```swift
struct KingProgressStatus: Decodable {
    let pid: Int32
    let account: String?
    let runs: [Run]

    struct Run: Decodable {
        let id: Int
        let repo: String
        let workflow: String
        let branch: String?
        let sha: String?
        let commit: String?
        let state: String
        let startedAt: Date
        let completedAt: Date?
        let expectedDuration: TimeInterval?
        let url: URL

        var isDone: Bool { state != "queued" && state != "running" }
    }

    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/KingProgress/runs.json")

    /// Nil while KingProgress is not running, not signed in or not sharing.
    static func load() -> KingProgressStatus? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(KingProgressStatus.self, from: data)
    }
}

// Keep the token; re-read on every ring.
let token = DistributedNotificationCenter.default().addObserver(
    forName: Notification.Name("com.kingprogress.app.runsChanged"), object: nil, queue: .main
) { _ in
    let runs = KingProgressStatus.load()?.runs ?? []
    print(runs.filter { !$0.isDone }.map { "\($0.repo) \($0.workflow): \($0.state)" })
}
```

PHP (e.g. a Laravel command on the same Mac):

```php
$path = getenv('HOME').'/Library/Application Support/KingProgress/runs.json';
$status = is_readable($path) ? json_decode(file_get_contents($path), true) : null;

$deploy = collect($status['runs'] ?? [])
    ->first(fn ($run) => $run['repo'] === 'owner/name' && ($run['sha'] ?? null) === $sha && $run['workflow'] === 'Deploy');

$state = $deploy['state'] ?? null; // null: not known (yet)
```

Python:

```python
import json, os
path = os.path.expanduser("~/Library/Application Support/KingProgress/runs.json")
try:
    with open(path) as f:
        runs = json.load(f)["runs"]
except (FileNotFoundError, ValueError):
    runs = None  # unknown right now
```

---

## 2. Cards in the stack: `cards.sock`

### Transport

- Unix domain **stream** socket at `~/Library/Application Support/KingProgress/cards.sock` (mode `0600`).
- Messages are JSON objects, UTF-8, **one per line** (`\n`), in both directions. A line may be at most about
  4 MB; more without a newline gets the client disconnected.
- **A card lives as long as the connection that sent it.** When the client disconnects, all its cards leave
  the stack. Keep one long-lived connection while cards should show. When the connection drops (KingProgress
  quit or restarted, or the user switched off **Show cards from other apps**), reconnect with a backoff
  (e.g. every 5–30 s) and send the cards that should still be there again.
- Card ids are scoped to the connection: two apps can both use `"1"`.
- The socket is missing while KingProgress is not running or cards from other apps are switched off: connect
  fails with `ENOENT` or `ECONNREFUSED`. That is normal; retry later.

### Client → KingProgress

```json
{"type": "hello", "app": "MyApp", "language": "nl"}
{"type": "show", "card": {"id": "m-1842", "title": "Marieke Postma", "subtitle": "Re: Offerte", "body": "Dank voor de offerte…"}}
{"type": "remove", "id": "m-1842"}
```

- `hello` (optional, send first): `app` names the client in logs; `language` `"en"` (default) or `"nl"` picks
  the words for the card's age label.
- `show`: adds a card, or replaces this client's card with the same `id` **in place** (keeps its position,
  restarts its linger).
- `remove`: slides the card out. No `dismissed` event follows.

Card fields. Only `id` and `title` are required; unknown fields and fields of the wrong type are ignored.

| Field        | Type | Meaning |
| ------------ | ---- | ------- |
| `id`         | string | Unique within this connection. |
| `title`      | string | Bold first line. |
| `subtitle`   | string | Line under the title. |
| `body`       | string | Up to two lines of text. |
| `date`       | number | Unix seconds the card is about; shown as an age. Default: now. |
| `accent`     | array of `"#RRGGBB"` | Colour(s) of the glowing left edge. Default `["#7D8590"]`. |
| `avatar`     | `{"image": "<base64 PNG>"}` or `{"initials": "BV"}` | 30-pt picture left of the text. |
| `glyph`      | `"envelope"`, `"check"` or `"bell"` | Small icon before the title, instead of an avatar. |
| `rows`       | array of `{"title", "subtitle", "avatar"}` | Up to 4 short rows, for a summary card. |
| `caption`    | string | Small line at the bottom left. |
| `captionDot` | `"#RRGGBB"` | Dot before the caption. |
| `actions`    | array of `{"id", "title", "icon"}` | Up to 3 buttons, shown on hover. `icon`: `archive`, `check`, `reply`, `open`, `trash`, `spam`. |
| `strip`      | `{"text", "detail", "button": {"id", "title"}}` | Makes it a one-line card with a check and one button, e.g. an undo. Still needs `title`. |
| `linger`     | number | Seconds before it leaves on its own. Default 20; `0` = until dismissed or removed. |
| `help`       | string | Tooltip. |

### KingProgress → client

```json
{"type": "open", "id": "m-1842"}
{"type": "action", "id": "m-1842", "action": "archive"}
{"type": "dismissed", "id": "m-1842"}
```

- `open`: the card itself was clicked. It stays; usually the app opens the thing and sends `remove`.
- `action`: a button (or the strip's button) was clicked; `action` is its `id`. The card stays until the app
  replaces or removes it.
- `dismissed`: closed with ×, by Clear all, or its linger ran out. It is gone; do not send `remove`.

### Recipe

Python, one card with a button, answering clicks:

```python
import json, os, socket

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(os.path.expanduser("~/Library/Application Support/KingProgress/cards.sock"))

def send(message):
    sock.sendall(json.dumps(message).encode() + b"\n")

send({"type": "hello", "app": "Example", "language": "en"})
send({"type": "show", "card": {"id": "1", "title": "Build finished", "glyph": "bell", "linger": 0,
                               "actions": [{"id": "open", "title": "Open", "icon": "open"}]}})

buffer = b""
while chunk := sock.recv(65536):
    buffer += chunk
    while b"\n" in buffer:
        line, buffer = buffer.split(b"\n", 1)
        event = json.loads(line)
        if event["type"] in ("open", "action"):
            send({"type": "remove", "id": event["id"]})
```

In Swift, use `NWConnection` with `NWEndpoint.unix(path:)` (Network framework), or a POSIX socket; read until
`\n`, decode each line, and write each message followed by `\n`.

---

## Checklist for the integration

- [ ] Missing file / socket handled quietly, retried later.
- [ ] The status file is re-read whole on each check (or on the notification), never cached across changes.
- [ ] A deploy is matched on repo + sha + workflow (configurable), with a timeout for "never showed up".
- [ ] `queued` and `running` are "not done"; every other `state` is final; only `success` is a pass.
- [ ] One long-lived socket connection for cards, reconnecting and re-sending its cards after a drop.
- [ ] No GitHub token, no writes to KingProgress's files.
