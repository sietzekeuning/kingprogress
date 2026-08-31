export type ActionState =
  | 'queued'
  | 'running'
  | 'success'
  | 'failure'
  | 'cancelled'
  | 'timed_out'
  | 'skipped'
  | 'action_required'
  | 'neutral';

export interface RunningAction {
  key: string;
  repo: string;
  runId: number;
  name: string;
  branch: string | null;
  event: string | null;
  status: 'queued' | 'in_progress' | 'completed';
  conclusion: string | null;
  state: ActionState;
  actor: string | null;
  isMine: boolean;
  startedAt: string;
  startedAtMs: number;
  completedAtMs: number | null;
  durationMs: number | null;
  expectedDurationMs: number | null;
  currentJob: string | null;
  currentStep: string | null;
  jobsTotal: number;
  jobsCompleted: number;
  url: string;
  lingerMs: number;
}

export interface Account {
  login: string;
  name: string | null;
  avatarUrl: string;
  scopes: string[];
}

export interface AuthState {
  signedIn: boolean;
  account: Account | null;
  hasClientId: boolean;
  tokenUrl: string;
}

export interface DeviceCode {
  deviceCode: string;
  userCode: string;
  verificationUri: string;
  intervalMs: number;
  expiresAt: number;
}

export type ActorMode = 'all' | 'me' | 'only';

export interface ActorFilter {
  mode: ActorMode;
  logins: string[];
}

export interface Settings {
  watchedRepos: string[];
  actorFilter: ActorFilter;
  account: Account | null;
  hasClientId: boolean;
  autoRepoCount: number;
  openAtLogin: boolean;
}

export interface RepoSummary {
  fullName: string;
  owner: string;
  name: string;
  private: boolean;
  fork: boolean;
  updatedAt: string;
}

export type UpdateStatus = 'idle' | 'checking' | 'downloading' | 'ready' | 'error' | 'unsupported';

export interface UpdateState {
  status: UpdateStatus;
  currentVersion: string;
  newVersion: string | null;
  percent: number;
  message: string | null;
  checkedAt: number | null;
}

export interface ElectronAPI {
  getAuthState: () => Promise<AuthState>;
  submitToken: (token: string) => Promise<Account>;
  startDeviceLogin: () => Promise<DeviceCode>;
  cancelDeviceLogin: () => Promise<boolean>;
  watchClipboard: (watch: boolean) => Promise<boolean>;
  signOut: () => Promise<boolean>;
  openGitHubUrl: (url: string) => Promise<boolean>;

  getSettings: () => Promise<Settings>;
  listRepos: (force?: boolean) => Promise<RepoSummary[]>;
  setWatchedRepos: (repos: string[]) => Promise<Settings>;
  setActorFilter: (filter: ActorFilter) => Promise<Settings>;
  setOpenAtLogin: (enabled: boolean) => Promise<Settings>;

  getRunningActions: () => Promise<RunningAction[]>;
  dismissAction: (key: string) => Promise<boolean>;
  dismissAll: () => Promise<boolean>;

  getUpdateState: () => Promise<UpdateState>;
  checkForUpdates: () => Promise<UpdateState>;
  installUpdate: () => Promise<boolean>;

  popupEmpty: () => Promise<boolean>;
  setPointerInteractive: (interactive: boolean) => Promise<boolean>;
  resizeWindow: (width: number, height: number) => Promise<boolean>;

  onActionsUpdate: (callback: (data: RunningAction[]) => void) => void;
  onLoginComplete: (callback: (account: Account) => void) => void;
  onLoginError: (callback: (message: string) => void) => void;
  onClipboardToken: (callback: (token: string) => void) => void;
  onUpdateState: (callback: (state: UpdateState) => void) => void;
}

declare global {
  interface Window {
    electronAPI: ElectronAPI;
  }
}
