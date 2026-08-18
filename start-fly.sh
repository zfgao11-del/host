#!/bin/bash
set -e

echo "🚀 Starting 3MH Host Platform on Fly.io..."

# Directory preparation for Fly persistent volume mounted at /data
DATA_DIR="/data"
DB_PATH="$DATA_DIR/custom.db"
APPS_DIR="$DATA_DIR/apps"
LOGS_DIR="$DATA_DIR/logs"

mkdir -p "$DATA_DIR"
mkdir -p "$APPS_DIR"
mkdir -p "$LOGS_DIR"

# Initialize SQLite database if missing from persistent storage
if [ ! -f "$DB_PATH" ]; then
    echo "🗄️ Initializing SQLite database at $DB_PATH..."
    if [ -f "/app/db/custom.db" ]; then
        cp "/app/db/custom.db" "$DB_PATH"
        echo "✅ Seed database copied to $DB_PATH"
    else
        touch "$DB_PATH"
        echo "✅ Created new empty database at $DB_PATH"
    fi
fi

# Export DATABASE_URL for Prisma
export DATABASE_URL="file:$DB_PATH"

echo "🔄 Running Prisma database schema sync..."
cd /app
if command -v prisma &> /dev/null; then
    prisma db push --accept-data-loss || echo "⚠️ Database sync warning"
else
    bunx --yes prisma db push --accept-data-loss || echo "⚠️ Database sync warning"
fi

# Symlink persistent app and log directories
rm -rf /app/apps /app/logs
ln -s "$APPS_DIR" /app/apps
ln -s "$LOGS_DIR" /app/logs

# Store PIDs of child processes
PIDS=""

cleanup() {
    echo ""
    echo "🛑 Shutting down 3MH Host services..."
    for pid in $PIDS; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "   Stopping PID $pid..."
            kill -TERM "$pid" 2>/dev/null
        fi
    done
    sleep 2
    for pid in $PIDS; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null
        fi
    done
    echo "✅ All services stopped."
    exit 0
}

trap cleanup SIGTERM SIGINT

# 1. Start Next.js standalone server internally on port 3000
echo "🚀 Starting Next.js Web App on internal port 3000..."
PORT=3000 HOSTNAME="0.0.0.0" NODE_ENV="production" bun /app/server.js &
NEXT_PID=$!
PIDS="$PIDS $NEXT_PID"
echo "✅ Next.js started (PID: $NEXT_PID)"

# 2. Start Process Manager mini-service on port 3003
echo "🚀 Starting Process Manager on port 3003..."
(cd /app/mini-services/process-manager && bun index.ts) &
PM_PID=$!
PIDS="$PIDS $PM_PID"
echo "✅ Process Manager started (PID: $PM_PID)"

# 3. Start Terminal Service mini-service on port 3004
echo "🚀 Starting Terminal Service on port 3004..."
(cd /app/mini-services/terminal-service && bun index.ts) &
TERM_PID=$!
PIDS="$PIDS $TERM_PID"
echo "✅ Terminal Service started (PID: $TERM_PID)"

sleep 2

# 4. Start Caddy as primary foreground process listening on FLY HTTP port (default 8080)
FLY_PORT="${PORT:-8080}"
if [ "$FLY_PORT" = "3000" ]; then
    FLY_PORT="8080"
fi
export PORT="$FLY_PORT"

echo "🚀 Starting Caddy Reverse Proxy on public port $PORT..."
exec caddy run --config /app/Caddyfile
