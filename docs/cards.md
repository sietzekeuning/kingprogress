# Cards from other apps

Other apps on the same Mac can put their own cards in KingProgress's floating stack, mixed in between the
run cards in the order they arrive. KingMail uses it for new mail; anything that can open a Unix socket can.

KingProgress knows nothing about what a card is about. It draws what the client sends, in the same chrome
as a run card (Classic or Glass, whichever is picked), and tells the client what was clicked. The client
decides what a click means.

## Transport

- A Unix domain stream socket at `~/Library/Application Support/KingProgress/cards.sock`, readable and
  writable by the current user only (mode `0600`). `KINGPROGRESS_CARDS_SOCKET=/some/path` moves it, which
  lets a development build run next to the installed one.
- Messages are JSON objects, UTF-8, one per line (`\n`), in both directions. A line may be at most about
  4 MB; a client that sends more without a newline is disconnected.
- Any number of clients may be connected at once. Card ids belong to the connection: two apps can both
  have a card called `"1"`.
- **A card lives as long as its connection.** When a client disconnects, all of its cards leave the
  stack, since nobody is left to answer their buttons. Keep the connection open for as long as the cards
  should stay, and reconnect and send them again if KingProgress restarts.
- The socket only exists while **Show cards from other apps** is on in KingProgress's settings (on by
  default). Switching it off closes the socket and removes every card from other apps.
- If a second copy of KingProgress starts while one already serves the socket, it leaves that one alone.

## Client → KingProgress

### `hello` (optional, first)

```json
{"type": "hello", "app": "KingMail", "language": "nl"}
```

`language` picks the words for a card's age: `"en"` (default) says `now`, `1m`, `12m`, `2h`; `"nl"` says
`nu`, `1 min`, `12 min`, `2 u`. Older than a day, a card shows a short date. The label ticks along on its own.

### `show`

```json
{"type": "show", "card": {"id": "m-1842", "title": "Marieke Postma", "subtitle": "Re: Offerte", "body": "Dank voor de offerte…"}}
```

Puts a card in the stack. If this client already has a card with that `id`, it is replaced **in place**: it
keeps its position and its arrival time, and its linger starts over.

### `remove`

```json
{"type": "remove", "id": "m-1842"}
```

Slides the card out. No `dismissed` comes back for it.

### Card fields

Only `id` and `title` are required; a card without them is ignored. Unknown fields are ignored, and so is a
known field of the wrong type.

| Field        | Type                                      | Meaning |
| ------------ | ----------------------------------------- | ------- |
| `id`         | string                                    | The card's id, unique within this connection. |
| `title`      | string                                    | Bold first line. |
| `subtitle`   | string                                    | Line under the title. |
| `body`       | string                                    | Up to two lines of text under the subtitle. |
| `date`       | number                                    | Unix seconds the card is about; shown as an age next to the title. Default: now. |
| `accent`     | array of `"#RRGGBB"`                      | Colour of the glowing left edge and the linger bar. Several colours split the edge into equal segments. Default `["#7D8590"]`. |
| `avatar`     | `{"image": "<base64 PNG>"}` or `{"initials": "BV"}` | 30-point picture left of the text. An image (a site's logo, say) sits on a light tile; initials sit in a circle. |
| `glyph`      | `"envelope"`, `"check"` or `"bell"`       | Small line icon before the title, for a card without an avatar. |
| `rows`       | array of `{"title", "subtitle", "avatar"}` | Short rows under the title, for a summary card. At most 4 are shown; the row avatar is 16 points. |
| `caption`    | string                                    | Small line at the bottom left, such as the account. |
| `captionDot` | `"#RRGGBB"`                               | A dot in this colour before the caption. |
| `actions`    | array of `{"id", "title", "icon"}`        | Buttons at the bottom right, shown while the cursor is on the card. At most 3. `icon`: `archive`, `check`, `reply`, `open` or `trash`. |
| `strip`      | `{"text", "detail", "button": {"id", "title"}}` | Makes the card a single line: a green check, `text`, `detail` and a filled button. For an undo after an action. |
| `linger`     | number                                    | Seconds before the card leaves on its own. Default 20; `0` keeps it until it is dismissed or removed. |
| `help`       | string                                    | Tooltip on the card. |

The four shapes, by the fields they use:

1. **Card**: `avatar`, `title`, `subtitle`, `body`, `caption`, `captionDot`, `actions`.
2. **Card with a glyph**: as above, with `glyph` instead of `avatar`.
3. **Summary**: `glyph`, `title`, `rows`, `caption`, `actions`; often with several `accent` colours.
4. **Strip**: `strip` (with `title` as well, which is required). A strip card has no ×.

## KingProgress → client

```json
{"type": "open", "id": "m-1842"}
{"type": "action", "id": "m-1842", "action": "archive"}
{"type": "dismissed", "id": "m-1842"}
```

- `open`: the card itself (not one of its buttons) was clicked. The card stays; the client usually opens
  whatever it is about and sends `remove`.
- `action`: one of the card's buttons was clicked. `action` is the button's `id`, also for the strip's
  button. The card stays until the client replaces or removes it.
- `dismissed`: the card was closed with ×, by **Clear all**, or because its linger ran out. It is gone.

## How the stack treats the cards

- Runs and cards are one column, newest first, by arrival: a run when it started, a card when it was first
  shown.
- The bar along the bottom of a card drains over its `linger`. While the cursor is on the card the countdown
  waits; when the cursor leaves it carries on with what was left, but with at least 3 seconds.
- **Clear all** counts and clears runs and cards alike.
- While KingProgress's window is open the run cards stay off the stack (the window lists the runs), but
  cards from other apps still show. The window does not list them.
- Dragging a card moves the whole stack, as with run cards.

## Trying it

`nc` closes the connection when its input ends, which takes the card with it, so keep the input open:

```bash
SOCK="$HOME/Library/Application Support/KingProgress/cards.sock"
( printf '%s\n' '{"type":"hello","app":"Shell","language":"en"}' \
    '{"type":"show","card":{"id":"1","title":"Hello from the shell","body":"Click me, or wait 20 seconds.","accent":["#34C77B"],"avatar":{"initials":"SH"},"actions":[{"id":"ok","title":"OK","icon":"check"}]}}'
  sleep 30 ) | nc -U "$SOCK"
```

The events come back on `nc`'s output. A small Python client:

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
while True:
    chunk = sock.recv(65536)
    if not chunk:
        break
    buffer += chunk
    while b"\n" in buffer:
        line, buffer = buffer.split(b"\n", 1)
        event = json.loads(line)
        print(event)
        if event["type"] in ("open", "action"):
            send({"type": "remove", "id": event["id"]})
```
