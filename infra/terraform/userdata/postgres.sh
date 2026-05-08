#!/bin/bash
set -euxo pipefail
exec > >(tee -a /var/log/userdata-postgres.log) 2>&1
log() { echo "[$(date -Is)] $*"; }
trap 'log "ERROR on line $LINENO"; exit 1' ERR

log "Install PostgreSQL 16"
dnf install -y postgresql16-server

log "Init database cluster"
if [[ ! -f /var/lib/pgsql/data/PG_VERSION ]]; then
  postgresql-setup --initdb
fi

CONF="/var/lib/pgsql/data/postgresql.conf"
HBA="/var/lib/pgsql/data/pg_hba.conf"

sed -i "s/^#\?listen_addresses.*/listen_addresses = '*'/g" "$CONF" || true
if ! grep -qE "^listen_addresses\s*=" "$CONF"; then
  echo "listen_addresses = '*'" >>"$CONF"
fi

if ! grep -q "10.0.0.0/16" "$HBA"; then
  echo "host  all  all  10.0.0.0/16  trust" >>"$HBA"
fi

log "Start PostgreSQL"
systemctl enable --now postgresql

for i in $(seq 1 30); do
  if sudo -u postgres psql -d postgres -c "SELECT 1" >/dev/null 2>&1; then
    break
  fi
  sleep 1
  if [[ "$i" -eq 30 ]]; then
    log "PostgreSQL did not start in time"
    systemctl --no-pager -l status postgresql || true
    exit 1
  fi
done

log "Create database, user, schema, seed data (idempotent)"
sudo -u postgres psql -d postgres -v ON_ERROR_STOP=0 <<'USERSQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'passports_user') THEN
    CREATE ROLE passports_user WITH LOGIN PASSWORD 'passports_pass';
  END IF;
END
$$;
USERSQL

if ! sudo -u postgres psql -d postgres -tc "SELECT 1 FROM pg_database WHERE datname = 'passports'" | grep -q 1; then
  sudo -u postgres createdb passports -O passports_user
fi

sudo -u postgres psql -d passports -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS applications (
  id            SERIAL PRIMARY KEY,
  citizen_ref   VARCHAR(64)  NOT NULL,
  fee_type      VARCHAR(64)  NOT NULL,
  status        VARCHAR(32)  NOT NULL,
  created_at    TIMESTAMP    NOT NULL DEFAULT now(),
  updated_at    TIMESTAMP    NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_applications_status ON applications (status);
CREATE INDEX IF NOT EXISTS idx_applications_fee_type ON applications (fee_type);
GRANT ALL PRIVILEGES ON TABLE applications TO passports_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO passports_user;
SQL

EXISTING=$(sudo -u postgres psql -d passports -t -A -c "SELECT count(*) FROM applications" | tr -d '[:space:]' || echo 0)
if [[ "${EXISTING:-0}" -eq 0 ]]; then
  sudo -u postgres psql -d passports -v ON_ERROR_STOP=1 <<'SEEDSQL'

-- Healthy applications: mix of statuses, recent timestamps (last few days)
INSERT INTO applications (citizen_ref, fee_type, status, created_at, updated_at)
SELECT
  'CZ-' || LPAD(i::text, 5, '0'),
  (ARRAY['fee.standard.adult','fee.standard.child','fee.priority.adult','fee.priority.child'])[1 + (random()*3)::int],
  (ARRAY['paid_pending_processing','processing','complete'])[1 + (random()*2)::int],
  now() - (random() * interval '5 days'),
  now() - (random() * interval '2 days')
FROM generate_series(1, 60) AS i;

-- Working application: priority adult, paid around the same time as the stuck
-- ones but progressed normally because fee.priority.adult routes correctly.
-- This is the contrast citizen for the demo.
INSERT INTO applications (citizen_ref, fee_type, status, created_at, updated_at) VALUES
  ('CIT-CLARK04', 'fee.priority.adult', 'processing', now() - interval '15 days', now() - interval '13 days');

-- Stuck applications: standard adult, payment was received weeks ago but
-- never progressed to processing. These citizens see "Payment Received -
-- Awaiting Processing" for 14+ days and call the contact centre.
-- Fixed refs for demo use:
INSERT INTO applications (citizen_ref, fee_type, status, created_at, updated_at) VALUES
  ('CIT-SMITH01', 'fee.standard.adult', 'paid_pending_processing', now() - interval '16 days', now() - interval '14 days'),
  ('CIT-JONES02', 'fee.standard.adult', 'paid_pending_processing', now() - interval '18 days', now() - interval '15 days'),
  ('CIT-PATEL03', 'fee.standard.adult', 'paid_pending_processing', now() - interval '20 days', now() - interval '17 days');
-- Additional random stuck records
INSERT INTO applications (citizen_ref, fee_type, status, created_at, updated_at)
SELECT
  'CIT-' || chr(65 + (random()*25)::int) || chr(65 + (random()*25)::int) || LPAD((1000 + i)::text, 4, '0'),
  'fee.standard.adult',
  'paid_pending_processing',
  now() - interval '18 days' - (random() * interval '4 days'),
  now() - interval '14 days' - (random() * interval '3 days')
FROM generate_series(1, 22) AS i;

-- Normal awaiting_payment (recent, not stuck yet)
INSERT INTO applications (citizen_ref, fee_type, status, created_at, updated_at)
SELECT
  'CZ-' || LPAD((100 + i)::text, 5, '0'),
  (ARRAY['fee.standard.adult','fee.standard.child','fee.priority.adult'])[1 + (random()*2)::int],
  'awaiting_payment',
  now() - (random() * interval '1 day'),
  now() - (random() * interval '1 day')
FROM generate_series(1, 15) AS i;

SEEDSQL
fi

sudo -u postgres psql -d passports -c "ANALYZE applications;"

log "PostgreSQL user-data completed successfully; rows=$(sudo -u postgres psql -d passports -t -c 'SELECT count(*) FROM applications' | tr -d '[:space:]')"
