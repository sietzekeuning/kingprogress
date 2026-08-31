<template>
    <div class="settings">
        <!-- Account -->
        <section class="account" v-if="settings?.account">
            <img v-if="settings.account.avatarUrl" class="avatar" :src="settings.account.avatarUrl" alt="" />
            <div class="who">
                <span class="login">{{ settings.account.login }}</span>
                <span class="scopes">{{ scopeLabel }}</span>
            </div>
            <button class="ghost" @click="signOut">Sign out</button>
        </section>

        <!-- Who triggered it -->
        <section>
            <h2>Triggered by</h2>
            <div class="segmented">
                <button
                    v-for="option in actorModes"
                    :key="option.value"
                    :class="{ on: actorMode === option.value }"
                    @click="setActorMode(option.value)"
                >
                    {{ option.label }}
                </button>
            </div>

            <div v-if="actorMode === 'only'" class="logins">
                <div class="chips">
                    <span v-for="login in actorLogins" :key="login" class="chip">
                        {{ login }}
                        <button @click="removeLogin(login)" aria-label="Remove">×</button>
                    </span>
                    <span v-if="actorLogins.length === 0" class="chips-empty">No one yet — nothing will show up.</span>
                </div>
                <input
                    v-model="loginDraft"
                    placeholder="GitHub username, then Enter"
                    spellcheck="false"
                    @keyup.enter="addLogin"
                />
            </div>

            <p class="note">{{ actorNote }}</p>
        </section>

        <!-- Repositories -->
        <section>
            <h2>
                Repositories
                <span class="count">{{ watched.size ? `${watched.size} watched` : `auto` }}</span>
            </h2>

            <div class="search">
                <input v-model="query" placeholder="Search repositories" spellcheck="false" />
                <button v-if="watched.size" class="ghost small" @click="clearRepos">Reset</button>
            </div>

            <p v-if="!watched.size" class="note">
                Watching your {{ settings?.autoRepoCount ?? 5 }} most recently updated repositories. Tick any below to
                choose yourself.
            </p>

            <div class="repos">
                <label v-for="repo in filteredRepos" :key="repo.fullName" class="repo">
                    <input type="checkbox" :checked="watched.has(repo.fullName)" @change="toggleRepo(repo.fullName)" />
                    <span class="repo-name">{{ repo.fullName }}</span>
                    <span v-if="repo.private" class="tag">private</span>
                    <span v-else-if="repo.fork" class="tag">fork</span>
                </label>

                <p v-if="loading" class="note">Loading repositories…</p>
                <p v-else-if="filteredRepos.length === 0" class="note">Nothing matches “{{ query }}”.</p>
            </div>
        </section>

        <!-- Startup -->
        <section>
            <h2>Startup</h2>

            <label class="toggle">
                <span class="toggle-label">Open Progressy when I log in</span>
                <input type="checkbox" :checked="openAtLogin" @change="setOpenAtLogin(!openAtLogin)" />
                <span class="switch" :class="{ on: openAtLogin }"></span>
            </label>

            <p class="note">{{ startupNote }}</p>
        </section>

        <!-- Version -->
        <section v-if="update">
            <h2>
                Version
                <span class="count">{{ update.currentVersion }}</span>
            </h2>

            <div class="update">
                <p class="update-line">{{ updateLine }}</p>
                <button v-if="update.status === 'ready'" class="ghost small" @click="installUpdate">Restart now</button>
                <button
                    v-else-if="canCheck"
                    class="ghost small"
                    :disabled="update.status === 'checking'"
                    @click="checkNow"
                >
                    Check now
                </button>
            </div>

            <div v-if="update.status === 'downloading'" class="progress">
                <span :style="{ width: update.percent + '%' }"></span>
            </div>

            <p class="note">{{ updateNote }}</p>
        </section>
    </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'

const settings = ref<any>(null)
const repos = ref<any[]>([])
const watched = ref<Set<string>>(new Set())
const actorMode = ref<'all' | 'me' | 'only'>('all')
const actorLogins = ref<string[]>([])
const openAtLogin = ref(true)
const loginDraft = ref('')
const query = ref('')
const loading = ref(true)
const update = ref<any>(null)

const actorModes = [
    { value: 'all' as const, label: 'Anyone' },
    { value: 'me' as const, label: 'Only me' },
    { value: 'only' as const, label: 'Specific people' },
]

const scopeLabel = computed(() => {
    const scopes: string[] = settings.value?.account?.scopes || []
    if (scopes.length === 0) {
        return 'fine-grained token'
    }
    const missing = ['repo', 'workflow'].filter((scope) => !scopes.includes(scope))
    return missing.length ? `missing scope: ${missing.join(', ')}` : 'repo, workflow'
})

const actorNote = computed(() => {
    if (actorMode.value === 'all') {
        return 'Every run in the repositories below shows up.'
    }
    if (actorMode.value === 'me') {
        return `Only runs triggered by ${settings.value?.account?.login || 'you'}.`
    }
    return 'Only runs triggered by the people listed above.'
})

const startupNote = computed(() =>
    openAtLogin.value
        ? 'Progressy comes back in the menu bar after a restart, without a window in the way.'
        : 'You start Progressy yourself. Runs you miss while it is closed stay missed.'
)

const updateLine = computed(() => {
    const state = update.value
    if (!state) return ''
    switch (state.status) {
        case 'checking':
            return 'Checking for a newer version…'
        case 'downloading':
            return `Downloading ${state.newVersion}…`
        case 'ready':
            return `Progressy ${state.newVersion} is ready to install.`
        case 'error':
            return 'Could not check for updates.'
        case 'unsupported':
            return state.message || 'This build does not update itself.'
        default:
            return 'Progressy is up to date.'
    }
})

const updateNote = computed(() => {
    const state = update.value
    if (!state) return ''
    if (state.status === 'unsupported') {
        return 'Progressy still tells you when there is something newer — it just cannot install it here.'
    }
    if (state.status === 'ready') {
        return 'It installs on the next restart, whether you do it now or quit later.'
    }
    if (state.status === 'error') {
        return `${state.message || 'Progressy could not reach GitHub.'} It tries again in a few hours.`
    }
    if (state.status === 'idle' && state.checkedAt) {
        return `Checked at ${new Date(state.checkedAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}. Progressy checks a few times a day and installs new versions on restart.`
    }
    return 'Progressy checks GitHub a few times a day and installs new versions on restart.'
})

const canCheck = computed(() => update.value && update.value.status !== 'unsupported')

const filteredRepos = computed(() => {
    const needle = query.value.trim().toLowerCase()
    const list = needle ? repos.value.filter((repo) => repo.fullName.toLowerCase().includes(needle)) : repos.value

    // Watched repos float to the top so a long list stays manageable.
    return [...list].sort((a, b) => {
        const aOn = watched.value.has(a.fullName) ? 0 : 1
        const bOn = watched.value.has(b.fullName) ? 0 : 1
        return aOn - bOn
    })
})

function applySettings(next: any) {
    settings.value = next
    watched.value = new Set(next.watchedRepos)
    actorMode.value = next.actorFilter.mode
    actorLogins.value = [...next.actorFilter.logins]
    openAtLogin.value = next.openAtLogin
}

async function setOpenAtLogin(enabled: boolean) {
    // Optimistic, so the switch moves under the finger; applySettings puts it
    // back if the OS refused the change.
    openAtLogin.value = enabled

    try {
        applySettings(await window.electronAPI.setOpenAtLogin(enabled))
    } catch (error) {
        console.error('Could not change the start-at-login setting:', error)
        openAtLogin.value = !enabled
    }
}

async function saveRepos() {
    try {
        applySettings(await window.electronAPI.setWatchedRepos([...watched.value]))
    } catch (error) {
        console.error('Could not save the repository selection:', error)
    }
}

function toggleRepo(fullName: string) {
    const next = new Set(watched.value)
    next.has(fullName) ? next.delete(fullName) : next.add(fullName)
    watched.value = next
    saveRepos()
}

function clearRepos() {
    watched.value = new Set()
    saveRepos()
}

async function saveActorFilter() {
    try {
        // Spread, don't pass the ref's array: a Vue reactive proxy cannot be
        // structured-cloned over IPC and the call would reject silently.
        applySettings(
            await window.electronAPI.setActorFilter({ mode: actorMode.value, logins: [...actorLogins.value] }),
        )
    } catch (error) {
        console.error('Could not save the trigger filter:', error)
    }
}

function setActorMode(mode: 'all' | 'me' | 'only') {
    actorMode.value = mode
    saveActorFilter()
}

function addLogin() {
    const value = loginDraft.value.trim().replace(/^@/, '')
    if (value && !actorLogins.value.includes(value)) {
        actorLogins.value = [...actorLogins.value, value]
        saveActorFilter()
    }
    loginDraft.value = ''
}

function removeLogin(login: string) {
    actorLogins.value = actorLogins.value.filter((item) => item !== login)
    saveActorFilter()
}

function signOut() {
    window.electronAPI.signOut().then(() => window.location.reload())
}

async function checkNow() {
    update.value = await window.electronAPI.checkForUpdates()
}

function installUpdate() {
    window.electronAPI.installUpdate()
}

onMounted(async () => {
    update.value = await window.electronAPI.getUpdateState()
    window.electronAPI.onUpdateState((state) => {
        update.value = state
    })

    applySettings(await window.electronAPI.getSettings())
    repos.value = await window.electronAPI.listRepos()
    loading.value = false
})
</script>

<style scoped>
.settings {
    padding: 4px 14px 16px;
}

section {
    padding: 12px 0;
    border-bottom: 1px solid #1c2129;
}

section:last-child {
    border-bottom: none;
}

h2 {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    margin-bottom: 8px;
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: #7d8590;
}

.count {
    font-size: 10.5px;
    font-weight: 500;
    text-transform: none;
    letter-spacing: 0;
    color: #6e7681;
}

.account {
    display: flex;
    align-items: center;
    gap: 10px;
}

.avatar {
    width: 30px;
    height: 30px;
    border-radius: 50%;
    background: #21262d;
}

.who {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
}

.login {
    font-size: 13px;
    font-weight: 600;
    color: #f0f6fc;
}

.scopes {
    font-size: 10.5px;
    color: #7d8590;
}

.ghost {
    padding: 5px 10px;
    border: 1px solid #30363d;
    border-radius: 7px;
    background: transparent;
    color: #c9d1d9;
    font-size: 11px;
    cursor: pointer;
}

.ghost:hover {
    border-color: #8b949e;
    color: #f0f6fc;
}

.ghost.small {
    padding: 4px 8px;
    font-size: 10.5px;
}

.segmented {
    display: flex;
    gap: 3px;
    padding: 3px;
    border-radius: 9px;
    background: #161b22;
    border: 1px solid #21262d;
}

.segmented button {
    flex: 1;
    padding: 5px 6px;
    border: none;
    border-radius: 6px;
    background: transparent;
    color: #8b949e;
    font-size: 11px;
    cursor: pointer;
    transition:
        background 0.15s ease,
        color 0.15s ease;
}

.segmented button.on {
    background: #2b3440;
    color: #f0f6fc;
}

.logins {
    margin-top: 8px;
}

.chips {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
    margin-bottom: 6px;
}

.chip {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 2px 4px 2px 7px;
    border-radius: 999px;
    background: #21262d;
    color: #c9d1d9;
    font-size: 10.5px;
}

.chip button {
    border: none;
    background: none;
    color: #8b949e;
    cursor: pointer;
    font-size: 12px;
    line-height: 1;
    padding: 0 2px;
}

.chips-empty {
    font-size: 10.5px;
    color: #6e7681;
}

.search {
    display: flex;
    gap: 6px;
    margin-bottom: 8px;
}

input[type='text'],
.search input,
.logins input {
    width: 100%;
    padding: 6px 9px;
    border: 1px solid #30363d;
    border-radius: 7px;
    background: #0d1117;
    color: #c9d1d9;
    font-size: 11.5px;
}

.search input:focus,
.logins input:focus {
    outline: none;
    border-color: #58a6ff;
}

.repos {
    max-height: 260px;
    overflow-y: auto;
    margin: 0 -6px;
}

.repo {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 5px 6px;
    border-radius: 6px;
    cursor: pointer;
}

.repo:hover {
    background: #161b22;
}

.repo input {
    accent-color: #2f81f7;
    cursor: pointer;
}

.repo-name {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: 11.5px;
    color: #c9d1d9;
}

.tag {
    flex: none;
    padding: 1px 5px;
    border-radius: 5px;
    background: #21262d;
    color: #7d8590;
    font-size: 9.5px;
}

.toggle {
    display: flex;
    align-items: center;
    gap: 10px;
    cursor: pointer;
}

.toggle-label {
    flex: 1;
    min-width: 0;
    font-size: 11.5px;
    color: #c9d1d9;
}

.toggle input {
    position: absolute;
    opacity: 0;
    pointer-events: none;
}

.switch {
    flex: none;
    position: relative;
    width: 30px;
    height: 17px;
    border-radius: 999px;
    background: #21262d;
    border: 1px solid #30363d;
    transition:
        background 0.15s ease,
        border-color 0.15s ease;
}

.switch::after {
    content: '';
    position: absolute;
    top: 2px;
    left: 2px;
    width: 11px;
    height: 11px;
    border-radius: 50%;
    background: #8b949e;
    transition:
        transform 0.15s ease,
        background 0.15s ease;
}

/* Driven by the bound class, not the input's own :checked state: a failed save
   puts the value back to what it already was, which Vue sees as no change and
   would leave the native checkbox flipped the wrong way. */
.switch.on {
    background: #2f81f7;
    border-color: #2f81f7;
}

.switch.on::after {
    transform: translateX(13px);
    background: #ffffff;
}

.toggle input:focus-visible + .switch {
    outline: 1px solid #58a6ff;
    outline-offset: 1px;
}

.update {
    display: flex;
    align-items: center;
    gap: 10px;
}

.update-line {
    flex: 1;
    min-width: 0;
    font-size: 11.5px;
    color: #c9d1d9;
}

.ghost:disabled {
    opacity: 0.5;
    cursor: default;
}

.progress {
    margin-top: 8px;
    height: 3px;
    border-radius: 999px;
    background: #21262d;
    overflow: hidden;
}

.progress span {
    display: block;
    height: 100%;
    border-radius: 999px;
    background: #2f81f7;
    transition: width 0.2s ease;
}

.note {
    margin-top: 6px;
    font-size: 10.5px;
    line-height: 1.5;
    color: #6e7681;
}
</style>
