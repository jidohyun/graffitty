# Bistro tour

A short film of Bistro World: nine prepared sessions, one per Bistro place,
visited only through real clicks in the compact left Sessions sidebar. No
typing on camera. Each arrival holds for `DWELL` seconds, then the pointer
leaves for the next row. Keep every session departure, camera flight and
arrival at 1×.

## The story

All panes work in one real repository, `bistro-orders`: table orders and
evening reservations for the bistro. The `reservations` branch holds an
uncommitted change that the Claude session made.

| Tour | Session | Bistro place | Panes |
| --- | --- | --- | --- |
| 1 | Overview | cafe-awning | `git log` and `git status`; filetree |
| 2 | Menu page | cafe-terrace | Neovim on `static/index.html`; Chromium on the live page |
| 3 | Server | terrace-tables | `python3 server.py` request log; `curl /menu`; `rush.py` dinner-rush traffic |
| 4 | Kitchen | tree-square | Live kitchen board; ticket printer log |
| 5 | Claude | dining-room | Claude adds reservations, runs the tests |
| 6 | Review | bottle-shelves | Codex reviews the change; `git diff server.py` |
| 7 | Tests | window-tables | Neovim on the reservation tests; `unittest -v` |
| 8 | Agents | square-reverse | Claude writes specials → solid wire → Codex checks allergens |
| 9 | Release | pharmacy-lane | `./release.sh 1.2.0`; the changelog |

Sessions are created in `ORDER` (the place order); the film visits them in
`TOUR`. The server, `rush.py`, the board, the ticket log and the Chromium page
all read the same live server, so activity keeps moving between visits. Agent
panes are scripted playbacks (`gft dev claude-mock` / `codex-mock`); their
shell steps run for real in the repository, and the Agents delivery is a real
graph receipt. Never call this a live-provider run.

## Known app issues the recorder works around

- **Chromium renderer abort.** The bundled CEF renderer aborts on a Blink
  DCHECK in `LayerTreeView::AddPresentationCallback` 60 to 100 seconds after
  launch, whatever the page does. The recorder opens the menu page just before
  capture and shows it second, asserts the page is healthy on arrival and when
  the tour leaves, and stores any macOS renderer crash reports from the take in
  `tour.json` (`menu_page_renderer`). Remove the workaround once CEF is fixed.

## Recording

```sh
mise run cli:build
mkdir -p /tmp/bistro-tour-bin && cp target/release/gft /tmp/bistro-tour-bin/gft  # snapshot
GRAFFITTY_TEST_SERVER=/tmp/bistro-tour-bin/gft \
  python3 videos/bistro-tour/recording/record.py --output videos/artifacts/bistro-tour-takes/TAKE
```

The recorder builds the repository at `/Users/Shared/gft/demo/bistro-orders`
(shown on camera; no account names), runs a private server on port 8090 and
the macOS background GPU guard, and encodes `videos/artifacts/bistro-tour.webm`
(VP9) directly from the 60 fps capture. The take keeps `capture.json`,
`tour.json`, per-arrival snapshots and a copy of the repository.
