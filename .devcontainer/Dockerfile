FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG POSTGRESQL=17

# Install PostgreSQL 17 from the official PGDG apt repository,
# along with build tools needed to compile libversion and the
# postgresql-libversion extension (mirrors the GHA repology.yml setup).
RUN install -dm 755 /etc/apt/keyrings \
    && curl -s https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/keyrings/pgdg.gpg \
    && sh -c 'echo "deb [signed-by=/etc/apt/keyrings/pgdg.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list' \
    && apt-get update \
    && apt-get install -y \
        postgresql-${POSTGRESQL} \
        postgresql-server-dev-${POSTGRESQL} \
        cmake \
        wget \
        build-essential \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
