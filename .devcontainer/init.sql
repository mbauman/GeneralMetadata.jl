-- init.sql
-- Runs once on first startup (via /docker-entrypoint-initdb.d/).
-- POSTGRES_USER/POSTGRES_PASSWORD/POSTGRES_DB (set in docker-compose.yml)
-- have already created the repology user and database by the time this runs.

GRANT pg_write_server_files TO repology;
GRANT CREATE ON SCHEMA public TO PUBLIC;
CREATE EXTENSION pg_trgm;
CREATE EXTENSION libversion;
