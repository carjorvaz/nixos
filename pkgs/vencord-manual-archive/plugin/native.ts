import type { IpcMainInvokeEvent } from "electron";
import { app } from "electron";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";

import type { CaptureForIndex, CaptureIndexEntry, ChannelArchiveState, CoverageInterval } from "./state";
import { emptyChannelArchiveState, mergeCaptureIntoState } from "./state";

const DISCORD_ID = /^\d{5,32}$/;

interface CaptureEnvelope {
    raw: Record<string, unknown>;
    guild: ChannelArchiveState["guild"];
    channel: ChannelArchiveState["channel"];
    capture: CaptureForIndex;
}

function object(value: unknown, label: string): Record<string, unknown> {
    if (value == null || typeof value !== "object" || Array.isArray(value)) {
        throw new Error(`${label} must be an object`);
    }
    return value as Record<string, unknown>;
}

function string(value: unknown, label: string): string {
    if (typeof value !== "string" || value.length === 0) throw new Error(`${label} must be a non-empty string`);
    return value;
}

function nullableString(value: unknown, label: string): string | null {
    if (value == null) return null;
    if (typeof value !== "string") throw new Error(`${label} must be a string or null`);
    return value;
}

function boolean(value: unknown, label: string): boolean {
    if (typeof value !== "boolean") throw new Error(`${label} must be a boolean`);
    return value;
}

function finiteNumber(value: unknown, label: string): number {
    if (typeof value !== "number" || !Number.isFinite(value)) throw new Error(`${label} must be a finite number`);
    return value;
}

function positiveInteger(value: unknown, label: string): number {
    const number = finiteNumber(value, label);
    if (!Number.isInteger(number) || number < 1) throw new Error(`${label} must be a positive integer`);
    return number;
}

function array(value: unknown, label: string): unknown[] {
    if (!Array.isArray(value)) throw new Error(`${label} must be an array`);
    return value;
}

function discordId(value: unknown, label: string): string {
    const id = string(value, label);
    if (!DISCORD_ID.test(id)) throw new Error(`${label} is not a Discord snowflake`);
    return id;
}

function stringArray(value: unknown, label: string): string[] {
    return array(value, label).map((item, index) => string(item, `${label}[${index}]`));
}

function parseCaptureEnvelope(value: unknown): CaptureEnvelope {
    const raw = object(value, "capture");
    const guildObject = object(raw.guild, "capture.guild");
    const channelObject = object(raw.channel, "capture.channel");
    const continuityObject = object(raw.continuity, "capture.continuity");
    const messages = array(raw.messages, "capture.messages").map((value, index) => {
        const message = object(value, `capture.messages[${index}]`);
        return { id: discordId(message.id, `capture.messages[${index}].id`) };
    });
    const breaks = array(continuityObject.breaks, "capture.continuity.breaks").map((value, index) => {
        const item = object(value, `capture.continuity.breaks[${index}]`);
        return {
            at: string(item.at, `capture.continuity.breaks[${index}].at`),
            previousOldestId: discordId(item.previousOldestId, `capture.continuity.breaks[${index}].previousOldestId`),
            previousNewestId: discordId(item.previousNewestId, `capture.continuity.breaks[${index}].previousNewestId`),
            nextOldestId: discordId(item.nextOldestId, `capture.continuity.breaks[${index}].nextOldestId`),
            nextNewestId: discordId(item.nextNewestId, `capture.continuity.breaks[${index}].nextNewestId`),
        };
    });
    const messageIds = new Set(messages.map((message) => message.id));
    const segments =
        continuityObject.segments == null
            ? undefined
            : array(continuityObject.segments, "capture.continuity.segments").map((value, index) => {
                  const item = object(value, `capture.continuity.segments[${index}]`);
                  return {
                      snapshotCount: positiveInteger(
                          item.snapshotCount,
                          `capture.continuity.segments[${index}].snapshotCount`,
                      ),
                      messageIds: array(item.messageIds, `capture.continuity.segments[${index}].messageIds`).map(
                          (id, messageIndex) =>
                              discordId(id, `capture.continuity.segments[${index}].messageIds[${messageIndex}]`),
                      ),
                  };
              });
    if (segments) {
        const segmentedIds = new Set<string>();
        for (const [segmentIndex, segment] of segments.entries()) {
            if (segment.messageIds.length === 0) {
                throw new Error(`capture.continuity.segments[${segmentIndex}].messageIds must not be empty`);
            }
            for (const id of segment.messageIds) {
                if (!messageIds.has(id)) throw new Error(`capture continuity segment references absent message ${id}`);
                if (segmentedIds.has(id)) throw new Error(`capture continuity segments duplicate message ${id}`);
                segmentedIds.add(id);
            }
        }
        if (segmentedIds.size !== messageIds.size) {
            throw new Error("capture continuity segments must partition every captured message");
        }
    }

    return {
        raw,
        guild: {
            id: discordId(guildObject.id, "capture.guild.id"),
            name: nullableString(guildObject.name, "capture.guild.name"),
        },
        channel: {
            id: discordId(channelObject.id, "capture.channel.id"),
            name: nullableString(channelObject.name, "capture.channel.name"),
        },
        capture: {
            id: string(raw.id, "capture.id"),
            startedAt: string(raw.startedAt, "capture.startedAt"),
            savedAt: string(raw.savedAt, "capture.savedAt"),
            messages,
            continuity: {
                snapshotCount: positiveInteger(continuityObject.snapshotCount, "capture.continuity.snapshotCount"),
                continuous: boolean(continuityObject.continuous, "capture.continuity.continuous"),
                breaks,
                segments,
            },
        },
    };
}

function parseCoverageInterval(value: unknown, label: string): CoverageInterval {
    const interval = object(value, label);
    return {
        id: string(interval.id, `${label}.id`),
        oldestId: discordId(interval.oldestId, `${label}.oldestId`),
        newestId: discordId(interval.newestId, `${label}.newestId`),
        oldestAnchors: stringArray(interval.oldestAnchors, `${label}.oldestAnchors`),
        newestAnchors: stringArray(interval.newestAnchors, `${label}.newestAnchors`),
        captureIds: stringArray(interval.captureIds, `${label}.captureIds`),
    };
}

function parseCaptureEntry(value: unknown, label: string): CaptureIndexEntry {
    const entry = object(value, label);
    const resultingIntervalId =
        entry.resultingIntervalId == null ? null : string(entry.resultingIntervalId, `${label}.resultingIntervalId`);
    return {
        id: string(entry.id, `${label}.id`),
        file: string(entry.file, `${label}.file`),
        startedAt: string(entry.startedAt, `${label}.startedAt`),
        savedAt: string(entry.savedAt, `${label}.savedAt`),
        messageCount: finiteNumber(entry.messageCount, `${label}.messageCount`),
        continuous: boolean(entry.continuous, `${label}.continuous`),
        matchedIntervalIds: stringArray(entry.matchedIntervalIds, `${label}.matchedIntervalIds`),
        resultingIntervalId,
        resultingIntervalIds:
            entry.resultingIntervalIds == null
                ? resultingIntervalId == null
                    ? []
                    : [resultingIntervalId]
                : stringArray(entry.resultingIntervalIds, `${label}.resultingIntervalIds`),
    };
}

function parseState(
    value: unknown,
    guild: ChannelArchiveState["guild"],
    channel: ChannelArchiveState["channel"],
): ChannelArchiveState {
    const state = object(value, "archive state");
    if (state.version !== 1) throw new Error("Unsupported archive state version");
    const persistedGuild = object(state.guild, "archive state.guild");
    const persistedChannel = object(state.channel, "archive state.channel");
    if (discordId(persistedGuild.id, "archive state.guild.id") !== guild.id)
        throw new Error("Archive guild ID mismatch");
    if (discordId(persistedChannel.id, "archive state.channel.id") !== channel.id)
        throw new Error("Archive channel ID mismatch");

    return {
        version: 1,
        guild: {
            id: guild.id,
            name: nullableString(persistedGuild.name, "archive state.guild.name") ?? guild.name,
        },
        channel: {
            id: channel.id,
            name: nullableString(persistedChannel.name, "archive state.channel.name") ?? channel.name,
        },
        intervals: array(state.intervals, "archive state.intervals").map((interval, index) =>
            parseCoverageInterval(interval, `archive state.intervals[${index}]`),
        ),
        captures: array(state.captures, "archive state.captures").map((entry, index) =>
            parseCaptureEntry(entry, `archive state.captures[${index}]`),
        ),
    };
}

function archiveRoot(): string {
    return join(app.getPath("userData"), "discord-manual-text-archive");
}

function channelDirectory(guildId: string, channelId: string): string {
    return join(archiveRoot(), guildId, channelId);
}

async function writeJsonAtomic(path: string, value: unknown): Promise<void> {
    const temporaryPath = `${path}.${randomUUID()}.tmp`;
    await writeFile(temporaryPath, `${JSON.stringify(value, null, 2)}\n`, { encoding: "utf8", flag: "wx" });
    await rename(temporaryPath, path);
}

async function readState(
    path: string,
    guild: ChannelArchiveState["guild"],
    channel: ChannelArchiveState["channel"],
): Promise<ChannelArchiveState> {
    try {
        const value: unknown = JSON.parse(await readFile(path, "utf8"));
        return parseState(value, guild, channel);
    } catch (error: unknown) {
        if (error instanceof Error && "code" in error && error.code === "ENOENT") {
            return emptyChannelArchiveState(guild, channel);
        }
        throw error;
    }
}

export async function getChannelState(
    _event: IpcMainInvokeEvent,
    guildIdValue: string,
    channelIdValue: string,
    guildName: string | null,
    channelName: string | null,
): Promise<string> {
    const guild = { id: discordId(guildIdValue, "guild ID"), name: nullableString(guildName, "guild name") };
    const channel = { id: discordId(channelIdValue, "channel ID"), name: nullableString(channelName, "channel name") };
    const directory = channelDirectory(guild.id, channel.id);
    const state = await readState(join(directory, "state.json"), guild, channel);
    return JSON.stringify({
        archiveRoot: archiveRoot(),
        intervals: state.intervals,
        captures: state.captures.slice(-20),
    });
}

export async function saveCapture(_event: IpcMainInvokeEvent, payload: string): Promise<string> {
    const parsed: unknown = JSON.parse(payload);
    const envelope = parseCaptureEnvelope(parsed);
    const directory = channelDirectory(envelope.guild.id, envelope.channel.id);
    const capturesDirectory = join(directory, "captures");
    await mkdir(capturesDirectory, { recursive: true });

    const sortedIds = envelope.capture.messages.map((message) => message.id).sort();
    const timestamp = envelope.capture.savedAt.replace(/[^0-9TZ]/g, "-");
    const archiveFilename = `${timestamp}_${sortedIds[0]}_${sortedIds[sortedIds.length - 1]}_${randomUUID()}.json`;
    const archivePath = join(capturesDirectory, archiveFilename);
    await writeJsonAtomic(archivePath, envelope.raw);

    const statePath = join(directory, "state.json");
    const currentState = await readState(statePath, envelope.guild, envelope.channel);
    const refreshedState = {
        ...currentState,
        guild: envelope.guild,
        channel: envelope.channel,
    };
    const { state, result } = mergeCaptureIntoState(
        refreshedState,
        envelope.capture,
        join("captures", archiveFilename),
    );
    await writeJsonAtomic(statePath, state);

    return JSON.stringify({ ...result, archivePath, archiveRoot: archiveRoot() });
}
