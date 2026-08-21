import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

import worker from "../src/index";

const calorieToken = "calorie-session-token";
const paceDeviceId = "11111111-1111-4111-8111-111111111111";
const kithDeviceId = "22222222-2222-4222-8222-222222222222";

describe.sequential("Personal Platform", () => {
  it("maps one Apple identity to scoped Pace and Kith sessions", async () => {
    const pace = await exchange("pace", "macos", paceDeviceId, [
      "life:read",
      "calorie:read",
      "calorie:write",
      "kith:read",
      "kith:write",
    ]);
    const kith = await exchange("kith", "ios", kithDeviceId, [
      "life:read",
      "kith:read",
      "kith:write",
    ]);

    expect(pace.identity.userId).toBe(kith.identity.userId);
    expect(pace.identity.appleSubject).toBe("apple-subject");
    expect(pace.scopes).toContain("calorie:write");
    expect(kith.scopes).not.toContain("calorie:read");
  });

  it("pushes, pulls, deduplicates, and undoes Kith records", async () => {
    const personId = crypto.randomUUID();
    const mutationKey = `kith-person-import-${personId}`;
    const kith = await exchange("kith", "ios", kithDeviceId, [
      "life:read",
      "kith:read",
      "kith:write",
    ]);
    const createdAt = "2026-08-20T08:00:00.000Z";
    const mutation = {
      idempotencyKey: mutationKey,
      entityType: "person",
      operation: "upsert",
      baseVersion: 0,
      payload: {
        id: personId,
        name: "Rahul",
        howWeMet: "School",
        circle: "close",
        closeness: 5,
        hue: "sage",
        birthday: null,
        standingNotes: "",
        createdAt,
        updatedAt: createdAt,
        deletedAt: null,
        version: 0,
        originDeviceId: kithDeviceId,
      },
    };
    const accepted = await platformJSON("/v1/sync/kith/push", {
      method: "POST",
      token: kith.token,
      body: { mutations: [mutation] },
    });
    expect(accepted.results[0]).toMatchObject({ status: "accepted", version: 1 });

    const duplicate = await platformJSON("/v1/sync/kith/push", {
      method: "POST",
      token: kith.token,
      body: { mutations: [mutation] },
    });
    expect(duplicate.results[0]).toMatchObject({ status: "duplicate", version: 1 });

    const pace = await exchange("pace", "macos", paceDeviceId, [
      "life:read",
      "calorie:read",
      "calorie:write",
      "kith:read",
      "kith:write",
    ]);
    const interaction = await platformJSON("/v1/actions/kith/record-interaction", {
      method: "POST",
      token: pace.token,
      body: {
        personName: "Rahul",
        kind: "call",
        body: "Caught up after work.",
        idempotencyKey: `pace-kith-call-${personId}`,
        originalInstruction: "Record that I spoke to Rahul.",
      },
    });
    const repeated = await platformJSON("/v1/actions/kith/record-interaction", {
      method: "POST",
      token: pace.token,
      body: {
        personName: "Rahul",
        kind: "call",
        body: "Caught up after work.",
        idempotencyKey: `pace-kith-call-${personId}`,
        originalInstruction: "Record that I spoke to Rahul.",
      },
    });
    expect(repeated.actionId).toBe(interaction.actionId);

    const pulled = await platformJSON("/v1/sync/kith/pull?cursor=0", { token: kith.token });
    expect(pulled.changes.map((change: { entityType: string }) => change.entityType)).toEqual([
      "person",
      "interaction",
    ]);

    const undone = await platformJSON(`/v1/actions/${interaction.actionId}/undo`, {
      method: "POST",
      token: pace.token,
    });
    expect(undone).toMatchObject({ domain: "kith", status: "undone" });
    const afterUndo = await platformJSON(`/v1/sync/kith/pull?cursor=${pulled.cursor}`, {
      token: kith.token,
    });
    expect(afterUndo.changes[0]).toMatchObject({ entityType: "interaction", operation: "delete" });
  });

  it("combines Calorie and Kith, audits Calorie writes, and exposes MCP tools", async () => {
    const pace = await exchange("pace", "macos", paceDeviceId, [
      "life:read",
      "calorie:read",
      "calorie:write",
      "kith:read",
      "kith:write",
    ]);
    await seedPerson(pace.token);

    const today = await platformJSON("/v1/life/today?date=2026-08-20&timezone=Asia%2FKolkata", {
      token: pace.token,
      calorieToken,
    });
    expect(today.consultedApplications).toEqual(["calorie", "kith"]);
    expect(today.sources.calorie.value.dashboard.totals.protein).toBe(42);
    expect(today.sources.kith.value.attentionRequired[0].name).toBe("Rahul");

    const logged = await platformJSON("/v1/actions/calorie/log-food", {
      method: "POST",
      token: pace.token,
      calorieToken,
      body: {
        foodId: "usual-breakfast",
        idempotencyKey: "pace-breakfast-1",
        originalInstruction: "Log my usual breakfast.",
      },
    });
    expect(logged).toMatchObject({ domain: "calorie", status: "succeeded" });
    const repeated = await platformJSON("/v1/actions/calorie/log-food", {
      method: "POST",
      token: pace.token,
      calorieToken,
      body: {
        foodId: "usual-breakfast",
        idempotencyKey: "pace-breakfast-1",
        originalInstruction: "Log my usual breakfast.",
      },
    });
    expect(repeated.actionId).toBe(logged.actionId);

    const activity = await platformJSON("/v1/life/recent-activity", { token: pace.token });
    expect(activity.actions[0]).toMatchObject({ tool_name: "calorie.log_food", status: "succeeded" });

    const mcp = await platformJSON("/mcp", {
      method: "POST",
      token: pace.token,
      body: { jsonrpc: "2.0", id: 1, method: "tools/list", params: {} },
    });
    expect(mcp.result.tools.map((tool: { name: string }) => tool.name)).toContain("life.get_today");
    expect(mcp.result.tools.map((tool: { name: string }) => tool.name)).toContain("kith.record_interaction");

    const undone = await platformJSON(`/v1/actions/${logged.actionId}/undo`, {
      method: "POST",
      token: pace.token,
      calorieToken,
    });
    expect(undone).toMatchObject({ domain: "calorie", status: "undone" });
  });
});

async function exchange(
  application: "pace" | "kith",
  platform: "macos" | "ios",
  deviceId: string,
  scopes: string[],
): Promise<any> {
  return platformJSON("/v1/auth/exchange", {
    method: "POST",
    authToken: calorieToken,
    body: {
      scopes,
      device: { id: deviceId, application, platform, displayName: `${application} test` },
    },
  });
}

async function seedPerson(token: string): Promise<void> {
  const personId = crypto.randomUUID();
  const createdAt = "2026-08-20T08:00:00.000Z";
  await platformJSON("/v1/sync/kith/push", {
    method: "POST",
    token,
    body: {
      mutations: [
        {
          idempotencyKey: `seed-rahul-${personId}`,
          entityType: "person",
          operation: "upsert",
          baseVersion: 0,
          payload: {
            id: personId,
            name: "Rahul",
            howWeMet: "School",
            circle: "close",
            closeness: 5,
            hue: "sage",
            birthday: null,
            standingNotes: "",
            createdAt,
            updatedAt: createdAt,
            deletedAt: null,
            version: 0,
            originDeviceId: paceDeviceId,
          },
        },
      ],
    },
  });
}

async function platformJSON(
  path: string,
  options: {
    method?: string;
    token?: string;
    authToken?: string;
    calorieToken?: string;
    body?: unknown;
  },
): Promise<any> {
  const headers = new Headers({ Accept: "application/json" });
  const bearer = options.authToken ?? options.token;
  if (bearer) headers.set("Authorization", `Bearer ${bearer}`);
  if (options.calorieToken) headers.set("X-Calorie-Session", `Bearer ${options.calorieToken}`);
  if (options.body !== undefined) headers.set("Content-Type", "application/json");
  const request = new Request(`https://personal-platform.test${path}`, {
    method: options.method ?? "GET",
    headers,
    ...(options.body === undefined ? {} : { body: JSON.stringify(options.body) }),
  });
  const response = await worker.fetch(request, env);
  const body = (await response.json()) as any;
  expect(response.status, JSON.stringify(body)).toBeLessThan(400);
  return body;
}
