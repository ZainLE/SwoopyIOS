#!/bin/bash

set -e

echo "Starting Swoopy API with cron job support..."

mkdir -p /var/log

echo "Installing cron job..."
crontab /app/crontab

echo "Starting cron daemon..."
cron

sleep 2

# Check if cron jobs were installed successfully
if crontab -l > /dev/null 2>&1; then
    echo "✅ Cron daemon is running"
    echo "📅 Cron jobs installed:"
    crontab -l
else
    echo "❌ Failed to install cron jobs"
    exit 1
fi

# Start Flask application
echo "🚀 Starting Flask application..."
exec flask run --host=0.0.0.0 --port=5555
