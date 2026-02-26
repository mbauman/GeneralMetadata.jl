#!/usr/bin/env bash
# post-start.sh
# Starts the PostgreSQL cluster each time the Codespace (re)starts.
# The cluster is created by post-create.sh; this script just brings it up.

set -euo pipefail

POSTGRESQL=17

sudo pg_ctlcluster ${POSTGRESQL} main start || true
