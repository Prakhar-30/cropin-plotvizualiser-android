# Document Scanner — design milestones

A new, standalone feature for the Cropin Grow app: scan paper documents with the
camera, clean them up, and keep them as multi-page files that sync when the
device is back online. It borrows the Grow look (slate-teal app bar, rounded
filled inputs, dark camera chrome, green confirm action) and is not tied to the
Add Farmer flow.

Artboards live in `project/` as `.dc.html` files, laid out by `project/canvas.json`.

| # | Milestone | Artboard | Done when |
|---|---|---|---|
| M1 | Capture | `Main.dc.html` | Camera with live edge detection, auto/manual capture, flash, import, page tray |
| M2 | Review & enhance | `Review.dc.html` | Crop handles, rotate, filters, quality check, retake / keep |
| M3 | Pages & save | `Pages.dc.html` | Reorder and delete pages, name, document type, format, save |
| M4 | Documents library | `Library.dc.html` | Search, type filters, sync states, offline banner, scan entry point |
| M5 | Document detail | `Detail.dc.html` | Page viewer, metadata, upload status, share / export / delete |

## Design tokens

| Token | Value | Use |
|---|---|---|
| Primary | `#234556` | App bar, primary buttons, selected chips |
| Primary pressed | `#1A3542` | Pressed / dark surfaces |
| Success | `#2F7D45` | Confirm, synced, detected edges |
| Warning | `#A15C07` | Low quality, pending sync |
| Danger | `#C62828` | Delete, required marker |
| Ground | `#F2F4F5` | Screen background |
| Surface | `#FFFFFF` | Cards, sheets |
| Field | `#F1F3F4` fill, `#C5CDD2` border | Inputs |
| Text | `#1A2228` / muted `#56636C` | Body / secondary |
| Camera chrome | `#0F1A20` at 72–100% | Scanner overlays |

Type: Roboto (the app's typeface), 20/16/14/12 sp scale. Radius 8 for inputs,
12 for cards, full for chips and icon buttons. Touch targets ≥ 48 dp.
