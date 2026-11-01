"""Persisted flight-source health, independent of price history and notifications."""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import tempfile
from typing import Callable
from urllib.request import Request, urlopen

from packaging.version import InvalidVersion, Version

MONITOR_VERSION = "0.1.0"
STATE_VERSION = 1
UPDATE_INTERVAL = timedelta(days=1)
FORMAT_FAILURE_THRESHOLD = 3


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass
class Health:
    state_version: int = STATE_VERSION
    monitor_version: str = MONITOR_VERSION
    connector_name: str = "fast-flights"
    connector_version: str | None = None
    google_api_version: str | None = None  # The unofficial interface has no supported version.
    observed_google_build: str | None = None  # Opaque, optional; never used as a version.
    last_successful_google_build: str | None = None
    status: str = "not_checked"
    detail: str = "No live flight-data check has completed."
    last_attempt: str | None = None
    last_success: str | None = None
    last_result_count: int | None = None
    consecutive_format_failures: int = 0
    latest_connector_version: str | None = None
    update_available: bool | None = None
    last_update_attempt: str | None = None
    last_update_check: str | None = None
    update_check_error: str | None = None
    events: list[dict] = field(default_factory=list)

    def set_connector_version(self, installed: str | None) -> None:
        self.connector_version = installed
        try:
            self.update_available = (
                Version(self.latest_connector_version) > Version(installed)
                if installed and self.latest_connector_version else None
            )
        except InvalidVersion:
            self.update_available = None

    def event(self, kind: str, detail: str, at: str) -> None:
        self.events.append({"at": at, "kind": kind, "detail": detail})
        self.events = self.events[-100:]

    def record_probe(
        self, kind: str, detail: str, *, at: str | None = None,
        result_count: int | None = None, google_build: str | None = None,
    ) -> None:
        if kind not in {"success", "format", "network", "blocked", "service", "local"}:
            raise ValueError("Unknown probe outcome")
        if kind == "success" and (type(result_count) is not int or result_count < 0):
            raise ValueError("A successful probe requires a non-negative result count")
        at = at or utc_now()
        previous_status = self.status
        self.last_attempt = at
        self.observed_google_build = google_build
        self.detail = detail
        if kind == "success":
            if google_build and self.last_successful_google_build not in (None, google_build):
                self.event("source_build_changed", "Google's build identifier changed; price parsing still works.", at)
            if google_build:
                self.last_successful_google_build = google_build
            self.last_success = at
            self.last_result_count = result_count
            self.consecutive_format_failures = 0
            self.status = "working" if result_count else "no_results"
        elif kind == "format":
            self.consecutive_format_failures += 1
            self.status = (
                "maintenance_suggested"
                if self.consecutive_format_failures >= FORMAT_FAILURE_THRESHOLD
                else "response_unrecognized"
            )
        else:
            # Wi-Fi loss, throttling and missing dependencies are different problems.
            self.consecutive_format_failures = 0
            self.status = {
                "network": "connection_problem", "blocked": "access_limited",
                "service": "source_unavailable", "local": "local_component_problem",
            }[kind]
        if self.status != previous_status:
            self.event(self.status, detail, at)

    def prices_are_fresh(self, *, now: datetime | None = None, max_age: timedelta = timedelta(hours=2)) -> bool:
        if self.status not in {"working", "no_results"} or not self.last_success:
            return False
        age = (now or datetime.now(timezone.utc)) - datetime.fromisoformat(self.last_success)
        return timedelta(0) <= age <= max_age

    def update_due(self, *, now: datetime | None = None) -> bool:
        # Rate-limit failed update checks too, so an offline device does not retry endlessly.
        if not self.last_update_attempt:
            return True
        age = (now or datetime.now(timezone.utc)) - datetime.fromisoformat(self.last_update_attempt)
        return age < timedelta(0) or age >= UPDATE_INTERVAL

    def record_update(self, latest: str | None, *, error: str | None = None, at: str | None = None) -> None:
        at = at or utc_now()
        self.last_update_attempt = at
        if error:
            self.update_check_error = error
            return  # Preserve the last successfully checked version and its date.
        try:
            newest = Version(latest or "")
            installed = Version(self.connector_version) if self.connector_version else None
            if newest.is_prerelease or newest.is_devrelease:
                raise InvalidVersion("Not a stable release")
        except InvalidVersion:
            self.update_check_error = "The release service returned an unrecognized version."
            return
        previous = self.latest_connector_version
        self.latest_connector_version = latest
        self.update_available = newest > installed if installed else None
        self.last_update_check = at
        self.update_check_error = None
        if self.update_available and latest != previous:
            self.event("connector_update_available", f"Connector {latest} is available; this does not imply a fault.", at)

    def report(self) -> dict:
        return {**asdict(self), "prices_fresh": self.prices_are_fresh()}


def load_health(path: Path) -> Health:
    if not path.exists():
        return Health()
    data = json.loads(path.read_text())
    if data.get("state_version") != STATE_VERSION:
        raise ValueError("Unsupported health-state version; the existing file was not modified.")
    fields = Health.__dataclass_fields__
    return Health(**{key: value for key, value in data.items() if key in fields})


def save_health(path: Path, health: Health) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(dir=path.parent, prefix=".health-", suffix=".json")
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(asdict(health), stream, indent=2)
            stream.write("\n")
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def fetch_latest_release() -> str:
    # Public metadata only. No account, API key, trip information or code download.
    request = Request("https://pypi.org/pypi/fast-flights/json", headers={"User-Agent": "BoschertTripTracker/0.1.1"})
    with urlopen(request, timeout=15) as response:
        data = json.load(response)
    # Ignore prereleases and releases whose distributions have all been withdrawn.
    stable = []
    for label, files in data["releases"].items():
        try:
            version = Version(label)
        except InvalidVersion:
            continue
        if version.is_prerelease or version.is_devrelease:
            continue
        if any(not item.get("yanked", False) for item in files):
            stable.append((version, label))
    if not stable:
        raise ValueError("No stable connector releases were found")
    return max(stable)[1]


def check_for_updates(health: Health, *, force: bool = False, fetch: Callable[[], str] = fetch_latest_release) -> None:
    if not force and not health.update_due():
        return
    try:
        health.record_update(fetch())
    except Exception:
        health.record_update(None, error="Could not check for connector updates. Existing tracking status is unchanged.")

