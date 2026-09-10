# Building KingProgress

```bash
npm install
npm run package:mac     # or package:win / package:linux
```

Output lands in `release/`:

| Platform | Files |
| --- | --- |
| macOS | `KingProgress-1.4.0-arm64.dmg`, `KingProgress-1.4.0-arm64-mac.zip` |
| Windows | `KingProgress Setup 1.4.0.exe`, `KingProgress-1.4.0-win-portable.exe` |
| Linux | `KingProgress-1.4.0.AppImage`, `kingprogress_1.4.0_amd64.deb` |

Each platform has to be built on that platform (or in CI); electron-builder cannot cross-compile the
Windows and Linux targets from macOS.

## Releasing

KingProgress updates itself from GitHub releases, so publishing is not just "attach the installers".
Every release also has to carry the `latest*.yml` manifest electron-builder generates next to them —
that file is the only thing an installed copy ever looks at. Forget it and nothing breaks loudly:
every install out there simply stays on its old version, silently, forever.

```bash
npm version minor          # or patch/major - the updater compares this to the release
npm run package:mac
npm run notarize:dmg       # macOS only, see below
npm run release            # uploads the installers *and* the manifest
```

`npm run release` creates the GitHub release as a **draft**, because a draft is invisible to the
updater — that is the last chance to check the artifacts before every install in the wild starts
downloading them. Publish it on GitHub when you are happy, or pass `--live` to skip the draft:

```bash
npm run release -- --live
```

Building for more than one platform? Run `npm run release` once, after all the `package:*` builds,
so a single release ends up with `latest-mac.yml`, `latest.yml` and `latest-linux.yml` side by side.
Running it again just uploads what is new.

Two things it deliberately refuses to do: upload a manifest whose version does not match
`package.json` (that is a leftover from an older build, and it would point installs at files that are
not there), and upload artifacts for a version it cannot find in `release/`.

Not every format can update itself. The macOS app, the Windows NSIS install and the Linux AppImage
can; the `.deb` belongs to the package manager and the Windows portable `.exe` is a loose file, so
those two say so in Settings instead and are left alone.

## Signing and notarising the macOS build

Without this, anyone who downloads the DMG gets *"KingProgress cannot be opened because the developer
cannot be verified"* and has to right-click → Open, or run
`xattr -dr com.apple.quarantine /Applications/KingProgress.app`. Notarising removes that entirely.

It needs a paid Apple Developer Program membership. **An "Apple Development" or "Apple Distribution"
certificate is not enough** — those are for local testing and the App Store. Downloads outside the
App Store need a *Developer ID Application* certificate.

### 1. Create the Developer ID certificate (once)

1. Open **Keychain Access** → menu **Certificate Assistant** → **Request a Certificate From a
   Certificate Authority**. Enter your email, leave CA Email empty, pick **Saved to disk**. That
   writes a `.certSigningRequest` file.
2. Go to <https://developer.apple.com/account/resources/certificates/add>.
3. Choose **Developer ID Application** → Continue → upload the CSR from step 1 → Continue.
4. Download the `.cer` and double-click it to add it to your login keychain.

Check that it landed:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 2. Give notarisation something to authenticate with

Apple needs credentials to accept the upload; your Apple ID password will not do. Pick either:

**An App Store Connect API key** (no password to type, works unattended):

1. <https://appstoreconnect.apple.com/access/integrations/api> → **Team Keys** → **+**.
2. Give it the **Developer** role — that is enough to notarise.
3. Download the `AuthKey_XXXXXXXXXX.p8`. It can only be downloaded once. Put it in
   `~/.appstoreconnect/private_keys/`, which is where Apple's tools look by default.
4. Note the **Key ID** and the **Issuer ID** shown on that page.

```bash
export APPLE_API_KEY=~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8
export APPLE_API_KEY_ID=XXXXXXXXXX
export APPLE_API_ISSUER=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

**Or an app-specific password:**

1. <https://appleid.apple.com> → **Sign-In and Security** → **App-Specific Passwords** → generate one.
2. Either export it, or keep it out of your shell history by storing it once:

```bash
xcrun notarytool store-credentials kingprogress --apple-id you@example.com --team-id 7Q6S4366TL
export APPLE_KEYCHAIN_PROFILE=kingprogress
```

Check the credentials before spending a whole build on them:

```bash
xcrun notarytool history --key ~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8 \
  --key-id XXXXXXXXXX --issuer xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

Anything other than an authentication error means they work.

### 3. Build

```bash
npm run package:mac
```

electron-builder signs with the Developer ID certificate, uploads the **app** to Apple and waits for
the verdict. Expect that to add a few minutes to the build.

It does not do the same for the DMG, and Gatekeeper assesses a downloaded disk image in its own
right — so the app inside would be fine while opening the DMG still warned. One more step:

```bash
npm run notarize:dmg
```

That signs the disk image, submits it, staples the ticket and verifies the result.

`electron-builder.json` has `mac.notarize: true`, which means the credentials come purely from the
environment. Do not put `{ "teamId": "…" }` there while using an API key: `@electron/notarize` counts
a `teamId` as password credentials and refuses the build with *"Cannot use password credentials, API
key credentials and keychain credentials at once"*. The app-specific-password route is the one that
needs it — for that, set `"notarize": { "teamId": "7Q6S4366TL" }` instead.

If no credentials are set at all, the build still succeeds but logs `skipped macOS notarization` —
that is the tell-tale that you would be shipping a build with the Gatekeeper prompt.

### 4. Verify before releasing

```bash
spctl -a -vvv -t install /Applications/KingProgress.app   # expect: accepted, source=Notarized Developer ID
xcrun stapler validate release/KingProgress-1.4.0-arm64.dmg
```

If `spctl` says `source=Notarized Developer ID`, a downloaded copy opens with a plain double-click.

Signing matters twice over on macOS: an unsigned app can download an update but not install it, so a
build that skipped notarisation leaves everyone stuck on it.

Stapling rewrites the disk image after electron-builder has already hashed it, so `notarize:dmg`
refreshes the DMG's entry in `latest-mac.yml` on its way out. The updater downloads the `.zip`, not
the `.dmg`, so this is housekeeping rather than the thing that makes an update work — but a manifest
with a wrong checksum in it is a confusing bug report waiting to happen.

## Windows signing (optional)

Add to `electron-builder.json`:

```json
"win": {
  "certificateFile": "path/to/certificate.pfx",
  "certificatePassword": "…"
}
```

Prefer environment variables (`CSC_LINK`, `CSC_KEY_PASSWORD`) over putting a password in a file that
is committed.

## Development

```bash
npm run dev                   # vite + electron, hot reload
KINGPROGRESS_DEMO=1 npm start    # fake runs, to work on the cards without waiting for CI
KINGPROGRESS_VERBOSE=1 npm start # log every poll: repos swept, how many were unchanged, runs tracked
```

`KINGPROGRESS_DEMO=1` seeds a few fake workflow runs that move through queued → running → passed and
failed, so the popup, the animations and the auto-dismiss can all be checked in about 40 seconds.

To try the first-run experience without touching your real settings, point Electron at a scratch
profile:

```bash
./node_modules/.bin/electron . --user-data-dir=/tmp/kingprogress-test
```
