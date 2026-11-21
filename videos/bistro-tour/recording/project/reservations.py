"""Evening reservations: one party per table and time slot."""
from orders import TABLES, OrderError

SLOTS = ["18:00", "18:30", "19:00", "19:30", "20:00", "20:30", "21:00", "21:30"]
MAX_PARTY = 8


class Book:
    def __init__(self):
        self.taken = {}

    def reserve(self, name, party, slot):
        if not isinstance(party, int) or not 1 <= party <= MAX_PARTY:
            raise OrderError(f"party size must be 1-{MAX_PARTY}")
        if slot not in SLOTS:
            raise OrderError(f"no seating at {slot}")
        for table in TABLES:
            if (table, slot) not in self.taken:
                self.taken[(table, slot)] = name
                return {"name": name, "party": party, "slot": slot, "table": table}
        raise OrderError(f"fully booked at {slot}")

    def tonight(self):
        return sorted(({"slot": slot, "table": table, "name": name}
                       for (table, slot), name in self.taken.items()),
                      key=lambda booking: (booking["slot"], booking["table"]))
