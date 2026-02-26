#!/usr/bin/env bash
# post-create.sh
# Builds and installs libversion and the postgresql-libversion extension from
# source, mirroring the "Install libversion" and "Install postgresql-libversion"
# steps in .github/workflows/repology.yml.

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
