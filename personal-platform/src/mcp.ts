import type { AuthenticatedSession, PersonalScope } from "./contracts";
import {
  executeCalorieLogFood,
  executeKithRecordInteraction,
  getCalorieToday,
  getKithPeopleNeedingAttention,
  getLifeRecentActivity,
} from "./domain-tools";
import { HTTPError, requireRecord } from "./http";

type PlatformEnvironment = Pick<Env, "DB"> & {
  CALORIE_SERVICE: Pick<Fetcher, "fetch">;
};

interface MCPRequest {
  jsonrpc: "2.0";
  id: string | number | null;
  method: string;
  params: Record<string, unknown>;
}

interface MCPTool {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  requiredScope: PersonalScope;
}

const tools: MCPTool[] = [
  {
    name: "life.get_today",
    description: "Get current Calorie and Kith summaries with per-source freshness and provenance.",
    inputSchema: {
      type: "object",
      properties: { timezone: { type: "string" }, date: { type: "string" } },
      additionalProperties: false,
    },
    requiredScope: "life:read",
  },
  {
    name: "life.get_recent_activity",
    description: "Get recent cross-domain life events and Pace action audit records.",
    inputSchema: {
      type: "object",
      properties: { limit: { type: "integer", minimum: 1, maximum: 100 } },
      additionalProperties: false,
    },
    requiredScope: "life:read",
  },
  {
    name: "calorie.get_today",
    description: "Get today's typed Calorie dashboard through its domain service.",
    inputSchema: {
      type: "object",
      properties: { timezone: { type: "string" }, date: { type: "string" } },
      additionalProperties: false,
    },
    requiredScope: "calorie:read",
  },
  {
    name: "calorie.log_food",
    description: "Log one exact saved Calorie food idempotently and return undo metadata.",
    inputSchema: {
      type: "object",
      required: ["foodId", "idempotencyKey", "originalInstruction"],
      properties: {
        foodId: { type: "string" },
        foodName: { type: "string" },
        amount: { type: "number", exclusiveMinimum: 0 },
        idempotencyKey: { type: "string" },
        originalInstruction: { type: "string" },
      },
      additionalProperties: false,
    },
    requiredScope: "calorie:write",
  },
  {
    name: "kith.get_people_needing_attention",
    description: "Get Kith people ordered by explicit closeness and interaction gap.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    requiredScope: "kith:read",
  },
  {
    name: "kith.record_interaction",
    description: "Record one additive Kith interaction idempotently and return undo metadata.",
    inputSchema: {
      type: "object",
      required: ["personName", "body", "idempotencyKey", "originalInstruction"],
      properties: {
        personId: { type: "string", format: "uuid" },
        personName: { type: "string" },
        kind: {
          type: "string",
          enum: ["note", "hangout", "call", "message", "gift", "milestone", "remember"],
        },
        happenedOn: { type: "string", format: "date-time" },
        body: { type: "string" },
        idempotencyKey: { type: "string" },
        originalInstruction: { type: "string" },
      },
      additionalProperties: false,
    },
    requiredScope: "kith:write",
  },
];

export async function handleMCPRequest(
  request: Request,
  env: PlatformEnvironment,
  session: AuthenticatedSession,
  body: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const rpcRequest = parseMCPRequest(body);
  try {
    switch (rpcRequest.method) {
      case "initialize":
        return success(rpcRequest.id, {
          protocolVersion: "2025-06-18",
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: "personal-platform", version: "0.1.0" },
        });
      case "notifications/initialized":
        return success(rpcRequest.id, {});
      case "tools/list":
        return success(rpcRequest.id, {
          tools: tools
            .filter((tool) => session.scopes.includes(tool.requiredScope))
            .map(({ requiredScope: _, ...tool }) => tool),
        });
      case "tools/call":
        return success(rpcRequest.id, await callTool(request, env, session, rpcRequest.params));
      default:
        return failure(rpcRequest.id, -32601, "Method not found");
    }
  } catch (error) {
    if (error instanceof HTTPError) {
      return failure(rpcRequest.id, -32000, error.message, { code: error.code, status: error.status });
    }
    throw error;
  }
}

async function callTool(
  request: Request,
  env: PlatformEnvironment,
  session: AuthenticatedSession,
  params: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const name = typeof params.name === "string" ? params.name : "";
  const tool = tools.find((candidate) => candidate.name === name);
  if (!tool) throw new HTTPError(404, "TOOL_NOT_FOUND", "That Personal Platform tool does not exist.");
  if (!session.scopes.includes(tool.requiredScope)) {
    throw new HTTPError(403, "INSUFFICIENT_SCOPE", `The session does not allow ${tool.requiredScope}.`);
  }
  const argumentsValue = params.arguments ?? {};
  const argumentsRecord = requireRecord(argumentsValue, "tool arguments");
  let structuredContent: unknown;
  switch (name) {
    case "life.get_today":
      structuredContent = await getLifeToday(request, env, session, argumentsRecord);
      break;
    case "life.get_recent_activity":
      structuredContent = await getLifeRecentActivity(
        env,
        session,
        typeof argumentsRecord.limit === "number" ? argumentsRecord.limit : 50,
      );
      break;
    case "calorie.get_today":
      structuredContent = await getCalorieToday(
        request,
        env,
        session,
        toolArgumentsURL(argumentsRecord),
      );
      break;
    case "calorie.log_food":
      structuredContent = await executeCalorieLogFood(request, env, session, argumentsRecord);
      break;
    case "kith.get_people_needing_attention":
      structuredContent = await getKithPeopleNeedingAttention(env, session);
      break;
    case "kith.record_interaction":
      structuredContent = await executeKithRecordInteraction(env, session, argumentsRecord);
      break;
    default:
      throw new HTTPError(404, "TOOL_NOT_FOUND", "That Personal Platform tool does not exist.");
  }
  return {
    content: [{ type: "text", text: JSON.stringify(structuredContent) }],
    structuredContent,
    isError: false,
  };
}

export async function getLifeToday(
  request: Request,
  env: PlatformEnvironment,
  session: AuthenticatedSession,
  argumentsRecord: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const [kithResult, calorieResult] = await Promise.allSettled([
    session.scopes.includes("kith:read")
      ? getKithPeopleNeedingAttention(env, session)
      : Promise.reject(new HTTPError(403, "INSUFFICIENT_SCOPE", "Kith read access is not enabled.")),
    session.scopes.includes("calorie:read")
      ? getCalorieToday(request, env, session, toolArgumentsURL(argumentsRecord))
      : Promise.reject(new HTTPError(403, "INSUFFICIENT_SCOPE", "Calorie read access is not enabled.")),
  ]);
  const sources = {
    calorie:
      calorieResult.status === "fulfilled"
        ? { status: "current", value: calorieResult.value }
        : { status: "unavailable", message: safeFailureMessage(calorieResult.reason) },
    kith:
      kithResult.status === "fulfilled"
        ? { status: "current", value: kithResult.value }
        : { status: "unavailable", message: safeFailureMessage(kithResult.reason) },
  };
  return {
    sources,
    consultedApplications: Object.entries(sources)
      .filter(([, source]) => source.status === "current")
      .map(([application]) => application),
    retrievedAt: new Date().toISOString(),
  };
}

function parseMCPRequest(body: Record<string, unknown>): MCPRequest {
  if (body.jsonrpc !== "2.0" || typeof body.method !== "string") {
    throw new HTTPError(400, "INVALID_MCP_REQUEST", "A valid JSON-RPC 2.0 request is required.");
  }
  const id = body.id;
  if (id !== null && typeof id !== "string" && typeof id !== "number") {
    throw new HTTPError(400, "INVALID_MCP_REQUEST", "The JSON-RPC id is invalid.");
  }
  return {
    jsonrpc: "2.0",
    id,
    method: body.method,
    params: body.params === undefined ? {} : requireRecord(body.params, "JSON-RPC params"),
  };
}

function toolArgumentsURL(argumentsRecord: Record<string, unknown>): URL {
  const url = new URL("https://personal-platform.invalid/");
  if (typeof argumentsRecord.date === "string") url.searchParams.set("date", argumentsRecord.date);
  if (typeof argumentsRecord.timezone === "string") {
    url.searchParams.set("timezone", argumentsRecord.timezone);
  }
  return url;
}

function success(id: MCPRequest["id"], result: unknown): Record<string, unknown> {
  return { jsonrpc: "2.0", id, result };
}

function failure(
  id: MCPRequest["id"],
  code: number,
  message: string,
  data?: unknown,
): Record<string, unknown> {
  return { jsonrpc: "2.0", id, error: { code, message, ...(data === undefined ? {} : { data }) } };
}

function safeFailureMessage(error: unknown): string {
  return error instanceof HTTPError ? error.message : "The source is temporarily unavailable.";
}
