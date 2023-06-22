#!/bin/bash

# Set the MariaDB database connection details
DB_HOST="localhost"
DB_USER="jc"
DB_PASSWORD="1008"
DB_NAME="seiscomp"

# Define the output JSON file path
OUTPUT_FILE="./scripts/output/stations.json"

SQL_QUERY=$(cat <<EOF
select 
  code, 
  latitude, 
  longitude, 
  description 
from 
  Station AS table1
where 
  end IS NULL;
EOF
)

# Execute the SQL query and save the output to a temporary file
mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" -D "$DB_NAME" \
  -e "$SQL_QUERY" --batch --raw \
  | tail -n +2 > temp.txt

# Convert the tabular output to JSON using a custom script
awk -F"\t" 'BEGIN{OFS=","; print "["} {print "{\"code\":\""$1"\",\"latitude\":\""$2"\",\"longitude\":\""$3"\",\"description\":\""$4"\"}"} END{print "]"}' temp.txt \
  > "$OUTPUT_FILE"

# Remove the temporary file
rm temp.txt

echo "Query executed and JSON output saved to $OUTPUT_FILE"
