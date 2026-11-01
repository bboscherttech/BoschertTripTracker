"""Flight search and complete-trip quote lookup for Boschert Trip Tracker."""
from __future__ import annotations

from datetime import date, datetime, timezone
import hashlib
import html as html_lib
import importlib.metadata
import json
import math
from pathlib import Path
import re
from urllib.parse import urlencode

from maintenance import Health, check_for_updates, load_health, save_health, utc_now
from probe import ProbeFailure, check_page, extract_payload


def validate_query(value: dict) -> dict:
    if not isinstance(value, dict):
        raise ValueError("Enter a trip to search.")
    q = {
        "origin": str(value.get("origin", "")).upper(),
        "destination": str(value.get("destination", "")).upper(),
        "departure": value.get("departure", ""), "returnDate": value.get("returnDate"),
        "adults": value.get("adults", 2), "children": value.get("children", 0),
        "cabin": value.get("cabin", "economy"), "maxStops": value.get("maxStops"),
        "airlines": value.get("airlines", []),
    }
    if not all(re.fullmatch(r"[A-Z]{3}", q[key]) for key in ("origin", "destination")):
        raise ValueError("Choose a departure and arrival airport.")
    if q["origin"] == q["destination"]:
        raise ValueError("Departure and arrival airports must differ.")
    try:
        departing = date.fromisoformat(q["departure"])
        returning = date.fromisoformat(q["returnDate"]) if q["returnDate"] else None
    except (TypeError, ValueError):
        raise ValueError("Choose valid travel dates.")
    if departing < date.today() or (returning and returning < departing):
        raise ValueError("Choose a future departure and a return on or after departure.")
    if type(q["adults"]) is not int or type(q["children"]) is not int or not (
        1 <= q["adults"] <= 9 and 0 <= q["children"] <= 8 and q["adults"] + q["children"] <= 9
    ):
        raise ValueError("Select 1–9 travelers, including at least one adult.")
    if q["cabin"] not in ("economy", "premium-economy", "business", "first"):
        raise ValueError("Choose a supported cabin.")
    if q["maxStops"] not in (None, 0, 1, 2):
        raise ValueError("Choose a supported stops limit.")
    if not isinstance(q["airlines"], list) or any(not re.fullmatch(r"[A-Z0-9]{2}", str(code)) for code in q["airlines"]):
        raise ValueError("Airline filters use two-character codes, such as UA, AA or DL.")
    return q


def varint(value: int) -> bytes:
    data = bytearray()
    while value > 127:
        data.append((value & 127) | 128)
        value >>= 7
    data.append(value)
    return bytes(data)


def wire_field(number: int, value: str | bytes) -> bytes:
    value = value.encode() if isinstance(value, str) else value
    return varint(number * 8 + 2) + varint(len(value)) + value


def apply_selection(query, segments: list[dict], leg: int = 0) -> None:
    """Pin flight numbers through Google's selection field, not stale session tokens."""
    if not segments or len(segments) > 6:
        raise ValueError("Choose a complete flight itinerary.")
    previous = None
    for segment in segments:
        for key in ("origin", "destination"):
            if not re.fullmatch(r"[A-Z]{3}", segment.get(key, "")):
                raise ValueError("The selected flight's airports are invalid.")
        if not re.fullmatch(r"[A-Z0-9]{2}", segment.get("carrier", "")) or not re.fullmatch(r"\d{1,4}[A-Z]?", segment.get("number", "")):
            raise ValueError("The selected flight number is unavailable.")
        date.fromisoformat(segment["date"])
        if previous and previous["destination"] != segment["origin"]:
            raise ValueError("Selected flight connections do not join.")
        encoded = b"".join(wire_field(key, segment[value]) for key, value in (
            (1, "origin"), (2, "date"), (3, "destination"), (5, "carrier"), (6, "number")
        ))
        query.flight_data[leg].MergeFromString(wire_field(4, encoded))
        previous = segment


def make_query(q: dict, outbound: dict | None = None):
    from fast_flights import FlightQuery, Passengers, create_query
    legs = [FlightQuery(date=q["departure"], from_airport=q["origin"], to_airport=q["destination"], airlines=q["airlines"] or None)]
    if q["returnDate"]:
        legs.append(FlightQuery(date=q["returnDate"], from_airport=q["destination"], to_airport=q["origin"], airlines=q["airlines"] or None))
    query = create_query(flights=legs, trip="round-trip" if q["returnDate"] else "one-way",
                         passengers=Passengers(adults=q["adults"], children=q["children"]),
                         currency="USD", language="en-US", seat=q["cabin"], max_stops=q["maxStops"])
    if outbound:
        if not q["returnDate"]:
            raise ValueError("Return-flight selection requires a round trip.")
        segments = outbound["segments"]
        if segments[0]["origin"] != q["origin"] or segments[-1]["destination"] != q["destination"] or segments[0]["date"] != q["departure"]:
            raise ValueError("The selected departure does not match this trip.")
        apply_selection(query, segments)
    return query


def itinerary_id(segments: list[dict]) -> str:
    # A schedule-time adjustment keeps the same flight selected; another flight
    # number or travel date never silently substitutes for the selected flight.
    identity = [(s["origin"], s["destination"], s["date"], s["carrier"], s["number"]) for s in segments]
    return hashlib.sha256(json.dumps(identity).encode()).hexdigest()[:24]


def local_datetime(day: list, clock: list | None) -> str:
    day = date(*day)
    clock = [*(clock or []), 0, 0]
    hour, minute = clock[0] or 0, clock[1] or 0
    if not 0 <= hour <= 23 or not 0 <= minute <= 59:
        raise ValueError("Invalid local flight time")
    return f"{day.isoformat()}T{hour:02}:{minute:02}"


def decode_options(payload: list, q: dict, selecting_return: bool) -> list[dict]:
    result, seen = [], {}
    expected_origin = q["destination"] if selecting_return else q["origin"]
    expected_destination = q["origin"] if selecting_return else q["destination"]
    expected_date = q["returnDate"] if selecting_return else q["departure"]
    try:
        if not isinstance(payload, list) or len(payload) <= 7 or not isinstance(payload[7][1], list):
            raise ValueError("Unrecognized metadata")
        for position in (2, 3):
            section = payload[position]
            if section is None:
                continue
            if not isinstance(section, list) or not section:
                raise ValueError("Unrecognized result group")
            rows = section[0]
            if rows is None:
                continue
            if not isinstance(rows, list):
                raise ValueError("Unrecognized flight rows")
            for row in rows:
                raw, price = row[0], row[1][0][1]
                if type(price) not in (int, float) or not math.isfinite(price) or price <= 0:
                    raise ValueError("Invalid price")
                segments = []
                for leg in raw[2]:
                    segments.append({
                        "origin": leg[3], "originName": leg[4], "destination": leg[6], "destinationName": leg[5],
                        "date": date(*leg[20]).isoformat(), "departure": local_datetime(leg[20], leg[8]),
                        "arrival": local_datetime(leg[21], leg[10]), "carrier": str(leg[22][0]), "number": str(leg[22][1]),
                        "durationMinutes": int(leg[11]), "aircraft": leg[17] or "",
                    })
                if not segments or segments[0]["origin"] != expected_origin or segments[-1]["destination"] != expected_destination or segments[0]["date"] != expected_date:
                    raise ValueError("Response did not match the requested route and date")
                if any(left["destination"] != right["origin"] for left, right in zip(segments, segments[1:])):
                    raise ValueError("Incomplete connections")
                stops = len(segments) - 1
                if q["maxStops"] is not None and stops > q["maxStops"]:
                    raise ValueError("Response ignored the stops filter")
                identifier = itinerary_id(segments)
                normalized = {"id": identifier, "totalCents": round(price * 100), "airlines": raw[1],
                              "segments": segments, "durationMinutes": int(raw[9]), "stops": stops}
                if identifier in seen:
                    index = seen[identifier]
                    if normalized["totalCents"] < result[index]["totalCents"]:
                        result[index] = normalized
                else:
                    seen[identifier] = len(result)
                    result.append(normalized)

    except (IndexError, TypeError, KeyError, ValueError, OverflowError) as error:
        raise ProbeFailure("format", "The flight response changed or did not match your search. No price was recorded.") from error
    return sorted(result, key=lambda option: (option["totalCents"], option["durationMinutes"]))


def validate_party_price(html: str, q: dict) -> None:
    text = html_lib.unescape(re.sub(r"<[^>]+>", " ", html))
    match = re.search(r"Prices include required taxes\s*\+\s*fees for\s+([^.<]{1,140})", text)
    if not match:
        raise ProbeFailure("format", "The total-traveler pricing could not be verified. No price was recorded.")
    party = match.group(1)
    by_total = re.search(rf"\b{q['adults'] + q['children']} passengers?\b", party)
    by_breakdown = re.search(rf"\b{q['adults']} adults?\b", party)
    if q["children"]:
        by_breakdown = by_breakdown and re.search(rf"\b{q['children']} (?:child|children)\b", party)
    elif re.search(r"\bchild(?:ren)?\b", party):
        by_breakdown = False
    if not (by_total or by_breakdown):
        raise ProbeFailure("format", "The total-traveler pricing could not be verified. No price was recorded.")
    raw_text = html_lib.unescape(html)
    if "US dollars" not in raw_text:
        raise ProbeFailure("format", "The fare currency could not be verified. No price was recorded.")
    if q["returnDate"] and "round trip total" not in raw_text:
        raise ProbeFailure("format", "Complete round-trip pricing could not be verified. No price was recorded.")


def search(q: dict, health: Health, outbound: dict | None = None) -> dict:
    from primp import Client
    query = make_query(q, outbound)
    try:
        client = Client(impersonate="chrome_145", impersonate_os="macos", timeout=30, cookie_store=True)
        response = client.get("https://www.google.com/travel/flights/search", params=query.params())
    except Exception as error:
        raise ProbeFailure("network", "Could not connect to flight search. Check your internet connection and try again.") from error
    build = check_page(response.text, response.status_code)
    options = decode_options(extract_payload(response.text), q, outbound is not None)
    if options:
        validate_party_price(response.text, q)
    health.record_probe("success", f"Read {len(options)} flight options for the selected trip.", result_count=len(options), google_build=build)
    return {"query": q, "stage": "return" if outbound else "departure", "options": options,
            "outbound": outbound, "checkedAt": utc_now(), "searchURL": query.url()}


def booking_url(q: dict, outbound: dict, returning: dict | None = None) -> str:
    query = make_query(q)
    apply_selection(query, outbound["segments"], 0)
    if q["returnDate"]:
        if not returning:
            return query.url()
        apply_selection(query, returning["segments"], 1)
    return "https://www.google.com/travel/flights/booking?" + urlencode(query.params())


def refresh(q: dict, health: Health, outbound: dict | None, returning: dict | None) -> dict:
    result = search(q, health)
    if not result["options"]:
        return {"available": False, "detail": "No matching fares were available at this check.", "checkedAt": utc_now()}
    if not outbound:
        option = result["options"][0]
        return {"available": True, "totalCents": option["totalCents"], "outbound": option,
                "returning": None, "bookingURL": result["searchURL"], "checkedAt": result["checkedAt"]}
    departure = next((item for item in result["options"] if item["id"] == outbound["id"]), None)
    if not departure:
        return {"available": False, "detail": "The selected departure was not available. No other flight was substituted.", "checkedAt": utc_now()}
    if not q["returnDate"]:
        return {"available": True, "totalCents": departure["totalCents"], "outbound": departure,
                "returning": None, "bookingURL": booking_url(q, departure), "checkedAt": utc_now()}
    if not returning:
        raise ValueError("Choose a return flight before tracking this specific round trip.")
    inbound = search(q, health, departure)
    chosen = next((item for item in inbound["options"] if item["id"] == returning["id"]), None)
    if not chosen:
        return {"available": False, "detail": "The selected return was not available. No other flight was substituted.", "checkedAt": utc_now()}
    return {"available": True, "totalCents": chosen["totalCents"], "outbound": departure,
            "returning": chosen, "bookingURL": booking_url(q, departure, chosen), "checkedAt": utc_now()}


def handle_request(request: dict, state: Path) -> dict:
    health = load_health(state)
    health.set_connector_version(importlib.metadata.version("fast-flights"))
    response = {}
    try:
        q = validate_query(request.get("query"))
        action = request.get("action")
        if action == "search":
            response["search"] = search(q, health, request.get("outbound"))
        elif action == "refresh":
            response["refresh"] = refresh(q, health, request.get("outbound"), request.get("returning"))
        elif action == "booking":
            response["bookingURL"] = booking_url(q, request["outbound"], request.get("returning"))
        else:
            raise ValueError("Unknown flight-search action.")
    except ProbeFailure as error:
        health.record_probe(error.kind, str(error))
        response["error"] = str(error)
    except (ValueError, KeyError, TypeError) as error:
        response["error"] = str(error) if isinstance(error, ValueError) else "The trip information was incomplete. Please search again."
    except Exception:
        health.record_probe("local", "The local flight-search component failed. No price was recorded.")
        response["error"] = "The flight-search component could not finish. See Flight data status for details."
    check_for_updates(health)
    save_health(state, health)
    response["health"] = health.report()
    return response
