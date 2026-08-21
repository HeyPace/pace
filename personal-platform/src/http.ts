export class HTTPError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

export function jsonResponse(value: unknown, status = 200): Response {
  return Response.json(value, {
    status,
    headers: {
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

export function errorResponse(error: unknown): Response {
  if (error instanceof HTTPError) {
    return jsonResponse({ code: error.code, message: error.message }, error.status);
  }
  const message = error instanceof Error ? error.message : "Unknown error";
  console.error(JSON.stringify({ message: "personal-platform request failed", error: message }));
  return jsonResponse(
    { code: "INTERNAL_ERROR", message: "Personal Platform could not complete the request." },
    500,
  );
}

export async function readJsonObject(
  request: Request,
  maximumBytes = 256 * 1024,
): Promise<Record<string, unknown>> {
  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(contentLength) && contentLength > maximumBytes) {
    throw new HTTPError(413, "PAYLOAD_TOO_LARGE", "The request payload is too large.");
  }
  if (!request.body) {
    throw new HTTPError(400, "INVALID_JSON", "A JSON request body is required.");
  }

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let byteCount = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    byteCount += value.byteLength;
    if (byteCount > maximumBytes) {
      await reader.cancel();
      throw new HTTPError(413, "PAYLOAD_TOO_LARGE", "The request payload is too large.");
    }
    chunks.push(value);
  }

  const body = new Uint8Array(byteCount);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return requireRecord(JSON.parse(new TextDecoder().decode(body)), "request body");
  } catch (error) {
    if (error instanceof HTTPError) throw error;
    throw new HTTPError(400, "INVALID_JSON", "The request body must be valid JSON.");
  }
}

export function requireRecord(value: unknown, name: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new HTTPError(400, "INVALID_INPUT", `${name} must be an object.`);
  }
  return value as Record<string, unknown>;
}

export function requireString(
  value: unknown,
  name: string,
  maximumLength: number,
  allowEmpty = false,
): string {
  if (typeof value !== "string") {
    throw new HTTPError(400, "INVALID_INPUT", `${name} must be a string.`);
  }
  const normalized = value.trim();
  if ((!allowEmpty && normalized.length === 0) || normalized.length > maximumLength) {
    throw new HTTPError(400, "INVALID_INPUT", `${name} has an invalid length.`);
  }
  return normalized;
}

export function optionalString(
  value: unknown,
  name: string,
  maximumLength: number,
): string | null {
  if (value === null || value === undefined) return null;
  return requireString(value, name, maximumLength, true);
}

export function requireUUID(value: unknown, name: string): string {
  const candidate = requireString(value, name, 36).toLowerCase();
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(candidate)) {
    throw new HTTPError(400, "INVALID_INPUT", `${name} must be a UUID.`);
  }
  return candidate;
}

export function requireISODate(value: unknown, name: string): string {
  const candidate = requireString(value, name, 40);
  const timestamp = Date.parse(candidate);
  if (!Number.isFinite(timestamp)) {
    throw new HTTPError(400, "INVALID_INPUT", `${name} must be an ISO-8601 date.`);
  }
  return new Date(timestamp).toISOString();
}

export function requireInteger(
  value: unknown,
  name: string,
  minimum: number,
  maximum: number,
): number {
  if (!Number.isInteger(value) || (value as number) < minimum || (value as number) > maximum) {
    throw new HTTPError(400, "INVALID_INPUT", `${name} must be between ${minimum} and ${maximum}.`);
  }
  return value as number;
}

export function requireEnum<const Values extends readonly string[]>(
  value: unknown,
  name: string,
  values: Values,
): Values[number] {
  if (typeof value !== "string" || !values.includes(value)) {
    throw new HTTPError(400, "INVALID_INPUT", `${name} is not supported.`);
  }
  return value as Values[number];
}
