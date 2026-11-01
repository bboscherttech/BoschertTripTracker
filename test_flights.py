from copy import deepcopy
from datetime import date, timedelta
from unittest.mock import patch
import unittest

from flights import decode_options, itinerary_id, make_query, refresh, validate_party_price, validate_query
from maintenance import Health
from probe import ProbeFailure
from test_maintenance import payload_fixture


def query():
    return validate_query(dict(origin="ORD", destination="BOS", departure=(date.today() + timedelta(days=30)).isoformat(),
        returnDate=(date.today() + timedelta(days=37)).isoformat(), adults=2))


def fixture(returning=False):
    payload = payload_fixture()
    q = query()
    for index in (2, 3):
        for row in payload[index][0]:
            row[0][9] = 120
            segment = row[0][2][0]
            day = date.fromisoformat(q["returnDate"] if returning else q["departure"])
            segment[20] = segment[21] = [day.year, day.month, day.day]
            segment.append(["AA", str(100 + index), None, "American"])
            if returning:
                segment[3], segment[6] = "BOS", "ORD"
                segment[4], segment[5] = "Logan", "O'Hare"
    return payload


class FlightTests(unittest.TestCase):
    def test_city_route_validation_and_traveler_limit(self):
        for changes in [{"origin": "ORD", "destination": "ORD"}, {"adults": 0}, {"adults": 8, "children": 2}, {"airlines": ["United"]}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                validate_query({**query(), **changes})

    def test_both_result_groups_and_party_fare_are_read_without_multiplication(self):
        options = decode_options(fixture(), query(), False)
        self.assertEqual(len(options), 2)
        self.assertEqual(options[0]["totalCents"], 12000)
        self.assertEqual(options[0]["segments"][0]["number"], "102")

    def test_duplicate_itinerary_keeps_the_cheapest_fare(self):
        payload = fixture()
        payload[3][0][0][0][2][0][22] = payload[2][0][0][0][2][0][22]
        payload[3][0][0][1][0][1] = 80
        options = decode_options(payload, query(), False)
        self.assertEqual(len(options), 1)
        self.assertEqual(options[0]["totalCents"], 8000)

    def test_return_options_must_have_reverse_route_and_return_date(self):
        options = decode_options(fixture(returning=True), query(), True)
        self.assertEqual(options[0]["segments"][0]["origin"], "BOS")
        with self.assertRaises(ProbeFailure):
            decode_options(fixture(), query(), True)

    def test_changed_best_group_is_not_silently_discarded(self):
        payload = fixture()
        payload[2] = "changed"
        with self.assertRaises(ProbeFailure):
            decode_options(payload, query(), False)

    def test_wrong_airport_date_price_or_stop_filter_cannot_become_a_quote(self):
        for change in ["airport", "date", "price", "stops"]:
            payload = fixture()
            row = payload[2][0][0]
            if change == "airport": row[0][2][0][3] = "JFK"
            if change == "date": row[0][2][0][20] = [2030, 1, 1]
            if change == "price": row[1][0][1] = 0
            if change == "stops": row[0][2].append(deepcopy(row[0][2][0]))
            with self.subTest(change=change), self.assertRaises(ProbeFailure):
                decode_options(payload, {**query(), "maxStops": 0}, False)

    def test_verified_party_and_complete_round_trip_label_are_required(self):
        good = '<div>Prices include required taxes + fees for 2 adults.</div><a aria-label="626 US dollars round trip total">$626</a>'
        validate_party_price(good, query())
        for changed in [good.replace("2 adults", "1 adult"), good.replace("round trip total", "one way total"), good.replace("US dollars", "euros")]:
            with self.assertRaises(ProbeFailure): validate_party_price(changed, query())

    def test_family_passenger_total_is_verified(self):
        html = '<div>Prices include required taxes + fees for 3 passengers.</div><a aria-label="939 US dollars round trip total">$939</a>'
        validate_party_price(html, {**query(), "children": 1})
        with self.assertRaises(ProbeFailure): validate_party_price(html, query())

    def test_selection_is_rebuilt_from_flight_identity_not_a_session_token(self):
        q = query()
        option = decode_options(fixture(), q, False)[0]
        pb = make_query(q, option).to_bytes()
        self.assertIn(b"AA", pb)
        self.assertIn(b"102", pb)
        self.assertIn(q["returnDate"].encode(), pb)

    def test_schedule_change_preserves_identity_but_different_flight_does_not(self):
        segment = decode_options(fixture(), query(), False)[0]["segments"][0]
        later = {**segment, "departure": "2030-01-01T12:00"}
        different = {**segment, "number": "999"}
        self.assertEqual(itinerary_id([segment]), itinerary_id([later]))
        self.assertNotEqual(itinerary_id([segment]), itinerary_id([different]))

    def test_specific_roundtrip_uses_complete_return_quote_not_sum_of_two_quotes(self):
        q = query()
        outbound = decode_options(fixture(), q, False)[0]
        returning = decode_options(fixture(True), q, True)[0]
        returning["totalCents"] = 73000
        with patch("flights.search", side_effect=[{"options": [outbound]}, {"options": [returning]}]):
            result = refresh(q, Health(), outbound, returning)
        self.assertTrue(result["available"])
        self.assertEqual(result["totalCents"], 73000)
        self.assertNotEqual(result["totalCents"], outbound["totalCents"] + returning["totalCents"])

    def test_missing_pinned_departure_is_unavailable_and_never_substituted(self):
        q = query()
        options = decode_options(fixture(), q, False)
        with patch("flights.search", return_value={"options": [options[1]]}):
            result = refresh(q, Health(), options[0], None)
        self.assertFalse(result["available"])
        self.assertNotIn("totalCents", result)

    def test_missing_pinned_return_is_unavailable_and_never_substituted(self):
        q = query()
        outbound = decode_options(fixture(), q, False)[0]
        returning = decode_options(fixture(True), q, True)
        with patch("flights.search", side_effect=[{"options": [outbound]}, {"options": [returning[1]]}]):
            result = refresh(q, Health(), outbound, returning[0])
        self.assertFalse(result["available"])
        self.assertNotIn("totalCents", result)

    def test_empty_search_does_not_record_zero_dollar_price(self):
        with patch("flights.search", return_value={"options": []}):
            result = refresh(query(), Health(), None, None)
        self.assertFalse(result["available"])
        self.assertNotIn("totalCents", result)


if __name__ == "__main__": unittest.main()
