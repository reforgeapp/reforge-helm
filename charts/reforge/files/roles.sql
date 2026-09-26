\getenv migrator_password REFORGE_MIGRATOR_PASSWORD
\getenv runtime_password REFORGE_RUNTIME_PASSWORD
\getenv migrator_url REFORGE_MIGRATION_DATABASE_URL
\getenv runtime_url REFORGE_DATABASE_URL
\getenv database_name PGDATABASE
SELECT CASE
    WHEN coalesce(nullif(:'migrator_password', '__FROM_DATABASE_URL__'), substring(:'migrator_url' FROM '^[^:]+://[^:]+:([^@]+)@')) IS NOT NULL
         AND length(coalesce(nullif(:'migrator_password', '__FROM_DATABASE_URL__'), substring(:'migrator_url' FROM '^[^:]+://[^:]+:([^@]+)@'))) > 0
     AND coalesce(nullif(:'runtime_password', '__FROM_DATABASE_URL__'), substring(:'runtime_url' FROM '^[^:]+://[^:]+:([^@]+)@')) IS NOT NULL
         AND length(coalesce(nullif(:'runtime_password', '__FROM_DATABASE_URL__'), substring(:'runtime_url' FROM '^[^:]+://[^:]+:([^@]+)@'))) > 0
    THEN 'SELECT 1'
    ELSE 'DO $failure$ BEGIN RAISE EXCEPTION ''migration and runtime passwords must be non-empty''; END $failure$'
END
\gexec
SELECT coalesce(nullif(:'migrator_password', '__FROM_DATABASE_URL__'), substring(:'migrator_url' FROM '^[^:]+://[^:]+:([^@]+)@')) AS migrator_password \gset
SELECT coalesce(nullif(:'runtime_password', '__FROM_DATABASE_URL__'), substring(:'runtime_url' FROM '^[^:]+://[^:]+:([^@]+)@')) AS runtime_password \gset
\o /dev/null
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_database d
        JOIN pg_roles r ON r.oid = d.datdba
        WHERE d.datname = current_database()
          AND r.rolname IN (current_user, 'reforge_migrator')
    ) THEN
        RAISE EXCEPTION 'database owner must be the configured PostgreSQL bootstrap user or reforge_migrator; migrate custom-owned databases explicitly';
    END IF;
END
$$;
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_auth_members m
        JOIN pg_roles r ON r.oid = m.member
        WHERE r.rolname IN ('reforge_migrator', 'reforge_runtime')
    ) THEN
        RAISE EXCEPTION 'migration and runtime roles must not inherit other roles; review existing memberships explicitly';
    END IF;
END
$$;
SELECT format('CREATE ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD %L', 'reforge_migrator', :'migrator_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reforge_migrator')
\gexec
SELECT format('ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD %L', 'reforge_migrator', :'migrator_password')
WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reforge_migrator')
\gexec
SELECT format('CREATE ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD %L', 'reforge_runtime', :'runtime_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reforge_runtime')
\gexec
SELECT format('ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD %L', 'reforge_runtime', :'runtime_password')
WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reforge_runtime')
\gexec
SELECT format('ALTER DATABASE %I OWNER TO reforge_migrator', :'database_name')
WHERE EXISTS (
    SELECT 1 FROM pg_database d
    JOIN pg_roles r ON r.oid = d.datdba
    WHERE d.datname = :'database_name' AND r.rolname = current_user
)
\gexec
DO $$
BEGIN
    IF (
        SELECT count(*) = 2 AND bool_and(
            rolcanlogin AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole
            AND NOT rolreplication AND NOT rolbypassrls AND rolpassword IS NOT NULL
        )
        FROM pg_roles
        WHERE rolname IN ('reforge_migrator', 'reforge_runtime')
    ) IS NOT TRUE THEN
        RAISE EXCEPTION 'migration and runtime roles must be non-superuser login roles with passwords';
    END IF;
END
$$;
\o
