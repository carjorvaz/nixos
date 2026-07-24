import { describe, expect, test } from "bun:test";

import type { CaptureForIndex } from "../plugin/state";
import { emptyChannelArchiveState, mergeCaptureIntoState } from "../plugin/state";

const guild = { id: "200000000000000001", name: "OMP" };
const channel = { id: "300000000000000001", name: "general" };

function capture(id: string, messageIds: string[], continuous = true, segments?: string[][]): CaptureForIndex {
    return {
        id,
        startedAt: "2026-07-18T08:00:00.000Z",
        savedAt: "2026-07-18T08:01:00.000Z",
        messages: messageIds.map((messageId) => ({ id: messageId })),
        continuity: {
            snapshotCount: 2,
            continuous,
            breaks: continuous
                ? []
                : [
                      {
                          at: "2026-07-18T08:00:30.000Z",
                          previousOldestId: messageIds[0],
                          previousNewestId: messageIds[0],
                          nextOldestId: messageIds[messageIds.length - 1],
                          nextNewestId: messageIds[messageIds.length - 1],
                      },
                  ],
            segments: segments?.map((segmentMessageIds) => ({
                snapshotCount: 1,
                messageIds: segmentMessageIds,
            })),
        },
    };
}

describe("coverage indexing", () => {
    test("merges overlap, exposes disjoint gaps, and closes them with a bridging capture", () => {
        const initial = mergeCaptureIntoState(
            emptyChannelArchiveState(guild, channel),
            capture("first", ["100000000000000001", "100000000000000002", "100000000000000003"]),
            "captures/first.json",
        );
        expect(initial.result.intervalCount).toBe(1);
        expect(initial.result.overlappedExisting).toBe(false);

        const newer = mergeCaptureIntoState(
            initial.state,
            capture("newer", ["100000000000000003", "100000000000000004", "100000000000000005"]),
            "captures/newer.json",
        );
        expect(newer.result.intervalCount).toBe(1);
        expect(newer.result.overlappedExisting).toBe(true);
        expect(newer.state.intervals[0].oldestId).toBe("100000000000000001");
        expect(newer.state.intervals[0].newestId).toBe("100000000000000005");

        const disjoint = mergeCaptureIntoState(
            newer.state,
            capture("disjoint", ["100000000000000010", "100000000000000011"]),
            "captures/disjoint.json",
        );
        expect(disjoint.result.intervalCount).toBe(2);
        expect(disjoint.result.unresolvedGapCount).toBe(1);

        const bridged = mergeCaptureIntoState(
            disjoint.state,
            capture("bridge", [
                "100000000000000005",
                "100000000000000006",
                "100000000000000007",
                "100000000000000008",
                "100000000000000009",
                "100000000000000010",
            ]),
            "captures/bridge.json",
        );
        expect(bridged.result.intervalCount).toBe(1);
        expect(bridged.result.unresolvedGapCount).toBe(0);
        expect(bridged.state.intervals[0].captureIds).toEqual(["first", "newer", "disjoint", "bridge"]);
    });

    test("merges a capture contained inside an indexed range without requiring shared boundary IDs", () => {
        const wide = mergeCaptureIntoState(
            emptyChannelArchiveState(guild, channel),
            capture("wide", ["100000000000000001", "100000000000000010"]),
            "captures/wide.json",
        );
        const contained = mergeCaptureIntoState(
            wide.state,
            capture("contained", ["100000000000000004", "100000000000000005"]),
            "captures/contained.json",
        );

        expect(contained.result.overlappedExisting).toBe(true);
        expect(contained.result.intervalCount).toBe(1);
        expect(contained.state.intervals[0].oldestId).toBe("100000000000000001");
        expect(contained.state.intervals[0].newestId).toBe("100000000000000010");
        expect(contained.state.intervals[0].captureIds).toEqual(["wide", "contained"]);
    });

    test("stores discontinuous captures without advancing known coverage", () => {
        const state = emptyChannelArchiveState(guild, channel);
        const result = mergeCaptureIntoState(
            state,
            capture("broken", ["100000000000000001", "100000000000000010"], false),
            "captures/broken.json",
        );

        expect(result.result.coverageUpdated).toBe(false);
        expect(result.state.intervals).toEqual([]);
        expect(result.state.captures[0].continuous).toBe(false);
    });

    test("indexes each verified segment of a discontinuous capture without claiming the gaps", () => {
        const result = mergeCaptureIntoState(
            emptyChannelArchiveState(guild, channel),
            capture(
                "segmented",
                ["100000000000000001", "100000000000000002", "100000000000000010", "100000000000000011"],
                false,
                [
                    ["100000000000000001", "100000000000000002"],
                    ["100000000000000010", "100000000000000011"],
                ],
            ),
            "captures/segmented.json",
        );

        expect(result.result.coverageUpdated).toBe(true);
        expect(result.result.intervalCount).toBe(2);
        expect(result.result.unresolvedGapCount).toBe(1);
        expect(result.result.resultingIntervalId).toBeNull();
        expect(result.result.resultingIntervalIds).toHaveLength(2);
        expect(result.state.captures[0].continuous).toBe(false);
        expect(result.state.captures[0].resultingIntervalIds).toEqual(result.result.resultingIntervalIds);
    });
});
