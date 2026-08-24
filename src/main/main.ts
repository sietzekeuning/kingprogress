import { app, BrowserWindow, Tray, Menu, nativeImage, screen, ipcMain, clipboard, shell, safeStorage } from 'electron'
import * as os from 'os'
import * as path from 'path'
import AutoLaunch from 'auto-launch'
import Store from 'electron-store'
import { Octokit } from '@octokit/rest'
import {
    AuthError,
    DeviceCode,
    Account,
    looksLikeToken,
    pollForDeviceToken,
    requestDeviceCode,
    tokenCreationUrl,
    validateToken,
} from './auth'
import { checkForUpdates, getUpdateState, initAutoUpdate, installUpdate, stopAutoUpdate } from './updater'

const store = new Store()

// Device flow needs a client id but no secret, so it is safe to ship. Leave it
// empty and Progressy falls back to a pasted personal access token; set it to
// your own OAuth App (with "Enable Device Flow" ticked) to get the
// "Sign in with GitHub" button.
const BUILT_IN_CLIENT_ID = ''


// How long a finished run keeps its card on screen before it slides away.
const COMPLETED_LINGER_MS = 20000
// How long a dismissed run stays dismissed. New runs get a new key, so they
// always come back on their own.
const DISMISSED_MEMORY_MS = 6 * 60 * 60 * 1000
const JOB_DETAILS_CACHE_MS = 30000 // Cache job details for 30 seconds
const EXPECTED_DURATION_CACHE_MS = 30 * 60 * 1000 // Re-measure a workflow's usual runtime twice an hour
const EXPECTED_DURATION_SAMPLES = 3 // Take the last 3 successful runs as the yardstick
// Idle repos cost nothing (conditional requests come back 304, which GitHub
// does not charge), so the interval only has to respect the runs we are
// actively following.
const POLL_IDLE_MS = 15000
const POLL_ACTIVE_MS = 8000
const REPOS_TO_SCAN = 5 // when the user has not picked repos themselves
const RUNS_PER_REPO = 5
const REPO_LIST_CACHE_MS = 10 * 60 * 1000

const VERBOSE = process.env.PROGRESSY_VERBOSE === '1'

const POPUP_WIDTH = 384
const POPUP_MARGIN = 16
const MAIN_WINDOW_WIDTH = 440

// The popup is a status HUD that lives on top of whatever the user is doing,
// so it must keep ticking while the app itself is in the background. Without
// this Chromium freezes its timers and animations the moment we lose focus.
app.commandLine.appendSwitch('disable-background-timer-throttling')
app.commandLine.appendSwitch('disable-renderer-backgrounding')
app.commandLine.appendSwitch('disable-backgrounding-occluded-windows')

type RunStatus = 'queued' | 'in_progress' | 'completed'

type ActorMode = 'all' | 'me' | 'only'

interface ActorFilter {
    mode: ActorMode
    logins: string[]
}

type ActionState =
    | 'queued'
    | 'running'
    | 'success'
    | 'failure'
    | 'cancelled'
    | 'timed_out'
    | 'skipped'
    | 'action_required'
    | 'neutral'

interface TrackedRun {
    key: string
    repo: string
    owner: string
    repoName: string
    runId: number
    workflowId: number | null
    name: string
    branch: string | null
    event: string | null
    status: RunStatus
    conclusion: string | null
    startedAt: string
    completedAtMs: number | null
    durationMs: number | null
    expectedDurationMs: number | null
    actor: string | null
    currentJob: string | null
    currentStep: string | null
    jobsTotal: number
    jobsCompleted: number
    url: string
}

let tray: Tray | null = null
let mainWindow: BrowserWindow | null = null
let popupWindow: BrowserWindow | null = null
let octokit: Octokit | null = null
let pollTimer: NodeJS.Timeout | null = null
let lingerInterval: NodeJS.Timeout | null = null
let pointerWatchdog: NodeJS.Timeout | null = null
let popupVisible = false
let popupInteractive = false

const runningActions: Map<string, TrackedRun> = new Map()
const dismissedKeys: Map<string, number> = new Map() // key -> dismissed at
const lastJobDetailsFetch: Map<string, number> = new Map() // Track when we last fetched job details
const expectedDurationCache: Map<string, { value: number | null; fetchedAt: number }> = new Map()
const runsCache: Map<string, { etag: string | null; runs: any[] }> = new Map()
let conditionalHits = 0 // 304s in the last sweep, for the verbose log

function updateTrayMenu() {
    if (!tray) return

    const token = store.get('githubToken') as string | undefined
    const menuItems: Electron.MenuItemConstructorOptions[] = [
        {
            label: 'Show Window',
            click: () => {
                if (mainWindow) {
                    mainWindow.show()
                } else {
                    createMainWindow()
                }
            },
        },
    ]

    // An update that is on its way, or waiting for a restart, is worth a line
    // here - this menu is the only part of Progressy that is always reachable.
    const update = getUpdateState()
    if (update.status === 'ready') {
        menuItems.push({
            label: `Restart to update to ${update.newVersion}`,
            click: () => installUpdate(),
        })
    } else if (update.status === 'downloading') {
        menuItems.push({
            label: `Downloading ${update.newVersion}… ${update.percent}%`,
            enabled: false,
        })
    }

    if (token) {
        menuItems.push({
            label: 'Disconnect',
            click: async () => {
                store.set('githubToken', '')
                octokit = null
                stopActionMonitoring()
                updateTrayMenu()
                if (mainWindow) {
                    mainWindow.reload()
                }
            },
        })
    }

    menuItems.push({
        type: 'separator',
    })

    menuItems.push({
        label: 'Quit',
        click: () => {
            app.quit()
        },
    })

    const contextMenu = Menu.buildFromTemplate(menuItems)
    tray.setContextMenu(contextMenu)
}

// Configure auto-launch (Windows only for now)
let autoLauncher: AutoLaunch | null = null
if (process.platform === 'win32') {
    autoLauncher = new AutoLaunch({
        name: 'Progressy',
        path: app.getPath('exe'),
    })

    // Enable auto-launch
    autoLauncher.enable().catch(console.error)
}

function createTray() {
    let icon = nativeImage.createEmpty()
    const appPath = app.getAppPath()
    const fs = require('fs')

    // On macOS, try template icons first, then fall back to regular icon
    if (process.platform === 'darwin') {
        // Try to load template icons (1x and 2x for retina)
        const templatePaths = [
            // Development paths (when running from project root)
            path.join(appPath, 'src/assets/iconTemplate@2x.png'),
            path.join(__dirname, '../../src/assets/iconTemplate@2x.png'),
            path.join(__dirname, '../assets/iconTemplate@2x.png'),
            // Production paths (when packaged)
            path.join(process.resourcesPath || appPath, 'assets/iconTemplate@2x.png'),
            path.join(process.resourcesPath || appPath, 'src/assets/iconTemplate@2x.png'),
            // Try 1x version if 2x not found
            path.join(appPath, 'src/assets/iconTemplate.png'),
            path.join(__dirname, '../../src/assets/iconTemplate.png'),
            path.join(__dirname, '../assets/iconTemplate.png'),
            path.join(process.resourcesPath || appPath, 'assets/iconTemplate.png'),
            path.join(process.resourcesPath || appPath, 'src/assets/iconTemplate.png'),
        ]

        for (const iconPath of templatePaths) {
            if (fs.existsSync(iconPath)) {
                const testIcon = nativeImage.createFromPath(iconPath)
                if (!testIcon.isEmpty()) {
                    icon = testIcon
                    // Set as template image for macOS menu bar
                    icon.setTemplateImage(true)
                    console.log('Loaded tray icon (template) from:', iconPath)
                    break
                }
            }
        }

        // If template icon didn't work or is empty, try regular icon
        if (icon.isEmpty()) {
            const regularIconPaths = [
                path.join(appPath, 'src/assets/icon.png'),
                path.join(__dirname, '../../src/assets/icon.png'),
                path.join(__dirname, '../assets/icon.png'),
                path.join(process.resourcesPath || appPath, 'assets/icon.png'),
                path.join(process.resourcesPath || appPath, 'src/assets/icon.png'),
            ]

            for (const iconPath of regularIconPaths) {
                if (fs.existsSync(iconPath)) {
                    const testIcon = nativeImage.createFromPath(iconPath)
                    if (!testIcon.isEmpty()) {
                        // Resize to appropriate size for menu bar (22x22)
                        const size = testIcon.getSize()
                        if (size.width > 22 || size.height > 22) {
                            icon = testIcon.resize({ width: 22, height: 22 })
                        } else {
                            icon = testIcon
                        }
                        console.log('Loaded tray icon (regular) from:', iconPath)
                        break
                    }
                }
            }
        }
    } else {
        // For Windows/Linux, try regular icon paths
        const iconPaths = [
            // Development paths
            path.join(appPath, 'src/assets/icon.png'),
            path.join(__dirname, '../../src/assets/icon.png'),
            path.join(__dirname, '../assets/icon.png'),
            // Production paths
            path.join(process.resourcesPath || appPath, 'assets/icon.png'),
            path.join(process.resourcesPath || appPath, 'src/assets/icon.png'),
        ]

        for (const iconPath of iconPaths) {
            if (fs.existsSync(iconPath)) {
                const testIcon = nativeImage.createFromPath(iconPath)
                if (!testIcon.isEmpty()) {
                    icon = testIcon
                    console.log('Loaded tray icon from:', iconPath)
                    break
                }
            }
        }
    }

    // Fallback: create a simple visible icon if none found
    if (icon.isEmpty()) {
        console.warn('No tray icon found, using fallback icon')
        const size = 22
        const iconBuffer = Buffer.alloc(size * size * 4)
        // Create a visible gray square
        for (let i = 0; i < iconBuffer.length; i += 4) {
            iconBuffer[i] = 100 // R
            iconBuffer[i + 1] = 100 // G
            iconBuffer[i + 2] = 100 // B
            iconBuffer[i + 3] = 255 // A
        }
        icon = nativeImage.createFromBuffer(iconBuffer, { width: size, height: size })
        if (process.platform === 'darwin') {
            icon.setTemplateImage(true)
        }
    }

    try {
        tray = new Tray(icon)
        console.log('Tray created successfully with icon size:', icon.getSize())
    } catch (error) {
        console.error('Failed to create tray:', error)
        return
    }

    updateTrayMenu()
    tray.setToolTip('Progressy - GitHub Actions Monitor')
    tray.on('click', () => {
        if (mainWindow && !mainWindow.isDestroyed()) {
            mainWindow.show()
            mainWindow.focus()
        } else {
            createMainWindow()
        }
    })
}

// ---------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------

function resolveRendererPath(): string {
    const fs = require('fs')
    const appPath = app.getAppPath()
    const candidates = [
        path.join(appPath, 'dist/renderer/index.html'), // running from the project root
        path.join(__dirname, '../renderer/index.html'), // __dirname is dist/main
        path.join(__dirname, 'renderer/index.html'), // __dirname is dist
        path.join(appPath, 'renderer/index.html'), // fallback
    ]

    return candidates.find((candidate: string) => fs.existsSync(candidate)) || candidates[0]
}

function createMainWindow() {
    // Show dock icon when window is opened (macOS)
    if (process.platform === 'darwin') {
        app.dock.show()
    }

    mainWindow = new BrowserWindow({
        width: MAIN_WINDOW_WIDTH,
        height: 420,
        minWidth: MAIN_WINDOW_WIDTH,
        maxWidth: MAIN_WINDOW_WIDTH,
        backgroundColor: '#0d1117',
        titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
        webPreferences: {
            nodeIntegration: false,
            contextIsolation: true,
            backgroundThrottling: false,
            preload: path.join(__dirname, 'preload.js'),
        },
        show: false,
    })

    if (process.env.NODE_ENV === 'development') {
        mainWindow.loadURL('http://localhost:5173')
    } else {
        mainWindow.loadFile(resolveRendererPath())
    }

    mainWindow.on('closed', () => {
        // Hide dock icon again when window is closed (macOS)
        if (process.platform === 'darwin') {
            app.dock.hide()
        }
        mainWindow = null
        syncPopupVisibility()
    })

    // Hand the screen back and forth as the window comes and goes. Without
    // these the stack would only reappear whenever the next poll happens to
    // land, which is up to fifteen seconds of nothing.
    mainWindow.on('show', syncPopupVisibility)
    mainWindow.on('hide', syncPopupVisibility)
    mainWindow.on('minimize', syncPopupVisibility)
    mainWindow.on('restore', syncPopupVisibility)

    mainWindow.once('ready-to-show', () => {
        mainWindow?.show()
    })

    // Log any errors from the renderer
    mainWindow.webContents.on('did-fail-load', (_event, errorCode, errorDescription, validatedURL) => {
        console.error('Failed to load:', validatedURL, errorCode, errorDescription)
    })

    mainWindow.webContents.on('console-message', (_event, level, message) => {
        console.log(`[Renderer ${level}]:`, message)
    })
}

// ---------------------------------------------------------------------------
// Popup window
//
// The popup is a transparent, click-through column pinned to the top-right of
// the work area. Because nothing but the cards themselves is ever painted, the
// container always fits the content exactly - no padding to guess at, and the
// cards are free to animate in and out beyond their own bounds.
// ---------------------------------------------------------------------------

function getPopupBounds(): Electron.Rectangle {
    const { workArea } = screen.getPrimaryDisplay()
    const width = POPUP_WIDTH + POPUP_MARGIN * 2
    const height = Math.max(240, workArea.height - POPUP_MARGIN)

    return {
        width,
        height,
        x: Math.round(workArea.x + workArea.width - width),
        y: Math.round(workArea.y),
    }
}

function setPopupInteractive(interactive: boolean) {
    if (!popupWindow || popupWindow.isDestroyed()) {
        return
    }

    if (interactive === popupInteractive) {
        return
    }

    popupInteractive = interactive

    if (interactive) {
        popupWindow.setIgnoreMouseEvents(false)
        startPointerWatchdog()
    } else {
        // `forward` keeps mousemove events flowing to the renderer while every
        // other event passes straight through to whatever is underneath.
        popupWindow.setIgnoreMouseEvents(true, { forward: true })
        stopPointerWatchdog()
    }
}

// Safety net: if the cursor leaves the window fast enough that the renderer
// never sees the exit, the window would stay clickable and swallow clicks meant
// for the app underneath. Poll the real cursor position while interactive.
function startPointerWatchdog() {
    if (pointerWatchdog) {
        return
    }

    pointerWatchdog = setInterval(() => {
        if (!popupWindow || popupWindow.isDestroyed() || !popupVisible) {
            setPopupInteractive(false)
            return
        }

        const cursor = screen.getCursorScreenPoint()
        const bounds = popupWindow.getBounds()
        const inside =
            cursor.x >= bounds.x &&
            cursor.x <= bounds.x + bounds.width &&
            cursor.y >= bounds.y &&
            cursor.y <= bounds.y + bounds.height

        if (!inside) {
            setPopupInteractive(false)
        }
    }, 400)
}

function stopPointerWatchdog() {
    if (pointerWatchdog) {
        clearInterval(pointerWatchdog)
        pointerWatchdog = null
    }
}

function ensurePopupWindow(): BrowserWindow {
    if (popupWindow && !popupWindow.isDestroyed()) {
        return popupWindow
    }

    popupWindow = new BrowserWindow({
        ...getPopupBounds(),
        frame: false,
        transparent: true,
        backgroundColor: '#00000000',
        hasShadow: false,
        resizable: false,
        movable: false,
        minimizable: false,
        maximizable: false,
        fullscreenable: false,
        skipTaskbar: true,
        alwaysOnTop: true,
        acceptFirstMouse: true,
        show: false,
        webPreferences: {
            nodeIntegration: false,
            contextIsolation: true,
            backgroundThrottling: false,
            preload: path.join(__dirname, 'preload.js'),
        },
    })

    popupWindow.setAlwaysOnTop(true, 'screen-saver')
    popupWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true })
    popupInteractive = true // force the next call through
    setPopupInteractive(false)

    if (process.env.NODE_ENV === 'development') {
        popupWindow.loadURL('http://localhost:5173/#popup')
    } else {
        // The hash has to be part of the initial load: the renderer decides
        // which view to mount from it, and it only reads it once.
        popupWindow.loadFile(resolveRendererPath(), { hash: 'popup' })
    }

    popupWindow.on('closed', () => {
        popupWindow = null
        popupVisible = false
        stopPointerWatchdog()
    })

    return popupWindow
}

/**
 * Is the user looking at the window right now?
 *
 * A minimised window is still "visible" as far as Electron is concerned, but
 * there is nothing on screen to look at.
 */
function mainWindowIsShowing(): boolean {
    return !!mainWindow && !mainWindow.isDestroyed() && mainWindow.isVisible() && !mainWindow.isMinimized()
}

/**
 * The window and the cards show the same runs, so having both on screen is
 * just the same information twice. The window wins while it is open.
 */
function syncPopupVisibility() {
    if (mainWindowIsShowing()) {
        hidePopupWindow()
    } else if (visibleActions().length > 0) {
        showPopupWindow()
    }
}

function showPopupWindow() {
    // Every path that puts a card on screen comes through here, so this one
    // check keeps the stack away for as long as the window is up.
    if (mainWindowIsShowing()) {
        return
    }

    const win = ensurePopupWindow()

    if (popupVisible && win.isVisible()) {
        return
    }

    win.setBounds(getPopupBounds())
    win.showInactive() // never steal focus from whatever the user is doing
    win.setAlwaysOnTop(true, 'screen-saver')
    popupVisible = true
}

function hidePopupWindow() {
    setPopupInteractive(false)
    popupVisible = false

    if (popupWindow && !popupWindow.isDestroyed() && popupWindow.isVisible()) {
        popupWindow.hide()
    }
}

// ---------------------------------------------------------------------------
// Action state
// ---------------------------------------------------------------------------

function normalizeStatus(status: string | null | undefined): RunStatus {
    switch (status) {
        case 'completed':
            return 'completed'
        case 'in_progress':
            return 'in_progress'
        default:
            // queued, waiting, requested, pending
            return 'queued'
    }
}

function median(values: number[]): number | null {
    if (!values.length) {
        return null
    }

    const sorted = [...values].sort((a, b) => a - b)
    const middle = Math.floor(sorted.length / 2)

    return sorted.length % 2
        ? sorted[middle]
        : Math.round((sorted[middle - 1] + sorted[middle]) / 2)
}

function actionState(action: TrackedRun): ActionState {
    if (action.status !== 'completed') {
        return action.status === 'in_progress' ? 'running' : 'queued'
    }

    switch (action.conclusion) {
        case 'success':
            return 'success'
        case 'failure':
        case 'startup_failure':
            return 'failure'
        case 'cancelled':
        case 'stale':
            return 'cancelled'
        case 'timed_out':
            return 'timed_out'
        case 'skipped':
            return 'skipped'
        case 'action_required':
            return 'action_required'
        default:
            return 'neutral'
    }
}

function serializeAction(action: TrackedRun) {
    return {
        key: action.key,
        repo: action.repo,
        runId: action.runId,
        name: action.name,
        branch: action.branch,
        event: action.event,
        status: action.status,
        conclusion: action.conclusion,
        state: actionState(action),
        actor: action.actor,
        isMine: !!action.actor && action.actor.toLowerCase() === (getAccount()?.login || '').toLowerCase(),
        startedAt: action.startedAt,
        startedAtMs: new Date(action.startedAt).getTime(),
        completedAtMs: action.completedAtMs,
        durationMs: action.durationMs,
        expectedDurationMs: action.expectedDurationMs,
        currentJob: action.currentJob,
        currentStep: action.currentStep,
        jobsTotal: action.jobsTotal,
        jobsCompleted: action.jobsCompleted,
        url: action.url,
        lingerMs: COMPLETED_LINGER_MS,
    }
}

function visibleActions(): TrackedRun[] {
    return Array.from(runningActions.values()).sort(
        (a, b) => new Date(b.startedAt).getTime() - new Date(a.startedAt).getTime(),
    )
}

function broadcastActions() {
    const payload = visibleActions().map(serializeAction)

    if (popupWindow && !popupWindow.isDestroyed()) {
        popupWindow.webContents.send('actions-update', payload)
    }
    if (mainWindow && !mainWindow.isDestroyed()) {
        mainWindow.webContents.send('actions-update', payload)
    }

    if (payload.length > 0) {
        showPopupWindow()
    }
    // Hiding is driven by the renderer once the leave animation has finished,
    // so the cards get to animate out instead of blinking away.
}

function forgetJobCache(key: string) {
    for (const cacheKey of Array.from(lastJobDetailsFetch.keys())) {
        if (cacheKey.startsWith(key)) {
            lastJobDetailsFetch.delete(cacheKey)
        }
    }
}

function dismissAction(key: string) {
    if (!runningActions.has(key) && !dismissedKeys.has(key)) {
        return
    }

    // Remember the dismissal so an action that is still running does not pop
    // straight back in on the next poll. A new run gets a new key, so the next
    // one still shows up.
    dismissedKeys.set(key, Date.now())
    runningActions.delete(key)
    forgetJobCache(key)
    broadcastActions()
}

function pruneDismissedKeys() {
    const now = Date.now()
    for (const [key, at] of Array.from(dismissedKeys.entries())) {
        if (now - at > DISMISSED_MEMORY_MS) {
            dismissedKeys.delete(key)
        }
    }
}

// Completed runs stick around for COMPLETED_LINGER_MS so the result is actually
// readable, then leave on their own.
function pruneCompletedActions(): boolean {
    const now = Date.now()
    let changed = false

    for (const [key, action] of Array.from(runningActions.entries())) {
        if (action.status === 'completed' && action.completedAtMs && now - action.completedAtMs >= COMPLETED_LINGER_MS) {
            runningActions.delete(key)
            forgetJobCache(key)
            changed = true
        }
    }

    return changed
}

// ---------------------------------------------------------------------------
// Stored settings
// ---------------------------------------------------------------------------

/**
 * The token lives in the OS keychain when that is available, and only falls
 * back to plain config.json when it is not. A token written by an older build
 * is migrated on first read.
 */
function getStoredToken(): string | undefined {
    const encrypted = store.get('githubTokenEncrypted') as string | undefined

    if (encrypted) {
        try {
            return safeStorage.decryptString(Buffer.from(encrypted, 'base64'))
        } catch (error) {
            console.error('[progressy] could not decrypt the stored token:', error)
            return undefined
        }
    }

    const plain = store.get('githubToken') as string | undefined

    if (plain && safeStorage.isEncryptionAvailable()) {
        setStoredToken(plain) // migrate it into the keychain
        return plain
    }

    return plain || undefined
}

function setStoredToken(token: string | null) {
    if (!token) {
        store.delete('githubToken')
        store.delete('githubTokenEncrypted')
        return
    }

    if (safeStorage.isEncryptionAvailable()) {
        store.set('githubTokenEncrypted', safeStorage.encryptString(token).toString('base64'))
        store.delete('githubToken')
        return
    }

    store.set('githubToken', token)
}

function getClientId(): string {
    return ((store.get('githubClientId') as string) || BUILT_IN_CLIENT_ID).trim()
}

function getAccount(): Account | null {
    return (store.get('account') as Account | undefined) || null
}

function getWatchedRepos(): string[] {
    const watched = store.get('watchedRepos') as string[] | undefined
    return Array.isArray(watched) ? watched : []
}

function getActorFilter(): ActorFilter {
    const stored = store.get('actorFilter') as ActorFilter | undefined

    if (!stored || (stored.mode !== 'all' && stored.mode !== 'me' && stored.mode !== 'only')) {
        return { mode: 'all', logins: [] }
    }

    return { mode: stored.mode, logins: Array.isArray(stored.logins) ? stored.logins : [] }
}

/** Everything the settings screen needs, in one round trip. */
function getSettings() {
    return {
        watchedRepos: getWatchedRepos(),
        actorFilter: getActorFilter(),
        account: getAccount(),
        hasClientId: !!getClientId(),
        autoRepoCount: REPOS_TO_SCAN,
    }
}

function whoTriggered(run: any): string | null {
    return run?.triggering_actor?.login || run?.actor?.login || null
}

/**
 * Filtering happens when a run is first picked up. A run already on screen is
 * never yanked away because the filter changed under it.
 */
function passesActorFilter(run: any): boolean {
    const filter = getActorFilter()

    if (filter.mode === 'all') {
        return true
    }

    const actor = whoTriggered(run)
    if (!actor) {
        return false
    }

    if (filter.mode === 'me') {
        const me = getAccount()?.login
        return me ? actor.toLowerCase() === me.toLowerCase() : true
    }

    return filter.logins.some((login) => login.toLowerCase() === actor.toLowerCase())
}

// ---------------------------------------------------------------------------
// Repositories
// ---------------------------------------------------------------------------

interface RepoSummary {
    fullName: string
    owner: string
    name: string
    private: boolean
    fork: boolean
    updatedAt: string
}

let repoCache: { fetchedAt: number; repos: RepoSummary[] } | null = null

async function listUserRepos(force = false): Promise<RepoSummary[]> {
    if (!octokit) {
        return []
    }

    if (!force && repoCache && Date.now() - repoCache.fetchedAt < REPO_LIST_CACHE_MS) {
        return repoCache.repos
    }

    try {
        const repos = await octokit.paginate(octokit.repos.listForAuthenticatedUser, {
            per_page: 100,
            sort: 'updated',
            direction: 'desc',
        })

        const summaries: RepoSummary[] = repos.map((repo) => ({
            fullName: repo.full_name,
            owner: repo.owner.login,
            name: repo.name,
            private: !!repo.private,
            fork: !!repo.fork,
            updatedAt: repo.updated_at || '',
        }))

        repoCache = { fetchedAt: Date.now(), repos: summaries }
        return summaries
    } catch (error) {
        console.error('Error listing repositories:', error)
        return repoCache?.repos || []
    }
}

/** The repos this poll should look at: whatever is ticked, or the recent ones. */
async function reposToScan(): Promise<RepoSummary[]> {
    const watched = getWatchedRepos()

    if (watched.length === 0) {
        return (await listUserRepos()).slice(0, REPOS_TO_SCAN)
    }

    const known = new Map((await listUserRepos()).map((repo) => [repo.fullName, repo]))

    return watched.map((fullName) => {
        const repo = known.get(fullName)
        if (repo) {
            return repo
        }

        const [owner, name] = fullName.split('/')
        return { fullName, owner, name, private: true, fork: false, updatedAt: '' }
    })
}

/**
 * Runs for one repo, using a conditional request. GitHub does not charge rate
 * limit for a 304, so a repo where nothing happened is free to watch - which is
 * what makes it reasonable to tick more than a handful of them.
 */
async function fetchRepoRuns(repo: RepoSummary): Promise<any[]> {
    if (!octokit) {
        return []
    }

    const cached = runsCache.get(repo.fullName)

    try {
        const response = await octokit.request('GET /repos/{owner}/{repo}/actions/runs', {
            owner: repo.owner,
            repo: repo.name,
            per_page: RUNS_PER_REPO,
            headers: cached?.etag ? { 'if-none-match': cached.etag } : {},
        })

        const runs = response.data.workflow_runs || []
        runsCache.set(repo.fullName, { etag: response.headers.etag || null, runs })
        return runs
    } catch (error: any) {
        if (error?.status === 304) {
            conditionalHits += 1
            return cached?.runs || []
        }

        if (error?.status === 404) {
            return [] // repo went away, or the token lost access to it
        }

        console.error(`Error fetching workflows for ${repo.fullName}:`, error?.message || error)
        return cached?.runs || []
    }
}

// ---------------------------------------------------------------------------
// GitHub polling
// ---------------------------------------------------------------------------

function createTrackedRun(key: string, repoFullName: string, run: any): TrackedRun {
    const [owner, repoName] = repoFullName.split('/')

    return {
        key,
        repo: repoFullName,
        owner,
        repoName,
        runId: run.id,
        workflowId: run.workflow_id ?? null,
        name: run.name || run.display_title || 'Workflow run',
        branch: run.head_branch || null,
        event: run.event || null,
        status: normalizeStatus(run.status),
        conclusion: run.conclusion ?? null,
        actor: whoTriggered(run),
        startedAt: run.run_started_at || run.created_at,
        completedAtMs: null,
        durationMs: null,
        expectedDurationMs: null,
        currentJob: null,
        currentStep: null,
        jobsTotal: 0,
        jobsCompleted: 0,
        url: run.html_url || `https://github.com/${repoFullName}/actions/runs/${run.id}`,
    }
}

function applyRunState(action: TrackedRun, run: any) {
    action.name = run.name || run.display_title || action.name
    action.branch = run.head_branch || action.branch
    action.actor = whoTriggered(run) || action.actor
    action.startedAt = run.run_started_at || run.created_at || action.startedAt

    const status = normalizeStatus(run.status)
    const wasCompleted = action.status === 'completed'
    action.status = status
    action.conclusion = run.conclusion ?? null

    if (status === 'completed' && !wasCompleted) {
        const startedAt = new Date(action.startedAt).getTime()
        const finishedAt = new Date(run.updated_at || Date.now()).getTime()

        action.completedAtMs = Date.now()
        action.durationMs = finishedAt > startedAt ? finishedAt - startedAt : Date.now() - startedAt
        action.currentJob = null
        action.currentStep = null

        if (action.jobsTotal > 0) {
            action.jobsCompleted = action.jobsTotal
        }

        console.log(`[progressy] ${action.repo} ${action.name} finished: ${action.conclusion}`)
    }
}

// Typical wall-clock duration of the last EXPECTED_DURATION_SAMPLES successful
// runs of the same workflow - the yardstick the progress bar uses. The median
// rather than the mean, because a single freak run (a cold cache, a stuck
// runner) would otherwise drag the estimate off for the next half hour.
async function getExpectedDurationMs(action: TrackedRun): Promise<number | null> {
    if (!octokit || !action.workflowId) {
        return action.expectedDurationMs
    }

    const cacheKey = `${action.repo}#${action.workflowId}`
    const cached = expectedDurationCache.get(cacheKey)

    if (cached && Date.now() - cached.fetchedAt < EXPECTED_DURATION_CACHE_MS) {
        return cached.value
    }

    try {
        const { data } = await octokit.actions.listWorkflowRuns({
            owner: action.owner,
            repo: action.repoName,
            workflow_id: action.workflowId,
            status: 'success',
            per_page: EXPECTED_DURATION_SAMPLES,
        })

        const durations = data.workflow_runs
            .map((run) => {
                const startedAt = new Date(run.run_started_at || run.created_at).getTime()
                const finishedAt = new Date(run.updated_at).getTime()
                return finishedAt - startedAt
            })
            .filter((ms) => Number.isFinite(ms) && ms > 1000 && ms < 6 * 60 * 60 * 1000)

        const value = median(durations)

        expectedDurationCache.set(cacheKey, { value, fetchedAt: Date.now() })

        if (value) {
            console.log(
                `[progressy] expected duration for ${cacheKey}: ${Math.round(value / 1000)}s ` +
                    `(from ${durations.length} run${durations.length === 1 ? '' : 's'})`,
            )
        }

        return value
    } catch (error) {
        console.error(`Error fetching previous runs for ${cacheKey}:`, error)
        expectedDurationCache.set(cacheKey, { value: null, fetchedAt: Date.now() })
        return null
    }
}

async function refreshJobDetails(action: TrackedRun) {
    if (!octokit) {
        return
    }

    try {
        const { data: jobs } = await octokit.actions.listJobsForWorkflowRun({
            owner: action.owner,
            repo: action.repoName,
            run_id: action.runId,
        })

        action.jobsTotal = jobs.jobs.length
        action.jobsCompleted = jobs.jobs.filter((job) => job.status === 'completed').length

        const runningJob = jobs.jobs.find((job) => job.status === 'in_progress' || job.status === 'queued')
        action.currentJob = runningJob?.name || null

        if (!runningJob) {
            action.currentStep = null
            return
        }

        // Step-level detail is a second request per job, so cache it.
        const jobDetailsKey = `${action.key}-${runningJob.id}`
        const lastFetch = lastJobDetailsFetch.get(jobDetailsKey) || 0

        if (Date.now() - lastFetch <= JOB_DETAILS_CACHE_MS) {
            return
        }

        try {
            const { data: jobDetails } = await octokit.actions.getJobForWorkflowRun({
                owner: action.owner,
                repo: action.repoName,
                job_id: runningJob.id,
            })

            const currentStepData = jobDetails.steps?.find(
                (step: any) => step.status === 'in_progress' || step.status === 'queued',
            )

            action.currentStep = currentStepData?.name || null
            lastJobDetailsFetch.set(jobDetailsKey, Date.now())
        } catch (error) {
            console.error(`Error fetching job details for ${runningJob.id}:`, error)
        }
    } catch (error) {
        console.error(`Error fetching jobs for ${action.repo}:`, error)
    }
}

async function checkGitHubActions() {
    if (!octokit) {
        return
    }

    conditionalHits = 0

    try {
        const repos = await reposToScan()

        // key -> { run, repoFullName } for every run we can currently see
        const seenRuns = new Map<string, { run: any; repoFullName: string }>()

        for (const repo of repos) {
            for (const run of await fetchRepoRuns(repo)) {
                seenRuns.set(`${repo.fullName}-${run.id}`, { run, repoFullName: repo.fullName })
            }
        }

        // 1. Pick up runs that have just started.
        for (const [key, { run, repoFullName }] of seenRuns) {
            if (runningActions.has(key) || dismissedKeys.has(key)) {
                continue
            }

            const status = normalizeStatus(run.status)
            if (status === 'completed') {
                continue // only announce runs we can watch from the start
            }

            if (!passesActorFilter(run)) {
                continue
            }

            const action = createTrackedRun(key, repoFullName, run)
            runningActions.set(key, action)
            console.log(`[progressy] ${action.repo} ${action.name} started (by ${action.actor || 'unknown'})`)
        }

        // 2. Refresh everything we are tracking.
        for (const [key, action] of Array.from(runningActions.entries())) {
            const seen = seenRuns.get(key)
            let run = seen?.run

            if (!run && action.status !== 'completed') {
                // The run dropped off the recent list - ask for it directly so
                // we learn its conclusion instead of just losing the card.
                try {
                    const { data } = await octokit.actions.getWorkflowRun({
                        owner: action.owner,
                        repo: action.repoName,
                        run_id: action.runId,
                    })
                    run = data
                } catch (error) {
                    console.error(`Error fetching run ${action.runId} for ${action.repo}:`, error)
                }
            }

            if (run) {
                applyRunState(action, run)
            }

            if (action.status === 'completed') {
                continue // finished runs just count down their linger time
            }

            action.expectedDurationMs = await getExpectedDurationMs(action)
            await refreshJobDetails(action)
        }

        pruneCompletedActions()
        pruneDismissedKeys()
        broadcastActions()

        if (VERBOSE) {
            console.log(
                `[progressy] swept ${repos.length} repo(s) (${conditionalHits} unchanged), ` +
                    `${seenRuns.size} recent run(s), tracking ${runningActions.size}`,
            )
        }
    } catch (error) {
        console.error('Error checking GitHub Actions:', error)
    }
}

function activeRunCount(): number {
    let active = 0

    for (const action of runningActions.values()) {
        if (action.status !== 'completed') {
            active += 1
        }
    }

    return active
}

/**
 * Watching idle repos is free, but every run we are actively following costs a
 * jobs request per sweep - so speed up when something is happening and back off
 * again as more runs pile up.
 */
function nextPollDelay(): number {
    const active = activeRunCount()

    if (active === 0) {
        return POLL_IDLE_MS
    }

    return Math.min(POLL_IDLE_MS, Math.max(POLL_ACTIVE_MS, active * 4000))
}

async function runPollCycle() {
    await checkGitHubActions()

    if (octokit) {
        pollTimer = setTimeout(runPollCycle, nextPollDelay())
    }
}

function startActionMonitoring() {
    stopActionMonitoring()

    console.log('[progressy] monitoring started')

    // Cheap local ticker that retires finished cards once their linger is up.
    lingerInterval = setInterval(() => {
        if (pruneCompletedActions()) {
            broadcastActions()
        }
    }, 500)

    runPollCycle()
}

function stopActionMonitoring() {
    if (pollTimer) {
        clearTimeout(pollTimer)
        pollTimer = null
    }
    if (lingerInterval) {
        clearInterval(lingerInterval)
        lingerInterval = null
    }
}

// ---------------------------------------------------------------------------
// Demo mode: PROGRESSY_DEMO=1 fakes a couple of runs so the popup can be
// checked without waiting for real CI.
// ---------------------------------------------------------------------------

function startDemoMode() {
    const now = Date.now()

    const demoRun = (overrides: Partial<TrackedRun>): TrackedRun => ({
        key: 'demo',
        repo: 'sietzekeuning/vvw-site',
        owner: 'sietzekeuning',
        repoName: 'vvw-site',
        runId: 1,
        workflowId: 1,
        name: 'CI/CD',
        branch: 'main',
        event: 'push',
        status: 'in_progress',
        conclusion: null,
        actor: getAccount()?.login || 'octocat',
        startedAt: new Date(now).toISOString(),
        completedAtMs: null,
        durationMs: null,
        expectedDurationMs: 90000,
        currentJob: 'test-and-deploy',
        currentStep: 'Run actions/checkout@v4',
        jobsTotal: 3,
        jobsCompleted: 1,
        url: 'https://github.com/sietzekeuning/vvw-site/actions/runs/32376222808',
        ...overrides,
    })

    const at = (ms: number, fn: () => void) => setTimeout(fn, ms)

    at(1000, () => {
        runningActions.set('demo-a', demoRun({ key: 'demo-a', status: 'queued', currentJob: null, currentStep: null }))
        broadcastActions()
    })

    at(3000, () => {
        const action = runningActions.get('demo-a')
        if (action) {
            action.status = 'in_progress'
        }
        broadcastActions()
    })

    at(6000, () => {
        runningActions.set(
            'demo-b',
            demoRun({
                key: 'demo-b',
                repo: 'sietzekeuning/marmaya',
                repoName: 'marmaya',
                name: 'Deploy to production',
                branch: 'release/2026-08',
                actor: 'octocat',
                currentJob: 'build-and-push-image',
                currentStep: 'Build and push Docker image to the registry',
                expectedDurationMs: null,
                jobsTotal: 5,
                jobsCompleted: 2,
                startedAt: new Date(now - 45000).toISOString(),
            }),
        )
        broadcastActions()
    })

    at(16000, () => {
        runningActions.set(
            'demo-c',
            demoRun({
                key: 'demo-c',
                repo: 'sietzekeuning/pos',
                repoName: 'pos',
                name: 'production',
                branch: 'master',
                currentJob: 'deploy',
                currentStep: 'Run php artisan migrate --force',
                expectedDurationMs: 352000,
                jobsTotal: 4,
                jobsCompleted: 3,
                startedAt: new Date(now - 210000).toISOString(),
            }),
        )
        broadcastActions()
    })

    at(12000, () => {
        const action = runningActions.get('demo-a')
        if (action) {
            action.status = 'completed'
            action.conclusion = 'success'
            action.completedAtMs = Date.now()
            action.durationMs = Date.now() - new Date(action.startedAt).getTime()
            action.currentJob = null
            action.currentStep = null
            action.jobsCompleted = action.jobsTotal
        }
        broadcastActions()
    })

    at(18000, () => {
        const action = runningActions.get('demo-b')
        if (action) {
            action.status = 'completed'
            action.conclusion = 'failure'
            action.completedAtMs = Date.now()
            action.durationMs = Date.now() - new Date(action.startedAt).getTime()
            action.currentJob = null
            action.currentStep = null
        }
        broadcastActions()
    })

    lingerInterval = setInterval(() => {
        if (pruneCompletedActions()) {
            broadcastActions()
        }
    }, 500)
}

// ---------------------------------------------------------------------------
// Signing in
// ---------------------------------------------------------------------------

function sendToMainWindow(channel: string, payload?: unknown) {
    if (mainWindow && !mainWindow.isDestroyed()) {
        mainWindow.webContents.send(channel, payload)
    }
}

/** Validate a token, remember it, and start watching. */
async function applyToken(token: string): Promise<Account> {
    const account = await validateToken(token)

    setStoredToken(token)
    store.set('account', account)
    octokit = new Octokit({ auth: token })
    repoCache = null
    runsCache.clear()
    startActionMonitoring()
    updateTrayMenu()

    console.log(`[progressy] signed in as ${account.login}`)
    return account
}

function signOut() {
    setStoredToken(null)
    store.delete('account')
    octokit = null
    repoCache = null
    runsCache.clear()
    runningActions.clear()
    dismissedKeys.clear()
    stopActionMonitoring()
    hidePopupWindow()
    updateTrayMenu()
    broadcastActions()
}

let deviceSession: { cancelled: boolean } | null = null

function cancelDeviceLogin() {
    if (deviceSession) {
        deviceSession.cancelled = true
        deviceSession = null
    }
}

async function startDeviceLogin(): Promise<DeviceCode> {
    const clientId = getClientId()

    if (!clientId) {
        throw new AuthError('No OAuth App client id is configured for this build.', 'no_client_id')
    }

    cancelDeviceLogin()

    const device = await requestDeviceCode(clientId)
    const session = { cancelled: false }
    deviceSession = session

    // Runs in the background; the renderer shows the code meanwhile.
    pollForDeviceToken(clientId, device, () => !session.cancelled && deviceSession === session)
        .then(async (token) => {
            const account = await applyToken(token)
            sendToMainWindow('login-complete', account)
        })
        .catch((error: AuthError) => {
            if (error?.code !== 'cancelled') {
                sendToMainWindow('login-error', error?.message || 'Sign-in failed.')
            }
        })
        .finally(() => {
            if (deviceSession === session) {
                deviceSession = null
            }
        })

    return device
}

// While the login screen is open we keep an eye on the clipboard: the moment a
// GitHub token is copied, the renderer can use it without the user having to
// find the paste field.
let clipboardTimer: NodeJS.Timeout | null = null
let lastClipboardText = ''

function startClipboardWatch() {
    stopClipboardWatch()
    lastClipboardText = ''

    clipboardTimer = setInterval(() => {
        let text = ''
        try {
            text = clipboard.readText()
        } catch {
            return
        }

        if (text === lastClipboardText) {
            return
        }

        lastClipboardText = text

        if (looksLikeToken(text)) {
            sendToMainWindow('clipboard-token', text.trim())
        }
    }, 700)
}

function stopClipboardWatch() {
    if (clipboardTimer) {
        clearInterval(clipboardTimer)
        clipboardTimer = null
    }
}

// ---------------------------------------------------------------------------
// App lifecycle
// ---------------------------------------------------------------------------

app.whenReady().then(() => {
    // Set dock icon on macOS using icons.icns (optional, since dock is hidden)
    if (process.platform === 'darwin') {
        const appPath = app.getAppPath()
        const fs = require('fs')
        const dockIconPaths = [
            // Try .icns first
            path.join(process.resourcesPath || appPath, 'assets/icons.icns'),
            path.join(process.resourcesPath || appPath, 'src/assets/icons.icns'),
            path.join(appPath, 'src/assets/icons.icns'),
            path.join(__dirname, '../../src/assets/icons.icns'),
            path.join(__dirname, '../assets/icons.icns'),
            // Fallback to PNG if .icns fails
            path.join(process.resourcesPath || appPath, 'assets/icon.png'),
            path.join(process.resourcesPath || appPath, 'src/assets/icon.png'),
            path.join(appPath, 'src/assets/icon.png'),
            path.join(__dirname, '../../src/assets/icon.png'),
            path.join(__dirname, '../assets/icon.png'),
        ]

        for (const iconPath of dockIconPaths) {
            if (fs.existsSync(iconPath)) {
                try {
                    app.dock.setIcon(iconPath)
                    break
                } catch (error) {
                    // Silently continue - dock icon is not critical since dock is hidden
                    continue
                }
            }
        }

        // Hide dock icon initially (show only menu bar icon)
        app.dock.hide()
    }

    createTray()

    initAutoUpdate((state) => {
        updateTrayMenu()
        sendToMainWindow('update-state', state)
    })

    if (process.env.PROGRESSY_DEMO === '1') {
        console.log('[progressy] demo mode')
        startDemoMode()
        return
    }

    const token = getStoredToken()
    if (token) {
        octokit = new Octokit({ auth: token })
        startActionMonitoring()

        // A token stored by an older build has no account attached, and we need
        // the login to make "only my runs" mean anything. It also tells us
        // early when a token has been revoked.
        validateToken(token)
            .then((account) => {
                store.set('account', account)
                sendToMainWindow('account-update', account)
            })
            .catch((error: AuthError) => {
                if (error?.code === 'bad_credentials') {
                    console.log('[progressy] the stored token is no longer valid - signing out')
                    signOut()
                    createMainWindow()
                } else {
                    console.error('[progressy] could not verify the stored token:', error?.message || error)
                }
            })
    } else {
        console.log('[progressy] not signed in yet - opening the window')
        createMainWindow()
    }
})

app.on('window-all-closed', () => {
    // Don't quit when windows are closed, keep running in tray
})

app.on('before-quit', () => {
    stopActionMonitoring()
    stopAutoUpdate()
    stopPointerWatchdog()
    stopClipboardWatch()
    cancelDeviceLogin()

    if (popupWindow && !popupWindow.isDestroyed()) {
        popupWindow.destroy()
        popupWindow = null
    }
})

// ---------------------------------------------------------------------------
// Renderer API
// ---------------------------------------------------------------------------

ipcMain.handle('get-auth-state', () => ({
    signedIn: !!getStoredToken(),
    account: getAccount(),
    hasClientId: !!getClientId(),
    tokenUrl: tokenCreationUrl(os.hostname().replace(/\.local$/, '')),
}))

ipcMain.handle('submit-token', async (_event, token: string) => {
    const account = await applyToken(String(token || '').trim())
    return account
})

ipcMain.handle('start-device-login', async () => startDeviceLogin())

ipcMain.handle('cancel-device-login', () => {
    cancelDeviceLogin()
    return true
})

ipcMain.handle('watch-clipboard', (_event, watch: boolean) => {
    if (watch) {
        startClipboardWatch()
    } else {
        stopClipboardWatch()
    }
    return true
})

ipcMain.handle('sign-out', () => {
    signOut()
    return true
})

// Only ever opens GitHub, so a compromised renderer cannot use us as a
// general-purpose URL opener.
ipcMain.handle('open-github-url', (_event, url: string) => {
    if (typeof url === 'string' && /^https:\/\/github\.com\//.test(url)) {
        shell.openExternal(url)
        return true
    }
    return false
})

ipcMain.handle('get-settings', () => getSettings())

ipcMain.handle('list-repos', async (_event, force: boolean) => listUserRepos(!!force))

ipcMain.handle('set-watched-repos', (_event, repos: string[]) => {
    const cleaned = Array.isArray(repos) ? repos.filter((repo) => typeof repo === 'string' && repo.includes('/')) : []
    store.set('watchedRepos', cleaned)
    runsCache.clear() // different repo set, different conditional requests
    checkGitHubActions()
    return getSettings()
})

ipcMain.handle('set-actor-filter', (_event, filter: ActorFilter) => {
    const mode = filter?.mode === 'me' || filter?.mode === 'only' ? filter.mode : 'all'
    const logins = Array.isArray(filter?.logins)
        ? filter.logins.map((login) => String(login).trim()).filter(Boolean)
        : []

    store.set('actorFilter', { mode, logins })
    return getSettings()
})

ipcMain.handle('get-running-actions', () => {
    return visibleActions().map(serializeAction)
})

ipcMain.handle('dismiss-action', (_event, key: string) => {
    dismissAction(key)
    return true
})

ipcMain.handle('dismiss-all', () => {
    for (const key of Array.from(runningActions.keys())) {
        dismissedKeys.set(key, Date.now())
        runningActions.delete(key)
        forgetJobCache(key)
    }
    broadcastActions()
    return true
})

// The renderer tells us when the stack is empty *and* done animating out.
ipcMain.handle('popup-empty', () => {
    if (runningActions.size === 0) {
        hidePopupWindow()
    }
    return true
})

ipcMain.handle('set-pointer-interactive', (_event, interactive: boolean) => {
    setPopupInteractive(!!interactive)
    return true
})

ipcMain.handle('resize-window', (_event, width: number, height: number) => {
    if (!mainWindow || mainWindow.isDestroyed()) {
        return false
    }

    // setContentSize, not setSize: the renderer measured content, not chrome.
    mainWindow.setContentSize(Math.round(width), Math.round(height))
    return true
})

ipcMain.handle('get-update-state', () => getUpdateState())

ipcMain.handle('check-for-updates', () => {
    checkForUpdates()
    return getUpdateState()
})

ipcMain.handle('install-update', () => installUpdate())
