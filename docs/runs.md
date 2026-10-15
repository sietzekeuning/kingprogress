# Run status for other apps

KingProgress keeps a file with the status of the runs in the repositories it watches, so other apps on the
same Mac can see how a deploy is doing without a GitHub token of their own: is the deploy of this commit done
yet, did it pass, how long until it is. A script that just pushed can wait for its deploy; a Mac app can show
it. KingProgress only writes the file and never reads it back, so there is nothing to send.

The other way round, putting cards in KingProgress's stack, is the card socket in [cards.md](cards.md).

## The file

- `~/Library/Application Support/KingProgress/runs.json`, readable and writable by the current user only
  (mode `0600`). `KINGPROGRESS_RUNS_FILE=/some/path` moves it, which lets a development build run next to the
  installed one.
- JSON, UTF-8. It is rewritten only when what it says changes, and always in one go: KingProgress writes a new
  file next to it and renames it over the old one, so a reader gets the old file or the new one, never half
  of either.
- After every change, and when the file is removed, KingProgress posts the distributed notification
  **`com.kingprogress.app.runsChanged`**. It carries nothing; read the file again. Every change is a new file,
  so watch the folder rather than the file if you would rather not use the notification.
- **The file only exists while KingProgress runs, is signed in and may share.** Quitting, signing out and
  switching off **Share run status with other apps** in the settings (on by default) all remove it. No file
  means KingProgress cannot tell you anything right now, not that nothing is running.
- A file left behind by a crash names a `pid` that is no longer running: `kill -0 <pid>` tells.
- If a second copy of KingProgress starts while one already keeps the file, it leaves that one alone. Once
  the first copy quits and the file is gone, the second takes over at its next change.

## What is in it

```json
{
  "account" : "sietzekeuning",
  "pid" : 1893,
  "runs" : [
    {
      "actor" : "sietzekeuning",
      "branch" : "master",
      "commit" : "Add refunds to the daily sales export",
      "event" : "push",
      "expectedDuration" : 352,
      "id" : 32376222803,
      "job" : "deploy",
      "jobsCompleted" : 3,
      "jobsTotal" : 4,
      "repo" : "sietzekeuning/pos",
      "sha" : "c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2",
      "startedAt" : 1792070740,
      "state" : "running",
      "step" : "Run php artisan migrate --force",
      "url" : "https://github.com/sietzekeuning/pos/actions/runs/32376222803",
      "workflow" : "production"
    },
    {
      "actor" : "octocat",
      "branch" : "release/2026-08",
      "commit" : "Bump image to PHP 8.4 and rotate the registry token",
      "completedAt" : 1792070968,
      "duration" : 64,
      "event" : "push",
      "id" : 32376222802,
      "repo" : "sietzekeuning/marmaya",
      "sha" : "9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b",
      "startedAt" : 1792070905,
      "state" : "failure",
      "url" : "https://github.com/sietzekeuning/marmaya/actions/runs/32376222802",
      "workflow" : "Deploy to production"
    }
  ],
  "version" : 1
}
```

| Field     | Type            | Meaning |
| --------- | --------------- | ------- |
| `version` | number          | `1`. A change that would break a reader gets a new number; new fields do not. |
| `pid`     | number          | The KingProgress process that keeps the file. |
| `account` | string          | The GitHub login KingProgress is signed in as, to tell your own runs from the rest. |
| `runs`    | array           | The runs, newest first by `startedAt`. |

Times are whole Unix seconds and durations whole seconds. A field that is not known is left out, never `null`.
Unknown fields should be ignored: more may come.

| Run field          | Type   | Meaning |
| ------------------ | ------ | ------- |
| `id`               | number | GitHub's id for the run, the number in its URL. |
| `repo`             | string | `owner/name`. |
| `workflow`         | string | The workflow's name, such as `Deploy to production`. |
| `branch`           | string | The branch the run builds. |
| `event`            | string | What started it: `push`, `workflow_dispatch`, `pull_request`, `schedule`, … |
| `sha`              | string | The full sha of the commit the run builds. |
| `commit`           | string | That commit's subject line. |
| `actor`            | string | The login of whoever triggered the run. |
| `state`            | string | Where it is: see below. |
| `startedAt`        | number | When the run started. For a run KingProgress saw waiting in the queue, the moment it left it. |
| `completedAt`      | number | When it finished, once it has. |
| `duration`         | number | How long it took, once it has finished. |
| `expectedDuration` | number | How long this workflow usually takes: the median of its last 3 successful runs. |
| `job`              | string | The job that is running now. |
| `step`             | string | The step of that job that is running now. |
| `jobsTotal`        | number | How many jobs the run has. |
| `jobsCompleted`    | number | How many of them are done. |
| `url`              | string | The run on GitHub. |

`expectedDuration`, `job`, `step`, `jobsTotal` and `jobsCompleted` are only there for runs that have, or had,
a card: those are the runs KingProgress asks GitHub about in detail. While a run is still going, `job`, `step`
and the job counts go when its card does.
How far along a run is, is `(now - startedAt) / expectedDuration`; KingProgress does not write it, since it
would change every second.

### `state`

| `state`           | Meaning |
| ----------------- | ------- |
| `queued`          | Waiting for a runner. |
| `running`         | Running. A run that is between two jobs, waiting for a runner for the next one, stays `running`. |
| `success`         | Passed. |
| `failure`         | Failed, also when it could not start at all. |
| `cancelled`       | Cancelled, or given up on by GitHub. |
| `timed_out`       | Ran out of time. |
| `skipped`         | Skipped. |
| `action_required` | Waits for someone to approve it. |
| `neutral`         | Finished, with no verdict. |

`queued` and `running` mean the run is not done yet. Every other state is final.

## Which runs are in it

- The 5 most recent runs of every watched repository: the ones ticked in the settings, or the 5 most recently
  updated repositories when none are. Whoever triggered them, whether they have a card on screen or not, and
  also runs that finished before KingProgress started.
- Runs that newer ones pushed off that list: while they are still going (KingProgress keeps asking GitHub
  about them until they finish), and for an hour once they have.
- A repository that is no longer watched takes its runs out of the file.

KingProgress polls GitHub every 8 seconds while something runs and every 15 when nothing does, so the file
is never far behind GitHub, but a run that has just started can take that long to show up. A push often
starts more than one workflow for the same commit, a CI run and a deploy say, so look for the workflow as
well as the sha.

## Trying it

Wait for the deploy of the commit you just pushed. `jq` gives an empty answer while there is no file or no
such run yet, which counts as not done:

```bash
FILE="$HOME/Library/Application Support/KingProgress/runs.json"
SHA=$(git rev-parse HEAD)

while :; do
  state=$(jq -r --arg sha "$SHA" '[.runs[] | select(.sha == $sha and .workflow == "Deploy")][0].state // empty' "$FILE" 2>/dev/null)
  case ${state:-waiting} in
    waiting|queued|running) sleep 5 ;;
    success) echo "deployed"; break ;;
    *) echo "the deploy ended in $state"; exit 1 ;;
  esac
done
```

Everything that is running right now, from Python:

```python
import json, os, time

path = os.path.expanduser("~/Library/Application Support/KingProgress/runs.json")
try:
    with open(path) as f:
        status = json.load(f)
except FileNotFoundError:
    status = None  # KingProgress is not running, not signed in, or not sharing

for run in (status or {}).get("runs", []):
    if run["state"] in ("queued", "running"):
        left = ""
        if "expectedDuration" in run:
            left = f", about {max(0, run['startedAt'] + run['expectedDuration'] - time.time()):.0f}s left"
        print(f"{run['repo']} {run['workflow']}: {run['state']}{left}")
```

A Mac app that keeps up with the deploys, in Swift:

```swift
import Foundation

struct RunStatus: Decodable {
    let account: String?
    let runs: [Run]

    struct Run: Decodable {
        let id: Int
        let repo: String
        let workflow: String
        let sha: String?
        let state: String
        let startedAt: Date
        let expectedDuration: TimeInterval?
        let url: URL
    }

    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/KingProgress/runs.json")

    /// Nil while KingProgress is not running, not signed in or not sharing.
    static func load() -> RunStatus? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(RunStatus.self, from: data)
    }
}

let observer = DistributedNotificationCenter.default().addObserver(
    forName: Notification.Name("com.kingprogress.app.runsChanged"), object: nil, queue: .main
) { _ in
    let deploys = RunStatus.load()?.runs.filter { $0.workflow == "Deploy" } ?? []
    print(deploys.map { "\($0.repo): \($0.state)" })
}
```

A sandboxed app can receive the notification as it is, but needs a read-only file exception for
`/Library/Application Support/KingProgress/` (home-relative) to read the file.
