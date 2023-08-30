#!/bin/bash

set -e # exit if any error is encountered

SCRIPTS_DIR=$(dirname "$(readlink -f "$0")")
LIST_OF_SCRIPTS="event_messaging_proxy.py pick_messaging_proxy.py"

SERVICES_DIR="$SCRIPTS_DIR/service-units"
LIST_OF_SERVICES="event-messaging-proxy.service pick-messaging-proxy.service"

PYTHON3_PATH="$SCRIPTS_DIR/.venv/bin/python3"

# Create venv
if [ ! -d "$SCRIPTS_DIR/.venv" ]; then
    python3 -m venv "$SCRIPTS_DIR/.venv" && echo "Created python3 venv"
fi

# Install dependencies from SCRIPTS_DIR/requirements.txt via venv
echo "Installing python script dependencies"
"$PYTHON3_PATH" -m pip install -r "$SCRIPTS_DIR/requirements.txt"

# Make each script executable
chmod +x $SCRIPTS_DIR/*.py

# Create a copy of each service unit template
for service in $LIST_OF_SERVICES; do
    cp "$SERVICES_DIR/$service.template" "$SERVICES_DIR/$service"
done

# Replace placeholders in each of the service units
for service in $LIST_OF_SERVICES; do
    sed -i "s|<user>|$USER|g; s|<scripts-dir>|$SCRIPTS_DIR|g; s|<python3-path>|$PYTHON3_PATH|g" "$SERVICES_DIR/$service"
done

# Copy each service unit to /etc/systemd/system
for service in $LIST_OF_SERVICES; do
    sudo cp "$SERVICES_DIR/$service" "/etc/systemd/system/$service"
done

# Reload systemctl
sudo systemctl daemon-reload

# Enable and start each service
for service in $LIST_OF_SERVICES; do
    sudo systemctl enable "$service"
    sudo systemctl restart "$service"
done

set +e # disable exit on error

echo "Service units installed successfully."
