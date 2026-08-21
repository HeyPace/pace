import { authenticatePersonalRequest, exchangeCalorieIdentity } from "./auth";
import {
  executeCalorieLogFood,
  executeKithRecordInteraction,
  getCalorieToday,
  getKithPeopleNeedingAttention,
  getLifeRecentActivity,
  undoAction,
} from "./domain-tools";
import { pullKithChanges, pushKithMutations } from "./domains/kith/sync";
import { errorResponse, HTTPError, jsonResponse, readJsonObject } from "./http";
import { getLifeToday, handleMCPRequest } from "./mcp";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const url = new URL(request.url);
      if (request.method === "GET" && url.pathname === "/health") {
        return jsonResponse({ ok: true, service: "personal-platform", storage: "d1" });
      }
      if (request.method === "POST" && url.pathname === "/v1/auth/exchange") {
        return jsonResponse(
          await exchangeCalorieIdentity(request, env, await readJsonObject(request)),
          201,
        );
      }

      if (request.method === "GET" && url.pathname === "/v1/connections") {
        const session = await authenticatePersonalRequest(request, env);
        const freshness = await connectionFreshness(env.DB, session.userId);
        return jsonResponse({ identity: session.identity, scopes: session.scopes, freshness });
      }
      if (request.method === "POST" && url.pathname === "/v1/sync/kith/push") {
        const session = await authenticatePersonalRequest(request, env, "kith:write");
        return jsonResponse(await pushKithMutations(env, session, await readJsonObject(request)));
      }
      if (request.method === "GET" && url.pathname === "/v1/sync/kith/pull") {
        const session = await authenticatePersonalRequest(request, env, "kith:read");
        return jsonResponse(await pullKithChanges(env, session, url));
      }
      if (request.method === "GET" && url.pathname === "/v1/life/today") {
        const session = await authenticatePersonalRequest(request, env, "life:read");
        return jsonResponse(await getLifeToday(request, env, session, queryArguments(url)));
      }
      if (request.method === "GET" && url.pathname === "/v1/life/recent-activity") {
        const session = await authenticatePersonalRequest(request, env, "life:read");
        return jsonResponse(
          await getLifeRecentActivity(env, session, Number(url.searchParams.get("limit") ?? "50")),
        );
      }
      if (request.method === "GET" && url.pathname === "/v1/calorie/today") {
        const session = await authenticatePersonalRequest(request, env, "calorie:read");
        return jsonResponse(await getCalorieToday(request, env, session, url));
      }
      if (request.method === "GET" && url.pathname === "/v1/kith/attention") {
        const session = await authenticatePersonalRequest(request, env, "kith:read");
        return jsonResponse(await getKithPeopleNeedingAttention(env, session));
      }
      if (request.method === "POST" && url.pathname === "/v1/actions/calorie/log-food") {
        const session = await authenticatePersonalRequest(request, env, "calorie:write");
        return jsonResponse(
          await executeCalorieLogFood(request, env, session, await readJsonObject(request)),
        );
      }
      if (request.method === "POST" && url.pathname === "/v1/actions/kith/record-interaction") {
        const session = await authenticatePersonalRequest(request, env, "kith:write");
        return jsonResponse(
          await executeKithRecordInteraction(env, session, await readJsonObject(request)),
        );
      }
      const undoMatch = url.pathname.match(/^\/v1\/actions\/([0-9a-f-]{36})\/undo$/i);
      if (request.method === "POST" && undoMatch?.[1]) {
        const session = await authenticatePersonalRequest(request, env);
        return jsonResponse(await undoAction(request, env, session, undoMatch[1]));
      }
      if (request.method === "POST" && url.pathname === "/mcp") {
        const session = await authenticatePersonalRequest(request, env);
        return jsonResponse(
          await handleMCPRequest(request, env, session, await readJsonObject(request)),
        );
      }
      throw new HTTPError(404, "NOT_FOUND", "That Personal Platform route does not exist.");
    } catch (error) {
      return errorResponse(error);
    }
  },
} satisfies ExportedHandler<Env>;

async function connectionFreshness(database: D1Database, userId: string): Promise<unknown> {
  const kith = await database
    .prepare(
      "SELECT MAX(changed_at) AS synchronized_at FROM sync_changes WHERE user_id = ? AND domain = 'kith'",
    )
    .bind(userId)
    .first<{ synchronized_at: string | null }>();
  return {
    kith: { synchronizedAt: kith?.synchronized_at ?? null, source: "personal-platform-d1" },
    calorie: { synchronizedAt: null, source: "on-demand-calorie-service" },
  };
}

function queryArguments(url: URL): Record<string, unknown> {
  return {
    ...(url.searchParams.has("date") ? { date: url.searchParams.get("date") } : {}),
    ...(url.searchParams.has("timezone") ? { timezone: url.searchParams.get("timezone") } : {}),
  };
}
