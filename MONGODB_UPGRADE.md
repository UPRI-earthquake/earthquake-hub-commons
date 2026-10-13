# MongoDB 8.0 + Auth Upgrade: Pre-Deployment Runbook

This runbook covers everything to do **before** the MongoDB changes in this repo reach the `dev` branch and the servers. Follow it in order, first on **dep-test**, then on **prod**.

> **Why this needs care:** the new compose files turn on MongoDB authentication. On a server whose database volume already exists, MongoDB will **not** create any users automatically. If you deploy without doing the steps below, MongoDB starts with auth on and no users, and the backend is locked out (site down).

---

## Contents

1. [What's changing](#1-whats-changing)
2. [Git workflow: work on a branch, merge last](#2-git-workflow-work-on-a-branch-merge-last)
3. [Pre-flight checklist](#3-pre-flight-checklist)
4. [Choose your path](#4-choose-your-path)
5. [Path A: fresh database (no data to keep)](#5-path-a-fresh-database-no-data-to-keep)
6. [Path B: existing database (keep the data)](#6-path-b-existing-database-keep-the-data)
7. [Verify](#7-verify)
8. [Rollback](#8-rollback)
9. [Merge and tell the team](#9-merge-and-tell-the-team)

---

## 1. What's changing

| Change | Files |
|---|---|
| MongoDB image `mongo:5.0` (end-of-life) → `mongo:8.0.32` | `docker-compose.yml`, `docker-compose.dep-test.yml` |
| Authentication on, with an `admin` user and a least-privilege app user `ehub_app` | same, plus [`mongo-init/create-app-user.js`](mongo-init/create-app-user.js) |
| Single-node replica set `rs0` (needed for transactions), initiated by the container healthcheck | compose files |
| Backend waits until MongoDB is healthy before starting | compose files |
| New environment variables | [`.env.example`](.env.example) |

New variables (must be in the server's env file before deploying):

```env
MONGO_INITDB_ROOT_USERNAME=admin
MONGO_INITDB_ROOT_PASSWORD=
MONGO_USER=ehub_app
MONGO_PASSWORD=
MONGO_AUTH_SOURCE=admin
MONGO_REPLICA_SET=rs0
```

The backend side of this change is in `earthquake-hub-backend` (`src/services/mongodb.service.js`, plus `MONGODB.md` for connecting with Compass).

### MongoDB accounts on each server

| Account | Role | Used by | Used for |
|---|---|---|---|
| `admin` | `root` | Only the 1–2 people who manage the server | Creating and removing users, backups, upgrades, maintenance |
| `ehub_app` | `readWrite` on `latestEQs` only | The backend app | Everyday reads and writes. People don't log in with it. |
| Personal users (optional) | e.g. `read` on `latestEQs` | Individual developers | Browsing server data through an SSH tunnel. Created by `admin`; see `earthquake-hub-backend/MONGODB.md`, section 3. |

Things to know about `admin`:

- **How it's created:** automatically from `MONGO_INITDB_ROOT_*` on an empty volume (Path A), or by hand in step 6.5 on an existing volume (Path B).
- **The container healthcheck logs in as `admin`** to check and initiate the replica set. If the password in the env file doesn't match the account, MongoDB never becomes healthy and the backend won't start.
- **Use different passwords** for dep-test and prod, keep them in the team's password manager, and never share them in chat or git.
- **Anyone who can read the server's env file can see the admin password**, so keep SSH access limited. Give developers their own read-only users instead of the admin password.

---

## 2. Git workflow: work on a branch, merge last

Keep these changes **off `dev`** until both servers are done. Anyone who pulls `dev` and redeploys before then would take the site down.

### 2.1 Create the branch from `dev`

```sh
cd earthquake-hub-commons
git switch dev
git pull origin dev
git switch -c chore/mongodb-8-auth
```

### 2.2 Commit only the MongoDB changes

`docker-compose.dep-test.yml` may also contain an unrelated `UPLOAD_DIR` / `UPLOAD_PUBLIC_PATH` change. Keep that in its own commit:

```sh
git add mongo-init/ .env.example docker-compose.yml MONGODB_UPGRADE.md README.md
git add -p docker-compose.dep-test.yml   # answer "y" for MongoDB hunks, "n" for the UPLOAD_DIR hunk
git commit -m "feat(db): upgrade MongoDB to 8.0 with auth and replica set"

# then, separately:
git add docker-compose.dep-test.yml
git commit -m "fix(dep-test): pass UPLOAD_DIR and UPLOAD_PUBLIC_PATH to backend"
```

### 2.3 Push the branch and open a PR (don't merge yet)

```sh
git push -u origin chore/mongodb-8-auth
```

Open a PR from `chore/mongodb-8-auth` into `dev`. In the description, write:

> **Do not merge until dep-test and prod have been migrated per `MONGODB_UPGRADE.md`.**

### 2.4 Deploy from the branch

On each server, check out the branch when you reach the deploy step (5.4 or 6.6):

```sh
git fetch origin
git switch chore/mongodb-8-auth
```

Merge into `dev` only after both servers pass [Verify](#7-verify). See [section 9](#9-merge-and-tell-the-team).

---

## 3. Pre-flight checklist

Tick all of these before touching a server.

- [ ] **Backend image is updated.** The backend image the servers pull (`ghcr.io/upri-earthquake/earthquake-hub-backend:latest`) must include the auth-aware `mongodb.service.js` from `earthquake-hub-backend` `dev`. An older image ignores `MONGO_USER` and will fail to log in. There's no CI, so whoever publishes the image builds and pushes it manually.
- [ ] **Someone has server access** with permission to run `docker`, and knows where the stack's env file is (`.env` for prod, `.dep-test.env` for dep-test).
- [ ] **Passwords generated** for `admin` and `ehub_app` (different for each server). Generate with:
  ```sh
  node -e "console.log(require('crypto').randomBytes(24).toString('base64url'))"
  # or: openssl rand -base64 24 | tr '+/' '-_' | tr -d '='
  ```
  Store them in the team's password manager, not in chat or git.
- [ ] **Maintenance window agreed.** Path A: about 5 minutes of downtime. Path B: 15–30 minutes. Avoid running this during an active earthquake sequence.
- [ ] **Team told** that `dev` will change after the migration, and that local setups will need `.env` updates (see `earthquake-hub-backend/MONGODB.md`).
- [ ] **Decided which path** each server takes ([section 4](#4-choose-your-path)).

---

## 4. Choose your path

Check whether the server's database has data worth keeping:

```sh
# prod
docker exec mongodb mongosh --quiet latestEQs --eval "db.getCollectionNames().map(c => c + ': ' + db[c].countDocuments())"
# dep-test
docker exec mongodb-dep-test mongosh --quiet latestEQs --eval "db.getCollectionNames().map(c => c + ': ' + db[c].countDocuments())"
```

If `mongosh` isn't found in the 5.0 container, use `mongo` instead.

| Result | Path |
|---|---|
| Empty, or only test data nobody needs | **[Path A](#5-path-a-fresh-database-no-data-to-keep)**: recreate the volume |
| Real accounts, devices, events or comments | **[Path B](#6-path-b-existing-database-keep-the-data)**: upgrade in place |

Server values used below:

| | prod | dep-test |
|---|---|---|
| Compose command | `docker compose` | `docker compose -f docker-compose.dep-test.yml --env-file .dep-test.env` |
| MongoDB service / container | `mongodb` | `mongodb-dep-test` |
| Backend service | `ehub-backend` | `earthquake-hub-backend-dep-test` |
| Volume | `earthquake-hub-mongodb-data` | `earthquake-hub-mongodb-data-dep-test` |
| Env file | `.env` | `.dep-test.env` |

The commands in sections 5–7 use the **prod** names. On dep-test, substitute the values from the right-hand column.

---

## 5. Path A: fresh database (no data to keep)

**5.1** Add the new variables ([section 1](#1-whats-changing)) with real passwords to the server's env file.

**5.2** Stop the stack:

```sh
docker compose down
```

**5.3** Recreate the volume. This **deletes all data** in it.

```sh
docker volume rm earthquake-hub-mongodb-data
docker volume create earthquake-hub-mongodb-data
```

**5.4** Switch to the branch ([2.4](#24-deploy-from-the-branch)), pull images and start:

```sh
docker compose pull
docker compose up -d
```

On the first start, MongoDB creates both users and the healthcheck initiates the replica set. Continue to [Verify](#7-verify).

---

## 6. Path B: existing database (keep the data)

MongoDB can only upgrade **one major version at a time**: 5.0 → 6.0 → 7.0 → 8.0. Each step starts a temporary container on the existing volume and raises the `featureCompatibilityVersion` (FCV). All of this runs **without auth**, using the **old** compose still checked out.

**6.1 Back up first.** If anything goes wrong, this dump is the only way back.

```sh
docker exec mongodb mongodump --archive --gzip > ~/mongo-backup-$(date +%F)-pre-8.0.gz
ls -lh ~/mongo-backup-*.gz       # check it isn't empty
```

Copy the file off the server too.

**6.2 Check the current FCV.** It must be `5.0` before you start.

```sh
docker exec mongodb mongosh --quiet --eval "db.adminCommand({ getParameter: 1, featureCompatibilityVersion: 1 })"
```

If it shows `4.4`, first run `db.adminCommand({ setFeatureCompatibilityVersion: "5.0" })` on the 5.0 container.

**6.3 Stop the backend and MongoDB:**

```sh
docker compose stop ehub-backend mongodb
```

**6.4 Step through the versions.** Run each block in order and wait for the `ok: 1` in each output before moving on.

```sh
VOL=earthquake-hub-mongodb-data

# --- 6.0 ---
docker run -d --name mongo-upgrade -v $VOL:/data/db mongo:6.0
sleep 15
docker exec mongo-upgrade mongosh --quiet --eval 'db.adminCommand({ setFeatureCompatibilityVersion: "6.0" })'
docker rm -f mongo-upgrade

# --- 7.0 (from 7.0, the FCV command needs confirm: true) ---
docker run -d --name mongo-upgrade -v $VOL:/data/db mongo:7.0
sleep 15
docker exec mongo-upgrade mongosh --quiet --eval 'db.adminCommand({ setFeatureCompatibilityVersion: "7.0", confirm: true })'
docker rm -f mongo-upgrade

# --- 8.0 ---
docker run -d --name mongo-upgrade -v $VOL:/data/db mongo:8.0.32
sleep 15
docker exec mongo-upgrade mongosh --quiet --eval 'db.adminCommand({ setFeatureCompatibilityVersion: "8.0", confirm: true })'
# keep this container running for step 6.5
```

If a container exits right away, check `docker logs mongo-upgrade`. It usually means the previous step's FCV wasn't set.

**6.5 Create the two users** on the 8.0 container, while auth is still off. `passwordPrompt()` asks for each password so it doesn't end up in your shell history; paste the values from your password manager.

```sh
docker exec -it mongo-upgrade mongosh
```

```js
use admin
db.createUser({ user: "admin", pwd: passwordPrompt(), roles: ["root"] })
db.createUser({ user: "ehub_app", pwd: passwordPrompt(), roles: [{ role: "readWrite", db: "latestEQs" }] })
db.getUsers().users.map(u => u.user)   // → [ 'admin', 'ehub_app' ]
exit
```

```sh
docker rm -f mongo-upgrade
```

The usernames and passwords must match exactly what you put in the env file in the next step.

**6.6 Add the new variables** ([section 1](#1-whats-changing)) to the server's env file, then switch to the branch ([2.4](#24-deploy-from-the-branch)) and start:

```sh
docker compose pull
docker compose up -d
```

MongoDB now starts with auth and `--replSet rs0`, and the healthcheck initiates the replica set on the existing data. Continue to [Verify](#7-verify).

---

## 7. Verify

Run on the server:

```sh
docker compose ps
# mongodb → (healthy); backend → Up

docker exec mongodb mongosh --quiet latestEQs --eval "db.accounts.countDocuments()"
# → MongoServerError: ... requires authentication      (auth is on)

docker exec -it mongodb mongosh --quiet -u admin -p --authenticationDatabase admin --eval "rs.status().members[0].stateStr"
# → PRIMARY  (enter the admin password when asked)

docker logs --tail 30 ehub-backend
# → "listening", no "Authentication failed", no "transactions are not supported"
```

Then in a browser:

- [ ] The site loads and the event list shows data (Path B: the same events as before).
- [ ] You can log in with an existing account (Path B) or register a test account (Path A).
- [ ] Port 27017 is not reachable from outside the server: from another machine, `nc -zv <server> 27017` should fail.

For Path B, also compare document counts with the numbers from [section 4](#4-choose-your-path).

---

## 8. Rollback

| Where it failed | What to do |
|---|---|
| Before 6.4 (nothing upgraded yet) | `docker compose up -d` with the old compose. Nothing has changed. |
| During 6.4 (FCV already raised) | The volume can no longer be opened by 5.0. Restore the backup into a fresh volume: create a new volume, start `mongo:5.0` on it, then `mongorestore --archive --gzip < ~/mongo-backup-<date>-pre-8.0.gz`, and point the old compose at it. |
| After deploying, backend can't log in | Usually the env file and the users don't match. Check spelling, then reset the password: `docker exec -it mongodb mongosh -u admin -p --authenticationDatabase admin` → `db.getSiblingDB('admin').changeUserPassword('ehub_app', passwordPrompt())`. Then `docker compose restart ehub-backend`. |
| After deploying, the auth/replica-set setup itself is the problem | Switch back to `dev` (8.0 image, no auth) and `docker compose up -d`. The data and users stay; MongoDB just runs without auth until fixed. |

---

## 9. Merge and tell the team

Once **both** dep-test and prod pass [Verify](#7-verify):

1. Merge the PR `chore/mongodb-8-auth` → `dev` on GitHub (or locally: `git switch dev && git merge --no-ff chore/mongodb-8-auth && git push origin dev`).
2. On each server, switch back to `dev`: `git switch dev && git pull origin dev`. Nothing changes, since `dev` now has the same files.
3. Delete the branch: `git push origin --delete chore/mongodb-8-auth`.
4. Tell the team:
   - `dev` now runs MongoDB 8.0 with auth and a replica set.
   - Local setup: add the new `MONGO_*` keys to `.env` and recreate the local volume (see `earthquake-hub-backend/MONGODB.md`).
   - Server database access for developers goes through personal read-only users and an SSH tunnel, not the `ehub_app` password.
