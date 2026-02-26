#!/usr/bin/env bash
# post-create.sh
# Builds and installs libversion and the postgresql-libversion extension from
# source, then creates and configures the PostgreSQL cluster used for
# repology work — mirroring .github/workflows/repology.yml.

set -euo pipefail

POSTGRESQL=17

# ---------------------------------------------------------------------------
# libversion
# ---------------------------------------------------------------------------
mkdir /tmp/_libversion
cd /tmp/_libversion
wget -qO- https://github.com/repology/libversion/archive/master.tar.gz | tar -xzf- --strip-components 1
cmake .
make
sudo make install
sudo ldconfig

# ---------------------------------------------------------------------------
# postgresql-libversion extension
# ---------------------------------------------------------------------------
mkdir /tmp/_postgresql-libversion
cd /tmp/_postgresql-libversion
wget -qO- https://github.com/repology/postgresql-libversion/archive/master.tar.gz | tar -xzf- --strip-components 1
make PG_CONFIG="/usr/lib/postgresql/${POSTGRESQL}/bin/pg_config"
sudo make install PG_CONFIG="/usr/lib/postgresql/${POSTGRESQL}/bin/pg_config"

# ---------------------------------------------------------------------------
# PostgreSQL cluster setup (mirrors "Setup database" GHA step)
# Creates a cluster on port 5433 to match the workflow, then creates the
# repology database/user and enables required extensions.
# ---------------------------------------------------------------------------
sudo pg_createcluster ${POSTGRESQL} main --start -- --port=5433

sudo -u postgres psql -p 5433 -c "CREATE DATABASE repology"
sudo -u postgres psql -p 5433 -c "CREATE USER repology WITH PASSWORD 'repology'"
sudo -u postgres psql -p 5433 -c "GRANT ALL ON DATABASE repology TO repology"
sudo -u postgres psql -p 5433 -c "GRANT pg_write_server_files TO repology"
sudo -u postgres psql -p 5433 --dbname repology -c "GRANT CREATE ON SCHEMA public TO PUBLIC"
sudo -u postgres psql -p 5433 --dbname repology -c "CREATE EXTENSION pg_trgm"
sudo -u postgres psql -p 5433 --dbname repology -c "CREATE EXTENSION libversion"
