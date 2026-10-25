import { useSyncExternalStore } from 'react';

export interface Store<T> {
  get(): T;
  set(update: (prev: T) => T): void;
  patch(partial: Partial<T>): void;
  subscribe(listener: () => void): () => void;
}

export function createStore<T extends object>(initial: T): Store<T> {
  let state = initial;
  const listeners = new Set<() => void>();
  const store: Store<T> = {
    get: () => state,
    set(update) {
      const next = update(state);
      if (next === state) return;
      state = next;
      for (const l of [...listeners]) l();
    },
    patch(partial) {
      store.set((s) => ({ ...s, ...partial }));
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
  return store;
}

/** Subscribe to a slice. The selector must return a stable reference for unchanged state. */
export function useStore<T extends object, S>(store: Store<T>, selector: (s: T) => S): S {
  return useSyncExternalStore(
    store.subscribe,
    () => selector(store.get()),
    () => selector(store.get()),
  );
}

// ───────────── shared clock ─────────────

const clockListeners = new Set<() => void>();
let clockNow = Date.now();
let clockTimer: ReturnType<typeof setInterval> | null = null;

function subscribeClock(l: () => void): () => void {
  clockListeners.add(l);
  if (!clockTimer) {
    clockTimer = setInterval(() => {
      clockNow = Date.now();
      for (const x of [...clockListeners]) x();
    }, 1000);
  }
  return () => {
    clockListeners.delete(l);
    if (clockListeners.size === 0 && clockTimer) {
      clearInterval(clockTimer);
      clockTimer = null;
    }
  };
}

/** Current time, re-rendering once per second. */
export function useNow(): number {
  return useSyncExternalStore(subscribeClock, () => clockNow, () => clockNow);
}
