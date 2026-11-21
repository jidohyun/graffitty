"""Replay a dinner rush against the local server: orders and bookings."""
import itertools
import json
import os
import random
import time
import urllib.error
import urllib.request

URL = "http://localhost:" + os.environ.get("PORT", "8090")
GUESTS = ["Martin", "Okafor", "Lee", "Dubois", "Haddad", "Rossi", "Nakamura", "Silva"]
MENU = [item["id"] for item in json.load(urllib.request.urlopen(URL + "/menu"))]
rng = random.Random(7)


def post(path, body):
    request = urllib.request.Request(URL + path, json.dumps(body).encode(), {"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)


for n in itertools.count():
    if n % 3 == 2:
        status, body = post("/reservations", {"name": rng.choice(GUESTS), "party": rng.randint(2, 6),
                                              "slot": rng.choice(["19:00", "19:30", "20:00", "20:30"])})
        print(f"book   {body.get('name', ''):<9} {body.get('slot', '')}  table {body.get('table', '-'):<3} {status}" if status == 201
              else f"book   {status}  {body['error']}", flush=True)
    else:
        status, body = post("/orders", {"table": rng.randint(1, 12), "items": rng.sample(MENU, rng.randint(1, 3))})
        print(f"order  #{body['id']:04d}  table {body['table']:<3} €{body['total']:>6.2f}  {status}", flush=True)
    time.sleep(rng.uniform(0.8, 1.6))
