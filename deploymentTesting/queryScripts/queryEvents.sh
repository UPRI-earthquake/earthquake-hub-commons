#!/bin/bash

# Set the MariaDB database connection details
DB_HOST="localhost"
DB_USER='<CHANGE_THIS_TO_YOUR_MYSQL_USERNAME>'
DB_PASSWORD='<CHANGE_THIS_TO_YOUR_MYSQL_PASSWORD>'
DB_NAME="seiscomp"

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
    print "{\"publicID\":\""$1"\",\"OT\":{\"$date\":\""$2"\"},\"latitude_value\":"$3",\"longitude_value\":"$4",\"depth_value\":"$5",\"magnitude_value\":"$6",\"type\":\""$7"\",\"text\":\""$8"\"}"
  }
  END{
    print "]"
  }
' temp.txt > "$OUTPUT_FILE"

# Remove the temporary file
rm temp.txt

echo "Query executed and JSON output saved to $OUTPUT_FILE"
