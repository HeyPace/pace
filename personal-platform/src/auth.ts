import {
  personalScopes,
  type AuthExchangeInput,
  type AuthExchangeOutput,
  type AuthenticatedSession,
  type PersonalApplication,
  type PersonalIdentity,
  type PersonalPlatform,
  type PersonalScope,
} from "./contracts";
import {
  HTTPError,
  requireEnum,
  requireRecord,
  requireString,
  requireUUID,
} from "./http";

type PlatformEnvironment = Pick<Env, "DB"> & {
  CALORIE_SERVICE: Pick<Fetcher, "fetch">;
};

interface CalorieIdentity {
  authUserId: string;
  appleSubject: string;
  email: string | null;
}

interface UserRow {
  id: string;
  auth_user_id: string;
  apple_subject: string;
  email: string | null;
}

interface SessionRow extends UserRow {
  session_id: string;
  device_id: string;
  scopes_json: string;
  expires_at: string;
}

const applications = ["pace", "kith"] as const;
const platforms = ["macos", "ios"] as const;
const sessionLifetimeMilliseconds = 30 * 24 * 60 * 60 * 1000;

const applicationScopes: Record<PersonalApplication, readonly PersonalScope[]> = {
  pace: personalScopes,
  kith: ["life:read", "kith:read", "kith:write"],
};

export async function exchangeCalorieIdentity(
  request: Request,
  env: PlatformEnvironment,
  input: Record<string, unknown>,
): Promise<AuthExchangeOutput> {
  const calorieToken = requireBearerToken(request.headers.get("authorization"));
  const parsedInput = parseAuthExchangeInput(input);
  const calorieIdentity = await verifyCalorieIdentity(calorieToken, env.CALORIE_SERVICE);
  const now = new Date();
  const nowISO = now.toISOString();
  const existingByApple = await env.DB.prepare(
    "SELECT id, auth_user_id, apple_subject, email FROM users WHERE apple_subject = ?",
  )
    .bind(calorieIdentity.appleSubject)
    .first<UserRow>();
  const existingByAuth = await env.DB.prepare(
    "SELECT id, auth_user_id, apple_subject, email FROM users WHERE auth_user_id = ?",
  )
    .bind(calorieIdentity.authUserId)
    .first<UserRow>();

  if (existingByApple && existingByAuth && existingByApple.id !== existingByAuth.id) {
    throw new HTTPError(409, "IDENTITY_CONFLICT", "The Apple identity is already mapped differently.");
  }
  const existingUser = existingByApple ?? existingByAuth;
  if (existingUser && existingUser.apple_subject !== calorieIdentity.appleSubject) {
    throw new HTTPError(409, "IDENTITY_CONFLICT", "The account must use the same Apple identity.");
  }

  const userId = existingUser?.id ?? crypto.randomUUID();
  const personalToken = createPersonalToken();
  const tokenHash = await sha256Hex(personalToken);
  const sessionId = crypto.randomUUID();
  const expiresAt = new Date(now.getTime() + sessionLifetimeMilliseconds).toISOString();
  const existingDeviceOwner = await env.DB.prepare("SELECT user_id FROM devices WHERE id = ?")
    .bind(parsedInput.device.id)
    .first<{ user_id: string }>();
  if (existingDeviceOwner && existingDeviceOwner.user_id !== userId) {
    throw new HTTPError(409, "DEVICE_CONFLICT", "That device identifier belongs to another account.");
  }

  const statements: D1PreparedStatement[] = [];
  if (existingUser) {
    statements.push(
      env.DB.prepare(
        "UPDATE users SET auth_user_id = ?, email = ?, updated_at = ? WHERE id = ?",
      ).bind(calorieIdentity.authUserId, calorieIdentity.email, nowISO, userId),
    );
  } else {
    statements.push(
      env.DB.prepare(
        "INSERT INTO users (id, auth_user_id, apple_subject, email, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
      ).bind(
        userId,
        calorieIdentity.authUserId,
        calorieIdentity.appleSubject,
        calorieIdentity.email,
        nowISO,
        nowISO,
      ),
    );
  }
  statements.push(
    env.DB.prepare(
      `INSERT INTO devices (id, user_id, application, platform, display_name, last_seen_at, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         application = excluded.application,
         platform = excluded.platform,
         display_name = excluded.display_name,
         last_seen_at = excluded.last_seen_at`,
    ).bind(
      parsedInput.device.id,
      userId,
      parsedInput.device.application,
      parsedInput.device.platform,
      parsedInput.device.displayName,
      nowISO,
      nowISO,
    ),
    env.DB.prepare(
      `INSERT INTO personal_sessions
       (id, user_id, device_id, token_hash, scopes_json, expires_at, revoked_at, created_at)
       VALUES (?, ?, ?, ?, ?, ?, NULL, ?)`,
    ).bind(
      sessionId,
      userId,
      parsedInput.device.id,
      tokenHash,
      JSON.stringify(parsedInput.scopes),
      expiresAt,
      nowISO,
    ),
  );
  await env.DB.batch(statements);

  return {
    token: personalToken,
    expiresAt,
    scopes: parsedInput.scopes,
    identity: {
      userId,
      authUserId: calorieIdentity.authUserId,
      appleSubject: calorieIdentity.appleSubject,
      email: calorieIdentity.email,
    },
  };
}

export async function authenticatePersonalRequest(
  request: Request,
  env: Pick<Env, "DB">,
  requiredScope?: PersonalScope,
): Promise<AuthenticatedSession> {
  const token = requireBearerToken(request.headers.get("authorization"));
  const tokenHash = await sha256Hex(token);
  const sessionRow = await env.DB.prepare(
    `SELECT
       personal_sessions.id AS session_id,
       personal_sessions.device_id,
       personal_sessions.scopes_json,
       personal_sessions.expires_at,
       users.id,
       users.auth_user_id,
       users.apple_subject,
       users.email
     FROM personal_sessions
     JOIN users ON users.id = personal_sessions.user_id
     WHERE personal_sessions.token_hash = ?
       AND personal_sessions.revoked_at IS NULL
       AND personal_sessions.expires_at > ?`,
  )
    .bind(tokenHash, new Date().toISOString())
    .first<SessionRow>();
  if (!sessionRow) {
    throw new HTTPError(401, "UNAUTHORIZED", "Sign in to Personal Platform again.");
  }
  const scopes = parseStoredScopes(sessionRow.scopes_json);
  if (requiredScope && !scopes.includes(requiredScope)) {
    throw new HTTPError(403, "INSUFFICIENT_SCOPE", `The session does not allow ${requiredScope}.`);
  }

  return {
    id: sessionRow.session_id,
    userId: sessionRow.id,
    deviceId: sessionRow.device_id,
    scopes,
    identity: rowIdentity(sessionRow),
  };
}

export async function verifyCalorieCredentialForSession(
  request: Request,
  session: AuthenticatedSession,
  calorieService: Pick<Fetcher, "fetch">,
): Promise<string> {
  const headerValue = request.headers.get("x-calorie-session");
  const calorieToken = requireBearerToken(headerValue);
  const calorieIdentity = await verifyCalorieIdentity(calorieToken, calorieService);
  if (
    calorieIdentity.authUserId !== session.identity.authUserId ||
    calorieIdentity.appleSubject !== session.identity.appleSubject
  ) {
    throw new HTTPError(403, "IDENTITY_MISMATCH", "Calorie is connected to a different Apple identity.");
  }
  return calorieToken;
}

function parseAuthExchangeInput(value: Record<string, unknown>): AuthExchangeInput {
  if (!Array.isArray(value.scopes) || value.scopes.length === 0) {
    throw new HTTPError(400, "INVALID_INPUT", "At least one scope is required.");
  }
  const device = requireRecord(value.device, "device");
  const application = requireEnum(
    device.application,
    "device.application",
    applications,
  ) as PersonalApplication;
  const platform = requireEnum(device.platform, "device.platform", platforms) as PersonalPlatform;
  const allowedScopes = applicationScopes[application];
  const scopes = [...new Set(value.scopes.map((scope) => requireEnum(scope, "scope", personalScopes)))];
  if (scopes.some((scope) => !allowedScopes.includes(scope))) {
    throw new HTTPError(403, "INVALID_SCOPE", `${application} cannot request one of those scopes.`);
  }
  return {
    scopes,
    device: {
      id: requireUUID(device.id, "device.id"),
      application,
      platform,
      displayName: requireString(device.displayName, "device.displayName", 120),
    },
  };
}

async function verifyCalorieIdentity(
  calorieToken: string,
  calorieService: Pick<Fetcher, "fetch">,
): Promise<CalorieIdentity> {
  const headers = new Headers({
    Accept: "application/json",
    Authorization: `Bearer ${calorieToken}`,
  });
  const [sessionResponse, accountsResponse] = await Promise.all([
    calorieService.fetch(
      new Request("https://calorie.significanthobbies.com/api/auth/get-session", { headers }),
    ),
    calorieService.fetch(
      new Request("https://calorie.significanthobbies.com/api/auth/list-accounts", { headers }),
    ),
  ]);
  if (!sessionResponse.ok || !accountsResponse.ok) {
    throw new HTTPError(401, "INVALID_CALORIE_SESSION", "The Calorie session is invalid.");
  }

  const session = requireRecord(await sessionResponse.json(), "Calorie session");
  const user = requireRecord(session.user, "Calorie session user");
  const authUserId = requireString(user.id, "Calorie user id", 128);
  const email = typeof user.email === "string" ? user.email.slice(0, 320) : null;
  const accountsValue: unknown = await accountsResponse.json();
  if (!Array.isArray(accountsValue)) {
    throw new HTTPError(502, "INVALID_CALORIE_RESPONSE", "Calorie returned invalid accounts.");
  }
  const appleAccount = accountsValue
    .map((account) => requireRecord(account, "Calorie account"))
    .find((account) => account.providerId === "apple");
  if (!appleAccount) {
    throw new HTTPError(403, "APPLE_REQUIRED", "Connect the same Sign in with Apple identity first.");
  }
  return {
    authUserId,
    appleSubject: requireString(appleAccount.accountId, "Apple subject", 255),
    email,
  };
}

function requireBearerToken(headerValue: string | null): string {
  const match = headerValue?.match(/^Bearer ([A-Za-z0-9._~-]{16,4096})$/);
  if (!match?.[1]) {
    throw new HTTPError(401, "UNAUTHORIZED", "A valid bearer session is required.");
  }
  return match[1];
}

function createPersonalToken(): string {
  const randomBytes = new Uint8Array(32);
  crypto.getRandomValues(randomBytes);
  const randomPart = btoa(String.fromCharCode(...randomBytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
  return `${crypto.randomUUID()}.${randomPart}`;
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function parseStoredScopes(value: string): PersonalScope[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(value);
  } catch {
    throw new HTTPError(401, "INVALID_SESSION", "The stored session scopes are invalid.");
  }
  if (!Array.isArray(parsed)) {
    throw new HTTPError(401, "INVALID_SESSION", "The stored session scopes are invalid.");
  }
  return parsed.map((scope) => requireEnum(scope, "stored scope", personalScopes));
}

function rowIdentity(row: UserRow): PersonalIdentity {
  return {
    userId: row.id,
    authUserId: row.auth_user_id,
    appleSubject: row.apple_subject,
    email: row.email,
  };
}
