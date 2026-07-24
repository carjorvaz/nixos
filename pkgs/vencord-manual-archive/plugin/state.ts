import { compareSnowflakes } from "./archive";

const BOUNDARY_ANCHOR_COUNT = 250;

export interface CaptureForIndex {
    id: string;
    startedAt: string;
    savedAt: string;
    messages: Array<{ id: string }>;
    continuity: {
        snapshotCount: number;
        continuous: boolean;
        breaks: Array<{
            at: string;
            previousOldestId: string;
            previousNewestId: string;
            nextOldestId: string;
            nextNewestId: string;
        }>;
        segments?: Array<{
            snapshotCount: number;
            messageIds: string[];
        }>;
    };
}

export interface CoverageInterval {
    id: string;
    oldestId: string;
    newestId: string;
    oldestAnchors: string[];
    newestAnchors: string[];
    captureIds: string[];
}

export interface CaptureIndexEntry {
    id: string;
    file: string;
    startedAt: string;
    savedAt: string;
    messageCount: number;
    continuous: boolean;
    matchedIntervalIds: string[];
    resultingIntervalId: string | null;
    resultingIntervalIds: string[];
}

export interface ChannelArchiveState {
    version: 1;
    guild: { id: string; name: string | null };
    channel: { id: string; name: string | null };
    intervals: CoverageInterval[];
    captures: CaptureIndexEntry[];
}

export interface SaveIndexResult {
    coverageUpdated: boolean;
    overlappedExisting: boolean;
    intervalCount: number;
    unresolvedGapCount: number;
    resultingIntervalId: string | null;
    resultingIntervalIds: string[];
}

export function emptyChannelArchiveState(
    guild: ChannelArchiveState["guild"],
    channel: ChannelArchiveState["channel"],
): ChannelArchiveState {
    return { version: 1, guild, channel, intervals: [], captures: [] };
}

function uniqueSorted(ids: string[]): string[] {
    return Array.from(new Set(ids)).sort(compareSnowflakes);
}

function intervalOverlapsCapture(interval: CoverageInterval, messageIds: string[]): boolean {
    const captureOldestId = messageIds[0];
    const captureNewestId = messageIds[messageIds.length - 1];
    return (
        compareSnowflakes(captureOldestId, interval.newestId) <= 0 &&
        compareSnowflakes(captureNewestId, interval.oldestId) >= 0
    );
}

export function mergeCaptureIntoState(
    state: ChannelArchiveState,
    capture: CaptureForIndex,
    archiveFile: string,
): { state: ChannelArchiveState; result: SaveIndexResult } {
    const ids = uniqueSorted(capture.messages.map((message) => message.id));
    if (ids.length === 0) throw new Error("Cannot index a capture without messages");

    const initialIntervalIds = new Set(state.intervals.map((interval) => interval.id));
    const matchedIntervalIds = new Set<string>();
    const segmentIds = capture.continuity.continuous
        ? [ids]
        : capture.continuity.segments?.map((segment) => uniqueSorted(segment.messageIds));
    let intervals = state.intervals;

    for (const [index, messageIds] of (segmentIds ?? []).entries()) {
        if (messageIds.length === 0) continue;
        const matched = intervals.filter((interval) => intervalOverlapsCapture(interval, messageIds));
        for (const interval of matched) {
            if (initialIntervalIds.has(interval.id)) matchedIntervalIds.add(interval.id);
        }
        const matchedIds = new Set(matched.map((interval) => interval.id));
        const untouched = intervals.filter((interval) => !matchedIds.has(interval.id));
        const boundaryCandidates = uniqueSorted([
            ...messageIds,
            ...matched.flatMap((interval) => [...interval.oldestAnchors, ...interval.newestAnchors]),
        ]);
        const resultingIntervalId =
            matched[0]?.id ??
            (segmentIds?.length === 1 ? `interval-${capture.id}` : `interval-${capture.id}-segment-${index + 1}`);
        const merged: CoverageInterval = {
            id: resultingIntervalId,
            oldestId: boundaryCandidates[0],
            newestId: boundaryCandidates[boundaryCandidates.length - 1],
            oldestAnchors: boundaryCandidates.slice(0, BOUNDARY_ANCHOR_COUNT),
            newestAnchors: boundaryCandidates.slice(-BOUNDARY_ANCHOR_COUNT),
            captureIds: Array.from(new Set([...matched.flatMap((interval) => interval.captureIds), capture.id])),
        };
        intervals = [...untouched, merged].sort((left, right) => compareSnowflakes(left.oldestId, right.oldestId));
    }

    const resultingIntervalIds = intervals
        .filter((interval) => interval.captureIds.includes(capture.id))
        .map((interval) => interval.id);
    const resultingIntervalId = resultingIntervalIds.length === 1 ? resultingIntervalIds[0] : null;
    const coverageUpdated = segmentIds != null && segmentIds.length > 0;
    const entry: CaptureIndexEntry = {
        id: capture.id,
        file: archiveFile,
        startedAt: capture.startedAt,
        savedAt: capture.savedAt,
        messageCount: ids.length,
        continuous: capture.continuity.continuous,
        matchedIntervalIds: Array.from(matchedIntervalIds),
        resultingIntervalId,
        resultingIntervalIds,
    };
    const nextState: ChannelArchiveState = {
        ...state,
        intervals,
        captures: [...state.captures, entry],
    };

    return {
        state: nextState,
        result: {
            coverageUpdated,
            overlappedExisting: matchedIntervalIds.size > 0,
            intervalCount: intervals.length,
            unresolvedGapCount: Math.max(0, intervals.length - 1),
            resultingIntervalId,
            resultingIntervalIds,
        },
    };
}
