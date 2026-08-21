export const personalScopes = [
  "life:read",
  "calorie:read",
  "calorie:write",
  "kith:read",
  "kith:write",
] as const;

export type PersonalScope = (typeof personalScopes)[number];
export type PersonalApplication = "pace" | "kith";
export type PersonalPlatform = "macos" | "ios";
export type KithEntityType = "person" | "interaction";
export type SyncOperation = "upsert" | "delete";

export interface AuthExchangeInput {
  scopes: PersonalScope[];
  device: {
    id: string;
    application: PersonalApplication;
    platform: PersonalPlatform;
    displayName: string;
  };
}

export interface PersonalIdentity {
  userId: string;
  authUserId: string;
  appleSubject: string;
  email: string | null;
}

export interface AuthExchangeOutput {
  token: string;
  expiresAt: string;
  scopes: PersonalScope[];
  identity: PersonalIdentity;
}

export interface AuthenticatedSession {
  id: string;
  userId: string;
  deviceId: string;
  scopes: PersonalScope[];
  identity: PersonalIdentity;
}

export interface KithPersonPayload {
  id: string;
  name: string;
  howWeMet: string;
  circle: "family" | "close" | "friends" | "work" | "other";
  closeness: number;
  hue: "clay" | "apricot" | "honey" | "rose" | "rust" | "sand" | "sage";
  birthday: string | null;
  standingNotes: string;
  createdAt: string;
  updatedAt: string;
  deletedAt: string | null;
  version: number;
  originDeviceId: string;
}

export interface KithInteractionPayload {
  id: string;
  personId: string;
  kind: "note" | "hangout" | "call" | "message" | "gift" | "milestone" | "remember";
  happenedOn: string;
  body: string;
  createdAt: string;
  updatedAt: string;
  deletedAt: string | null;
  version: number;
  originDeviceId: string;
}

export interface KithMutation {
  idempotencyKey: string;
  entityType: KithEntityType;
  operation: SyncOperation;
  baseVersion: number;
  payload: KithPersonPayload | KithInteractionPayload;
}

export interface KithPushInput {
  mutations: KithMutation[];
}

export interface KithMutationResult {
  idempotencyKey: string;
  entityType: KithEntityType;
  entityId: string;
  status: "accepted" | "duplicate" | "conflict" | "rejected";
  version: number | null;
  sequence: number | null;
  message: string;
  serverRecord?: KithPersonPayload | KithInteractionPayload;
}

export interface KithPushOutput {
  results: KithMutationResult[];
  cursor: number;
  synchronizedAt: string;
}

export interface KithChange {
  sequence: number;
  entityType: KithEntityType;
  entityId: string;
  operation: SyncOperation;
  version: number;
  changedAt: string;
  payload: KithPersonPayload | KithInteractionPayload;
}

export interface KithPullOutput {
  changes: KithChange[];
  cursor: number;
  hasMore: boolean;
  synchronizedAt: string;
}

export interface ToolActionResult {
  actionId: string;
  domain: "calorie" | "kith";
  toolName: string;
  status: "pending" | "succeeded" | "failed" | "undone";
  occurredAt: string | null;
  message: string;
  undo: {
    actionId: string;
    expiresAt: string | null;
  } | null;
}
