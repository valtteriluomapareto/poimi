#!/usr/bin/env python3
"""Generate a fixture with unmodified historical production models on a disposable simulator."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile

REPO = Path(__file__).resolve().parent.parent


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def output(*args):
    return run(*args, stdout=subprocess.PIPE).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", required=True, help="Verified release commit (must exist locally)")
    parser.add_argument("--runtime", required=True, help="simctl runtime identifier")
    parser.add_argument("--output", type=Path, required=True, help="New directory; never overwrite a fixture")
    parser.add_argument("--testflight-run", required=True, help="URL of the release build's provenance")
    parser.add_argument("--device-type", default="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro")
    args = parser.parse_args()
    destination = args.output.resolve()
    if destination.exists():
        parser.error(f"Output already exists: {destination}")
    revision = output("git", "-C", str(REPO), "rev-parse", "--verify", args.revision + "^{commit}")
    seed = REPO / "Scripts/migration/FixtureSeed.swift"
    runtimes = json.loads(output("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
    runtime = next(item for item in runtimes if item["identifier"] == args.runtime and item["isAvailable"])
    with tempfile.TemporaryDirectory(prefix="poimi-migration-") as temporary:
        scratch = Path(temporary)
        archive = scratch / "source.tar"
        run("git", "-C", str(REPO), "archive", "--format=tar", "-o", str(archive), revision)
        source = scratch / "source"
        source.mkdir()
        run("tar", "-xf", str(archive), "-C", str(source))
        support = source / "App/PoimiAppTests/TestSupport.swift"
        with support.open("a") as handle:
            handle.write("\n" + seed.read_text())
        simulator = output("xcrun", "simctl", "create", "Poimi migration fixture", args.device_type, args.runtime)
        log = REPO / "build/migration-fixture-generation.log"
        log.parent.mkdir(exist_ok=True)
        try:
            run("xcrun", "simctl", "boot", simulator)
            print(f"Building {revision}; progress log: {log}", flush=True)
            with log.open("w") as handle:
                run("xcodebuild", "test", "-project", str(source / "App/PoimiApp.xcodeproj"),
                    "-scheme", "PoimiApp", "-configuration", "Debug",
                    "-destination", f"platform=iOS Simulator,id={simulator}",
                    "-derivedDataPath", str(scratch / "DerivedData"),
                    "-parallel-testing-enabled", "NO", "-only-testing:PoimiAppTests/MigrationFixtureSeed",
                    "CODE_SIGNING_ALLOWED=NO", stdout=handle, stderr=subprocess.STDOUT)
            container = Path(output("xcrun", "simctl", "get_app_container", simulator,
                                    "com.valtteriluoma.poimi", "data"))
            # Stop the simulator before copying: no process can keep writing the SQLite/WAL/blob set.
            run("xcrun", "simctl", "shutdown", simulator)
            generated = container / "Documents/MigrationFixture"
            staged = scratch / "fixture"
            shutil.copytree(generated, staged)
            database = staged / "Store/default.store"
            with sqlite3.connect(database) as connection:
                checkpoint = connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
                assert checkpoint[0] == 0, f"WAL checkpoint failed: {checkpoint}"
                assert connection.execute("PRAGMA integrity_check").fetchone() == ("ok",)
            # sqlite3's context manager commits but does not close the connection.
            connection.close()
            for suffix in ("-wal", "-shm"):
                Path(str(database) + suffix).unlink(missing_ok=True)
            manifest = json.loads((staged / "manifest.json").read_text())
            checksums = {str(path.relative_to(staged)): hashlib.sha256(path.read_bytes()).hexdigest()
                         for path in sorted((staged / "Store").rglob("*")) if path.is_file()}
            for album in manifest["albums"]:
                matches = [path for path, digest in checksums.items()
                           if digest == album["baselineSHA256"] and path != "Store/default.store"]
                assert matches, f"Baseline is not present in external storage: {album['id']}"
                album["externalBaselineFile"] = matches[0]
            manifest["provenance"] = {
                "sourceCommit": revision, "testFlightRun": args.testflight_run,
                "xcode": output("xcodebuild", "-version"),
                "sdk": output("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"),
                "runtime": runtime["identifier"], "runtimeVersion": runtime["version"],
                "runtimeBuild": runtime["buildversion"],
                "harnessSHA256": hashlib.sha256(seed.read_bytes()).hexdigest(),
                "historicalChanges": ["Append Scripts/migration/FixtureSeed.swift to test-only TestSupport.swift"],
            }
            manifest["filesSHA256"] = checksums
            (staged / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(staged, destination)
            print(f"Generated {destination} ({len(checksums)} store files)", flush=True)
        finally:
            run("xcrun", "simctl", "delete", simulator)


if __name__ == "__main__":
    main()
