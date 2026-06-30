#!/usr/bin/env python3

"""Import Raspberry Shake StationXML into a SeisComP inventory pool.

This script intentionally uses SeisComP-supported command-line tools instead of
modifying SeisComP internals:

* import_inv fdsnxml
* scinv check
* scinv sync --test
* seiscomp update-config inventory
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_ENV_FILE = SCRIPT_DIR / "inventory_import.env"
DEFAULT_FDSN_STATION_URL = "https://data.raspberryshake.org/fdsnws/station/1/query"


class ImportErrorWithHint(RuntimeError):
    """Error with a message suitable for operator-facing output."""


def load_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key:
            values[key] = value
    return values


def env_bool(values: dict[str, str], key: str, default: bool) -> bool:
    raw = values.get(key)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def stationxml_contains_station(path: Path, network: str, station: str) -> bool:
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as exc:
        raise ImportErrorWithHint(f"StationXML is not valid XML: {exc}") from exc

    for network_node in root.iter():
        if local_name(network_node.tag) != "Network":
            continue
        if network_node.attrib.get("code") != network:
            continue
        for station_node in network_node:
            if (
                local_name(station_node.tag) == "Station"
                and station_node.attrib.get("code") == station
            ):
                return True
    return False


def resolve_seiscomp_root(args: argparse.Namespace, env: dict[str, str]) -> Path:
    candidates = []
    if args.seiscomp_root:
        candidates.append(Path(args.seiscomp_root).expanduser())
    if env.get("SEISCOMP_ROOT"):
        candidates.append(Path(env["SEISCOMP_ROOT"]).expanduser())
    if os.environ.get("SEISCOMP_ROOT"):
        candidates.append(Path(os.environ["SEISCOMP_ROOT"]).expanduser())
    candidates.append(Path.home() / "seiscomp")
    candidates.append(SCRIPT_DIR.parent.parent / "seiscomp")

    for candidate in candidates:
        if (candidate / "bin" / "seiscomp").exists():
            return candidate.resolve()

    checked = "\n".join(f"  - {candidate}" for candidate in candidates)
    raise ImportErrorWithHint(
        "Could not find a SeisComP installation. Checked:\n"
        f"{checked}\n"
        "Set --seiscomp-root or SEISCOMP_ROOT."
    )


def require_executable(path: Path) -> None:
    if not path.exists():
        raise ImportErrorWithHint(f"Required command is missing: {path}")
    if not os.access(path, os.X_OK):
        raise ImportErrorWithHint(f"Required command is not executable: {path}")


def run_command(cmd: list[str], *, cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    print("+ " + " ".join(cmd))
    result = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if result.stdout:
        print(result.stdout.rstrip())
    if check and result.returncode != 0:
        raise ImportErrorWithHint(
            f"Command failed with exit code {result.returncode}: {' '.join(cmd)}"
        )
    return result


def download_stationxml(
    base_url: str,
    network: str,
    station: str,
    level: str,
    destination: Path,
) -> None:
    query = urllib.parse.urlencode(
        {
            "network": network,
            "station": station,
            "level": level,
            "format": "xml",
        }
    )
    url = f"{base_url}?{query}"
    print(f"Downloading StationXML: {url}")
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            destination.write_bytes(response.read())
    except Exception as exc:
        raise ImportErrorWithHint(f"Failed to download StationXML from {url}: {exc}") from exc


def copy_inventory_pool(inventory_dir: Path, stage_dir: Path, target_name: str) -> None:
    stage_dir.mkdir(parents=True, exist_ok=True)
    for source in inventory_dir.glob("*.xml"):
        if source.name == target_name:
            continue
        shutil.copy2(source, stage_dir / source.name)


def read_bytes_if_exists(path: Path) -> bytes | None:
    if not path.exists():
        return None
    return path.read_bytes()


def backup_existing(path: Path) -> Path:
    timestamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = path.with_name(f"{path.name}.bak-{timestamp}")
    shutil.copy2(path, backup)
    return backup


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as tmp:
        tmp.write(data)
        tmp_path = Path(tmp.name)
    tmp_path.replace(path)


def write_managed_file(
    target: Path,
    data: bytes,
    *,
    force: bool,
    dry_run: bool,
    label: str,
) -> str:
    existing = read_bytes_if_exists(target)
    if existing == data:
        print(f"{label} already matches: {target}")
        return "unchanged"
    if dry_run:
        if existing is not None and not force:
            print(
                f"DRY RUN: {label} exists and differs; a real run would require --force: {target}"
            )
            return "would-require-force"
        action = "replace" if existing is not None else "create"
        print(f"DRY RUN: would {action} {label}: {target}")
        return f"would-{action}"
    if existing is not None and not force:
        raise ImportErrorWithHint(
            f"{label} already exists and differs: {target}\n"
            "Re-run with --force to replace it after reviewing the change."
        )
    if existing is not None:
        backup = backup_existing(target)
        print(f"Backed up existing {label}: {backup}")
    atomic_write(target, data)
    print(f"Wrote {label}: {target}")
    return "replaced" if existing is not None else "created"


def parse_args(argv: list[str]) -> argparse.Namespace:
    env_defaults = load_env_file(DEFAULT_ENV_FILE)

    parser = argparse.ArgumentParser(
        description="Import Raspberry Shake StationXML into SeisComP inventory.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--network", default=env_defaults.get("DEFAULT_NETWORK", "AM"))
    parser.add_argument("--station", required=True, help="Station code, e.g. R1382")
    parser.add_argument("--location", default=env_defaults.get("DEFAULT_LOCATION", "00"))
    parser.add_argument(
        "--level",
        default=env_defaults.get("DEFAULT_STATION_LEVEL", "response"),
        help="FDSN station service level when downloading metadata.",
    )
    parser.add_argument(
        "--source-file",
        help="Local StationXML file. If omitted, metadata is downloaded from the FDSN station endpoint.",
    )
    parser.add_argument(
        "--fdsn-url",
        default=env_defaults.get("RSHAKE_FDSN_STATION_URL", DEFAULT_FDSN_STATION_URL),
        help="FDSN station service query endpoint.",
    )
    parser.add_argument("--seiscomp-root", help="SeisComP installation root.")
    parser.add_argument(
        "--binding-template",
        default=env_defaults.get("DEFAULT_BINDING_TEMPLATE", "inventory-bindings/rshake-am-ehz.key"),
        help="Station key binding template path. Relative paths are resolved from seiscomp-scripts.",
    )
    parser.add_argument("--dry-run", action="store_true", help="Validate and print planned writes without changing active files.")
    parser.add_argument("--force", action="store_true", help="Replace an existing inventory file or binding key after making backups.")
    parser.add_argument(
        "--force-bindings",
        action="store_true",
        help="Replace only an existing station binding key after making a backup.",
    )
    parser.add_argument("--skip-sync-test", action="store_true", help="Skip scinv sync --test against the staged inventory pool.")
    parser.add_argument(
        "--strict-pool-check",
        action="store_true",
        help="Fail when the staged full inventory pool does not pass scinv check.",
    )
    parser.add_argument("--skip-apply", action="store_true", help="Do not run seiscomp update-config commands after writing files.")
    parser.add_argument(
        "--no-full-update-config",
        action="store_true",
        default=not env_bool(env_defaults, "RUN_FULL_UPDATE_CONFIG", True),
        help="Do not run full 'seiscomp update-config' after updating the inventory module.",
    )
    parser.set_defaults(env_defaults=env_defaults)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    env_defaults = args.env_defaults
    network = args.network.upper()
    station = args.station.upper()
    location = args.location.upper()

    try:
        seiscomp_root = resolve_seiscomp_root(args, env_defaults)
        bin_dir = seiscomp_root / "bin"
        import_inv = bin_dir / "import_inv"
        scinv = bin_dir / "scinv"
        seiscomp = bin_dir / "seiscomp"

        for command in (import_inv, scinv, seiscomp):
            require_executable(command)

        inventory_dir = seiscomp_root / "etc" / "inventory"
        key_dir = seiscomp_root / "etc" / "key"
        target_inventory = inventory_dir / f"{network}.{station}.{location}.MULTI.xml"
        target_key = key_dir / f"station_{network}_{station}"

        binding_template = Path(args.binding_template).expanduser()
        if not binding_template.is_absolute():
            binding_template = SCRIPT_DIR / binding_template
        if not binding_template.exists():
            raise ImportErrorWithHint(f"Binding template does not exist: {binding_template}")

        print(f"SeisComP root: {seiscomp_root}")
        run_command([str(seiscomp), "exec", "scmaster", "--version"], check=False)

        with tempfile.TemporaryDirectory(prefix="seiscomp-inventory-import-") as tmp_name:
            tmp_dir = Path(tmp_name)
            source_xml = tmp_dir / f"{network}.{station}.stationxml"
            converted_xml = tmp_dir / target_inventory.name
            staged_inventory = tmp_dir / "inventory-stage"

            if args.source_file:
                source_path = Path(args.source_file).expanduser().resolve()
                if not source_path.exists():
                    raise ImportErrorWithHint(f"Source file does not exist: {source_path}")
                shutil.copy2(source_path, source_xml)
                print(f"Using local StationXML: {source_path}")
            else:
                download_stationxml(args.fdsn_url, network, station, args.level, source_xml)

            if not stationxml_contains_station(source_xml, network, station):
                raise ImportErrorWithHint(
                    f"StationXML does not contain requested station {network}.{station}."
                )
            print(f"Validated StationXML contains {network}.{station}")

            run_command([str(import_inv), "fdsnxml", str(source_xml), str(converted_xml)])
            run_command([str(scinv), "check", str(converted_xml)])

            copy_inventory_pool(inventory_dir, staged_inventory, target_inventory.name)
            shutil.copy2(converted_xml, staged_inventory / target_inventory.name)
            pool_check = run_command(
                [str(scinv), "check", "--filebase", str(staged_inventory)],
                check=args.strict_pool_check,
            )
            pool_check_passed = pool_check.returncode == 0
            if not pool_check_passed and not args.strict_pool_check:
                print(
                    "WARNING: staged full inventory pool check reported issues. "
                    "The converted station file itself passed validation. "
                    "Use --strict-pool-check to make this fatal."
                )

            if not args.skip_sync_test and pool_check_passed:
                run_command([str(scinv), "sync", "--test", "--filebase", str(staged_inventory)])
            elif not args.skip_sync_test:
                print(
                    "WARNING: skipped scinv sync --test because the staged "
                    "full inventory pool check did not pass."
                )

            inventory_data = converted_xml.read_bytes()
            key_data = binding_template.read_bytes()

            inventory_status = write_managed_file(
                target_inventory,
                inventory_data,
                force=args.force,
                dry_run=args.dry_run,
                label="inventory XML",
            )
            key_status = write_managed_file(
                target_key,
                key_data,
                force=args.force or args.force_bindings,
                dry_run=args.dry_run,
                label="station binding key",
            )

        if args.dry_run:
            print("DRY RUN: no active SeisComP files were changed.")
        elif args.skip_apply:
            print("Skipped SeisComP update-config commands because --skip-apply was set.")
        else:
            run_command([str(seiscomp), "--wait", "30", "update-config", "inventory"])
            if not args.no_full_update_config:
                run_command([str(seiscomp), "--wait", "30", "update-config"])

        print("")
        print("Import summary")
        print(f"  station: {network}.{station}")
        print(f"  inventory: {target_inventory} ({inventory_status})")
        print(f"  key: {target_key} ({key_status})")
        print(f"  applied: {not args.dry_run and not args.skip_apply}")
        return 0

    except ImportErrorWithHint as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
