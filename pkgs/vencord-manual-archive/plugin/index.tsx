import type { NavContextMenuPatchCallback } from "@api/ContextMenu";
import { definePluginSettings } from "@api/Settings";
import definePlugin, { OptionType, type PluginNative } from "@utils/types";
import { ChannelStore, GuildStore, Menu, MessageStore, showToast, Toasts } from "@webpack/common";

import type { CaptureAccumulator } from "./archive";
import {
    compareSnowflakes,
    continuousSnapshotSegments,
    createAccumulator,
    ingestSnapshot,
    loadedMessagesFromStore,
    snapshotAccumulatorBaseline,
} from "./archive";
import type { getChannelState, saveCapture } from "./native";

const POLL_INTERVAL_MS = 1_000;
const QUIET_FLUSH_MS = 10_000;
const MAX_FLUSH_MS = 60_000;
const INITIALIZATION_BACKOFF_MS = 60_000;
const DISCORD_ID = /^\d{5,32}$/;

interface NativeMethods {
    getChannelState: typeof getChannelState;
    saveCapture: typeof saveCapture;
}

// Vencord generates this renderer-to-main proxy from the plugin's native exports.
const Native = VencordNative.pluginHelpers.ManualChannelArchive as unknown as PluginNative<NativeMethods>;

const settings = definePluginSettings({
    allowedChannelIds: {
        type: OptionType.STRING,
        default: "",
        description:
            "Discord channel IDs explicitly enrolled in continuous local text archiving. Prefer managing this with each channel's context menu.",
    },
});

interface CoverageIntervalSummary {
    oldestAnchors: string[];
    newestAnchors: string[];
}

interface ChannelStateResponse {
    archiveRoot: string;
    intervals: CoverageIntervalSummary[];
}

interface SaveResponse {
    coverageUpdated: boolean;
    overlappedExisting: boolean;
    intervalCount: number;
    unresolvedGapCount: number;
    archivePath: string;
}

interface EnrolledChannel {
    guildId: string;
    guildName: string | null;
    channelId: string;
    channelName: string | null;
}

interface ChannelArchiveSession extends EnrolledChannel {
    archiveRoot: string;
    intervalCountAtStart: number;
    knownAnchorIds: Set<string>;
    accumulator: CaptureAccumulator;
    captureStartedAt: string;
    lastFlushedSnapshotCount: number;
    lastChangeAt: number;
    lastFlushAt: number;
    lastErrorToastAt: number;
    saving: boolean;
    announcedFirstSave: boolean;
}

const sessions = new Map<string, ChannelArchiveSession>();
const sessionInitializers = new Map<string, Promise<ChannelArchiveSession | null>>();
const initializationBackoffUntil = new Map<string, number>();
let pollTimer: number | null = null;

function objectOrNull(value: unknown): Record<string, unknown> | null {
    if (value == null || typeof value !== "object" || Array.isArray(value)) return null;
    return value as Record<string, unknown>;
}

function requiredString(value: unknown, label: string): string {
    if (typeof value !== "string" || value.length === 0) throw new Error(`${label} must be a non-empty string`);
    return value;
}

function requiredBoolean(value: unknown, label: string): boolean {
    if (typeof value !== "boolean") throw new Error(`${label} must be a boolean`);
    return value;
}

function requiredNumber(value: unknown, label: string): number {
    if (typeof value !== "number" || !Number.isFinite(value)) throw new Error(`${label} must be a finite number`);
    return value;
}

function parseStringArray(value: unknown, label: string): string[] {
    if (!Array.isArray(value) || !value.every((item) => typeof item === "string")) {
        throw new Error(`${label} must be a string array`);
    }
    return value;
}

function parseChannelState(payload: string): ChannelStateResponse {
    const parsed: unknown = JSON.parse(payload);
    const response = objectOrNull(parsed);
    if (!response || !Array.isArray(response.intervals)) throw new Error("Native channel state is malformed");
    return {
        archiveRoot: requiredString(response.archiveRoot, "archiveRoot"),
        intervals: response.intervals.map((value, index) => {
            const interval = objectOrNull(value);
            if (!interval) throw new Error(`intervals[${index}] must be an object`);
            return {
                oldestAnchors: parseStringArray(interval.oldestAnchors, `intervals[${index}].oldestAnchors`),
                newestAnchors: parseStringArray(interval.newestAnchors, `intervals[${index}].newestAnchors`),
            };
        }),
    };
}

function parseSaveResponse(payload: string): SaveResponse {
    const parsed: unknown = JSON.parse(payload);
    const response = objectOrNull(parsed);
    if (!response) throw new Error("Native save response is malformed");
    return {
        coverageUpdated: requiredBoolean(response.coverageUpdated, "coverageUpdated"),
        overlappedExisting: requiredBoolean(response.overlappedExisting, "overlappedExisting"),
        intervalCount: requiredNumber(response.intervalCount, "intervalCount"),
        unresolvedGapCount: requiredNumber(response.unresolvedGapCount, "unresolvedGapCount"),
        archivePath: requiredString(response.archivePath, "archivePath"),
    };
}

function allowedChannelIds(): Set<string> {
    return new Set(
        settings.store.allowedChannelIds
            .split(",")
            .map((id) => id.trim())
            .filter((id) => DISCORD_ID.test(id)),
    );
}

function persistAllowedChannelIds(ids: Set<string>): void {
    settings.store.allowedChannelIds = Array.from(ids).sort().join(",");
}

function enrolledChannel(channelId: string): EnrolledChannel | null {
    const channel = objectOrNull(ChannelStore.getChannel(channelId));
    if (!channel || typeof channel.id !== "string") return null;
    const guildId =
        typeof channel.guild_id === "string"
            ? channel.guild_id
            : typeof channel.guildId === "string"
              ? channel.guildId
              : null;
    if (!guildId) return null;
    return {
        guildId,
        guildName: GuildStore.getGuild(guildId)?.name ?? null,
        channelId: channel.id,
        channelName: typeof channel.name === "string" ? channel.name : null,
    };
}

function sessionHasUnsavedChanges(session: ChannelArchiveSession): boolean {
    return session.accumulator.snapshotCount > session.lastFlushedSnapshotCount;
}

function snapshotSession(session: ChannelArchiveSession): boolean {
    const result = ingestSnapshot(
        session.accumulator,
        loadedMessagesFromStore(MessageStore.getMessages(session.channelId)),
        session.knownAnchorIds,
        { guildId: session.guildId, channelId: session.channelId },
    );
    if (result.changed) session.lastChangeAt = Date.now();
    return result.changed;
}

function boundaryAnchors(ids: string[]): Set<string> {
    const sorted = Array.from(new Set(ids)).sort(compareSnowflakes);
    return new Set([...sorted.slice(0, 250), ...sorted.slice(-250)]);
}

function ensureSession(channel: EnrolledChannel): Promise<ChannelArchiveSession | null> {
    const existing = sessions.get(channel.channelId);
    if (existing) return Promise.resolve(existing);
    const pending = sessionInitializers.get(channel.channelId);
    if (pending) return pending;
    if ((initializationBackoffUntil.get(channel.channelId) ?? 0) > Date.now()) return Promise.resolve(null);

    const promise = (async (): Promise<ChannelArchiveSession | null> => {
        try {
            const state = parseChannelState(
                await Native.getChannelState(
                    channel.guildId,
                    channel.channelId,
                    channel.guildName,
                    channel.channelName,
                ),
            );
            const now = Date.now();
            const session: ChannelArchiveSession = {
                ...channel,
                archiveRoot: state.archiveRoot,
                intervalCountAtStart: state.intervals.length,
                knownAnchorIds: new Set(
                    state.intervals.flatMap((interval) => [...interval.oldestAnchors, ...interval.newestAnchors]),
                ),
                accumulator: createAccumulator(),
                captureStartedAt: new Date(now).toISOString(),
                lastFlushedSnapshotCount: 0,
                lastChangeAt: now,
                lastFlushAt: now,
                lastErrorToastAt: 0,
                saving: false,
                announcedFirstSave: false,
            };
            sessions.set(channel.channelId, session);
            snapshotSession(session);
            return session;
        } catch (error: unknown) {
            initializationBackoffUntil.set(channel.channelId, Date.now() + INITIALIZATION_BACKOFF_MS);
            const detail = error instanceof Error ? error.message : String(error);
            showToast(
                `Could not initialize #${channel.channelName ?? channel.channelId} archive: ${detail}`,
                Toasts.Type.FAILURE,
                {
                    duration: 10_000,
                },
            );
            return null;
        }
    })();
    sessionInitializers.set(channel.channelId, promise);
    void promise.finally(() => {
        if (sessionInitializers.get(channel.channelId) === promise) sessionInitializers.delete(channel.channelId);
    });
    return promise;
}

async function flushSession(
    session: ChannelArchiveSession,
    trigger: "automatic" | "archive-now" | "disabled" | "plugin-stop",
): Promise<boolean> {
    if (session.saving) return false;
    if (!sessionHasUnsavedChanges(session)) {
        if (trigger === "archive-now")
            showToast(`#${session.channelName ?? session.channelId} archive is already up to date.`);
        return true;
    }

    const accumulator = session.accumulator;
    const snapshotCount = accumulator.snapshotCount;
    const messages = Array.from(accumulator.messages.values()).sort((left, right) =>
        compareSnowflakes(left.id, right.id),
    );
    if (messages.length === 0) return true;
    const savedBaseline = snapshotAccumulatorBaseline(accumulator);
    const savedAt = new Date().toISOString();
    const segments = continuousSnapshotSegments(accumulator);
    const payload = {
        format: "vencord-manual-text-archive",
        formatVersion: 1,
        id: `${savedAt}-${crypto.randomUUID()}`,
        startedAt: session.captureStartedAt,
        savedAt,
        guild: { id: session.guildId, name: session.guildName },
        channel: { id: session.channelId, name: session.channelName },
        source: {
            method: "Continuous snapshots of Discord MessageStore for an explicitly enrolled channel",
            networkRequestsInitiatedByPlugin: false,
            attachmentPolicy: "metadata only; no bytes or CDN URLs",
            messageUrlTemplate: "https://discord.com/channels/{guildId}/{channelId}/{messageId}",
            archiveRoot: session.archiveRoot,
            flushTrigger: trigger,
        },
        coverageAtStart: {
            intervalCount: session.intervalCountAtStart,
            knownBoundaryOverlapIds: Array.from(accumulator.knownOverlapIds).sort(compareSnowflakes),
        },
        continuity: {
            snapshotCount,
            continuous: segments.length === 1,
            breaks: accumulator.breaks,
            segments,
        },
        messageCount: messages.length,
        messages,
    };

    session.saving = true;
    try {
        const result = parseSaveResponse(await Native.saveCapture(JSON.stringify(payload)));
        session.lastFlushAt = Date.now();
        session.intervalCountAtStart = result.intervalCount;
        session.knownAnchorIds = boundaryAnchors(messages.map((message) => message.id));
        session.lastFlushedSnapshotCount = Math.max(session.lastFlushedSnapshotCount, snapshotCount);
        session.captureStartedAt = savedAt;

        if (session.accumulator.snapshotCount === snapshotCount) {
            session.accumulator = savedBaseline;
            session.lastFlushedSnapshotCount = savedBaseline.snapshotCount;
        }

        if (!result.coverageUpdated) {
            showToast(
                `Saved #${session.channelName ?? session.channelId}, but its loaded message batches contain a continuity break.`,
                Toasts.Type.FAILURE,
                { duration: 10_000 },
            );
        } else if (trigger === "archive-now" || !session.announcedFirstSave) {
            session.announcedFirstSave = true;
            const gapStatus =
                result.unresolvedGapCount === 0
                    ? "known coverage is gap-free"
                    : `${result.unresolvedGapCount} known gap(s) remain`;
            showToast(
                `Continuously archived ${messages.length} loaded messages from #${session.channelName ?? session.channelId}; ${gapStatus}.`,
                Toasts.Type.SUCCESS,
                { duration: 10_000 },
            );
        }
        return true;
    } catch (error: unknown) {
        const now = Date.now();
        if (trigger !== "automatic" || now - session.lastErrorToastAt >= INITIALIZATION_BACKOFF_MS) {
            session.lastErrorToastAt = now;
            const detail = error instanceof Error ? error.message : String(error);
            showToast(
                `Archive save failed for #${session.channelName ?? session.channelId}: ${detail}`,
                Toasts.Type.FAILURE,
                {
                    duration: 10_000,
                },
            );
        }
        return false;
    } finally {
        session.saving = false;
    }
}

function pollAllowedChannels(): void {
    const allowed = allowedChannelIds();
    for (const [channelId, session] of sessions) {
        if (allowed.has(channelId)) continue;
        void flushSession(session, "disabled");
        sessions.delete(channelId);
    }

    const now = Date.now();
    for (const channelId of allowed) {
        const channel = enrolledChannel(channelId);
        if (!channel) continue;
        const session = sessions.get(channelId);
        if (!session) {
            void ensureSession(channel);
            continue;
        }
        snapshotSession(session);
        if (
            sessionHasUnsavedChanges(session) &&
            !session.saving &&
            (now - session.lastChangeAt >= QUIET_FLUSH_MS || now - session.lastFlushAt >= MAX_FLUSH_MS)
        ) {
            void flushSession(session, "automatic");
        }
    }
}

function startPolling(): void {
    if (pollTimer != null) return;
    pollAllowedChannels();
    pollTimer = window.setInterval(pollAllowedChannels, POLL_INTERVAL_MS);
}

function stopPolling(): void {
    if (pollTimer == null) return;
    window.clearInterval(pollTimer);
    pollTimer = null;
}

function sessionStatus(channelId: string): string {
    const session = sessions.get(channelId);
    if (!session) return "Initializing continuous archive";
    if (session.saving) return `Saving ${session.accumulator.messages.size} loaded messages`;
    if (sessionHasUnsavedChanges(session)) return `${session.accumulator.messages.size} loaded messages; save pending`;
    return `${session.accumulator.messages.size} loaded messages; archive current`;
}

const patchChannelContextMenu: NavContextMenuPatchCallback = (children, rawProps) => {
    const props = objectOrNull(rawProps);
    const channelObject = objectOrNull(props?.channel);
    if (!channelObject || typeof channelObject.id !== "string") return;
    const channel = enrolledChannel(channelObject.id);
    if (!channel) return;
    const allowed = allowedChannelIds();
    const isAllowed = allowed.has(channel.channelId);

    children.push(
        <Menu.MenuItem
            id="vc-manual-channel-archive"
            label={isAllowed ? "Continuous text archive" : "Enable continuous text archive"}
            action={
                isAllowed
                    ? undefined
                    : () => {
                          allowed.add(channel.channelId);
                          persistAllowedChannelIds(allowed);
                          void ensureSession(channel);
                          showToast(
                              `Continuous local text archive enabled for #${channel.channelName ?? channel.channelId}. Already-loaded messages will save automatically.`,
                              Toasts.Type.SUCCESS,
                              { duration: 8_000 },
                          );
                      }
            }
        >
            {isAllowed && (
                <>
                    <Menu.MenuItem
                        id="vc-manual-channel-archive-status"
                        label={sessionStatus(channel.channelId)}
                        disabled
                    />
                    <Menu.MenuItem
                        id="vc-manual-channel-archive-save-now"
                        label="Archive loaded messages now"
                        action={() => {
                            void (async () => {
                                const session = await ensureSession(channel);
                                if (!session) return;
                                snapshotSession(session);
                                await flushSession(session, "archive-now");
                            })();
                        }}
                    />
                    <Menu.MenuItem
                        id="vc-manual-channel-archive-remove"
                        label="Disable continuous text archive"
                        color="danger"
                        action={() => {
                            void (async () => {
                                const session = sessions.get(channel.channelId);
                                if (session && !(await flushSession(session, "disabled"))) return;
                                allowed.delete(channel.channelId);
                                persistAllowedChannelIds(allowed);
                                sessions.delete(channel.channelId);
                                showToast(
                                    `Continuous text archive disabled for #${channel.channelName ?? channel.channelId}.`,
                                );
                            })();
                        }}
                    />
                </>
            )}
        </Menu.MenuItem>,
    );
};

export default definePlugin({
    name: "ManualChannelArchive",
    description:
        "Continuously archives already-loaded Discord text for explicitly enrolled channels without initiating history requests.",
    authors: [{ name: "cjv", id: 0n }],
    enabledByDefault: true,
    settings,
    contextMenus: {
        "channel-context": patchChannelContextMenu,
        "thread-context": patchChannelContextMenu,
    },
    start() {
        startPolling();
    },
    stop() {
        stopPolling();
        for (const session of sessions.values()) void flushSession(session, "plugin-stop");
    },
});
