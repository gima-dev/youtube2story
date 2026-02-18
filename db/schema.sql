CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TABLE IF NOT EXISTS users (
  id BIGSERIAL PRIMARY KEY,
  telegram_user_id BIGINT NOT NULL UNIQUE,
  username TEXT,
  first_name TEXT,
  last_name TEXT,
  language_code TEXT,
  timezone TEXT,
  is_premium BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS quotas (
  id BIGSERIAL PRIMARY KEY,
  user_id BIGINT NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  period_start DATE NOT NULL,
  period_end DATE NOT NULL,
  max_jobs_per_period INTEGER NOT NULL DEFAULT 30 CHECK (max_jobs_per_period >= 0),
  max_seconds_per_period INTEGER NOT NULL DEFAULT 1800 CHECK (max_seconds_per_period >= 0),
  jobs_used INTEGER NOT NULL DEFAULT 0 CHECK (jobs_used >= 0),
  seconds_used INTEGER NOT NULL DEFAULT 0 CHECK (seconds_used >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (period_end >= period_start)
);

CREATE TABLE IF NOT EXISTS jobs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  sidekiq_jid TEXT UNIQUE,
  source_platform TEXT NOT NULL DEFAULT 'youtube' CHECK (source_platform IN ('youtube')),
  source_url TEXT NOT NULL,
  requested_duration_sec INTEGER CHECK (requested_duration_sec IS NULL OR requested_duration_sec >= 1),
  output_duration_sec INTEGER CHECK (output_duration_sec IS NULL OR output_duration_sec >= 0),
  status TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'processing', 'done', 'failed', 'cancelled')),
  stage TEXT,
  progress_percent SMALLINT NOT NULL DEFAULT 0 CHECK (progress_percent BETWEEN 0 AND 100),
  error_message TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  started_at TIMESTAMPTZ,
  finished_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (finished_at IS NULL OR started_at IS NULL OR finished_at >= started_at)
);

CREATE TABLE IF NOT EXISTS artifacts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id UUID NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('source_video', 'processed_video', 'thumbnail', 'audio', 'subtitle', 'log')),
  storage_backend TEXT NOT NULL DEFAULT 'local' CHECK (storage_backend IN ('local', 's3', 'url')),
  path TEXT NOT NULL,
  content_type TEXT,
  byte_size BIGINT CHECK (byte_size IS NULL OR byte_size >= 0),
  duration_sec INTEGER CHECK (duration_sec IS NULL OR duration_sec >= 0),
  width INTEGER CHECK (width IS NULL OR width > 0),
  height INTEGER CHECK (height IS NULL OR height > 0),
  sha256 TEXT,
  is_public BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS events (
  id BIGSERIAL PRIMARY KEY,
  job_id UUID REFERENCES jobs(id) ON DELETE CASCADE,
  user_id BIGINT REFERENCES users(id) ON DELETE SET NULL,
  event_type TEXT NOT NULL,
  level TEXT NOT NULL DEFAULT 'info' CHECK (level IN ('info', 'warn', 'error')),
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_jobs_user_id_created_at ON jobs(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_jobs_status_created_at ON jobs(status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_jobs_sidekiq_jid ON jobs(sidekiq_jid);
CREATE INDEX IF NOT EXISTS idx_artifacts_job_id_kind ON artifacts(job_id, kind);
CREATE INDEX IF NOT EXISTS idx_events_job_id_created_at ON events(job_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_events_user_id_created_at ON events(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_events_type_created_at ON events(event_type, created_at DESC);

DROP TRIGGER IF EXISTS trg_users_updated_at ON users;
CREATE TRIGGER trg_users_updated_at
BEFORE UPDATE ON users
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_quotas_updated_at ON quotas;
CREATE TRIGGER trg_quotas_updated_at
BEFORE UPDATE ON quotas
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_jobs_updated_at ON jobs;
CREATE TRIGGER trg_jobs_updated_at
BEFORE UPDATE ON jobs
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();
