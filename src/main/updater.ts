import { app, Notification } from 'electron'
import { autoUpdater, type UpdateInfo, type ProgressInfo } from 'electron-updater'

// Wait a moment after launch before the first check, so it does not compete
// with signing in and the first poll of the workflow runs.
const FIRST_CHECK_DELAY_MS = 10000
const CHECK_INTERVAL_MS = 6 * 60 * 60 * 1000

const VERBOSE = process.env.PROGRESSY_VERBOSE === '1'

export type UpdateStatus =
    | 'idle' // nothing to do; the last check found no newer version
    | 'checking'
    | 'downloading'
    | 'ready' // downloaded and staged; it installs on restart
    | 'error'
    | 'unsupported' // this build cannot update itself

export interface UpdateState {
    status: UpdateStatus
    /** The version running right now. */
    currentVersion: string
    /** The version being downloaded, or waiting to be installed. */
    newVersion: string | null
    /** 0-100 while downloading. */
    percent: number
    /** Why it is unsupported, or what went wrong. */
    message: string | null
    /** When the last check finished, as epoch ms. */
    checkedAt: number | null
}

let state: UpdateState = {
    status: 'idle',
    currentVersion: app.getVersion(),
    newVersion: null,
    percent: 0,
    message: null,
    checkedAt: null,
}

let onChange: (state: UpdateState) => void = () => {}
let checkTimer: NodeJS.Timeout | null = null
let notifiedVersion: string | null = null

function setState(patch: Partial<UpdateState>) {
    state = { ...state, ...patch }
    onChange(getUpdateState())
}

export function getUpdateState(): UpdateState {
    return { ...state }
}

/**
 * Why this build cannot update itself, or null when it can.
 *
 * Only the installed formats know how to replace themselves: the macOS app, the
 * NSIS install on Windows and the Linux AppImage. A .deb belongs to the package
 * manager, and the Windows portable .exe is a loose file the updater has no
 * business overwriting.
 */
function updateBlocker(): string | null {
    if (!app.isPackaged) {
        return 'Updates only apply to a packaged build.'
    }
    if (process.platform === 'linux' && !process.env.APPIMAGE) {
        return 'Installed from a package — update it with your package manager.'
    }
    if (process.platform === 'win32' && process.env.PORTABLE_EXECUTABLE_FILE) {
        return 'Portable build — download a new copy to update.'
    }
    return null
}

/**
 * Watch GitHub releases for a newer version, download it in the background and
 * stage it for the next restart.
 *
 * Nothing is installed behind the user's back mid-session: the swap happens when
 * Progressy quits, or immediately if they pick "Restart to update".
 */
export function initAutoUpdate(listener: (state: UpdateState) => void) {
    onChange = listener

    const blocker = updateBlocker()
    if (blocker) {
        if (VERBOSE) {
            console.log('[progressy] auto-update off:', blocker)
        }
        setState({ status: 'unsupported', message: blocker })
        return
    }

    autoUpdater.autoDownload = true
    autoUpdater.autoInstallOnAppQuit = true
    autoUpdater.logger = VERBOSE ? console : null

    autoUpdater.on('checking-for-update', () => {
        // Keep a staged update visible; a check does not undo it.
        if (state.status !== 'ready') {
            setState({ status: 'checking', message: null })
        }
    })

    autoUpdater.on('update-not-available', (info: UpdateInfo) => {
        if (VERBOSE) {
            console.log(`[progressy] no update - ${info.version} is the latest`)
        }
        if (state.status !== 'ready') {
            setState({ status: 'idle', newVersion: null, message: null, checkedAt: Date.now() })
        }
    })

    autoUpdater.on('update-available', (info: UpdateInfo) => {
        // A version that is already downloaded is announced again on every
        // check. Re-running the download UI for it would only flicker.
        if (state.status === 'ready' && state.newVersion === info.version) {
            return
        }
        console.log(`[progressy] ${info.version} is available - downloading`)
        setState({ status: 'downloading', newVersion: info.version, percent: 0, checkedAt: Date.now() })
    })

    autoUpdater.on('download-progress', (progress: ProgressInfo) => {
        setState({ status: 'downloading', percent: Math.round(progress.percent) })
    })

    autoUpdater.on('update-downloaded', (info: UpdateInfo) => {
        console.log(`[progressy] ${info.version} is ready - it installs on restart`)
        setState({ status: 'ready', newVersion: info.version, percent: 100, checkedAt: Date.now() })
        announce(info.version)
    })

    autoUpdater.on('error', (error: Error) => {
        console.error('[progressy] update failed:', error?.message || error)
        // A failed check is not worth nagging about - it retries in a few hours.
        // But do not throw away an update that already downloaded.
        if (state.status !== 'ready') {
            setState({
                status: 'error',
                message: error?.message || 'Could not reach GitHub.',
                checkedAt: Date.now(),
            })
        }
    })

    setTimeout(() => {
        checkForUpdates()
        checkTimer = setInterval(checkForUpdates, CHECK_INTERVAL_MS)
    }, FIRST_CHECK_DELAY_MS)
}

export function stopAutoUpdate() {
    if (checkTimer) {
        clearInterval(checkTimer)
        checkTimer = null
    }
}

/** Tell the user once per version that a restart is all it takes. */
function announce(version: string) {
    if (notifiedVersion === version || !Notification.isSupported()) {
        return
    }
    notifiedVersion = version

    const notification = new Notification({
        title: `Progressy ${version} is ready`,
        body: 'It installs the next time Progressy restarts.',
        silent: true,
    })
    notification.on('click', () => installUpdate())
    notification.show()
}

export function checkForUpdates() {
    // Nothing a check could turn up matters while a version is already sitting
    // there waiting for a restart.
    if (updateBlocker() || state.status === 'ready') {
        return
    }
    autoUpdater.checkForUpdates().catch((error: Error) => {
        // The error event above already reported it; this only stops the
        // rejection from surfacing as an unhandled promise.
        if (VERBOSE) {
            console.log('[progressy] check rejected:', error?.message || error)
        }
    })
}

/** Quit, swap in the downloaded version and come back up. */
export function installUpdate(): boolean {
    if (state.status !== 'ready') {
        return false
    }
    // Silent on Windows so a tray app does not pop an installer wizard, and
    // relaunch afterwards so the user lands back where they were.
    setImmediate(() => autoUpdater.quitAndInstall(true, true))
    return true
}
