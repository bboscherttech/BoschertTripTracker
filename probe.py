"""Live, account-free flight-data probe for the maintenance prototype.

No price alerts are emitted. Run --help for the explicit sample-search arguments.
"""

from __future__ import annotations

import argparse
from datetime import date
import importlib.metadata
import json
import math
from pathlib import Path
import re
import sys

from maintenance import Health, check_for_updates, load_health, save_health


class ProbeFailure(Exception):
    def __init__(self, kind: str, detail: str):
        super().__init__(detail)
        self.kind = kind


def check_page(html: str, status: int = 200) -> str | None:
    lower = html.lower()
    if status in (403, 429) or any(marker in lower for marker in (
        "our systems have detected unusual traffic", "id=\"captcha-form\"", "g-recaptcha",
    )):
        raise ProbeFailure("blocked", "Google limited this request. This does not establish a connector-version problem.")
    if status >= 400:
        raise ProbeFailure("service", f"Google returned HTTP {status}; no price was recorded.")
    if "consent.google.com" in lower and "before you continue" in lower:
        raise ProbeFailure("blocked", "Google requires a consent step; this check did not return flight prices.")
    # This is an optional internal build label, not a Google Flights API version.
    match = re.search(r'''["']cfb2h["']\s*:\s*["']([^"']{1,200})["']''', html)
    return match.group(1) if match else None


def extract_payload(html: str) -> list:
    from selectolax.lexbor import LexborHTMLParser
    page = LexborHTMLParser(html)
    script = page.css_first(r"script.ds\:1")
    if not script:
        raise ProbeFailure("format", "The response did not contain the flight-data section this connector expects.")
    js = script.text()
    if "errorHasStatus: true" in js:
        raise ProbeFailure("service", "Google reported a search error. No price was recorded.")
    try:
        return json.loads(js.split("data:", 1)[1].rsplit(",", 1)[0])
    except (IndexError, ValueError) as error:
        raise ProbeFailure("format", "The flight-data response could not be decoded.") from error


def parse_all_results(payload: list) -> list[dict]:
    """Read both result groups, including Best flights omitted by upstream 3.1.0.

    Delegate itinerary decoding to the pinned library. Treat any unexpected group
    as a failed probe rather than silently presenting an incomplete minimum price.
    """
    from fast_flights.parser import parse_js
    if not isinstance(payload, list) or len(payload) <= 7:
        raise ProbeFailure("format", "Google's flight-data structure was not recognized.")
    results = []
    seen = set()
    try:
        # Empty result groups only mean "no results" when the surrounding schema
        # is still recognizable. A blank or newly structured response is a fault.
        meta = payload[7][1]
        if not isinstance(meta, list) or len(meta) < 2 or not all(isinstance(value, list) for value in meta[:2]):
            raise ValueError("Unexpected search metadata")
        for index in (2, 3):
            section = payload[index]
            if section is None:
                continue
            if not isinstance(section, list) or not section:
                raise ValueError("Unexpected result group")
            rows = section[0]
            if rows is None or rows == []:
                continue
            if not isinstance(rows, list):
                raise ValueError("Unexpected flight rows")
            adapted = list(payload)
            adapted[3] = section
            flights = parse_js("data:" + json.dumps(adapted) + ",sideChannel:{}")
            if len(flights) != len(rows):
                raise ValueError("Incomplete decoding")
            for flight in flights:
                price = flight.price
                if type(price) not in (float, int) or not math.isfinite(price) or price <= 0:
                    raise ValueError("Invalid price")
                if not flight.flights:
                    raise ValueError("Missing itinerary")
                segments = []
                for leg in flight.flights:
                    if not leg.from_airport.code or not leg.to_airport.code:
                        raise ValueError("Missing airports")
                    segments.append({
                        "from": leg.from_airport.code, "to": leg.to_airport.code,
                        "departure_date": list(leg.departure.date),
                        "departure_time": list(leg.departure.time),
                        "arrival_date": list(leg.arrival.date),
                        "arrival_time": list(leg.arrival.time),
                    })
                normalized = {"source_price": price, "airlines": flight.airlines, "segments": segments}
                key = json.dumps(normalized, sort_keys=True)
                if key not in seen:
                    results.append(normalized)
                    seen.add(key)
    except (IndexError, KeyError, TypeError, ValueError, AttributeError) as error:
        raise ProbeFailure("format", "Some flight results could not be decoded; prices were withheld to avoid an incomplete comparison.") from error
    return sorted(results, key=lambda item: item["source_price"])


def run_probe(health: Health, origin: str, destination: str, departure: str,
              return_date: str | None, adults: int) -> dict:
    build = None
    try:
        from fast_flights import FlightQuery, Passengers, create_query
        from primp import Client
    except Exception as error:
        health.record_probe("local", "The bundled flight-search component could not load. Google was not queried.")
        return {"failure_kind": "local", "error_type": type(error).__name__}
    try:
        legs = [FlightQuery(date=departure, from_airport=origin, to_airport=destination)]
        if return_date:
            legs.append(FlightQuery(date=return_date, from_airport=destination, to_airport=origin))
        query = create_query(flights=legs, trip="round-trip" if return_date else "one-way",
                             passengers=Passengers(adults=adults), language="en-US", currency="USD")
    except Exception:
        health.record_probe("local", "The search component could not construct a query. Google was not queried.")
        return {"failure_kind": "local"}
    try:
        # A bounded request; no external proxy, scraping service, account, or login.
        client = Client(impersonate="chrome_145", impersonate_os="macos", referer=True,
                        cookie_store=True, timeout=30)
        response = client.get("https://www.google.com/travel/flights", params=query.params())
    except Exception:
        health.record_probe("network", "The flight-data request could not connect or timed out. No new price was recorded.")
        return {"failure_kind": "network"}
    try:
        build = check_page(response.text, response.status_code)
        results = parse_all_results(extract_payload(response.text))
    except ProbeFailure as error:
        health.record_probe(error.kind, str(error), google_build=build)
        return {"failure_kind": error.kind}
    except Exception as error:
        health.record_probe("local", "An unexpected connector error occurred. No new price was recorded.", google_build=build)
        return {"failure_kind": "local", "error_type": type(error).__name__}
    health.record_probe("success", f"Decoded {len(results)} flight options across both result groups.",
                        result_count=len(results), google_build=build)
    return {
        "query": {"origin": origin, "destination": destination, "departure": departure,
                  "return": return_date, "adults": adults, "currency": "USD"},
        "results": results,
        "pricing_note": "Raw source quotes for compatibility testing. Total-party and complete round-trip pricing still require validation before alerts are enabled.",
        "price_alerts_enabled": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--request", action="store_true")
    parser.add_argument("--state", type=Path, default=Path(__file__).parent / ".local" / "health.json")
    parser.add_argument("--check-updates", action="store_true")
    parser.add_argument("--force-update-check", action="store_true")
    parser.add_argument("--origin")
    parser.add_argument("--destination")
    parser.add_argument("--departure")
    parser.add_argument("--return-date")
    parser.add_argument("--adults", type=int, default=2)
    args = parser.parse_args()
    if args.request:
        from flights import handle_request
        print(json.dumps(handle_request(json.load(sys.stdin), args.state)))
        return 0
    if any((args.origin, args.destination, args.departure, args.return_date)):
        if not all((args.origin, args.destination, args.departure)):
            parser.error("A live probe requires origin, destination, and departure.")
        args.origin, args.destination = args.origin.upper(), args.destination.upper()
        if not all(re.fullmatch("[A-Z]{3}", code) for code in (args.origin, args.destination)):
            parser.error("Use three-letter airport codes for this prototype.")
        if args.origin == args.destination:
            parser.error("Origin and destination must differ.")
        try:
            departure = date.fromisoformat(args.departure)
            returning = date.fromisoformat(args.return_date) if args.return_date else None
        except ValueError:
            parser.error("Dates must use YYYY-MM-DD.")
        if departure < date.today() or (returning and returning < departure):
            parser.error("Use a future departure and a return on or after departure.")
        if not 1 <= args.adults <= 9:
            parser.error("Adult count must be between 1 and 9.")
    try:
        health = load_health(args.state)
    except (ValueError, OSError, TypeError):
        print(json.dumps({"error": "Could not read health history; the existing file was not modified."}))
        return 2
    try:
        health.set_connector_version(importlib.metadata.version("fast-flights"))
    except importlib.metadata.PackageNotFoundError:
        health.set_connector_version(None)
        health.record_probe("local", "The flight connector is not installed.")
    if args.check_updates or args.force_update_check:
        check_for_updates(health, force=args.force_update_check)
    probe = run_probe(health, args.origin, args.destination, args.departure, args.return_date, args.adults) if args.origin else None
    save_health(args.state, health)
    print(json.dumps({"health": health.report(), "probe": probe}, indent=2))
    return 0 if not probe or not probe.get("failure_kind") else 1


if __name__ == "__main__":
    sys.exit(main())
