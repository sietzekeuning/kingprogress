<template>
    <div class="main">
        <header class="bar">
            <span class="brand"><BrandIcon width="18" height="18" />KingProgress</span>
            <span class="count">{{ countLabel }}</span>
            <button v-if="actions.length && !showSettings" class="icon" title="Clear all" @click="clearAll">
                <svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true">
                    <path
                        fill="currentColor"
                        d="M6.5 1.75a.25.25 0 0 1 .25-.25h2.5a.25.25 0 0 1 .25.25V3h-3V1.75Zm4.5 0V3h2.25a.75.75 0 0 1 0 1.5H13v8.75A1.75 1.75 0 0 1 11.25 15h-6.5A1.75 1.75 0 0 1 3 13.25V4.5h-.25a.75.75 0 0 1 0-1.5H5V1.75C5 .784 5.784 0 6.75 0h2.5C10.216 0 11 .784 11 1.75ZM4.5 4.5v8.75c0 .138.112.25.25.25h6.5a.25.25 0 0 0 .25-.25V4.5h-7Z"
                    />
                </svg>
            </button>
            <button class="icon" :class="{ on: showSettings }" title="Settings" @click="toggleSettings">
                <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
                    <path
                        fill="currentColor"
                        d="M8 0a8.2 8.2 0 0 1 1.4.13.75.75 0 0 1 .6.6l.21 1.2c.29.12.57.27.83.44l1.14-.42a.75.75 0 0 1 .82.22c.37.43.68.92.92 1.44a.75.75 0 0 1-.14.84l-.83.88a5.7 5.7 0 0 1 0 .96l.83.88c.22.23.28.57.14.84-.24.52-.55 1.01-.92 1.44a.75.75 0 0 1-.82.22l-1.14-.42c-.26.17-.54.32-.83.44l-.21 1.2a.75.75 0 0 1-.6.6 8.2 8.2 0 0 1-2.8 0 .75.75 0 0 1-.6-.6l-.21-1.2a5.5 5.5 0 0 1-.83-.44l-1.14.42a.75.75 0 0 1-.82-.22 7.4 7.4 0 0 1-.92-1.44.75.75 0 0 1 .14-.84l.83-.88a5.7 5.7 0 0 1 0-.96l-.83-.88a.75.75 0 0 1-.14-.84c.24-.52.55-1.01.92-1.44a.75.75 0 0 1 .82-.22l1.14.42c.26-.17.54-.32.83-.44l.21-1.2a.75.75 0 0 1 .6-.6A8.2 8.2 0 0 1 8 0Zm0 5a3 3 0 1 0 0 6 3 3 0 0 0 0-6Zm0 1.5a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3Z"
                    />
                </svg>
            </button>
        </header>

        <div class="list">
            <div ref="stackEl" class="stack">
                <SettingsView v-if="showSettings" />

                <template v-else>
                    <div v-if="actions.length === 0" class="empty">
                        <p>Nothing running</p>
                        <small>Workflow runs show up here the moment they start</small>
                    </div>

                    <TransitionGroup v-else name="card" tag="div" class="cards" appear>
                        <div v-for="action in actions" :key="action.key" class="item">
                            <div class="item-inner">
                                <ActionCard :action="action" :now="now" @dismiss="dismiss" @open="openRun" />
                            </div>
                        </div>
                    </TransitionGroup>
                </template>
            </div>
        </div>
    </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted, nextTick } from 'vue'
import ActionCard from '../components/ActionCard.vue'
import BrandIcon from '../components/BrandIcon.vue'
import SettingsView from './SettingsView.vue'

const WINDOW_WIDTH = 440
const BAR_HEIGHT = 38
const MIN_HEIGHT = 150
const MAX_HEIGHT = 820

const actions = ref<any[]>([])
const now = ref(Date.now())
const stackEl = ref<HTMLElement | null>(null)
const showSettings = ref(false)

let clockInterval: ReturnType<typeof setInterval> | null = null
let resizeObserver: ResizeObserver | null = null

const countLabel = computed(() => {
    if (showSettings.value) {
        return 'settings'
    }
    if (actions.value.length === 0) {
        return 'idle'
    }
    const running = actions.value.filter((action) => action.state === 'running' || action.state === 'queued').length
    return running ? `${running} running` : `${actions.value.length} finished`
})

// Measure the real content instead of guessing per-card heights, so the window
// hugs whatever is in it.
function fitWindow() {
    nextTick(() => {
        if (!stackEl.value) {
            return
        }
        const content = Math.ceil(stackEl.value.getBoundingClientRect().height)
        const height = Math.max(MIN_HEIGHT, Math.min(BAR_HEIGHT + content + 8, MAX_HEIGHT))
        window.electronAPI.resizeWindow(WINDOW_WIDTH, height)
    })
}

function toggleSettings() {
    showSettings.value = !showSettings.value
    fitWindow()
}

function dismiss(key: string) {
    actions.value = actions.value.filter((action) => action.key !== key)
    window.electronAPI.dismissAction(key)
}

// Clicking a card opens that run on GitHub. The main process only lets
// github.com URLs through, so a card can never send us anywhere else.
function openRun(url: string) {
    window.electronAPI.openGitHubUrl(url)
}

function clearAll() {
    actions.value = []
    window.electronAPI.dismissAll()
}

onMounted(async () => {
    actions.value = await window.electronAPI.getRunningActions()
    fitWindow()

    // Only tick while there is actually something to count.
    clockInterval = setInterval(() => {
        if (actions.value.length) {
            now.value = Date.now()
        }
    }, 500)

    window.electronAPI.onActionsUpdate((data) => {
        actions.value = data
        now.value = Date.now()
        fitWindow()
    })

    if (stackEl.value) {
        resizeObserver = new ResizeObserver(() => fitWindow())
        resizeObserver.observe(stackEl.value)
    }
})

onUnmounted(() => {
    if (clockInterval) {
        clearInterval(clockInterval)
    }
    resizeObserver?.disconnect()
})
</script>

<style scoped>
.main {
    display: flex;
    flex-direction: column;
    height: 100vh;
    background: #0d1117;
}

.bar {
    display: flex;
    align-items: center;
    gap: 8px;
    height: 38px;
    padding: 0 10px 0 78px; /* room for the traffic lights */
    border-bottom: 1px solid #21262d;
    -webkit-app-region: drag;
}

.brand {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    font-size: 12px;
    font-weight: 600;
    color: #e6edf3;
    letter-spacing: -0.01em;
}

.brand svg {
    flex-shrink: 0;
    color: #58a6ff;
}

.count {
    flex: 1;
    text-align: right;
    font-size: 11px;
    color: #7d8590;
}

.icon {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 24px;
    height: 24px;
    padding: 0;
    border: none;
    border-radius: 6px;
    background: transparent;
    color: #7d8590;
    cursor: pointer;
    -webkit-app-region: no-drag;
    transition:
        background 0.15s ease,
        color 0.15s ease;
}

.icon:hover {
    background: #21262d;
    color: #f0f6fc;
}

.icon.on {
    background: #21262d;
    color: #58a6ff;
}

.list {
    flex: 1;
    overflow-y: auto;
}

.stack {
    padding: 6px 0 2px;
}

.empty {
    padding: 34px 20px;
    text-align: center;
    color: #7d8590;
}

.empty p {
    margin: 0 0 4px;
    font-size: 13px;
    color: #adb6c0;
}

.empty small {
    font-size: 11px;
}

.item {
    display: grid;
    grid-template-rows: 1fr;
    transition:
        grid-template-rows 420ms cubic-bezier(0.16, 1, 0.3, 1),
        opacity 260ms ease,
        transform 420ms cubic-bezier(0.16, 1, 0.3, 1);
}

.item-inner {
    min-height: 0;
    overflow: hidden;
    padding: 5px 12px 5px;
}

.card-enter-from,
.card-leave-to {
    grid-template-rows: 0fr;
    opacity: 0;
    transform: translateX(24px) scale(0.97);
}

.card-leave-active {
    transition:
        grid-template-rows 320ms cubic-bezier(0.4, 0, 1, 1) 60ms,
        opacity 220ms ease,
        transform 300ms cubic-bezier(0.4, 0, 1, 1);
}
</style>
