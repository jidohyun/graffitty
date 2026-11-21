# bistro-orders

Table orders and evening reservations for the bistro. A small JSON API, a
menu page for the dining room, and a board for the kitchen.

```sh
python3 server.py         # http://localhost:8090
python3 board.py          # kitchen board
python3 rush.py           # replay a dinner rush against the server
python3 -m unittest       # tests
./release.sh 1.2.0        # tested, checksummed tarball in dist/
```

| Route | |
| --- | --- |
| `GET /menu` | Tonight's dishes and prices |
| `GET /orders`, `POST /orders` | Open orders; `{"table": 4, "items": ["espresso"]}` |
| `GET /reservations`, `POST /reservations` | Bookings; `{"name": "Lee", "party": 2, "slot": "19:30"}` |
