"""Kitchen board: open orders by table, refreshed every second."""
import json
import os
import time
import urllib.request

URL = "http://localhost:" + os.environ.get("PORT", "8090")
NAMES = {item["id"]: item["name"] for item in json.load(urllib.request.urlopen(URL + "/menu"))}

while True:
    orders = json.load(urllib.request.urlopen(URL + "/orders?watch=1"))
    bookings = json.load(urllib.request.urlopen(URL + "/reservations?watch=1"))
    lines = [f"\033[1;33m KITCHEN BOARD\033[0m   {time.strftime('%H:%M:%S')}   "
             f"{len(orders)} open · {len(bookings)} booked", ""]
    for order in reversed(orders[-8:]):
        dishes = ", ".join(NAMES[item] for item in order["items"])
        lines.append(f" \033[1m#{order['id']:04d}\033[0m  table {order['table']:<3} {dishes}")
    lines += ["", "\033[1;36m NEXT SEATINGS\033[0m"]
    lines += [f"  {b['slot']}  {b['name']:<10} table {b['table']}" for b in bookings[:5]]
    print("\033[H\033[2J" + "\n".join(lines), end="", flush=True)
    time.sleep(1)
