#!/bin/sh

# This script is used to MANUALLY import json data from ./data/
# folder into the persistent mongodb volume. That volume is also
# used by the other repositories which has a mongodb container.
# Note that this drops the collections first before importing the
# contents of the json files.

# NOTE: Run this script from git repo root directory,
#       and the mongo container should be running

echo "--- Re-importing data into Docker Mongo DB volume ---"

# Set the name of the Docker MongoDB container
CONTAINER_NAME="mongodb-dep-test"

# Set the name of the MongoDB database
DB_NAME="latestEQs"

# Set the path containing the json files
PATH_TO_JSON_FILES="./deploymentTesting/mongodb/data"

# Import the data into the collection, dropping it first
# Note that the json file is on the host, not in the container
docker exec -i "$CONTAINER_NAME" mongoimport \
  --db "$DB_NAME" \
  --collection "accounts" \
  --jsonArray \
  --drop \
  < "$PATH_TO_JSON_FILES/accounts.json"

docker exec -i "$CONTAINER_NAME" mongoimport \
  --db "$DB_NAME" \
  --collection "devices" \
  --jsonArray \
  --drop \
  < "$PATH_TO_JSON_FILES/devices.json"

docker exec -i "$CONTAINER_NAME" mongoimport \
  --db "$DB_NAME" \
  --collection "events" \
  --jsonArray \
  --drop \
  < "$PATH_TO_JSON_FILES/events.json"

