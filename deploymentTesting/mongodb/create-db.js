// Create DB and collections
db = new Mongo().getDB("latestEQs");
db.createCollection("accounts", { capped: false });
db.createCollection("accountdetails", { capped: false });
db.createCollection("devices", { capped: false });
