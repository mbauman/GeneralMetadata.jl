FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG POSTGRESQL=17

# Install only the PostgreSQL client tools (psql etc.) so the developer can
# connect to the postgres:17 service container defined in docker-compose.yml.
RUN install -dm 755 /etc/apt/keyrings \
    && curl -s https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/keyrings/pgdg.gpg \
    && sh -c 'echo "deb [signed-by=/etc/apt/keyrings/pgdg.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list' \
    && apt-get update \
    && apt-get install -y postgresql-client-${POSTGRESQL} \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
