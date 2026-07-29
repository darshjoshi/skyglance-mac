# Notice — third-party data terms

The [MIT licence](LICENSE) covers the source code in this repository only.

The flight data the application displays at runtime is **not** covered by it, is not mine to
license, and carries its own terms. These obligations travel with the app: if you fork, repackage,
or redistribute it, they apply to you too.

| Source | Terms |
|---|---|
| [adsb.lol](https://www.adsb.lol) | **[ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/)** — attribution required |
| [airplanes.live](https://airplanes.live) | Non-commercial use |
| [adsb.fi](https://adsb.fi) | Community-run feed |
| [adsbdb.com](https://www.adsbdb.com) | Free, volunteer-run |
| [hexdb.io](https://hexdb.io) | Free, volunteer-run |
| [planespotters.net](https://www.planespotters.net) | Photographs remain the property of their photographers and **must** carry the credit the API returns |
| [Open-Meteo](https://open-meteo.com) | Free, non-commercial |

## How this app meets them

- **Attribution** — every contributing source is named in the panel footer, and the full list with
  links sits behind **Data sources & licences** in the `⋯` menu.
- **Photographer credit** — rendered under every photograph as `photo © <name>`, taken from the
  API response rather than hardcoded, and the detail card refuses to show a photo it cannot
  credit.
- **ODbL share-alike** — applies to derived *databases*. This app displays live data and does not
  redistribute a database, so the code stays MIT. The attribution requirement is not optional
  either way.

## If you fork this

None of these services require an API key. All of them are run by volunteers, funded by nobody, and
are easy to overload. Keep the per-source rate limiting and the circuit breakers, keep the
enrichment caching, and put a real contact URL in your `User-Agent` — planespotters rejects generic
ones outright, which is why that string exists at all.

See [docs/FREE-STACK.md](docs/FREE-STACK.md) before pointing anything at them at scale.
