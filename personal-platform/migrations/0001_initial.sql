PRAGMA foreign_keys = ON;

CREATE TABLE users (
  id TEXT PRIMARY KEY,
  auth_user_id TEXT NOT NULL UNIQUE,
  apple_subject TEXT NOT NULL UNIQUE,
  email TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  application TEXT NOT NULL,
  platform TEXT NOT NULL,
  display_name TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX devices_user_id_idx ON devices(user_id, last_seen_at DESC);

CREATE TABLE personal_sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  scopes_json TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  revoked_at TEXT,
  created_at TEXT NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE
);
CREATE INDEX personal_sessions_user_id_idx ON personal_sessions(user_id, expires_at);

CREATE TABLE kith_people (
  id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  name TEXT NOT NULL,
  how_we_met TEXT NOT NULL DEFAULT '',
  circle TEXT NOT NULL,
  closeness INTEGER NOT NULL CHECK (closeness BETWEEN 1 AND 5),
  hue TEXT NOT NULL,
  birthday TEXT,
  standing_notes TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  version INTEGER NOT NULL,
  origin_device_id TEXT NOT NULL,
  PRIMARY KEY (user_id, id),
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX kith_people_attention_idx
  ON kith_people(user_id, deleted_at, closeness DESC, updated_at);

CREATE TABLE kith_interactions (
  id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  person_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  happened_on TEXT NOT NULL,
  body TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  version INTEGER NOT NULL,
  origin_device_id TEXT NOT NULL,
  PRIMARY KEY (user_id, id),
  FOREIGN KEY (user_id, person_id) REFERENCES kith_people(user_id, id) ON DELETE CASCADE
);
CREATE INDEX kith_interactions_person_idx
  ON kith_interactions(user_id, person_id, deleted_at, happened_on DESC);

CREATE TABLE sync_changes (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,
  domain TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  operation TEXT NOT NULL,
  version INTEGER NOT NULL,
  changed_at TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX sync_changes_cursor_idx ON sync_changes(user_id, domain, sequence);

CREATE TABLE sync_mutations (
  idempotency_key TEXT NOT NULL,
  user_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  domain TEXT NOT NULL,
  response_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (user_id, idempotency_key),
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE TABLE life_events (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  domain TEXT NOT NULL,
  event_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  occurred_at TEXT NOT NULL,
  recorded_at TEXT NOT NULL,
  actor TEXT NOT NULL,
  summary TEXT NOT NULL,
  metadata_json TEXT NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX life_events_timeline_idx ON life_events(user_id, occurred_at DESC);

CREATE TABLE pace_actions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  domain TEXT NOT NULL,
  tool_name TEXT NOT NULL,
  input_json TEXT NOT NULL,
  original_instruction TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  completed_at TEXT,
  before_json TEXT,
  after_json TEXT,
  undo_payload TEXT,
  undone_at TEXT,
  error_message TEXT,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  UNIQUE (user_id, idempotency_key)
);
CREATE INDEX pace_actions_activity_idx ON pace_actions(user_id, created_at DESC);

CREATE TRIGGER kith_people_insert_change
AFTER INSERT ON kith_people
BEGIN
  INSERT INTO sync_changes (
    user_id, domain, entity_type, entity_id, operation, version, changed_at, payload_json
  ) VALUES (
    NEW.user_id,
    'kith',
    'person',
    NEW.id,
    CASE WHEN NEW.deleted_at IS NULL THEN 'upsert' ELSE 'delete' END,
    NEW.version,
    NEW.updated_at,
    json_object(
      'id', NEW.id,
      'name', NEW.name,
      'howWeMet', NEW.how_we_met,
      'circle', NEW.circle,
      'closeness', NEW.closeness,
      'hue', NEW.hue,
      'birthday', NEW.birthday,
      'standingNotes', NEW.standing_notes,
      'createdAt', NEW.created_at,
      'updatedAt', NEW.updated_at,
      'deletedAt', NEW.deleted_at,
      'version', NEW.version,
      'originDeviceId', NEW.origin_device_id
    )
  );
END;

CREATE TRIGGER kith_people_update_change
AFTER UPDATE ON kith_people
BEGIN
  INSERT INTO sync_changes (
    user_id, domain, entity_type, entity_id, operation, version, changed_at, payload_json
  ) VALUES (
    NEW.user_id,
    'kith',
    'person',
    NEW.id,
    CASE WHEN NEW.deleted_at IS NULL THEN 'upsert' ELSE 'delete' END,
    NEW.version,
    NEW.updated_at,
    json_object(
      'id', NEW.id,
      'name', NEW.name,
      'howWeMet', NEW.how_we_met,
      'circle', NEW.circle,
      'closeness', NEW.closeness,
      'hue', NEW.hue,
      'birthday', NEW.birthday,
      'standingNotes', NEW.standing_notes,
      'createdAt', NEW.created_at,
      'updatedAt', NEW.updated_at,
      'deletedAt', NEW.deleted_at,
      'version', NEW.version,
      'originDeviceId', NEW.origin_device_id
    )
  );
END;

CREATE TRIGGER kith_interactions_insert_change
AFTER INSERT ON kith_interactions
BEGIN
  INSERT INTO sync_changes (
    user_id, domain, entity_type, entity_id, operation, version, changed_at, payload_json
  ) VALUES (
    NEW.user_id,
    'kith',
    'interaction',
    NEW.id,
    CASE WHEN NEW.deleted_at IS NULL THEN 'upsert' ELSE 'delete' END,
    NEW.version,
    NEW.updated_at,
    json_object(
      'id', NEW.id,
      'personId', NEW.person_id,
      'kind', NEW.kind,
      'happenedOn', NEW.happened_on,
      'body', NEW.body,
      'createdAt', NEW.created_at,
      'updatedAt', NEW.updated_at,
      'deletedAt', NEW.deleted_at,
      'version', NEW.version,
      'originDeviceId', NEW.origin_device_id
    )
  );
END;

CREATE TRIGGER kith_interactions_update_change
AFTER UPDATE ON kith_interactions
BEGIN
  INSERT INTO sync_changes (
    user_id, domain, entity_type, entity_id, operation, version, changed_at, payload_json
  ) VALUES (
    NEW.user_id,
    'kith',
    'interaction',
    NEW.id,
    CASE WHEN NEW.deleted_at IS NULL THEN 'upsert' ELSE 'delete' END,
    NEW.version,
    NEW.updated_at,
    json_object(
      'id', NEW.id,
      'personId', NEW.person_id,
      'kind', NEW.kind,
      'happenedOn', NEW.happened_on,
      'body', NEW.body,
      'createdAt', NEW.created_at,
      'updatedAt', NEW.updated_at,
      'deletedAt', NEW.deleted_at,
      'version', NEW.version,
      'originDeviceId', NEW.origin_device_id
    )
  );
END;
