export type ResourceCacheStatus = "idle" | "loading" | "success" | "error";

export type ResourceCacheEntry<T> = {
  data?: T;
  fetchedAt: number;
  status: ResourceCacheStatus;
  loading: boolean;
  refreshing: boolean;
  error: unknown;
  promise: Promise<T> | null;
};

type HydrateOptions = {
  staleMs?: number;
  force?: boolean;
};

const DEFAULT_STALE_MS = 60_000;

function stableSerialize(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableSerialize).join(",")}]`;

  const record = value as Record<string, unknown>;
  return `{${Object.keys(record)
    .sort()
    .map((key) => `${JSON.stringify(key)}:${stableSerialize(record[key])}`)
    .join(",")}}`;
}

export function resourceCacheKey(resource: string, params: Record<string, unknown> = {}) {
  return `${resource}:${stableSerialize(params)}`;
}

export class RuntimeResourceCache {
  private entries = new Map<string, ResourceCacheEntry<unknown>>();

  get<T>(key: string): ResourceCacheEntry<T> | undefined {
    return this.entries.get(key) as ResourceCacheEntry<T> | undefined;
  }

  ensure<T>(key: string): ResourceCacheEntry<T> {
    let entry = this.entries.get(key);
    if (!entry) {
      entry = {
        fetchedAt: 0,
        status: "idle",
        loading: false,
        refreshing: false,
        error: null,
        promise: null,
      };
      this.entries.set(key, entry);
    }
    return entry as ResourceCacheEntry<T>;
  }

  isStale(key: string, staleMs = DEFAULT_STALE_MS) {
    const entry = this.entries.get(key);
    return !entry?.data || Date.now() - entry.fetchedAt > staleMs;
  }

  hydrate<T>(
    key: string,
    fetcher: () => Promise<T>,
    options: HydrateOptions = {},
  ): Promise<ResourceCacheEntry<T>> {
    const staleMs = options.staleMs ?? DEFAULT_STALE_MS;
    const entry = this.ensure<T>(key);

    if (!options.force && entry.data !== undefined && !this.isStale(key, staleMs)) {
      return Promise.resolve(entry);
    }

    if (entry.promise) {
      return entry.promise.then(() => entry);
    }

    entry.error = null;
    entry.loading = entry.data === undefined;
    entry.refreshing = entry.data !== undefined;
    entry.status = entry.loading ? "loading" : "success";

    entry.promise = fetcher()
      .then((data) => {
        entry.data = data;
        entry.fetchedAt = Date.now();
        entry.status = "success";
        entry.error = null;
        return data;
      })
      .catch((error) => {
        entry.error = error;
        entry.status = entry.data === undefined ? "error" : "success";
        throw error;
      })
      .finally(() => {
        entry.loading = false;
        entry.refreshing = false;
        entry.promise = null;
      });

    return entry.promise.then(() => entry);
  }

  invalidate(prefix?: string) {
    if (!prefix) {
      this.entries.clear();
      return;
    }

    for (const key of this.entries.keys()) {
      if (key.startsWith(prefix)) this.entries.delete(key);
    }
  }

  markStale(prefix?: string) {
    for (const [key, entry] of this.entries.entries()) {
      if (!prefix || key.startsWith(prefix)) entry.fetchedAt = 0;
    }
  }
}

export const resourceCache = new RuntimeResourceCache();
