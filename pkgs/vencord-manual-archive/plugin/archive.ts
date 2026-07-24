export interface ArchiveAuthor {
    id: string;
    username: string | null;
    globalName: string | null;
    bot: boolean;
}

export interface ArchiveMessageContext {
    guildId?: string;
    channelId?: string;
}

export interface ArchiveMessage {
    id: string;
    guildId: string | null;
    channelId: string;
    type: number | null;
    timestamp: string | null;
    editedTimestamp: string | null;
    content: string;
    author: ArchiveAuthor | null;
    mentions: ArchiveAuthor[];
    mentionRoleIds: string[];
    attachments: Array<{
        id: string;
        filename: string | null;
        description: string | null;
        contentType: string | null;
        size: number | null;
        width: number | null;
        height: number | null;
        durationSeconds: number | null;
        ephemeral: boolean;
    }>;
    embeds: Array<{
        type: string | null;
        title: string | null;
        description: string | null;
        url: string | null;
        timestamp: string | null;
        provider: { name: string | null; url: string | null } | null;
        author: { name: string | null; url: string | null } | null;
        footer: { text: string | null } | null;
        fields: Array<{ name: string; value: string; inline: boolean }>;
    }>;
    reactions: Array<{
        emoji: { id: string | null; name: string | null; animated: boolean };
        count: number;
        me: boolean;
    }>;
    stickers: Array<{ id: string; name: string | null; formatType: number | null }>;
    reference: {
        messageId: string | null;
        channelId: string | null;
        guildId: string | null;
    } | null;
    referencedMessage: {
        id: string;
        channelId: string | null;
        timestamp: string | null;
        content: string;
        author: ArchiveAuthor | null;
    } | null;
    interaction: { id: string | null; name: string | null; user: ArchiveAuthor | null } | null;
    thread: { id: string; name: string | null } | null;
    flags: number | null;
    pinned: boolean;
    tts: boolean;
    sourceUrl: string | null;
}

export interface SnapshotBreak {
    at: string;
    previousOldestId: string;
    previousNewestId: string;
    nextOldestId: string;
    nextNewestId: string;
}

export interface ContinuousSnapshotSegment {
    messageIds: Set<string>;
    snapshotCount: number;
}

export interface CaptureAccumulator {
    messages: Map<string, ArchiveMessage>;
    lastSnapshotIds: Set<string>;
    lastSnapshotFingerprint: string | null;
    snapshotCount: number;
    breaks: SnapshotBreak[];
    segments: ContinuousSnapshotSegment[];
    knownOverlapIds: Set<string>;
}

export interface SnapshotResult {
    changed: boolean;
    addedMessages: number;
    foundKnownOverlap: boolean;
    introducedBreak: boolean;
}

export interface SnapshotOptions extends ArchiveMessageContext {
    at?: string;
}

function nullableString(value: unknown): string | null {
    return typeof value === "string" ? value : null;
}

function nullableNumber(value: unknown): number | null {
    return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function boolean(value: unknown): boolean {
    return value === true;
}

function objectOrNull(value: unknown): Record<string, unknown> | null {
    if (value == null || typeof value !== "object" || Array.isArray(value)) return null;
    return value as Record<string, unknown>;
}

function isoTimestamp(value: unknown): string | null {
    if (value == null) return null;
    if (typeof value === "string") return value;
    if (typeof value === "number") return new Date(value).toISOString();
    const candidate = objectOrNull(value);
    if (!candidate) return null;
    if (typeof candidate.toISOString === "function") {
        const result: unknown = Reflect.apply(candidate.toISOString, value, []);
        return nullableString(result);
    }
    if (typeof candidate.toDate === "function") {
        const result: unknown = Reflect.apply(candidate.toDate, value, []);
        return isoTimestamp(result);
    }
    return null;
}

function arrayFrom(value: unknown): unknown[] {
    if (value == null) return [];
    if (Array.isArray(value)) return value;
    const candidate = objectOrNull(value);
    if (!candidate) return [];
    if (typeof candidate.toArray === "function") {
        const result: unknown = Reflect.apply(candidate.toArray, value, []);
        return Array.isArray(result) ? result : [];
    }
    if (typeof candidate.values === "function") {
        const result: unknown = Reflect.apply(candidate.values, value, []);
        if (result != null && typeof result === "object" && Symbol.iterator in result) {
            return Array.from(result as Iterable<unknown>);
        }
    }
    return [];
}

export function loadedMessagesFromStore(value: unknown): unknown[] {
    if (Array.isArray(value)) return value;
    const collection = objectOrNull(value);
    if (!collection) return [];
    if (Array.isArray(collection._array)) return collection._array;
    if (typeof collection.toArray === "function") {
        const result: unknown = Reflect.apply(collection.toArray, value, []);
        if (Array.isArray(result)) return result;
    }
    if (typeof collection.forEach !== "function") return [];
    const messages: unknown[] = [];
    Reflect.apply(collection.forEach, value, [(message: unknown) => messages.push(message)]);
    return messages;
}

function sanitizeAuthor(value: unknown): ArchiveAuthor | null {
    const author = objectOrNull(value);
    if (!author || typeof author.id !== "string") return null;
    return {
        id: author.id,
        username: nullableString(author.username),
        globalName: nullableString(author.globalName ?? author.global_name),
        bot: boolean(author.bot),
    };
}

function sanitizeExternalUrl(value: unknown): string | null {
    if (typeof value !== "string") return null;
    try {
        const url = new URL(value);
        if (url.protocol !== "http:" && url.protocol !== "https:") return null;
        return url.toString();
    } catch {
        return null;
    }
}

function sanitizeReferencedMessage(value: unknown): ArchiveMessage["referencedMessage"] {
    const message = objectOrNull(value);
    if (!message || typeof message.id !== "string") return null;
    return {
        id: message.id,
        channelId: nullableString(message.channel_id ?? message.channelId),
        timestamp: isoTimestamp(message.timestamp),
        content: typeof message.content === "string" ? message.content : "",
        author: sanitizeAuthor(message.author),
    };
}

export function compareSnowflakes(left: string, right: string): number {
    if (left.length !== right.length) return left.length - right.length;
    return left < right ? -1 : left > right ? 1 : 0;
}

export function sanitizeMessage(value: unknown, context: ArchiveMessageContext = {}): ArchiveMessage | null {
    const message = objectOrNull(value);
    if (!message || typeof message.id !== "string") return null;
    const channelId = nullableString(message.channel_id ?? message.channelId) ?? context.channelId ?? null;
    if (!channelId) return null;
    const guildId = nullableString(message.guild_id ?? message.guildId) ?? context.guildId ?? null;
    const reference = objectOrNull(message.message_reference ?? message.messageReference);
    const interaction = objectOrNull(message.interaction ?? message.interaction_metadata);
    const thread = objectOrNull(message.thread);

    return {
        id: message.id,
        guildId,
        channelId,
        type: nullableNumber(message.type),
        timestamp: isoTimestamp(message.timestamp),
        editedTimestamp: isoTimestamp(message.edited_timestamp ?? message.editedTimestamp),
        content: typeof message.content === "string" ? message.content : "",
        author: sanitizeAuthor(message.author),
        mentions: arrayFrom(message.mentions)
            .map(sanitizeAuthor)
            .filter((author): author is ArchiveAuthor => author != null),
        mentionRoleIds: arrayFrom(message.mention_roles ?? message.mentionRoleIds).filter(
            (roleId): roleId is string => typeof roleId === "string",
        ),
        attachments: arrayFrom(message.attachments).flatMap((value) => {
            const attachment = objectOrNull(value);
            if (!attachment || typeof attachment.id !== "string") return [];
            return [
                {
                    id: attachment.id,
                    filename: nullableString(attachment.filename),
                    description: nullableString(attachment.description),
                    contentType: nullableString(attachment.content_type ?? attachment.contentType),
                    size: nullableNumber(attachment.size),
                    width: nullableNumber(attachment.width),
                    height: nullableNumber(attachment.height),
                    durationSeconds: nullableNumber(attachment.duration_secs ?? attachment.durationSeconds),
                    ephemeral: boolean(attachment.ephemeral),
                },
            ];
        }),
        embeds: arrayFrom(message.embeds).map((value) => {
            const embed = objectOrNull(value);
            const provider = objectOrNull(embed?.provider);
            const author = objectOrNull(embed?.author);
            const footer = objectOrNull(embed?.footer);
            return {
                type: nullableString(embed?.type),
                title: nullableString(embed?.title),
                description: nullableString(embed?.description),
                url: sanitizeExternalUrl(embed?.url),
                timestamp: isoTimestamp(embed?.timestamp),
                provider: provider
                    ? {
                          name: nullableString(provider.name),
                          url: sanitizeExternalUrl(provider.url),
                      }
                    : null,
                author: author
                    ? {
                          name: nullableString(author.name),
                          url: sanitizeExternalUrl(author.url),
                      }
                    : null,
                footer: footer ? { text: nullableString(footer.text) } : null,
                fields: arrayFrom(embed?.fields).flatMap((value) => {
                    const field = objectOrNull(value);
                    if (typeof field?.name !== "string" || typeof field.value !== "string") return [];
                    return [{ name: field.name, value: field.value, inline: boolean(field.inline) }];
                }),
            };
        }),
        reactions: arrayFrom(message.reactions).flatMap((value) => {
            const reaction = objectOrNull(value);
            const emoji = objectOrNull(reaction?.emoji);
            if (!reaction || !emoji) return [];
            return [
                {
                    emoji: {
                        id: nullableString(emoji.id),
                        name: nullableString(emoji.name),
                        animated: boolean(emoji.animated),
                    },
                    count: nullableNumber(reaction.count) ?? 0,
                    me: boolean(reaction.me),
                },
            ];
        }),
        stickers: arrayFrom(message.sticker_items ?? message.stickerItems).flatMap((value) => {
            const sticker = objectOrNull(value);
            if (!sticker || typeof sticker.id !== "string") return [];
            return [
                {
                    id: sticker.id,
                    name: nullableString(sticker.name),
                    formatType: nullableNumber(sticker.format_type ?? sticker.formatType),
                },
            ];
        }),
        reference: reference
            ? {
                  messageId: nullableString(reference.message_id ?? reference.messageId),
                  channelId: nullableString(reference.channel_id ?? reference.channelId),
                  guildId: nullableString(reference.guild_id ?? reference.guildId),
              }
            : null,
        referencedMessage: sanitizeReferencedMessage(message.referenced_message ?? message.referencedMessage),
        interaction: interaction
            ? {
                  id: nullableString(interaction.id),
                  name: nullableString(interaction.name),
                  user: sanitizeAuthor(interaction.user),
              }
            : null,
        thread:
            thread && typeof thread.id === "string"
                ? {
                      id: thread.id,
                      name: nullableString(thread.name),
                  }
                : null,
        flags: nullableNumber(message.flags),
        pinned: boolean(message.pinned),
        tts: boolean(message.tts),
        sourceUrl: guildId ? `https://discord.com/channels/${guildId}/${channelId}/${message.id}` : null,
    };
}

export function continuousSnapshotSegments(
    accumulator: CaptureAccumulator,
): Array<{ messageIds: string[]; snapshotCount: number }> {
    return accumulator.segments
        .map((segment) => ({
            messageIds: Array.from(segment.messageIds).sort(compareSnowflakes),
            snapshotCount: segment.snapshotCount,
        }))
        .filter((segment) => segment.messageIds.length > 0);
}

export function createAccumulator(): CaptureAccumulator {
    return {
        messages: new Map(),
        lastSnapshotIds: new Set(),
        lastSnapshotFingerprint: null,
        snapshotCount: 0,
        breaks: [],
        segments: [],
        knownOverlapIds: new Set(),
    };
}

export function snapshotAccumulatorBaseline(accumulator: CaptureAccumulator): CaptureAccumulator {
    const lastSnapshotIds = new Set(accumulator.lastSnapshotIds);
    const messages = new Map<string, ArchiveMessage>();
    for (const id of lastSnapshotIds) {
        const message = accumulator.messages.get(id);
        if (message) messages.set(id, message);
    }
    return {
        messages,
        lastSnapshotIds,
        lastSnapshotFingerprint: accumulator.lastSnapshotFingerprint,
        snapshotCount: lastSnapshotIds.size > 0 ? 1 : 0,
        breaks: [],
        segments: lastSnapshotIds.size > 0 ? [{ messageIds: lastSnapshotIds, snapshotCount: 1 }] : [],
        knownOverlapIds: new Set(accumulator.knownOverlapIds),
    };
}

function sameSet(left: Set<string>, right: Set<string>): boolean {
    if (left.size !== right.size) return false;
    for (const value of left) if (!right.has(value)) return false;
    return true;
}

function intersects(left: Set<string>, right: Set<string>): boolean {
    for (const value of left) if (right.has(value)) return true;
    return false;
}

function bounds(ids: Set<string>): [string, string] {
    const sorted = Array.from(ids).sort(compareSnowflakes);
    return [sorted[0], sorted[sorted.length - 1]];
}

export function ingestSnapshot(
    accumulator: CaptureAccumulator,
    rawMessages: unknown[],
    knownAnchorIds: Set<string>,
    options: SnapshotOptions = {},
): SnapshotResult {
    const at = options.at ?? new Date().toISOString();
    const serialized = rawMessages
        .map((message) => sanitizeMessage(message, options))
        .filter((message): message is ArchiveMessage => message != null);
    const currentIds = new Set(serialized.map((message) => message.id));
    if (currentIds.size === 0) {
        return { changed: false, addedMessages: 0, foundKnownOverlap: false, introducedBreak: false };
    }
    const fingerprint = JSON.stringify(serialized);
    if (sameSet(currentIds, accumulator.lastSnapshotIds) && fingerprint === accumulator.lastSnapshotFingerprint) {
        return { changed: false, addedMessages: 0, foundKnownOverlap: false, introducedBreak: false };
    }

    const introducedBreak =
        accumulator.lastSnapshotIds.size > 0 && !intersects(currentIds, accumulator.lastSnapshotIds);
    if (introducedBreak) {
        const [previousOldestId, previousNewestId] = bounds(accumulator.lastSnapshotIds);
        const [nextOldestId, nextNewestId] = bounds(currentIds);
        accumulator.breaks.push({ at, previousOldestId, previousNewestId, nextOldestId, nextNewestId });
    }

    let overlappingSegment: ContinuousSnapshotSegment | null = null;
    const retainedSegments: ContinuousSnapshotSegment[] = [];
    for (const segment of accumulator.segments) {
        if (!intersects(currentIds, segment.messageIds)) {
            retainedSegments.push(segment);
            continue;
        }
        if (overlappingSegment == null) {
            overlappingSegment = segment;
            retainedSegments.push(segment);
            continue;
        }
        for (const id of segment.messageIds) overlappingSegment.messageIds.add(id);
        overlappingSegment.snapshotCount += segment.snapshotCount;
    }
    if (overlappingSegment == null) {
        retainedSegments.push({ messageIds: new Set(currentIds), snapshotCount: 1 });
    } else {
        for (const id of currentIds) overlappingSegment.messageIds.add(id);
        overlappingSegment.snapshotCount++;
    }
    accumulator.segments = retainedSegments;

    let addedMessages = 0;
    for (const message of serialized) {
        if (!accumulator.messages.has(message.id)) addedMessages++;
        accumulator.messages.set(message.id, message);
    }

    let foundKnownOverlap = false;
    for (const id of currentIds) {
        if (!knownAnchorIds.has(id)) continue;
        foundKnownOverlap ||= !accumulator.knownOverlapIds.has(id);
        accumulator.knownOverlapIds.add(id);
    }

    accumulator.lastSnapshotIds = currentIds;
    accumulator.lastSnapshotFingerprint = fingerprint;
    accumulator.snapshotCount++;
    return { changed: true, addedMessages, foundKnownOverlap, introducedBreak };
}
