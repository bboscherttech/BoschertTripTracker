# Boschert Trip Tracker

A private, native macOS flight-price tracker by Boschert Technologies. The main
screen searches live flights inside the app. SwiftUI provides the interface;
a bundled Python helper performs fare searches and connector health checks.

## Open and run in Xcode

1. Open `BoschertTripTracker.xcodeproj`.
2. Choose the **Boschert Trip Tracker** scheme and **My Mac**.
3. Stop an older running build, then press **Command-R**.

Local signing is configured. No Apple Developer account or team selection is
required for development on this Mac. Dependencies are already installed in this
solution folder. On a fresh checkout, install Python 3.13 and run
`zsh scripts/setup.sh` once. The built app bundles Python, so the recipient needs
neither Python nor Xcode.

## Search and track a trip

1. Select **Search flights** in the sidebar.
2. Type a city, airport name, or IATA code into **From** and **To**. Choose dates,
   one way or round trip, traveler counts, cabin, and optional stop/airline filters.
3. Click **Search flights**.
4. Choose **Track cheapest trip** to follow the lowest complete-trip fare matching
   the search. For specific round trips, click **Choose return**, select a return,
   then click **Track these flights**.
5. Enter a name, optional target, and optional manual bag estimate, then save.

Prices are USD totals for all selected travelers and include required taxes.
Round-trip return-selection prices cover both directions; they are not added to
the outbound quote. Bag estimates are added once to the entire trip and are shown
separately from the sourced fare. Times are local to each airport; overnight
arrivals are labeled. Infants are not currently an input option.

Saved trips show current and lowest recorded totals, target, selected flights,
price-history chart, recent checks, and alert history. Targets and bag estimates
can be edited. Trips can be paused, archived, and restored without losing history.
A selected flight that is unavailable is reported as unavailable; another flight
is never silently substituted. Failed searches never record a zero-dollar fare.

## Alerts and background checks

- Alerts fire below the target and for every new all-time low, including $1 drops.
- The first observation establishes the baseline. An initial quote already below
  a target can alert; unchanged observations do not repeatedly alert.
- Defaults to hourly checks. Cadence is configurable in **Notifications & settings**.
- Checks continue when the window closes while the menu-bar app is running.
- Use the airplane menu-bar icon to reopen the app or check all tracked trips.
- Past-departure and paused trips are skipped. Checks resume on wake when due.
- Allow Mac notifications when prompted. Foreground alerts also use banners.
- Optional iPhone notifications use Apple's built-in **Reminders**, replacing ntfy.
  No additional phone app, SMS provider, developer membership, or new service
  account is required. Reminders must be installed and iCloud Reminders enabled
  on both devices under the same existing Apple account.
- In **Notifications & settings**, choose **Set up Reminders alerts** and allow
  Reminders access. The app creates or connects to an iCloud list named **Boschert
  Trip Tracker**, then enables the optional alerts. No other lists or existing
  reminders are edited or deleted. A local-only or Google list is not substituted.
- Choose **Send test notification**, lock the iPhone, and wait two minutes. Enable
  iPhone Reminders notifications and verify an actual banner/sound on her devices
  before relying on the channel. Building the app cannot verify remote delivery.
- Each price alert is a visible, timed reminder scheduled two minutes ahead to
  allow iCloud time to sync. Mark reminders complete when done. Saving a reminder
  on the Mac is not proof that the phone received it; delayed iCloud sync can delay
  or miss the alert. These are Reminders notifications, not SMS or Boschert-native
  iPhone pushes. No actual reminders were created during build verification.
- Alert titles and text pass through her existing iCloud Reminders account. The
  full trip history remains local. Setup is opt-in; old ntfy settings do not turn
  it on. Automatic price checks never request Reminders permission or create lists.

**Power limitation:** automatic checks require the app to be running and the Mac
awake. The optional keep-awake switch prevents idle sleep when the screen turns
off. It does not override lid-triggered sleep. Reliable closed-lid operation on
her M2 Air still needs a separate keep-awake configuration and hardware validation.
No power settings or privileged helpers are installed automatically.

## Flight data status

The maintenance panel is a supporting sidebar section. It tracks installed and
latest stable connector versions, last successful lookups, optional Google build
labels, and recent status changes. Release metadata is checked at most daily.
A new release or changed build label alone does not imply maintenance is needed.
Repeated incompatible responses are separated from network failures, consent
pages, rate limits, and local-component failures. Updates are not auto-installed.
There is no supported public Google Flights API version for this unofficial
interface. All live data depends on the connector continuing to work.

## Local storage

Trips, preferences, targets, fare history and alert history are stored in
`~/Library/Application Support/Boschert Trip Tracker/trips.json`. Connector health
is stored beside it in `health.json`. Writes are atomic. An unreadable or unknown
trip-store version is preserved rather than overwritten. No account or hosted
compute is used. Logs and trip history are not uploaded for analytics.

The solution is `/Users/benboschert/PersonalProjects/BoschertTripTracker`.
Original Boschert Technologies artwork is preserved in `Assets/` and used in the
window/sidebar, application icon, Dock, and About dialog.

## Build and verify

```sh
.venv/bin/python -m unittest -q
swiftc -parse-as-library -module-cache-path .build/module-cache TripCore.swift tests/CoreChecks.swift -o .build/trip-core-checks
.build/trip-core-checks
zsh build.sh
```

The distributable is `dist/Boschert Trip Tracker.zip`. Expand it and open the app.
The private development build is locally signed, not notarized for public release.

The helper uses `probe.py --request --state PATH`, accepting JSON on stdin. New
flight operations live in `flights.py`; maintenance logic lives in `maintenance.py`.
The build script caches the helper and rebuilds it after Python-source changes.
`BuildIcon.swift` is a separate icon tool, not part of the application target.

Validation includes Python tests for prices, passenger counts, both result
groups, selected-flight identity, unavailable itineraries and source health;
Swift checks for budgets, $1/new-low and threshold alerts, bag totals and persisted
history; and live searches for one way, round trip, selected returns and families.
An isolated app copy was used to save and refresh both tracking modes without
adding sample trips to the user's own store or sending notifications.

## Data sources

- [Flight connector](https://github.com/AWeirdDev/flights)
- [OurAirports public-domain airport data](https://ourairports.com/data/), bundled for city/name/code lookup
- [Apple's iCloud Reminders setup](https://support.apple.com/guide/icloud/set-up-reminders-mmbf52194b5a/icloud)
- [EventKit reminder alarms](https://developer.apple.com/documentation/eventkit/setting-an-alarm)

App version: 0.2.1.
