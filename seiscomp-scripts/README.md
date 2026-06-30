# SeisComP Scripts

This directory contains host-side SeisComP helper scripts used by the
Earthquake Hub deployment.

## Auto Inventory Import

`inventory_import.py` imports Raspberry Shake StationXML metadata into a
SeisComP inventory pool and creates the matching station binding key file.
It uses supported SeisComP CLI tools rather than editing SeisComP internals.

Supported first milestone:

- one station per command
- Raspberry Shake `AM.*` stations
- default UPRI bindings
- local StationXML files or direct download from the Raspberry Shake FDSN
  station service
- dry-run validation
- backups before replacement

The importer does not upgrade SeisComP and does not restart running SeisComP
modules.

### Configuration

Copy the example config and edit it for the host:

```sh
cp inventory_import.env.example inventory_import.env
```

At minimum, set:

```sh
SEISCOMP_ROOT=/home/sysop/seiscomp
```

CLI arguments override values from `inventory_import.env`.

### Binding Template

The default AM/Raspberry Shake binding template is:

```txt
inventory-bindings/rshake-am-ehz.key
```

It generates station keys such as:

```txt
$SEISCOMP_ROOT/etc/key/station_AM_R1382
```

with these binding references:

```txt
# Binding references
global:AM_EHZ
scautopick:default
seedlink:UPRI
slarchive:two-week
slmon:default
```

### Usage

Import from a StationXML file already available on the host:

```sh
./inventory_import.py \
  --network AM \
  --station R1382 \
  --source-file /path/to/AM.R1382.stationxml
```

Download StationXML from the configured FDSN station service:

```sh
./inventory_import.py --network AM --station R1382
```

Run without changing active SeisComP files:

```sh
./inventory_import.py --network AM --station R1382 --source-file /path/to/AM.R1382.stationxml --dry-run
```

Make full inventory pool validation fatal:

```sh
./inventory_import.py --network AM --station R1382 --source-file /path/to/AM.R1382.stationxml --strict-pool-check
```

Replace existing inventory/key files after review:

```sh
./inventory_import.py --network AM --station R1382 --source-file /path/to/AM.R1382.stationxml --force
```

Skip the final `seiscomp update-config` commands:

```sh
./inventory_import.py --network AM --station R1382 --source-file /path/to/AM.R1382.stationxml --skip-apply
```

### What The Importer Does

1. Resolves the SeisComP installation root.
2. Checks for `import_inv`, `scinv`, and `seiscomp`.
3. Reads or downloads StationXML metadata.
4. Validates that the XML contains the requested network/station.
5. Converts StationXML using:

```sh
import_inv fdsnxml input.stationxml output.xml
```

6. Runs `scinv check` on the converted XML.
7. Builds a temporary staged inventory pool and runs `scinv check` against it.
8. Runs `scinv sync --test` against the staged inventory pool unless
   `--skip-sync-test` is set.
9. Writes the converted inventory XML to:

```txt
$SEISCOMP_ROOT/etc/inventory/AM.R1382.00.MULTI.xml
```

10. Writes the station key to:

```txt
$SEISCOMP_ROOT/etc/key/station_AM_R1382
```

11. Runs:

```sh
seiscomp --wait 30 update-config inventory
seiscomp --wait 30 update-config
```

The second command is skipped when `RUN_FULL_UPDATE_CONFIG=false` or
`--no-full-update-config` is set.

### Safety Behavior

- Existing files are not replaced unless `--force` is set.
- Existing matching files are left unchanged.
- Replaced files are backed up with a `.bak-YYYYMMDD-HHMMSS` suffix.
- Active SeisComP files are not touched until conversion and validation pass.
- `--dry-run` performs validation and reports planned file changes.
- The converted station file must pass `scinv check`.
- Full inventory pool validation is advisory by default because existing
  deployments can have unrelated legacy inventory warnings or conflicts. Use
  `--strict-pool-check` to make full-pool issues fatal.

### Operational Notes

Run imports from a maintenance shell on the SeisComP host. The command must be
able to write to `$SEISCOMP_ROOT/etc/inventory` and `$SEISCOMP_ROOT/etc/key`.

The script updates SeisComP configuration, but it does not restart running
modules. If the new station is not picked up by running services after
`update-config`, restart the affected modules during a maintenance window, for
example:

```sh
seiscomp restart seedlink slarchive slmon scautopick
```

The importer has been designed for the current SeisComP 6.x command set. Major
SeisComP upgrades should re-validate this workflow before production use.
