from copy import deepcopy
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from maintenance import Health, check_for_updates, fetch_latest_release, load_health, save_health
from probe import ProbeFailure, check_page, extract_payload, parse_all_results

NOW = "2026-10-31T18:00:00+00:00"


class HealthTests(unittest.TestCase):
    def test_installing_an_update_clears_cached_update_notice_without_another_request(self):
        health = Health(connector_version="3.1.0")
        health.record_update("3.2.0", at=NOW)
        self.assertTrue(health.update_available)
        health.set_connector_version("3.2.0")
        self.assertFalse(health.update_available)
        self.assertEqual(health.last_update_check, NOW)

    def test_connector_update_is_not_a_tracking_failure(self):
        health = Health(connector_version="3.1.0")
        health.record_probe("success", "Parsed prices", result_count=4, at=NOW)
        health.record_update("3.2.0", at=NOW)
        self.assertTrue(health.update_available)
        self.assertEqual(health.status, "working")
        self.assertEqual(health.last_success, NOW)

    def test_source_build_can_change_without_breaking_prices(self):
        health = Health()
        health.record_probe("success", "Parsed", result_count=4, google_build="old", at=NOW)
        health.record_probe("success", "Parsed", result_count=4, google_build="new", at=NOW)
        self.assertEqual(health.status, "working")
        self.assertEqual(health.last_successful_google_build, "new")
        self.assertIn("source_build_changed", [item["kind"] for item in health.events])
        self.assertIsNone(health.google_api_version)

    def test_repeated_bad_responses_suggest_maintenance_then_recover(self):
        health = Health()
        for expected in ("response_unrecognized", "response_unrecognized", "maintenance_suggested"):
            health.record_probe("format", "Unexpected data", at=NOW)
            self.assertEqual(health.status, expected)
        health.record_probe("success", "Recovered", result_count=2, at=NOW)
        self.assertEqual(health.status, "working")
        self.assertEqual(health.consecutive_format_failures, 0)

    def test_network_failure_preserves_success_history_and_marks_prices_stale(self):
        health = Health()
        health.record_probe("success", "Parsed", result_count=4, at=NOW)
        health.record_probe("network", "Offline", at=NOW)
        self.assertEqual(health.status, "connection_problem")
        self.assertEqual(health.last_success, NOW)
        self.assertEqual(health.last_result_count, 4)
        self.assertFalse(health.prices_are_fresh(now=datetime.fromisoformat(NOW)))

    def test_throttling_and_dependency_errors_do_not_imply_google_changed(self):
        for kind, expected in (("blocked", "access_limited"), ("local", "local_component_problem"), ("service", "source_unavailable")):
            with self.subTest(kind=kind):
                health = Health()
                for _ in range(5):
                    health.record_probe(kind, "Failed", at=NOW)
                self.assertEqual(health.status, expected)
                self.assertEqual(health.consecutive_format_failures, 0)

    def test_update_check_failure_keeps_last_known_version_and_health(self):
        health = Health(connector_version="3.1.0")
        health.record_update("3.2.0", at=NOW)
        health.record_probe("success", "Parsed", result_count=4, at=NOW)
        health.record_update(None, error="Offline", at="2026-11-01T18:00:00+00:00")
        self.assertEqual(health.latest_connector_version, "3.2.0")
        self.assertEqual(health.last_update_check, NOW)
        self.assertEqual(health.status, "working")

    def test_update_checks_are_limited_to_once_a_day_even_after_failure(self):
        health = Health()
        health.record_update(None, error="Offline", at=NOW)
        self.assertFalse(health.update_due(now=datetime.fromisoformat(NOW) + timedelta(hours=1)))
        self.assertTrue(health.update_due(now=datetime.fromisoformat(NOW) + timedelta(days=1)))
        with patch("maintenance.utc_now", return_value=NOW):
            check_for_updates(health, fetch=lambda: self.fail("Daily limit ignored"))

    def test_version_comparison_is_numeric_and_ignores_prereleases(self):
        health = Health(connector_version="3.9.0")
        health.record_update("3.10.0", at=NOW)
        self.assertTrue(health.update_available)
        health.record_update("4.0rc1", at=NOW)
        self.assertEqual(health.latest_connector_version, "3.10.0")
        self.assertIsNotNone(health.update_check_error)

    def test_newer_installed_release_is_not_a_downgrade_suggestion(self):
        health = Health(connector_version="3.2.0")
        health.record_update("3.1.0", at=NOW)
        self.assertFalse(health.update_available)

    def test_success_expires_without_another_check(self):
        health = Health()
        health.record_probe("success", "Parsed", result_count=4, at=NOW)
        self.assertTrue(health.prices_are_fresh(now=datetime.fromisoformat(NOW)))
        self.assertFalse(health.prices_are_fresh(now=datetime.fromisoformat(NOW) + timedelta(hours=3)))

    def test_no_results_requires_a_successful_probe_but_does_not_produce_a_price(self):
        health = Health()
        health.record_probe("success", "No matching flights", result_count=0, at=NOW)
        self.assertEqual(health.status, "no_results")
        self.assertEqual(health.last_result_count, 0)
        self.assertNotIn("price", health.report())

    def test_state_round_trip_and_bounded_event_history(self):
        health = Health()
        for i in range(125):
            health.event("test", str(i), NOW)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "nested" / "health.json"
            save_health(path, health)
            restored = load_health(path)
            self.assertEqual(restored, health)
            self.assertEqual(len(restored.events), 100)

    def test_unknown_state_version_is_not_silently_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "health.json"
            path.write_text('{"state_version":99}')
            with self.assertRaises(ValueError):
                load_health(path)
            self.assertEqual(json.loads(path.read_text())["state_version"], 99)

    def test_stable_release_lookup_skips_yanked_and_prerelease_versions(self):
        from io import BytesIO
        payload = {"releases": {
            "3.1.0": [{"yanked": False}], "3.2.0": [{"yanked": True}],
            "4.0rc1": [{"yanked": False}], "invalid": [{"yanked": False}],
        }}
        with patch("maintenance.urlopen", return_value=BytesIO(json.dumps(payload).encode())):
            self.assertEqual(fetch_latest_release(), "3.1.0")


def payload_fixture(best=120, other=210):
    def row(price):
        segment = [None] * 22
        for index, value in {3: "ORD", 4: "O'Hare", 5: "Logan", 6: "BOS", 8: [9], 10: [12],
                             11: 120, 17: "Airbus A320", 20: [2026, 12, 1], 21: [2026, 12, 1]}.items():
            segment[index] = value
        flight = [None] * 23
        flight[0], flight[1], flight[2] = "AA", ["American"], [segment]
        flight[22] = [None] * 9
        flight[22][7], flight[22][8] = 100, 120
        return [flight, [[None, price]]]
    payload = [None] * 8
    payload[2] = [[row(best)]] if best is not None else [None]
    payload[3] = [[row(other)]] if other is not None else [None]
    payload[7] = [None, [[["ONEWORLD", "oneworld"]], [["AA", "American"]]]]
    return payload


class ResponseTests(unittest.TestCase):
    def test_cheapest_best_flight_is_included_even_if_upstream_only_reads_other(self):
        results = parse_all_results(payload_fixture())
        self.assertEqual([item["source_price"] for item in results], [120, 210])
        self.assertEqual(results[0]["segments"][0]["departure_time"], [9, 0])

    def test_duplicate_across_groups_is_only_counted_once(self):
        self.assertEqual(len(parse_all_results(payload_fixture(best=120, other=120))), 1)

    def test_no_flights_with_recognized_schema_is_valid(self):
        self.assertEqual(parse_all_results(payload_fixture(best=None, other=None)), [])

    def test_malformed_schema_and_invalid_prices_are_never_accepted(self):
        invalid = [[], [None] * 8]
        for value in (0, -1, "120", True):
            invalid.append(payload_fixture(best=value))
        for payload in invalid:
            with self.subTest(payload=repr(payload)[:80]), self.assertRaises(ProbeFailure):
                parse_all_results(payload)

    def test_broken_best_group_with_working_other_group_is_not_silently_ignored(self):
        payload = payload_fixture()
        payload[2] = "changed"
        with self.assertRaises(ProbeFailure) as caught:
            parse_all_results(payload)
        self.assertEqual(caught.exception.kind, "format")

    def test_payload_extraction_and_optional_build_label(self):
        html = '<script>var WIZ_global_data={"cfb2h":"flight-build-123"};</script>'
        html += '<script class="ds:1">AF_initDataCallback({key:"ds:1",data:' + json.dumps(payload_fixture()) + ',sideChannel:{}});</script>'
        self.assertEqual(check_page(html), "flight-build-123")
        self.assertEqual(len(parse_all_results(extract_payload(html))), 2)

    def test_missing_data_is_format_failure(self):
        with self.assertRaises(ProbeFailure) as caught:
            extract_payload("<html>Changed flight page</html>")
        self.assertEqual(caught.exception.kind, "format")

    def test_rate_limit_consent_and_source_error_are_distinct_from_format_change(self):
        for html, code, expected in (
            ("", 429, "blocked"), ("", 503, "service"),
            ('Before you continue <form action="https://consent.google.com/save">', 200, "blocked"),
            ("Our systems have detected unusual traffic", 200, "blocked"),
        ):
            with self.subTest(code=code, html=html), self.assertRaises(ProbeFailure) as caught:
                check_page(html, code)
            self.assertEqual(caught.exception.kind, expected)


if __name__ == "__main__":
    unittest.main()
