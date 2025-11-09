#!/usr/bin/env python3
import os
import psycopg2
from dotenv import load_dotenv
from pathlib import Path

load_dotenv()


class DatabaseMigrator:
    def __init__(self):
        self.supabase_url = os.environ.get('SUPABASE_URL')
        self.database_url = os.environ.get('DATABASE_URL')

        if not self.database_url and self.supabase_url:
            # Construct database URL from Supabase URL
            project_ref = self.supabase_url.split('//')[1].split('.')[0]
            self.database_url = f'postgresql://postgres:password@db.{project_ref}.supabase.co:5432/postgres'

        if not self.database_url:
            raise ValueError("DATABASE_URL or SUPABASE_URL environment variable is required")

        self.migrations_dir = Path('migrations')
        self.migrations_table = "schema_migrations"

    def get_connection(self):
        """Get database connection"""
        return psycopg2.connect(self.database_url)

    def ensure_migrations_table(self, conn):
        """Create migrations table if it doesn't exist"""
        with conn.cursor() as cur:
            cur.execute(f"""
                CREATE TABLE IF NOT EXISTS {self.migrations_table} (
                    id SERIAL PRIMARY KEY,
                    version VARCHAR(50) NOT NULL UNIQUE,
                    name VARCHAR(255) NOT NULL,
                    applied_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
                )
            """)
            conn.commit()

    def get_applied_migrations(self, conn):
        """Get list of applied migrations"""
        self.ensure_migrations_table(conn)

        with conn.cursor() as cur:
            cur.execute(f"SELECT version FROM {self.migrations_table} ORDER BY applied_at")
            return [row[0] for row in cur.fetchall()]

    def get_pending_migrations(self, applied_migrations):
        """Get list of pending migrations"""
        migrations = []
        for migration_file in sorted(self.migrations_dir.glob('*.sql')):
            version = migration_file.stem
            if version not in applied_migrations:
                migrations.append((version, migration_file))
        return migrations

    def apply_migration(self, conn, version, migration_file):
        """Apply a single migration"""
        print(f"Applying migration: {version}")

        try:
            with open(migration_file, 'r') as f:
                sql_content = f.read()

            with conn.cursor() as cur:
                # Split SQL content into individual statements
                statements = sql_content.split(';')
                for statement in statements:
                    statement = statement.strip()
                    if statement:
                        cur.execute(statement)

                # Record the migration
                cur.execute(
                    f"INSERT INTO {self.migrations_table} (version, name) VALUES (%s, %s)",
                    (version, migration_file.name)
                )

            conn.commit()
            print(f"✓ Successfully applied {version}")
            return True

        except Exception as e:
            conn.rollback()
            print(f"✗ Failed to apply {version}: {e}")
            return False

    def run_migrations(self, target_version=None):
        """Run all pending migrations"""
        print("Starting database migrations...")
        print(f"Database: {self.database_url.split('@')[-1]}")

        try:
            with self.get_connection() as conn:
                applied_migrations = self.get_applied_migrations(conn)
                pending_migrations = self.get_pending_migrations(applied_migrations)

                if not pending_migrations:
                    print("✓ No pending migrations")
                    return True

                print(f"Found {len(pending_migrations)} pending migration(s)")

                for version, migration_file in pending_migrations:
                    if target_version and version > target_version:
                        print(f"Skipping {version} (target version: {target_version})")
                        continue

                    success = self.apply_migration(conn, version, migration_file)
                    if not success:
                        return False

                print("✓ All migrations completed successfully")
                return True

        except Exception as e:
            print(f"✗ Migration failed: {e}")
            return False

    def status(self):
        """Show migration status"""
        try:
            with self.get_connection() as conn:
                applied_migrations = self.get_applied_migrations(conn)
                pending_migrations = self.get_pending_migrations(applied_migrations)

                print("Migration Status:")
                print("=================")
                print(f"Applied migrations: {len(applied_migrations)}")
                print(f"Pending migrations: {len(pending_migrations)}")

                if applied_migrations:
                    print("\nApplied:")
                    for migration in applied_migrations:
                        print(f"  ✓ {migration}")

                if pending_migrations:
                    print("\nPending:")
                    for version, _ in pending_migrations:
                        print(f"  ○ {version}")

        except Exception as e:
            print(f"Error getting status: {e}")


if __name__ == '__main__':
    DatabaseMigrator().run_migrations()
    pass
