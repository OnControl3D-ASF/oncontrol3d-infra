-- Separate database for the auth service (same Postgres server as clinical).
-- Runs ONLY on a fresh data volume (docker-entrypoint-initdb.d); on an existing
-- volume run `docker compose down -v` or create it by hand:
--   docker compose exec postgres psql -U postgres -c 'CREATE DATABASE oncontrol_auth'
CREATE DATABASE oncontrol_auth;
