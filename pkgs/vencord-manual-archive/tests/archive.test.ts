import { describe, expect, test } from "bun:test";

import {
    continuousSnapshotSegments,
    createAccumulator,
    ingestSnapshot,
    loadedMessagesFromStore,
    sanitizeMessage,
    snapshotAccumulatorBaseline,
} from "../plugin/archive";

describe("message sanitization", () => {
    test("keeps durable text context and strips credential-like client fields and media URLs", () => {
        const archived = sanitizeMessage({
            id: "100000000000000001",
            guild_id: "200000000000000001",
            channel_id: "300000000000000001",
            timestamp: "2026-07-18T08:00:00.000Z",
            content: "Read https://example.com/source",
            token: "must-not-survive",
            author: {
                id: "400000000000000001",
                username: "alice",
                globalName: "Alice",
                avatar: "private-avatar-hash",
            },
            attachments: [
                {
                    id: "500000000000000001",
                    filename: "notes.txt",
                    description: "source notes",
                    content_type: "text/plain",
                    size: 42,
                    url: "https://cdn.discordapp.com/attachments/signed-secret",
                },
            ],
            embeds: [
                {
                    title: "Primary source",
                    url: "https://example.com/paper?section=2",
                    fields: [{ name: "Finding", value: "Useful", inline: true }],
                },
            ],
            reactions: [
                {
                    emoji: { name: "thumbsup" },
                    count: 3,
                    users: [{ id: "private-reactor-list" }],
                },
            ],
            message_reference: {
                message_id: "100000000000000000",
                channel_id: "300000000000000001",
                guild_id: "200000000000000001",
            },
        });

        expect(archived).not.toBeNull();
        expect(archived?.content).toBe("Read https://example.com/source");
        expect(archived?.sourceUrl).toBe(
            "https://discord.com/channels/200000000000000001/300000000000000001/100000000000000001",
        );
        expect(archived?.attachments).toEqual([
            {
                id: "500000000000000001",
                filename: "notes.txt",
                description: "source notes",
                contentType: "text/plain",
                size: 42,
                width: null,
                height: null,
                durationSeconds: null,
                ephemeral: false,
            },
        ]);
        expect(archived?.embeds[0].url).toBe("https://example.com/paper?section=2");
        expect(archived?.reactions[0]).toEqual({
            emoji: { id: null, name: "thumbsup", animated: false },
            count: 3,
            me: false,
        });
        expect(JSON.stringify(archived)).not.toContain("must-not-survive");
        expect(JSON.stringify(archived)).not.toContain("signed-secret");
        expect(JSON.stringify(archived)).not.toContain("private-reactor-list");
        expect(JSON.stringify(archived)).not.toContain("private-avatar-hash");
    });

    test("uses capture context when Discord records omit guild metadata", () => {
        const archived = sanitizeMessage(
            {
                id: "100000000000000001",
                channel_id: "300000000000000001",
                content: "context fallback",
            },
            {
                guildId: "200000000000000001",
                channelId: "300000000000000001",
            },
        );

        expect(archived?.guildId).toBe("200000000000000001");
        expect(archived?.sourceUrl).toBe(
            "https://discord.com/channels/200000000000000001/300000000000000001/100000000000000001",
        );
    });
});

describe("Vencord MessageStore collection compatibility", () => {
    test("reads the Vencord 1.14.15 ChannelMessages _array shape", () => {
        const messages = [{ id: "100000000000000001" }, { id: "100000000000000002" }];
        const channelMessages = { _array: messages };

        expect(loadedMessagesFromStore(channelMessages)).toBe(messages);
    });
});

describe("capture accumulation", () => {
    test("deduplicates overlapping snapshots and records a non-overlapping transition", () => {
        const accumulator = createAccumulator();
        const anchors = new Set(["100000000000000003"]);
        const message = (id: string, content = id) => ({
            id,
            guild_id: "200000000000000001",
            channel_id: "300000000000000001",
            content,
        });

        const first = ingestSnapshot(
            accumulator,
            [message("100000000000000001"), message("100000000000000002")],
            anchors,
            { at: "2026-07-18T08:00:00.000Z" },
        );
        const overlap = ingestSnapshot(
            accumulator,
            [message("100000000000000002", "edited"), message("100000000000000003")],
            anchors,
            { at: "2026-07-18T08:01:00.000Z" },
        );
        const repeated = ingestSnapshot(
            accumulator,
            [message("100000000000000002", "edited"), message("100000000000000003")],
            anchors,
            { at: "2026-07-18T08:02:00.000Z" },
        );
        const editedInPlace = ingestSnapshot(
            accumulator,
            [message("100000000000000002", "edited again"), message("100000000000000003")],
            anchors,
            { at: "2026-07-18T08:02:30.000Z" },
        );
        const breakResult = ingestSnapshot(accumulator, [message("100000000000000010")], anchors, {
            at: "2026-07-18T08:03:00.000Z",
        });
        const revisitEarlierViewport = ingestSnapshot(
            accumulator,
            [message("100000000000000001"), message("100000000000000002", "edited again")],
            anchors,
            { at: "2026-07-18T08:04:00.000Z" },
        );

        expect(first.addedMessages).toBe(2);
        expect(overlap.foundKnownOverlap).toBe(true);
        expect(repeated.changed).toBe(false);
        expect(editedInPlace.changed).toBe(true);
        expect(breakResult.introducedBreak).toBe(true);
        expect(revisitEarlierViewport.introducedBreak).toBe(true);
        expect(accumulator.messages.size).toBe(4);
        expect(accumulator.messages.get("100000000000000002")?.content).toBe("edited again");
        expect(accumulator.knownOverlapIds).toEqual(new Set(["100000000000000003"]));
        expect(accumulator.breaks).toHaveLength(2);
        expect(continuousSnapshotSegments(accumulator)).toEqual([
            {
                messageIds: ["100000000000000001", "100000000000000002", "100000000000000003"],
                snapshotCount: 4,
            },
            { messageIds: ["100000000000000010"], snapshotCount: 1 },
        ]);
    });

    test("detects messages that arrive while the previous snapshot is being saved", () => {
        const accumulator = createAccumulator();
        const original = {
            id: "100000000000000001",
            guild_id: "200000000000000001",
            channel_id: "300000000000000001",
            content: "saved",
        };
        ingestSnapshot(accumulator, [original], new Set());

        // flushSession takes this baseline before awaiting native disk I/O.
        const savedBaseline = snapshotAccumulatorBaseline(accumulator);
        const arrivedDuringSave = {
            ...original,
            id: "100000000000000002",
            content: "arrived during save",
        };
        const nextPoll = ingestSnapshot(savedBaseline, [original, arrivedDuringSave], new Set());

        expect(nextPoll.changed).toBe(true);
        expect(nextPoll.addedMessages).toBe(1);
        expect(savedBaseline.messages.get("100000000000000002")?.content).toBe("arrived during save");
        expect(savedBaseline.snapshotCount).toBe(2);
    });

    test("coalesces segments when a later viewport bridges both sides of a loader jump", () => {
        const accumulator = createAccumulator();
        const message = (id: string) => ({
            id,
            guild_id: "200000000000000001",
            channel_id: "300000000000000001",
            content: id,
        });
        ingestSnapshot(accumulator, [message("100000000000000001"), message("100000000000000002")], new Set());
        ingestSnapshot(accumulator, [message("100000000000000010"), message("100000000000000011")], new Set());
        ingestSnapshot(
            accumulator,
            [message("100000000000000002"), message("100000000000000003"), message("100000000000000010")],
            new Set(),
        );

        expect(continuousSnapshotSegments(accumulator)).toEqual([
            {
                messageIds: [
                    "100000000000000001",
                    "100000000000000002",
                    "100000000000000003",
                    "100000000000000010",
                    "100000000000000011",
                ],
                snapshotCount: 3,
            },
        ]);
    });
});
