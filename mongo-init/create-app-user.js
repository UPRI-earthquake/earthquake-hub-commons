// Runs once, on the first start of an empty MongoDB volume (docker-entrypoint-initdb.d).
// Creates the least-privilege user the backend connects with. The admin (root) user
// comes from MONGO_INITDB_ROOT_USERNAME / MONGO_INITDB_ROOT_PASSWORD.
// Existing volumes skip this script: create the user manually with the same command.
const user = process.env.MONGO_USER;
const pwd = process.env.MONGO_PASSWORD;
const appDb = process.env.MONGO_INITDB_DATABASE || 'latestEQs';

if (!user || !pwd) {
  throw new Error('MONGO_USER and MONGO_PASSWORD must be set to create the app user');
}

db.getSiblingDB('admin').createUser({
  user,
  pwd,
  roles: [{ role: 'readWrite', db: appDb }],
});

print(`Created app user "${user}" with readWrite on "${appDb}"`);
