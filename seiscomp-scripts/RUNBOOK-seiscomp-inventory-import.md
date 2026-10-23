# SeisComP Inventory Import Runbook

Use this runbook on the SeisComP deployment server before importing or
refreshing Raspberry Shake inventory metadata.

## 1. Confirm Environment

Run from the commons repository on the SeisComP host:

```sh
cd ~/earthquake-hub-commons
test -x ./seiscomp-scripts/inventory_import.py
test -x ../seiscomp/bin/seiscomp
../seiscomp/bin/seiscomp exec scmaster --version
```

Confirm the resolved root is the production SeisComP root, for example:

```txt
/home/seismin/seiscomp
```

## 2. New Station Dry Run

For a new station, run:

```sh
./seiscomp-scripts/inventory_import.py \
  --network AM \
  --station R1382 \
  --production-dry-run \
  --seiscomp-root ../seiscomp
```

Expected safe output:

```txt
DRY RUN: no active SeisComP files were changed.
applied: False
```

If the output is too long because of existing inventory warnings, rerun with:

```sh
./seiscomp-scripts/inventory_import.py \
  --network AM \
  --station R1382 \
  --production-dry-run \
  --skip-pool-check \
  --seiscomp-root ../seiscomp
```

Do not use `--skip-pool-check` for final confidence if you are changing many
stations. It is for quick no-write validation and noise reduction.

## 3. Existing Station Metadata Refresh

Use compare mode first:

```sh
./seiscomp-scripts/inventory_import.py \
  --network AM \
  --station R1382 \
  --compare-only \
  --show-diff \
  --seiscomp-root ../seiscomp
```

Review the diff. A Raspberry Shake owner changing coordinates or elevation can
cause upstream StationXML to change, so a diff can be expected during metadata
refresh.

Apply only after review:

```sh
./seiscomp-scripts/inventory_import.py \
  --network AM \
  --station R1382 \
  --refresh \
  --force \
  --seiscomp-root ../seiscomp
```

## 4. New Station Apply

After dry-run review:

```sh
./seiscomp-scripts/inventory_import.py \
  --network AM \
  --station R1382 \
  --seiscomp-root ../seiscomp
```

If the station inventory already exists and differs, the command will stop and
ask for `--force`. That is intentional.

## 5. Batch Import

Create a CSV:

```csv
network,station,location,source_file,binding_template
AM,R1382,00,,
AM,R40BD,00,,
```

Always dry-run first:

```sh
./seiscomp-scripts/inventory_import.py \
  --batch-file stations.csv \
  --dry-run \
  --seiscomp-root ../seiscomp
```

Apply only after reviewing all rows:

```sh
./seiscomp-scripts/inventory_import.py \
  --batch-file stations.csv \
  --batch-apply \
  --seiscomp-root ../seiscomp
```

## 6. Post-Import Checks

Check generated files:

```sh
ls -l ../seiscomp/etc/inventory/AM.R1382.00.MULTI.xml
ls -l ../seiscomp/etc/key/station_AM_R1382
```

Check module status:

```sh
../seiscomp/bin/seiscomp status
```

If the new station is not visible to running services after `update-config`,
restart affected modules during a maintenance window:

```sh
../seiscomp/bin/seiscomp restart seedlink slarchive slmon scautopick
```

## 7. Rollback

If a forced replacement causes problems, restore the generated backup:

```sh
ls -l ../seiscomp/etc/inventory/AM.R1382.00.MULTI.xml.bak-*
cp ../seiscomp/etc/inventory/AM.R1382.00.MULTI.xml.bak-YYYYMMDD-HHMMSS \
  ../seiscomp/etc/inventory/AM.R1382.00.MULTI.xml
../seiscomp/bin/seiscomp --wait 30 update-config inventory
../seiscomp/bin/seiscomp --wait 30 update-config
```

Backups are only created when an existing active file is replaced.
