# Plot Finder — UI redesign milestones

A visual redesign of the existing Plot Finder screens (`lib/ui/`) in the Cropin
Grow look: slate-teal app bar, light cards and filled fields for the planning
screens, dark camera chrome for the AR view. Behaviour, copy rules and every
caveat the current screens carry stay. The redesign changes how they look, not
what they say.

Artboards live in `project/` as `.dc.html` files, laid out by `project/canvas.json`.

| # | Milestone | Artboard | Maps to | Done when |
|---|---|---|---|---|
| D1 | Permissions | `Main.dc.html` | `_PermissionGate` in `lib/app.dart` | Camera + location rationale, grant, open settings |
| D2 | Plots list | `Plots.dc.html` | `lib/ui/plots/plot_list_screen.dart` | Sync, cache age, fix state, nearest-first rows, empty state |
| D3 | Plot detail | `Detail.dc.html` | `lib/ui/detail/plot_detail_screen.dart` | Boundary sketch, access point, landmark, facts, Find / Simulate |
| D4 | AR finder · locked | `Finder.dc.html` | `lib/ui/ar/ar_screen.dart`, `heading_chip.dart` | Heading chip, FAR/NEAR badge, health controls + legend, pin heading |
| D5 | AR finder · caution | `FinderCaution.dc.html` | `ar_screen.dart`, `simulation_panel.dart` | Unreliable heading veto, synthetic-data warning, message, simulation panel |

## Design tokens

| Token | Value | Use |
|---|---|---|
| Primary | `#234556` | App bar, primary buttons, selected states |
| Primary dark | `#1A3542` | Pressed, camera-side panels |
| Ground | `#F2F4F5` | Planning screens background |
| Surface | `#FFFFFF` | Cards, sheets |
| Field | `#F1F3F4` fill, `#C5CDD2` border | Read-only value fields |
| Text | `#1A2228` / muted `#56636C` | Body / secondary |
| Camera scrim | `#0F1A20` at 80–92% | Panels over the camera |
| Locked | `#4ADE80` (on dark) / `#2F7D45` (on light) | Heading locked, synced |
| Holding / warning | `#F59E0B` (on dark) / `#A15C07` (on light) | Holding heading, caveats |
| Unreliable | `#9CA3AF` | Heading unreliable |
| Severity | `#2FD44E` `#FFE81A` `#FF8A00` `#FF2118` | Healthy, Mild, Stressed, Critical (unchanged from `plot_palette.dart`) |

The plot boundary keeps its palette slot colour from `plotColours`, and the
sketch keeps cyan boundary + amber access point. Type: Roboto, 20/16/14/12 sp.
Radius 8 for fields and buttons, 12 for cards, full for chips. Touch targets ≥ 48 dp.

The AR view stays dark on purpose (see `lib/ui/theme.dart`): light chrome over
a daylight camera feed washes the overlay out.
