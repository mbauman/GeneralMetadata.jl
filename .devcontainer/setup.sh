#!/bin/bash
set -e

POSTGRESQL=17

# Install PostgreSQL and build dependencies (matching workflow)
sudo apt-get update -q
sudo apt-get install -y -q \
    postgresql-${POSTGRESQL} \
    postgresql-server-dev-${POSTGRESQL} \
    cmake \
    build-essential \
    wget \
    zstd

# Install libversion (following workflow steps exactly)
mkdir /tmp/_libversion
cd /tmp/_libversion
wget -qO- https://github.com/repology/libversion/archive/master.tar.gz | tar -xzf- --strip-components 1
cmake .
make
sudo make install
sudo ldconfig

# Install postgresql-libversion (following workflow steps exactly)
mkdir /tmp/_postgresql-libversion
cd /tmp/_postgresql-libversion
wget -qO- https://github.com/repology/postgresql-libversion/archive/master.tar.gz | tar -xzf- --strip-components 1
make
sudo make install

# Setup database on port 5433 (matching CI environment)
# On a fresh Ubuntu 24.04, apt creates a cluster on 5432. Reconfigure to 5433.
sudo pg_ctlcluster ${POSTGRESQL} main stop || true
sudo sed -i "s/^port = .*/port = 5433/" /etc/postgresql/${POSTGRESQL}/main/postgresql.conf
sudo pg_ctlcluster ${POSTGRESQL} main start

sudo -u postgres psql -p 5433 -c "CREATE DATABASE repology"
sudo -u postgres psql -p 5433 -c "CREATE USER repology WITH PASSWORD 'repology'"
sudo -u postgres psql -p 5433 -c "GRANT ALL ON DATABASE repology TO repology"
sudo -u postgres psql -p 5433 -c "GRANT pg_write_server_files TO repology"
sudo -u postgres psql -p 5433 --dbname repology -c "GRANT CREATE ON SCHEMA public TO PUBLIC"
sudo -u postgres psql -p 5433 --dbname repology -c "CREATE EXTENSION pg_trgm"
sudo -u postgres psql -p 5433 --dbname repology -c "CREATE EXTENSION libversion"

# Install Julia dependencies
julia --project=/workspaces/GeneralMetadata.jl -e 'using Pkg; Pkg.instantiate()'
