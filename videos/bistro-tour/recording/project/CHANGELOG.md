# Changelog

## 1.2.0

- Evening reservations: `POST /reservations` seats a party at the first free
  table for its time slot, from 18:00 to 21:30.
- The menu page and the kitchen board list tonight's bookings.

## 1.1.0

- Kitchen tickets are written to `logs/tickets.log` for the printer.
- `rush.py` replays a dinner rush for load checks.

## 1.0.0

- Orders API and the dining-room menu page.
