#!/bin/bash

echo "########### Loading data to Mongo DB ###########"
mongoimport --jsonArray --db latestEQs --collection accountdetails --file /tmp/data/accountdetails.json
mongoimport --jsonArray --db latestEQs --collection accounts --file /tmp/data/accounts.json
mongoimport --jsonArray --db latestEQs --collection devices --file /tmp/data/devices.json