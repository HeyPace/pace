import { verifyCalorieCredentialForSession } from "./auth";
import type { AuthenticatedSession, ToolActionResult } from "./contracts";
import {
  HTTPError,
  optionalString,
  requireEnum,
  requireISODate,
  requireRecord,
  requireString,
  requireUUID,
} from "./http";

type PlatformEnvironment = Pick<Env, "DB"> & {
  CALORIE_SERVICE: Pick<Fetcher, "fetch">;
};

interface AuditRow {
  id: string;
  domain: "calorie" | "kith";
  tool_name: string;
  status: "pending" | "succeeded" | "failed" | "undone";
  created_at: string;
  completed_at: string | null;
  after_json: string | null;
  undo_payload: string | null;
  undone_at: string | null;
}

interface KithPersonRow {
  id: string;
  name: string;
  circle: string;
  closeness: number;
  last_interaction_at: string | null;
}

interface KithInteractionRow {
  id: string;
  person_id: string;
  kind: string;
  happened_on: string;
  body: string;
  version: number;
  deleted_at: string | null;
}

const interactionKinds = [
  "note",
  "hangout",
  "call",
  "message",
  "gift",
  "milestone",
  "remember",
] as const;

export async function getCalorieToday(
  request: Request,
  env: PlatformEnvironment,
  session: AuthenticatedSession,
  url: URL,
): Promise<unknown> {
  const calorieToken = await verifyCalorieCredentialForSession(
    request,
    session,
    env.CALORIE_SERVICE,
  );
  const timezone = url.searchParams.get("timezone")?.slice(0, 100) || "UTC";
  const date = url.searchParams.get("date")?.slice(0, 10) || new Date().toISOString().slice(0, 10);
  const start = Date.parse(`${date}T00:00:00.000Z`);
  const end = start + 86_400_000;
  const dashboardURL = new URL("https://calorie.significanthobbies.com/api/app/dashboard");
  dashboardURL.searchParams.set("start", String(start));
  dashboardURL.searchParams.set("end", String(end));
  dashboardURL.searchParams.set("date", date);
  dashboardURL.searchParams.set("timezone", timezone);
  const dashboard = await calorieServiceJSON(
    env.CALORIE_SERVICE,
    calorieToken,
    dashboardURL,
  );
  const dashboardRecord = requireRecord(dashboard, "Calorie dashboard");
  return {
    application: "calorie",
    synchronizedAt: new Date().toISOString(),
    provenance: "Calorie authenticated domain service via Cloudflare service binding",
    dashboard: dashboardRecord,
  };
}

export async function getKithPeopleNeedingAttention(
  env: Pick<Env, "DB">,
  session: AuthenticatedSession,
): Promise<unknown> {
  const { results } = await env.DB.prepare(
    `SELECT
       people.id,
       people.name,
       people.circle,
       people.closeness,
       MAX(interactions.happened_on) AS last_interaction_at
     FROM kith_people AS people
     LEFT JOIN kith_interactions AS interactions
       ON interactions.user_id = people.user_id
       AND interactions.person_id = people.id
       AND interactions.deleted_at IS NULL
     WHERE people.user_id = ? AND people.deleted_at IS NULL
     GROUP BY people.id, people.name, people.circle, people.closeness
     ORDER BY people.closeness DESC, last_interaction_at ASC, people.name ASC
     LIMIT 100`,
  )
    .bind(session.userId)
    .all<KithPersonRow>();
  const now = Date.now();
  const people = results.map((person) => {
    const attentionAfterDays = attentionCadenceDays(person.closeness);
    const daysSinceInteraction = person.last_interaction_at
      ? Math.max(0, Math.floor((now - Date.parse(person.last_interaction_at)) / 86_400_000))
      : null;
    return {
      id: person.id,
      name: person.name,
      circle: person.circle,
      closeness: person.closeness,
      lastInteractionAt: person.last_interaction_at,
      daysSinceInteraction,
      attentionAfterDays,
      attentionRequired:
        daysSinceInteraction === null || daysSinceInteraction >= attentionAfterDays,
    };
  });
  const lastSync = await env.DB.prepare(
    "SELECT MAX(changed_at) AS changed_at FROM sync_changes WHERE user_id = ? AND domain = 'kith'",
  )
    .bind(session.userId)
    .first<{ changed_at: string | null }>();
  return {
    application: "kith",
    synchronizedAt: lastSync?.changed_at ?? null,
    provenance: "Kith domain records in Personal Platform D1",
    cadencePolicy: "Explicit closeness maps to a transparent attention cadence; recency never changes closeness.",
    people,
    attentionRequired: people.filter((person) => person.attentionRequired),
  };
}

export async function executeKithRecordInteraction(
  env: Pick<Env, "DB">,
  session: AuthenticatedSession,
  input: Record<string, unknown>,
): Promise<ToolActionResult> {
  const idempotencyKey = requireString(input.idempotencyKey, "idempotencyKey", 200);
  const originalInstruction = requireString(
    input.originalInstruction,
    "originalInstruction",
    2_000,
  );
  const existing = await findAudit(env.DB, session.userId, idempotencyKey);
  if (existing) return resultFromAudit(existing);

  const person = await resolveKithPerson(env.DB, session.userId, input);
  const kind = requireEnum(input.kind ?? "note", "kind", interactionKinds);
  const body = requireString(input.body, "body", 20_000);
  const happenedOn = input.happenedOn
    ? requireISODate(input.happenedOn, "happenedOn")
    : new Date().toISOString();
  const createdAt = new Date().toISOString();
  const actionId = crypto.randomUUID();
  const interactionId = crypto.randomUUID();
  const result: ToolActionResult = {
    actionId,
    domain: "kith",
    toolName: "kith.record_interaction",
    status: "succeeded",
    occurredAt: happenedOn,
    message: `Recorded a ${kind} with ${person.name} in Kith.`,
    undo: { actionId, expiresAt: null },
  };
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO kith_interactions
       (id, user_id, person_id, kind, happened_on, body, created_at, updated_at,
        deleted_at, version, origin_device_id)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, 1, ?)`,
    ).bind(
      interactionId,
      session.userId,
      person.id,
      kind,
      happenedOn,
      body,
      createdAt,
      createdAt,
      session.deviceId,
    ),
    env.DB.prepare(
      `INSERT INTO pace_actions
       (id, user_id, domain, tool_name, input_json, original_instruction, idempotency_key,
        status, created_at, completed_at, before_json, after_json, undo_payload, undone_at, error_message)
       VALUES (?, ?, 'kith', 'kith.record_interaction', ?, ?, ?, 'succeeded', ?, ?, NULL, ?, ?, NULL, NULL)`,
    ).bind(
      actionId,
      session.userId,
      JSON.stringify(redactedActionInput(input)),
      originalInstruction,
      idempotencyKey,
      createdAt,
      createdAt,
      JSON.stringify(result),
      JSON.stringify({ domain: "kith", interactionId }),
    ),
    env.DB.prepare(
      `INSERT INTO life_events
       (id, user_id, domain, event_type, entity_id, occurred_at, recorded_at, actor, summary, metadata_json)
       VALUES (?, ?, 'kith', 'kith.interaction_recorded', ?, ?, ?, 'pace', ?, ?)`,
    ).bind(
      crypto.randomUUID(),
      session.userId,
      interactionId,
      happenedOn,
      createdAt,
      `Recorded a ${kind} with ${person.name}.`,
      JSON.stringify({ personId: person.id, kind, actionId }),
    ),
  ]);
  return result;
}

export async function executeCalorieLogFood(
  request: Request,
  env: PlatformEnvironment,
  session: AuthenticatedSession,
  input: Record<string, unknown>,
): Promise<ToolActionResult> {
  const calorieToken = await verifyCalorieCredentialForSession(
    request,
    session,
    env.CALORIE_SERVICE,
  );
  const idempotencyKey = requireString(input.idempotencyKey, "idempotencyKey", 200);
  const originalInstruction = requireString(
    input.originalInstruction,
    "originalInstruction",
    2_000,
  );
  const existing = await findAudit(env.DB, session.userId, idempotencyKey);
  if (existing) return resultFromAudit(existing);

  const actionId = crypto.randomUUID();
  const createdAt = new Date().toISOString();
  const pendingInsert = await env.DB.prepare(
    `INSERT OR IGNORE INTO pace_actions
     (id, user_id, domain, tool_name, input_json, original_instruction, idempotency_key,
      status, created_at, completed_at, before_json, after_json, undo_payload, undone_at, error_message)
     VALUES (?, ?, 'calorie', 'calorie.log_food', ?, ?, ?, 'pending', ?, NULL, NULL, NULL, NULL, NULL, NULL)`,
  )
    .bind(
      actionId,
      session.userId,
      JSON.stringify(redactedActionInput(input)),
      originalInstruction,
      idempotencyKey,
      createdAt,
    )
    .run();
  if (pendingInsert.meta.changes !== 1) {
    const racedAudit = await findAudit(env.DB, session.userId, idempotencyKey);
    if (!racedAudit) throw new HTTPError(409, "ACTION_CONFLICT", "That action is already running.");
    return resultFromAudit(racedAudit);
  }

  try {
    const food = await resolveCalorieFood(env.CALORIE_SERVICE, calorieToken, input);
    const amountValue = input.amount ?? food.defaultAmount;
    if (typeof amountValue !== "number" || !Number.isFinite(amountValue) || amountValue <= 0 || amountValue > 10_000) {
      throw new HTTPError(400, "INVALID_INPUT", "amount must be a positive number.");
    }
    const entryId = crypto.randomUUID();
    const entryResponse = await calorieServiceJSON(
      env.CALORIE_SERVICE,
      calorieToken,
      new URL("https://calorie.significanthobbies.com/api/app/entries"),
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          id: entryId,
          foodId: food.id,
          amount: amountValue,
          eatenAt: Date.now(),
        }),
      },
    );
    const entry = requireRecord(entryResponse, "Calorie entry");
    const acceptedEntryId = requireString(entry.id, "Calorie entry id", 128);
    const acceptedFoodName =
      typeof entry.foodName === "string" && entry.foodName.trim() ? entry.foodName.trim() : food.name;
    const completedAt = new Date().toISOString();
    const result: ToolActionResult = {
      actionId,
      domain: "calorie",
      toolName: "calorie.log_food",
      status: "succeeded",
      occurredAt: completedAt,
      message: `Logged ${acceptedFoodName} in Calorie.`,
      undo: { actionId, expiresAt: null },
    };
    await env.DB.batch([
      env.DB.prepare(
        `UPDATE pace_actions SET status = 'succeeded', completed_at = ?, after_json = ?, undo_payload = ?
         WHERE id = ? AND user_id = ?`,
      ).bind(
        completedAt,
        JSON.stringify(result),
        JSON.stringify({ domain: "calorie", entryId: acceptedEntryId }),
        actionId,
        session.userId,
      ),
      env.DB.prepare(
        `INSERT INTO life_events
         (id, user_id, domain, event_type, entity_id, occurred_at, recorded_at, actor, summary, metadata_json)
         VALUES (?, ?, 'calorie', 'calorie.meal_logged', ?, ?, ?, 'pace', ?, ?)`,
      ).bind(
        crypto.randomUUID(),
        session.userId,
        acceptedEntryId,
        completedAt,
        completedAt,
        `Logged ${acceptedFoodName}.`,
        JSON.stringify({ actionId }),
      ),
    ]);
    return result;
  } catch (error) {
    const failedAt = new Date().toISOString();
    const message = error instanceof HTTPError ? error.message : "Calorie could not apply the action.";
    const result: ToolActionResult = {
      actionId,
      domain: "calorie",
      toolName: "calorie.log_food",
      status: "failed",
      occurredAt: null,
      message,
      undo: null,
    };
    await env.DB.prepare(
      `UPDATE pace_actions
       SET status = 'failed', completed_at = ?, after_json = ?, error_message = ?
       WHERE id = ? AND user_id = ?`,
    )
      .bind(failedAt, JSON.stringify(result), message, actionId, session.userId)
      .run();
    return result;
  }
}

export async function undoAction(
  request: Request,
  env: PlatformEnvironment,
  session: AuthenticatedSession,
  actionIdValue: string,
): Promise<ToolActionResult> {
  const actionId = requireUUID(actionIdValue, "actionId");
  const original = await env.DB.prepare(
    `SELECT id, domain, tool_name, status, created_at, completed_at, after_json, undo_payload, undone_at
     FROM pace_actions WHERE id = ? AND user_id = ?`,
  )
    .bind(actionId, session.userId)
    .first<AuditRow>();
  if (!original) throw new HTTPError(404, "ACTION_NOT_FOUND", "That Pace action was not found.");
  if (!original.undo_payload) throw new HTTPError(409, "NOT_UNDOABLE", "That action cannot be undone.");
  if (original.undone_at) {
    const existingUndo = await findAudit(env.DB, session.userId, `undo:${actionId}`);
    if (existingUndo) return resultFromAudit(existingUndo);
  }

  const undo = requireRecord(JSON.parse(original.undo_payload), "undo payload");
  const undoneAt = new Date().toISOString();
  const undoActionId = crypto.randomUUID();
  const result: ToolActionResult = {
    actionId: undoActionId,
    domain: original.domain,
    toolName: `${original.tool_name}.undo`,
    status: "undone",
    occurredAt: undoneAt,
    message: original.domain === "calorie" ? "Removed the Calorie entry." : "Removed the Kith interaction.",
    undo: null,
  };

  if (undo.domain === "calorie") {
    const calorieToken = await verifyCalorieCredentialForSession(
      request,
      session,
      env.CALORIE_SERVICE,
    );
    const entryId = requireString(undo.entryId, "undo.entryId", 128);
    await calorieServiceJSON(
      env.CALORIE_SERVICE,
      calorieToken,
      new URL(`https://calorie.significanthobbies.com/api/app/entries/${encodeURIComponent(entryId)}`),
      { method: "DELETE" },
      true,
    );
  } else if (undo.domain === "kith") {
    const interactionId = requireUUID(undo.interactionId, "undo.interactionId");
    const interaction = await env.DB.prepare(
      `SELECT id, person_id, kind, happened_on, body, version, deleted_at
       FROM kith_interactions WHERE user_id = ? AND id = ?`,
    )
      .bind(session.userId, interactionId)
      .first<KithInteractionRow>();
    if (!interaction || interaction.deleted_at) {
      throw new HTTPError(409, "NOT_UNDOABLE", "The Kith interaction is already absent.");
    }
    await env.DB.prepare(
      `UPDATE kith_interactions
       SET deleted_at = ?, updated_at = ?, version = version + 1, origin_device_id = ?
       WHERE user_id = ? AND id = ? AND deleted_at IS NULL`,
    )
      .bind(undoneAt, undoneAt, session.deviceId, session.userId, interactionId)
      .run();
  } else {
    throw new HTTPError(409, "NOT_UNDOABLE", "That action domain cannot be undone.");
  }

  await env.DB.batch([
    env.DB.prepare("UPDATE pace_actions SET undone_at = ? WHERE id = ? AND user_id = ?").bind(
      undoneAt,
      actionId,
      session.userId,
    ),
    env.DB.prepare(
      `INSERT INTO pace_actions
       (id, user_id, domain, tool_name, input_json, original_instruction, idempotency_key,
        status, created_at, completed_at, before_json, after_json, undo_payload, undone_at, error_message)
       VALUES (?, ?, ?, ?, ?, ?, ?, 'undone', ?, ?, NULL, ?, NULL, NULL, NULL)`,
    ).bind(
      undoActionId,
      session.userId,
      original.domain,
      result.toolName,
      JSON.stringify({ actionId }),
      `Undo action ${actionId}`,
      `undo:${actionId}`,
      undoneAt,
      undoneAt,
      JSON.stringify(result),
    ),
  ]);
  return result;
}

export async function getLifeRecentActivity(
  env: Pick<Env, "DB">,
  session: AuthenticatedSession,
  limit = 50,
): Promise<unknown> {
  const { results } = await env.DB.prepare(
    `SELECT id, domain, event_type, entity_id, occurred_at, recorded_at, actor, summary, metadata_json
     FROM life_events WHERE user_id = ? ORDER BY occurred_at DESC LIMIT ?`,
  )
    .bind(session.userId, Math.min(100, Math.max(1, limit)))
    .all();
  const { results: actions } = await env.DB.prepare(
    `SELECT id, domain, tool_name, original_instruction, status, created_at, completed_at,
            after_json, undo_payload, undone_at, error_message
     FROM pace_actions WHERE user_id = ? ORDER BY created_at DESC LIMIT ?`,
  )
    .bind(session.userId, Math.min(100, Math.max(1, limit)))
    .all();
  return { events: results, actions, retrievedAt: new Date().toISOString() };
}

async function resolveKithPerson(
  database: D1Database,
  userId: string,
  input: Record<string, unknown>,
): Promise<{ id: string; name: string }> {
  const personId = input.personId ? requireUUID(input.personId, "personId") : null;
  const personName = optionalString(input.personName, "personName", 120);
  if (!personId && !personName) {
    throw new HTTPError(400, "INVALID_INPUT", "Provide personId or personName.");
  }
  if (personId) {
    const person = await database
      .prepare("SELECT id, name FROM kith_people WHERE user_id = ? AND id = ? AND deleted_at IS NULL")
      .bind(userId, personId)
      .first<{ id: string; name: string }>();
    if (!person) throw new HTTPError(404, "PERSON_NOT_FOUND", "That person is not in Kith.");
    return person;
  }
  const { results } = await database
    .prepare(
      "SELECT id, name FROM kith_people WHERE user_id = ? AND name = ? COLLATE NOCASE AND deleted_at IS NULL LIMIT 2",
    )
    .bind(userId, personName)
    .all<{ id: string; name: string }>();
  if (results.length === 0) throw new HTTPError(404, "PERSON_NOT_FOUND", "That person is not in Kith.");
  if (results.length > 1) {
    throw new HTTPError(409, "AMBIGUOUS_PERSON", "More than one Kith person has that name.");
  }
  return results[0]!;
}

async function resolveCalorieFood(
  service: Pick<Fetcher, "fetch">,
  calorieToken: string,
  input: Record<string, unknown>,
): Promise<{ id: string; name: string; defaultAmount: number }> {
  const requestedFoodId = optionalString(input.foodId, "foodId", 128);
  const requestedFoodName = optionalString(input.foodName, "foodName", 200);
  const today = new Date().toISOString().slice(0, 10);
  const url = new URL("https://calorie.significanthobbies.com/api/app/dashboard");
  const start = Date.parse(`${today}T00:00:00.000Z`);
  url.searchParams.set("start", String(start));
  url.searchParams.set("end", String(start + 86_400_000));
  url.searchParams.set("date", today);
  url.searchParams.set("timezone", "UTC");
  const dashboard = requireRecord(await calorieServiceJSON(service, calorieToken, url), "Calorie dashboard");
  if (!Array.isArray(dashboard.foods)) {
    throw new HTTPError(502, "INVALID_CALORIE_RESPONSE", "Calorie did not return saved foods.");
  }
  const matches = dashboard.foods
    .map((food) => requireRecord(food, "Calorie food"))
    .filter((food) => {
      if (requestedFoodId) return food.id === requestedFoodId;
      if (requestedFoodName && typeof food.name === "string") {
        return food.name.localeCompare(requestedFoodName, undefined, { sensitivity: "accent" }) === 0;
      }
      return false;
    });
  if (matches.length !== 1) {
    throw new HTTPError(
      matches.length === 0 ? 404 : 409,
      matches.length === 0 ? "FOOD_NOT_FOUND" : "AMBIGUOUS_FOOD",
      "Choose one exact saved Calorie food before logging.",
    );
  }
  const food = matches[0]!;
  if (typeof food.defaultAmount !== "number" || !Number.isFinite(food.defaultAmount)) {
    throw new HTTPError(502, "INVALID_CALORIE_RESPONSE", "Calorie returned an invalid food amount.");
  }
  return {
    id: requireString(food.id, "Calorie food id", 128),
    name: requireString(food.name, "Calorie food name", 200),
    defaultAmount: food.defaultAmount,
  };
}

async function calorieServiceJSON(
  service: Pick<Fetcher, "fetch">,
  token: string,
  url: URL,
  init: RequestInit = {},
  allowsEmptyBody = false,
): Promise<unknown> {
  const headers = new Headers(init.headers);
  headers.set("Accept", "application/json");
  headers.set("Authorization", `Bearer ${token}`);
  const response = await service.fetch(new Request(url, { ...init, headers }));
  if (!response.ok) {
    if (response.status === 401) {
      throw new HTTPError(401, "INVALID_CALORIE_SESSION", "Reconnect Calorie before continuing.");
    }
    throw new HTTPError(502, "CALORIE_FAILED", "Calorie could not complete the domain operation.");
  }
  if (allowsEmptyBody || response.status === 204) return null;
  return response.json();
}

async function findAudit(
  database: D1Database,
  userId: string,
  idempotencyKey: string,
): Promise<AuditRow | null> {
  return database
    .prepare(
      `SELECT id, domain, tool_name, status, created_at, completed_at, after_json, undo_payload, undone_at
       FROM pace_actions WHERE user_id = ? AND idempotency_key = ?`,
    )
    .bind(userId, idempotencyKey)
    .first<AuditRow>();
}

function resultFromAudit(audit: AuditRow): ToolActionResult {
  if (audit.after_json) {
    const stored: unknown = JSON.parse(audit.after_json);
    return parseToolActionResult(stored);
  }
  return {
    actionId: audit.id,
    domain: audit.domain,
    toolName: audit.tool_name,
    status: "pending",
    occurredAt: null,
    message: "That action is already being processed.",
    undo: null,
  };
}

function parseToolActionResult(value: unknown): ToolActionResult {
  const record = requireRecord(value, "stored action result");
  const domain = requireEnum(record.domain, "stored action domain", ["calorie", "kith"] as const);
  const status = requireEnum(
    record.status,
    "stored action status",
    ["pending", "succeeded", "failed", "undone"] as const,
  );
  const undoRecord = record.undo === null ? null : requireRecord(record.undo, "stored undo");
  return {
    actionId: requireUUID(record.actionId, "stored action id"),
    domain,
    toolName: requireString(record.toolName, "stored tool name", 120),
    status,
    occurredAt: optionalString(record.occurredAt, "stored occurredAt", 40),
    message: requireString(record.message, "stored result message", 2_000),
    undo: undoRecord
      ? {
          actionId: requireUUID(undoRecord.actionId, "stored undo action id"),
          expiresAt: optionalString(undoRecord.expiresAt, "stored undo expiry", 40),
        }
      : null,
  };
}

function redactedActionInput(input: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(input).filter(([key]) => key !== "calorieSession" && key !== "accessToken"),
  );
}

function attentionCadenceDays(closeness: number): number {
  switch (closeness) {
    case 5:
      return 14;
    case 4:
      return 30;
    case 3:
      return 60;
    case 2:
      return 90;
    default:
      return 180;
  }
}
