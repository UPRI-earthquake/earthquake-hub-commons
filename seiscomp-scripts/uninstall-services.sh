#!/bin/bash

set -e

SCRIPTS_DIR=$(dirname "$(readlink -f "$0")")

SERVICES_DIR="$SCRIPTS_DIR/service-units"
LIST_OF_SERVICES="event-messaging-proxy.service pick-messaging-proxy.service"

# Stop and disable each service
for service in $LIST_OF_SERVICES; do
    sudo systemctl stop "$service" || true
    sudo systemctl disable "$service" || true
done

# Remove each service unit from /etc/systemd/system
for service in $LIST_OF_SERVICES; do
    sudo rm -f "/etc/systemd/system/$service"
done

# Reload systemctl
sudo systemctl daemon-reload

set +e

echo "Service units uninstalled successfully."

