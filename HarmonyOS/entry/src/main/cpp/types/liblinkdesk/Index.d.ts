export const start: (surfaceId: string, windowId: number) => void;
export const stop: () => void;
export const stats: () => string;
export const setLatestMode: (enabled: boolean) => void;
export const cursor: () => string;

export const setMicrophoneEnabled: (enabled: boolean) => void;

export const setMicrophoneRequested: (enabled: boolean) => void;
