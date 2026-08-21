import type {
  AuthenticatedSession,
  KithChange,
  KithInteractionPayload,
  KithMutation,
  KithMutationResult,
  KithPersonPayload,
  KithPullOutput,
  KithPushOutput,
} from "../../contracts";
import {
  HTTPError,
  optionalString,
  requireEnum,
  requireInteger,
  requireISODate,
  requireRecord,
  requireString,
  requireUUID,
} from "../../http";

interface VersionRow {
  version: number;
  payload_json: string;
}

interface StoredMutationRow {
  response_json: string;
}

interface SequenceRow {
  sequence: number;
}

interface ChangeRow {
  sequence: number;
  entity_type: "person" | "interaction";
  entity_id: string;
  operation: "upsert" | "delete";
  version: number;
  changed_at: string;
  payload_json: string;
}

const entityTypes = ["person", "interaction"] as const;
const operations = ["upsert", "delete"] as const;
const circles = ["family", "close", "friends", "work", "other"] as const;
const hues = ["clay", "apricot", "honey", "rose", "rust", "sand", "sage"] as const;
const interactionKinds = [
  "note",
  "hangout",
  "call",
  "message",
  "gift",
  "milestone",
  "remember",
] as const;

export async function pushKithMutations(
  env: Pick<Env, "DB">,
  session: AuthenticatedSession,
  input: Record<string, unknown>,
): Promise<KithPushOutput> {
  if (!Array.isArray(input.mutations) || input.mutations.length === 0 || input.mutations.length > 100) {
    throw new HTTPError(400, "INVALID_INPUT", "Provide between 1 and 100 Kith mutations.");
  }
  const mutations = input.mutations.map(parseMutation);
  const results: KithMutationResult[] = [];
  for (const mutation of mutations) {
    results.push(await applyMutation(env.DB, session, mutation));
  }
  const cursor = await latestCursor(env.DB, session.userId);
  return { results, cursor, synchronizedAt: new Date().toISOString() };
}

export async function pullKithChanges(
  env: Pick<Env, "DB">,
  session: AuthenticatedSession,
  url: URL,
): Promise<KithPullOutput> {
  const cursorValue = Number(url.searchParams.get("cursor") ?? "0");
  const limitValue = Number(url.searchParams.get("limit") ?? "100");
  if (!Number.isInteger(cursorValue) || cursorValue < 0) {
    throw new HTTPError(400, "INVALID_CURSOR", "The synchronization cursor is invalid.");
  }
  if (!Number.isInteger(limitValue) || limitValue < 1 || limitValue > 200) {
    throw new HTTPError(400, "INVALID_LIMIT", "The synchronization limit must be 1 to 200.");
  }

  const { results } = await env.DB.prepare(
    `SELECT sequence, entity_type, entity_id, operation, version, changed_at, payload_json
     FROM sync_changes
     WHERE user_id = ? AND domain = 'kith' AND sequence > ?
     ORDER BY sequence ASC
     LIMIT ?`,
  )
    .bind(session.userId, cursorValue, limitValue + 1)
    .all<ChangeRow>();
  const visibleRows = results.slice(0, limitValue);
  const changes = visibleRows.map(parseChangeRow);
  return {
    changes,
    cursor: changes.at(-1)?.sequence ?? cursorValue,
    hasMore: results.length > limitValue,
    synchronizedAt: new Date().toISOString(),
  };
}

async function applyMutation(
  database: D1Database,
  session: AuthenticatedSession,
  mutation: KithMutation,
): Promise<KithMutationResult> {
  const existingMutation = await database
    .prepare(
      "SELECT response_json FROM sync_mutations WHERE user_id = ? AND idempotency_key = ?",
    )
    .bind(session.userId, mutation.idempotencyKey)
    .first<StoredMutationRow>();
  if (existingMutation) {
    const acceptedResult = parseStoredMutationResult(existingMutation.response_json);
    return {
      ...acceptedResult,
      status: "duplicate",
      message: "This mutation was already accepted.",
    };
  }

  const current = await currentVersion(database, session.userId, mutation);
  if (
    (current === null && mutation.baseVersion !== 0) ||
    (current !== null && current.version !== mutation.baseVersion)
  ) {
    const conflictResult: KithMutationResult = {
      idempotencyKey: mutation.idempotencyKey,
      entityType: mutation.entityType,
      entityId: mutation.payload.id,
      status: "conflict",
      version: current?.version ?? null,
      sequence: null,
      message: "The server record changed after this device last synchronized.",
      ...(current ? { serverRecord: parseServerRecord(mutation.entityType, current.payload_json) } : {}),
    };
    await rememberMutation(database, session, conflictResult);
    return conflictResult;
  }

  const acceptedVersion = mutation.baseVersion + 1;
  const acceptedAt = new Date().toISOString();
  const acceptedPayload = canonicalPayload(
    mutation,
    session.deviceId,
    acceptedVersion,
    acceptedAt,
  );
  const mutationResult = await writeEntity(
    database,
    session.userId,
    mutation,
    acceptedPayload,
  );
  // D1 includes trigger writes in `meta.changes`; every accepted Kith write also
  // appends one sync_changes row, so success is any positive change count.
  if (!mutationResult.success || mutationResult.meta.changes < 1) {
    const racedCurrent = await currentVersion(database, session.userId, mutation);
    const conflictResult: KithMutationResult = {
      idempotencyKey: mutation.idempotencyKey,
      entityType: mutation.entityType,
      entityId: mutation.payload.id,
      status: "conflict",
      version: racedCurrent?.version ?? null,
      sequence: null,
      message: "A concurrent update won. Pull the latest record before retrying.",
      ...(racedCurrent
        ? { serverRecord: parseServerRecord(mutation.entityType, racedCurrent.payload_json) }
        : {}),
    };
    await rememberMutation(database, session, conflictResult);
    return conflictResult;
  }

  const sequence = await database
    .prepare(
      `SELECT sequence FROM sync_changes
       WHERE user_id = ? AND domain = 'kith' AND entity_type = ? AND entity_id = ? AND version = ?
       ORDER BY sequence DESC LIMIT 1`,
    )
    .bind(
      session.userId,
      mutation.entityType,
      mutation.payload.id,
      acceptedVersion,
    )
    .first<SequenceRow>();
  const acceptedResult: KithMutationResult = {
    idempotencyKey: mutation.idempotencyKey,
    entityType: mutation.entityType,
    entityId: mutation.payload.id,
    status: "accepted",
    version: acceptedVersion,
    sequence: sequence?.sequence ?? null,
    message: mutation.operation === "delete" ? "Deletion synchronized." : "Record synchronized.",
    serverRecord: acceptedPayload,
  };
  await rememberMutation(database, session, acceptedResult);
  await recordLifeEventForMutation(database, session, mutation, acceptedPayload, acceptedAt);
  return acceptedResult;
}

function parseMutation(value: unknown): KithMutation {
  const record = requireRecord(value, "mutation");
  const entityType = requireEnum(record.entityType, "mutation.entityType", entityTypes);
  const operation = requireEnum(record.operation, "mutation.operation", operations);
  const payloadRecord = requireRecord(record.payload, "mutation.payload");
  const payload = entityType === "person" ? parsePerson(payloadRecord) : parseInteraction(payloadRecord);
  if (operation === "delete" && payload.deletedAt === null) {
    throw new HTTPError(400, "INVALID_INPUT", "A delete mutation requires deletedAt.");
  }
  return {
    idempotencyKey: requireString(record.idempotencyKey, "mutation.idempotencyKey", 200),
    entityType,
    operation,
    baseVersion: requireInteger(record.baseVersion, "mutation.baseVersion", 0, 2_147_483_647),
    payload,
  };
}

function parsePerson(value: Record<string, unknown>): KithPersonPayload {
  return {
    id: requireUUID(value.id, "person.id"),
    name: requireString(value.name, "person.name", 120),
    howWeMet: requireString(value.howWeMet, "person.howWeMet", 4_000, true),
    circle: requireEnum(value.circle, "person.circle", circles),
    closeness: requireInteger(value.closeness, "person.closeness", 1, 5),
    hue: requireEnum(value.hue, "person.hue", hues),
    birthday: optionalString(value.birthday, "person.birthday", 40),
    standingNotes: requireString(value.standingNotes, "person.standingNotes", 20_000, true),
    createdAt: requireISODate(value.createdAt, "person.createdAt"),
    updatedAt: requireISODate(value.updatedAt, "person.updatedAt"),
    deletedAt:
      value.deletedAt === null || value.deletedAt === undefined
        ? null
        : requireISODate(value.deletedAt, "person.deletedAt"),
    version: requireInteger(value.version, "person.version", 0, 2_147_483_647),
    originDeviceId: requireUUID(value.originDeviceId, "person.originDeviceId"),
  };
}

function parseInteraction(value: Record<string, unknown>): KithInteractionPayload {
  return {
    id: requireUUID(value.id, "interaction.id"),
    personId: requireUUID(value.personId, "interaction.personId"),
    kind: requireEnum(value.kind, "interaction.kind", interactionKinds),
    happenedOn: requireISODate(value.happenedOn, "interaction.happenedOn"),
    body: requireString(value.body, "interaction.body", 20_000),
    createdAt: requireISODate(value.createdAt, "interaction.createdAt"),
    updatedAt: requireISODate(value.updatedAt, "interaction.updatedAt"),
    deletedAt:
      value.deletedAt === null || value.deletedAt === undefined
        ? null
        : requireISODate(value.deletedAt, "interaction.deletedAt"),
    version: requireInteger(value.version, "interaction.version", 0, 2_147_483_647),
    originDeviceId: requireUUID(value.originDeviceId, "interaction.originDeviceId"),
  };
}

function canonicalPayload(
  mutation: KithMutation,
  originDeviceId: string,
  acceptedVersion: number,
  acceptedAt: string,
): KithPersonPayload | KithInteractionPayload {
  return {
    ...mutation.payload,
    updatedAt: acceptedAt,
    deletedAt: mutation.operation === "delete" ? acceptedAt : null,
    version: acceptedVersion,
    originDeviceId,
  };
}

async function currentVersion(
  database: D1Database,
  userId: string,
  mutation: KithMutation,
): Promise<VersionRow | null> {
  const table = mutation.entityType === "person" ? "kith_people" : "kith_interactions";
  const changeEntity = mutation.entityType;
  return database
    .prepare(
      `SELECT ${table}.version,
         (SELECT payload_json FROM sync_changes
          WHERE user_id = ${table}.user_id AND entity_type = ? AND entity_id = ${table}.id
          ORDER BY sequence DESC LIMIT 1) AS payload_json
       FROM ${table} WHERE user_id = ? AND id = ?`,
    )
    .bind(changeEntity, userId, mutation.payload.id)
    .first<VersionRow>();
}

function writeEntity(
  database: D1Database,
  userId: string,
  mutation: KithMutation,
  payload: KithPersonPayload | KithInteractionPayload,
): Promise<D1Result<unknown>> {
  if (mutation.entityType === "person") {
    const person = payload as KithPersonPayload;
    if (mutation.baseVersion === 0) {
      return database
        .prepare(
          `INSERT OR IGNORE INTO kith_people
           (id, user_id, name, how_we_met, circle, closeness, hue, birthday, standing_notes,
            created_at, updated_at, deleted_at, version, origin_device_id)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .bind(
          person.id,
          userId,
          person.name,
          person.howWeMet,
          person.circle,
          person.closeness,
          person.hue,
          person.birthday,
          person.standingNotes,
          person.createdAt,
          person.updatedAt,
          person.deletedAt,
          person.version,
          person.originDeviceId,
        )
        .run();
    }
    return database
      .prepare(
        `UPDATE kith_people SET
           name = ?, how_we_met = ?, circle = ?, closeness = ?, hue = ?, birthday = ?,
           standing_notes = ?, updated_at = ?, deleted_at = ?, version = ?, origin_device_id = ?
         WHERE user_id = ? AND id = ? AND version = ?`,
      )
      .bind(
        person.name,
        person.howWeMet,
        person.circle,
        person.closeness,
        person.hue,
        person.birthday,
        person.standingNotes,
        person.updatedAt,
        person.deletedAt,
        person.version,
        person.originDeviceId,
        userId,
        person.id,
        mutation.baseVersion,
      )
      .run();
  }

  const interaction = payload as KithInteractionPayload;
  if (mutation.baseVersion === 0) {
    return database
      .prepare(
        `INSERT OR IGNORE INTO kith_interactions
         (id, user_id, person_id, kind, happened_on, body, created_at, updated_at,
          deleted_at, version, origin_device_id)
         SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
         WHERE EXISTS (
           SELECT 1 FROM kith_people WHERE user_id = ? AND id = ? AND deleted_at IS NULL
         )`,
      )
      .bind(
        interaction.id,
        userId,
        interaction.personId,
        interaction.kind,
        interaction.happenedOn,
        interaction.body,
        interaction.createdAt,
        interaction.updatedAt,
        interaction.deletedAt,
        interaction.version,
        interaction.originDeviceId,
        userId,
        interaction.personId,
      )
      .run();
  }
  return database
    .prepare(
      `UPDATE kith_interactions SET
         person_id = ?, kind = ?, happened_on = ?, body = ?, updated_at = ?, deleted_at = ?,
         version = ?, origin_device_id = ?
       WHERE user_id = ? AND id = ? AND version = ?`,
    )
    .bind(
      interaction.personId,
      interaction.kind,
      interaction.happenedOn,
      interaction.body,
      interaction.updatedAt,
      interaction.deletedAt,
      interaction.version,
      interaction.originDeviceId,
      userId,
      interaction.id,
      mutation.baseVersion,
    )
    .run();
}

async function rememberMutation(
  database: D1Database,
  session: AuthenticatedSession,
  result: KithMutationResult,
): Promise<void> {
  await database
    .prepare(
      `INSERT OR IGNORE INTO sync_mutations
       (idempotency_key, user_id, device_id, domain, response_json, created_at)
       VALUES (?, ?, ?, 'kith', ?, ?)`,
    )
    .bind(
      result.idempotencyKey,
      session.userId,
      session.deviceId,
      JSON.stringify(result),
      new Date().toISOString(),
    )
    .run();
}

async function recordLifeEventForMutation(
  database: D1Database,
  session: AuthenticatedSession,
  mutation: KithMutation,
  payload: KithPersonPayload | KithInteractionPayload,
  recordedAt: string,
): Promise<void> {
  if (mutation.entityType !== "interaction") return;
  const interaction = payload as KithInteractionPayload;
  const person = await database
    .prepare("SELECT name FROM kith_people WHERE user_id = ? AND id = ?")
    .bind(session.userId, interaction.personId)
    .first<{ name: string }>();
  if (!person) return;
  await database
    .prepare(
      `INSERT INTO life_events
       (id, user_id, domain, event_type, entity_id, occurred_at, recorded_at, actor, summary, metadata_json)
       VALUES (?, ?, 'kith', ?, ?, ?, ?, 'kith', ?, ?)`,
    )
    .bind(
      crypto.randomUUID(),
      session.userId,
      mutation.operation === "delete" ? "kith.interaction_deleted" : "kith.interaction_recorded",
      interaction.id,
      interaction.happenedOn,
      recordedAt,
      mutation.operation === "delete"
        ? `Removed an interaction with ${person.name}.`
        : `Recorded a ${interaction.kind} with ${person.name}.`,
      JSON.stringify({ personId: interaction.personId, kind: interaction.kind }),
    )
    .run();
}

async function latestCursor(database: D1Database, userId: string): Promise<number> {
  const row = await database
    .prepare(
      "SELECT COALESCE(MAX(sequence), 0) AS sequence FROM sync_changes WHERE user_id = ? AND domain = 'kith'",
    )
    .bind(userId)
    .first<SequenceRow>();
  return row?.sequence ?? 0;
}

function parseStoredMutationResult(value: string): KithMutationResult {
  const parsed: unknown = JSON.parse(value);
  return parsed as KithMutationResult;
}

function parseServerRecord(
  entityType: "person" | "interaction",
  value: string,
): KithPersonPayload | KithInteractionPayload {
  const parsed: unknown = JSON.parse(value);
  const record = requireRecord(parsed, "stored Kith record");
  return entityType === "person" ? parsePerson(record) : parseInteraction(record);
}

function parseChangeRow(row: ChangeRow): KithChange {
  return {
    sequence: row.sequence,
    entityType: row.entity_type,
    entityId: row.entity_id,
    operation: row.operation,
    version: row.version,
    changedAt: row.changed_at,
    payload: parseServerRecord(row.entity_type, row.payload_json),
  };
}
