// GitHub authentication.
//
// Two routes, both without a client secret - this repository is public, so a
// secret could never ship with it:
//
//   1. Device flow (like `gh auth login`): needs an OAuth App client id, but no
//      secret. Only available once a client id is configured.
//   2. A personal access token the user pastes. The renderer opens GitHub with
//      the scopes pre-ticked and we pick the token up off the clipboard, so in
//      practice it is "click, click, done" as well.

const DEVICE_CODE_URL = 'https://github.com/login/device/code'
const ACCESS_TOKEN_URL = 'https://github.com/login/oauth/access_token'
const USER_URL = 'https://api.github.com/user'

export const OAUTH_SCOPES = 'repo workflow'

export interface DeviceCode {
    deviceCode: string
    userCode: string
    verificationUri: string
    intervalMs: number
    expiresAt: number
}

export interface Account {
    login: string
    name: string | null
    avatarUrl: string
    scopes: string[]
}

export class AuthError extends Error {
    constructor(
        message: string,
        readonly code: string = 'auth_error',
    ) {
        super(message)
    }
}

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === 'object' && value !== null
}

async function postForm(url: string, body: Record<string, string>): Promise<Record<string, unknown>> {
    const response = await fetch(url, {
        method: 'POST',
        headers: {
            Accept: 'application/json',
            'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: new URLSearchParams(body).toString(),
    })

    const data: unknown = await response.json().catch(() => null)

    if (!isRecord(data)) {
        throw new AuthError(`GitHub returned an unexpected response (${response.status})`, 'bad_response')
    }

    return data
}

/** Step 1 of the device flow: ask GitHub for a code to show the user. */
export async function requestDeviceCode(clientId: string): Promise<DeviceCode> {
    const data = await postForm(DEVICE_CODE_URL, { client_id: clientId, scope: OAUTH_SCOPES })

    if (typeof data.error === 'string') {
        // "Not Found" means the client id does not exist; "device_flow_disabled"
        // means the OAuth App exists but has device flow switched off.
        throw new AuthError(
            data.error === 'device_flow_disabled'
                ? 'This OAuth App does not have device flow enabled.'
                : `GitHub rejected the client id (${data.error}).`,
            String(data.error),
        )
    }

    const deviceCode = data.device_code
    const userCode = data.user_code
    const verificationUri = data.verification_uri

    if (typeof deviceCode !== 'string' || typeof userCode !== 'string' || typeof verificationUri !== 'string') {
        throw new AuthError('GitHub did not return a device code.', 'bad_response')
    }

    const intervalSeconds = typeof data.interval === 'number' ? data.interval : 5
    const expiresInSeconds = typeof data.expires_in === 'number' ? data.expires_in : 900

    return {
        deviceCode,
        userCode,
        verificationUri,
        intervalMs: intervalSeconds * 1000,
        expiresAt: Date.now() + expiresInSeconds * 1000,
    }
}

/**
 * Step 2: poll until the user has approved in the browser. GitHub asks us to
 * back off whenever it answers `slow_down`, so honour that rather than hammering.
 */
export async function pollForDeviceToken(
    clientId: string,
    device: DeviceCode,
    shouldContinue: () => boolean,
): Promise<string> {
    let waitMs = device.intervalMs

    while (shouldContinue()) {
        await new Promise((resolve) => setTimeout(resolve, waitMs))

        if (!shouldContinue()) {
            break
        }

        if (Date.now() > device.expiresAt) {
            throw new AuthError('The code expired before it was approved.', 'expired_token')
        }

        const data = await postForm(ACCESS_TOKEN_URL, {
            client_id: clientId,
            device_code: device.deviceCode,
            grant_type: 'urn:ietf:params:oauth:grant-type:device_code',
        })

        if (typeof data.access_token === 'string') {
            return data.access_token
        }

        switch (data.error) {
            case 'authorization_pending':
                break // the user is still busy in the browser
            case 'slow_down':
                waitMs += 5000
                break
            case 'expired_token':
                throw new AuthError('The code expired before it was approved.', 'expired_token')
            case 'access_denied':
                throw new AuthError('Access was denied in the browser.', 'access_denied')
            default:
                throw new AuthError(`GitHub returned "${String(data.error)}".`, String(data.error ?? 'unknown'))
        }
    }

    throw new AuthError('Sign-in was cancelled.', 'cancelled')
}

/**
 * Check a token and report who it belongs to. The granted scopes come back in a
 * response header, which is the only way to tell the user up front that they
 * ticked the wrong boxes.
 */
export async function validateToken(token: string): Promise<Account> {
    const response = await fetch(USER_URL, {
        headers: {
            Authorization: `Bearer ${token}`,
            Accept: 'application/vnd.github+json',
            'User-Agent': 'KingProgress',
        },
    })

    if (response.status === 401) {
        throw new AuthError('GitHub does not recognise that token.', 'bad_credentials')
    }

    if (!response.ok) {
        throw new AuthError(`GitHub replied ${response.status} ${response.statusText}.`, 'http_error')
    }

    const data: unknown = await response.json().catch(() => null)

    if (!isRecord(data) || typeof data.login !== 'string') {
        throw new AuthError('GitHub returned an unexpected response.', 'bad_response')
    }

    // Fine-grained tokens send no scope header at all; treat that as "unknown"
    // rather than "missing", because we cannot tell from here.
    const scopeHeader = response.headers.get('x-oauth-scopes')
    const scopes = scopeHeader === null ? [] : scopeHeader.split(',').map((scope) => scope.trim()).filter(Boolean)

    return {
        login: data.login,
        name: typeof data.name === 'string' ? data.name : null,
        avatarUrl: typeof data.avatar_url === 'string' ? data.avatar_url : '',
        scopes,
    }
}

/** Does this look like a GitHub token? Used to spot one on the clipboard. */
export function looksLikeToken(text: string): boolean {
    const trimmed = text.trim()

    if (trimmed.length > 255 || /\s/.test(trimmed)) {
        return false
    }

    return (
        /^gh[posur]_[A-Za-z0-9]{16,}$/.test(trimmed) ||
        /^github_pat_[A-Za-z0-9_]{20,}$/.test(trimmed) ||
        /^[a-f0-9]{40}$/.test(trimmed) // classic pre-2021 tokens
    )
}

/** The "new token" page with the right scopes and a description already filled in. */
export function tokenCreationUrl(hostname: string): string {
    const params = new URLSearchParams({
        scopes: OAUTH_SCOPES.split(' ').join(','),
        description: `KingProgress on ${hostname}`,
    })

    return `https://github.com/settings/tokens/new?${params.toString()}`
}
