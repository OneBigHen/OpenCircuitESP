# ringconn-card

Custom Lovelace card for the RingConn Gen 2 bridge. One file, no dependencies.

## Install
Copy `ringconn-card.js` to `/config/www/`, add it as a dashboard resource (`/local/ringconn-card.js`, type JavaScript module), then:

```yaml
type: custom:ringconn-card
```

## Entities read
- `sensor.ringconn_dashboard` (state = generated_at; attributes `latest`, `series_24h`, `steps_today`, `battery_drain_pct_per_h`, `days`, `bridge`, `timezone`)
- `sensor.ringconn_ring_state` (in_case / out_of_case / unknown)
- `sensor.ringconn_ring_location` (bedside_case / bedside / living_room / out_of_range)
- `sensor.ringconn_ring_area` (optional Bermuda room; shown as the headline when set)

## Options
| Option | Default | Meaning |
|---|---|---|
| `title` | `RingConn Gen 2` | Small heading |
| `dashboard_entity` | `sensor.ringconn_dashboard` | Main data sensor |
| `state_entity` | `sensor.ringconn_ring_state` | Case state |
| `location_entity` | `sensor.ringconn_ring_location` | Coarse location |
| `area_entity` | `sensor.ringconn_ring_area` | Room sensor |
| `default_metric` | `hr_bpm` | Starting tab (`hrv_rmssd_ms`, `spo2_pct`, `respiratory_rate`, `skin_temp_c`, `battery_pct`, `quarter_hour_steps`) |
| `step_goal` | none | Shows a progress bar under steps |
| `show_bridge` | `true` | Hide the bridge health section |

Test locally: `python3 -m http.server` in this folder, open `harness.html` (toggles for sparse data, theme, width).
