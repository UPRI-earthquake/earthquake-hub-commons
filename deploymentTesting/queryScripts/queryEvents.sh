#!/bin/bash

# Parse command-line arguments
while getopts ":u:h:p:n:" opt; do
  case ${opt} in
    h) DB_HOST=${OPTARG} ;;
    u) DB_USER=${OPTARG} ;;
    p) DB_PASSWORD=${OPTARG} ;;
    \?) echo "Invalid option: -$OPTARG" >&2
      exit 1 ;;
    :) echo "Option -$OPTARG requires an argument." >&2
      exit 1 ;;
  esac
done

# Check if required parameters are provided
if [[ -z $DB_USER || -z $DB_HOST || -z $DB_PASSWORD ]]; then
  echo "Usage: $0 -h <DB_HOST> -u <DB_USER> -p <DB_PASSWORD>"
  exit 1
fi

DB_NAME='seiscomp'

# Define the output JSON file path
OUTPUT_FILE="./deploymentTesting/mongodb/data/events.json"

# Build the SQL query with direct start and end time values
SQL_QUERY=$(cat <<EOF
select 
  PEvent.publicID, 
  DATE_FORMAT(Origin.time_value, "%Y-%m-%dT%H:%i:%sZ") as OT, 
  Origin.latitude_value,
  Origin.longitude_value,
  Origin.depth_value,
  Magnitude.magnitude_value, 
  Magnitude.type, 
  EventDescription.text 
from 
  Origin,
  PublicObject as POrigin, 
  Event,
  PublicObject as PEvent, 
  Magnitude,
  PublicObject as PMagnitude,
  EventDescription
where 
  Event._oid=PEvent._oid 
  and Origin._oid=POrigin._oid 
  and Magnitude._oid=PMagnitude._oid 
  and PMagnitude.publicID=Event.preferredMagnitudeID 
  and POrigin.publicID=Event.preferredOriginID
  and Event._oid=EventDescription._parent_oid
  and EventDescription.type='region name'
EOF
)

# Execute the SQL query and save the output to a temporary file
mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" -D "$DB_NAME" \
  -e "$SQL_QUERY" --batch --raw \
  | tail -n +2 > temp.txt

# Check if the SQL query result is empty
if [[ ! -s temp.txt ]]; then
  echo "SQL query returns an empty array."
  rm temp.txt
  exit 0
fi

# Convert the tabular output to JSON using a custom script
# (NR) record number 
awk -F"\t" '
  BEGIN{
    OFS=","
    print "["
  }
  {
    if (NR > 1) {
      print ","
    }
    print "{\"publicID\":\"" $1 "\","
    print " \"OT\":{\"$date\":\"" $2 "\"},"
    print " \"latitude_value\":" $3 ","
    print " \"longitude_value\":" $4 ","
    print " \"depth_value\":" $5 ","
    print " \"magnitude_value\":" $6 ","
    print " \"type\":\"" $7 "\","
    print " \"text\":\"" $8 "\"}"
  }
  END{
    print "]"
  }
' temp.txt > "$OUTPUT_FILE"

# Remove the temporary file
rm temp.txt

echo "Query executed and JSON output saved to $OUTPUT_FILE"
