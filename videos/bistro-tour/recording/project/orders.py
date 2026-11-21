"""Order rules for the dining room: tables, menu items and totals."""
import itertools
import json
from pathlib import Path

MENU = {item["id"]: item for item in json.loads((Path(__file__).parent / "menu.json").read_text())}
TABLES = range(1, 13)
_ids = itertools.count(41)


class OrderError(ValueError):
    pass


def total(items):
    return round(sum(MENU[item]["price"] for item in items), 2)


def create_order(table, items):
    if table not in TABLES:
        raise OrderError(f"no table {table}")
    unknown = [item for item in items if item not in MENU]
    if unknown:
        raise OrderError("not on the menu: " + ", ".join(unknown))
    if not items:
        raise OrderError("an order needs at least one item")
    return {"id": next(_ids), "table": table, "items": list(items), "total": total(items)}


def ticket(order, clock):
    lines = [f"#{order['id']:04d}  table {order['table']:<2}  {clock}"]
    counts = {}
    for item in order["items"]:
        counts[item] = counts.get(item, 0) + 1
    lines += [f"  {count} × {MENU[item]['name']}" for item, count in counts.items()]
    return "\n".join(lines) + "\n"
