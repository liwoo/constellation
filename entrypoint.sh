#!/bin/bash
# entrypoint.sh - Custom entrypoint script for Constellation application

# Exit on error
set -e

# Construct DATABASE_URL from individual environment variables
if [ -z "$DATABASE_URL" ]; then
    export DATABASE_URL="ecto://${DATABASE_USERNAME}:${DATABASE_PASSWORD}@${DATABASE_HOST}:${DATABASE_PORT}/${DATABASE_NAME}"
    echo "DATABASE_URL constructed from individual variables"
fi

# Extract database connection details
DB_NAME="${DATABASE_NAME}"
DB_HOST="${DATABASE_HOST}"
DB_PORT="${DATABASE_PORT}"
DB_USER="${DATABASE_USERNAME}"
DB_PASS="${DATABASE_PASSWORD}"

# Run migrations if the command is 'start'
if [ "${1}" = "start" ]; then
    echo "Checking database connection..."
    
    # Try to connect to the PostgreSQL server (without specifying a database)
    export PGPASSWORD="$DB_PASS"
    if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -c '\l' postgres > /dev/null 2>&1; then
        echo "Connected to PostgreSQL server"
        
        # Check if our database exists
        if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
            echo "Database $DB_NAME exists"
        else
            echo "Database $DB_NAME does not exist, creating..."
            psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -c "CREATE DATABASE $DB_NAME;" postgres
            echo "Database $DB_NAME created successfully"
        fi
        
        echo "Running database migrations..."
        /app/bin/constellation eval "Constellation.Release.migrate()"
        echo "Migrations completed successfully!"
    else
        echo "WARNING: Could not connect to PostgreSQL server. Migrations will be skipped."
        echo "The application will try to start, but may fail if database is required."
    fi
fi

# Execute the passed command
exec /app/bin/constellation "$@"
