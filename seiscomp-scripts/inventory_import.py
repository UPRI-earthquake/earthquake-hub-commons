#!/usr/bin/env python3

"""Import Raspberry Shake StationXML into a SeisComP inventory pool.

The importer intentionally uses SeisComP-supported command-line tools instead
of modifying SeisComP internals:

* import_inv fdsnxml
* scinv check
* scinv sync --test
* seiscomp update-config inventory
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import difflib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_ENV_FILE = SCRIPT_DIR / "inventory_import.env"
DEFAULT_FDSN_STATION_URL = "https://data.raspberryshake.org/fdsnws/station/1/query"


class ImportErrorWithHint(RuntimeError):
    """Error with a message suitable for operator-facing output."""


@dataclass
class ToolPaths:
    seiscomp_root: Path
    import_inv: Path
    scinv: Path
    seiscomp: Path


@dataclass
class StationJob:
    network: str
    station: str
    location: str
    source_file: str | None = None
    binding_template: str | None = None


@dataclass
class StationResult:
    job: StationJob
    inventory_path: Path
    key_path: Path
    inventory_status: str
    key_status: str
    pool_check_passed: bool
    sync_test_ran: bool


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


def resolve_tools(args: argparse.Namespace, env: dict[str, str]) -> ToolPaths:
    seiscomp_root = resolve_seiscomp_root(args, env)
    bin_dir = seiscomp_root / "bin"
    tools = ToolPaths(
        seiscomp_root=seiscomp_root,
        import_inv=bin_dir / "import_inv",
        scinv=bin_dir / "scinv",
        seiscomp=bin_dir / "seiscomp",
    )
    for command in (tools.import_inv, tools.scinv, tools.seiscomp):
        require_executable(command)
    return tools


def summarize_command_output(output: str) -> str:
    conflicts = re.findall(r"^(\d+) conflicts?$", output, flags=re.MULTILINE)
    warnings = re.findall(r"^(\d+) warnings?$", output, flags=re.MULTILINE)
    parts = []
    if conflicts:
        parts.append(f"{conflicts[-1]} conflicts")
    if warnings:
        parts.append(f"{warnings[-1]} warnings")
    return ", ".join(parts) if parts else "no summary counts reported"


def run_command(
    cmd: list[str],
    *,
    cwd: Path | None = None,
    check: bool = True,
    verbose: bool = False,
    quiet_success: bool = False,
    suppress_output: bool = False,
) -> subprocess.CompletedProcess[str]:
    print("+ " + " ".join(cmd))
    result = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    should_print = not suppress_output and (verbose or (result.returncode != 0) or not quiet_success)
    if result.stdout and should_print:
        print(result.stdout.rstrip())
    if quiet_success and result.returncode == 0 and not verbose:
        print("  ok")
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


def render_diff(
    existing: bytes | None,
    new: bytes,
    from_name: str,
    to_name: str,
    max_lines: int,
    max_chars: int,
) -> str:
    if existing is None:
        return f"{from_name} does not exist; {to_name} would be created."
    old_lines = existing.decode("utf-8", errors="replace").splitlines(keepends=True)
    new_lines = new.decode("utf-8", errors="replace").splitlines(keepends=True)
    diff_lines = list(
        difflib.unified_diff(old_lines, new_lines, fromfile=from_name, tofile=to_name)
    )
    if max_lines > 0 and len(diff_lines) > max_lines:
        omitted = len(diff_lines) - max_lines
        diff_lines = diff_lines[:max_lines]
        diff_lines.append(f"\n... diff truncated, {omitted} lines omitted. Use --max-diff-lines 0 for full diff.\n")
    diff = "".join(diff_lines)
    if max_chars > 0 and len(diff) > max_chars:
        omitted = len(diff) - max_chars
        diff = (
            diff[:max_chars]
            + f"\n... diff truncated, {omitted} characters omitted. Use --max-diff-chars 0 for full diff.\n"
        )
    return diff


def write_managed_file(
    target: Path,
    data: bytes,
    *,
    force: bool,
    dry_run: bool,
    compare_only: bool,
    show_diff: bool,
    max_diff_lines: int,
    max_diff_chars: int,
    label: str,
) -> str:
    existing = read_bytes_if_exists(target)
    if existing == data:
        print(f"{label} already matches: {target}")
        return "unchanged"

    if compare_only or show_diff:
        print(f"{label} differs: {target}")
        diff = render_diff(
            existing,
            data,
            str(target),
            f"generated {label}",
            max_diff_lines,
            max_diff_chars,
        )
        if diff:
            print(diff.rstrip())

    if compare_only:
        return "differs" if existing is not None else "missing"

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


def resolve_binding_template(template: str) -> Path:
    binding_template = Path(template).expanduser()
    if not binding_template.is_absolute():
        binding_template = SCRIPT_DIR / binding_template
    if not binding_template.exists():
        raise ImportErrorWithHint(f"Binding template does not exist: {binding_template}")
    return binding_template


def load_batch_jobs(args: argparse.Namespace, env: dict[str, str]) -> list[StationJob]:
    if not args.batch_file:
        return [
            StationJob(
                network=args.network.upper(),
                station=args.station.upper(),
                location=args.location.upper(),
                source_file=args.source_file,
                binding_template=args.binding_template,
            )
        ]

    path = Path(args.batch_file).expanduser()
    if not path.exists():
        raise ImportErrorWithHint(f"Batch file does not exist: {path}")

    jobs: list[StationJob] = []
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        required = {"station"}
        missing = required - set(reader.fieldnames or [])
        if missing:
            raise ImportErrorWithHint(
                f"Batch file is missing required column(s): {', '.join(sorted(missing))}"
            )
        for row_number, row in enumerate(reader, start=2):
            station = (row.get("station") or "").strip()
            if not station:
                raise ImportErrorWithHint(f"Batch row {row_number} has an empty station value.")
            jobs.append(
                StationJob(
                    network=(row.get("network") or args.network).strip().upper(),
                    station=station.upper(),
                    location=(row.get("location") or args.location).strip().upper(),
                    source_file=(row.get("source_file") or "").strip() or None,
                    binding_template=(row.get("binding_template") or args.binding_template).strip(),
                )
            )

    if not jobs:
        raise ImportErrorWithHint(f"Batch file has no station rows: {path}")

    if not (args.dry_run or args.compare_only or args.batch_apply):
        raise ImportErrorWithHint(
            "Batch mode requires --dry-run, --compare-only, or explicit --batch-apply."
        )

    return jobs


def parse_args(argv: list[str]) -> argparse.Namespace:
    env_defaults = load_env_file(DEFAULT_ENV_FILE)

    parser = argparse.ArgumentParser(
        description="Import Raspberry Shake StationXML into SeisComP inventory.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--network", default=env_defaults.get("DEFAULT_NETWORK", "AM"))
    parser.add_argument("--station", help="Station code, e.g. R1382. Required unless --batch-file is used.")
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
    parser.add_argument("--batch-file", help="CSV file with station rows. Required column: station. Optional: network, location, source_file, binding_template.")
    parser.add_argument("--batch-apply", action="store_true", help="Allow batch mode to write files when not using --dry-run or --compare-only.")
    parser.add_argument("--continue-on-error", action="store_true", help="Continue processing remaining batch rows after a station fails.")
    parser.add_argument("--dry-run", action="store_true", help="Validate and print planned writes without changing active files.")
    parser.add_argument(
        "--production-dry-run",
        action="store_true",
        help="Production-safe validation alias for --dry-run --skip-apply.",
    )
    parser.add_argument("--compare-only", action="store_true", help="Generate and compare files without writing or running update-config.")
    parser.add_argument("--show-diff", action="store_true", help="Print unified diffs for differing generated files.")
    parser.add_argument(
        "--max-diff-lines",
        type=int,
        default=120,
        help="Maximum diff lines to print with --show-diff or --compare-only. Use 0 for full diff.",
    )
    parser.add_argument(
        "--max-diff-chars",
        type=int,
        default=8000,
        help="Maximum diff characters to print with --show-diff or --compare-only. Use 0 for full diff.",
    )
    parser.add_argument("--refresh", action="store_true", help="Treat the operation as an existing-station metadata refresh; fail if inventory is missing.")
    parser.add_argument("--force", action="store_true", help="Replace an existing inventory file or binding key after making backups.")
    parser.add_argument(
        "--force-bindings",
        action="store_true",
        help="Replace only an existing station binding key after making a backup.",
    )
    parser.add_argument("--skip-pool-check", action="store_true", help="Skip staged full inventory pool validation.")
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
    parser.add_argument("--verbose", action="store_true", help="Print full output from SeisComP validation commands.")
    parser.set_defaults(env_defaults=env_defaults)
    args = parser.parse_args(argv)

    if args.production_dry_run:
        args.dry_run = True
        args.skip_apply = True
    if args.compare_only:
        args.dry_run = True
        args.skip_apply = True
    if not args.batch_file and not args.station:
        parser.error("--station is required unless --batch-file is used")
    if args.source_file and args.batch_file:
        parser.error("--source-file is only for single-station mode; use source_file column in --batch-file")
    return args


def import_station(
    job: StationJob,
    args: argparse.Namespace,
    tools: ToolPaths,
) -> StationResult:
    network = job.network.upper()
    station = job.station.upper()
    location = job.location.upper()
    inventory_dir = tools.seiscomp_root / "etc" / "inventory"
    key_dir = tools.seiscomp_root / "etc" / "key"
    target_inventory = inventory_dir / f"{network}.{station}.{location}.MULTI.xml"
    target_key = key_dir / f"station_{network}_{station}"
    binding_template = resolve_binding_template(job.binding_template or args.binding_template)

    print("")
    print(f"Station {network}.{station}")

    if args.refresh and not target_inventory.exists():
        raise ImportErrorWithHint(
            f"--refresh was requested but inventory file does not exist: {target_inventory}"
        )
    if target_inventory.exists() and not args.refresh:
        print("Existing inventory found. Use --refresh to document an intentional metadata refresh.")

    with tempfile.TemporaryDirectory(prefix="seiscomp-inventory-import-") as tmp_name:
        tmp_dir = Path(tmp_name)
        source_xml = tmp_dir / f"{network}.{station}.stationxml"
        converted_xml = tmp_dir / target_inventory.name
        staged_inventory = tmp_dir / "inventory-stage"

        if job.source_file:
            source_path = Path(job.source_file).expanduser().resolve()
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

        run_command(
            [str(tools.import_inv), "fdsnxml", str(source_xml), str(converted_xml)],
            verbose=args.verbose,
            quiet_success=True,
        )
        run_command(
            [str(tools.scinv), "check", str(converted_xml)],
            verbose=args.verbose,
            quiet_success=True,
        )

        pool_check_passed = True
        sync_test_ran = False
        if not args.skip_pool_check:
            copy_inventory_pool(inventory_dir, staged_inventory, target_inventory.name)
            shutil.copy2(converted_xml, staged_inventory / target_inventory.name)
            pool_check = run_command(
                [str(tools.scinv), "check", "--filebase", str(staged_inventory)],
                check=args.strict_pool_check,
                verbose=args.verbose,
                quiet_success=True,
                suppress_output=not args.verbose,
            )
            pool_check_passed = pool_check.returncode == 0
            if pool_check_passed:
                print("Staged full inventory pool check passed.")
            else:
                print(
                    "WARNING: staged full inventory pool check reported issues "
                    f"({summarize_command_output(pool_check.stdout)}). "
                    "Use --verbose to print full validation output or "
                    "--strict-pool-check to make this fatal."
                )

            if not args.skip_sync_test and pool_check_passed:
                run_command(
                    [str(tools.scinv), "sync", "--test", "--filebase", str(staged_inventory)],
                    verbose=args.verbose,
                    quiet_success=True,
                )
                sync_test_ran = True
            elif not args.skip_sync_test:
                print(
                    "WARNING: skipped scinv sync --test because the staged "
                    "full inventory pool check did not pass."
                )
        else:
            print("Skipped staged full inventory pool check because --skip-pool-check was set.")

        inventory_data = converted_xml.read_bytes()
        key_data = binding_template.read_bytes()

        inventory_status = write_managed_file(
            target_inventory,
            inventory_data,
            force=args.force,
            dry_run=args.dry_run,
            compare_only=args.compare_only,
            show_diff=args.show_diff,
            max_diff_lines=args.max_diff_lines,
            max_diff_chars=args.max_diff_chars,
            label="inventory XML",
        )
        key_status = write_managed_file(
            target_key,
            key_data,
            force=args.force or args.force_bindings,
            dry_run=args.dry_run,
            compare_only=args.compare_only,
            show_diff=args.show_diff,
            max_diff_lines=args.max_diff_lines,
            max_diff_chars=args.max_diff_chars,
            label="station binding key",
        )

    return StationResult(
        job=job,
        inventory_path=target_inventory,
        key_path=target_key,
        inventory_status=inventory_status,
        key_status=key_status,
        pool_check_passed=pool_check_passed,
        sync_test_ran=sync_test_ran,
    )


def apply_seiscomp_update(args: argparse.Namespace, tools: ToolPaths) -> bool:
    if args.compare_only:
        print("COMPARE ONLY: no active SeisComP files were changed.")
        return False
    if args.dry_run:
        print("DRY RUN: no active SeisComP files were changed.")
        return False
    if args.skip_apply:
        print("Skipped SeisComP update-config commands because --skip-apply was set.")
        return False

    run_command(
        [str(tools.seiscomp), "--wait", "30", "update-config", "inventory"],
        verbose=args.verbose,
    )
    if not args.no_full_update_config:
        run_command([str(tools.seiscomp), "--wait", "30", "update-config"], verbose=args.verbose)
    return True


def print_summary(results: list[StationResult], applied: bool) -> None:
    print("")
    print("Import summary")
    for result in results:
        job = result.job
        print(f"  station: {job.network}.{job.station}")
        print(f"    inventory: {result.inventory_path} ({result.inventory_status})")
        print(f"    key: {result.key_path} ({result.key_status})")
        print(f"    pool_check_passed: {result.pool_check_passed}")
        print(f"    sync_test_ran: {result.sync_test_ran}")
    print(f"  applied: {applied}")


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    env_defaults = args.env_defaults

    try:
        jobs = load_batch_jobs(args, env_defaults)
        tools = resolve_tools(args, env_defaults)
        print(f"SeisComP root: {tools.seiscomp_root}")
        run_command(
            [str(tools.seiscomp), "exec", "scmaster", "--version"],
            check=False,
            verbose=True,
        )

        results: list[StationResult] = []
        failures = 0

        for job in jobs:
            try:
                results.append(import_station(job, args, tools))
            except ImportErrorWithHint as exc:
                failures += 1
                print(f"ERROR: {job.network}.{job.station}: {exc}", file=sys.stderr)
                if not args.continue_on_error:
                    raise

        applied = False
        if results and failures == 0:
            applied = apply_seiscomp_update(args, tools)
        elif failures:
            print("Skipped SeisComP update-config because at least one station failed.")

        print_summary(results, applied)
        return 1 if failures else 0

    except ImportErrorWithHint as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
