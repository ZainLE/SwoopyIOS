#!/bin/bash
# Street Post Expiration Cron Job
# This script should be added to crontab to run every 5 minutes
# Add this line to crontab: */5 * * * * /path/to/this/script.sh

# Set the API directory (use environment variable or default)
API_DIR="${SWOOPY_API_DIR:-/app}"

# Change to the API directory
cd "$API_DIR"

# Activate virtual environment if it exists
if [ -f "venv/bin/activate" ]; then
    source venv/bin/activate
fi

# Run the expiration handler
python -m app.tasks.expire_street_posts

# Log execution (use environment variable for log path or default)
LOG_FILE="${SWOOPY_LOG_FILE:-/var/log/swoopy_expiration.log}"
echo "$(date): Street post expiration handler executed" >> "$LOG_FILE"
