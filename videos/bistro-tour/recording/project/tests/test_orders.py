import unittest

import orders


class OrderTests(unittest.TestCase):
    def test_total_adds_menu_prices(self):
        self.assertEqual(orders.total(["steak-frites", "espresso"]), 27.0)

    def test_order_keeps_items_in_sequence(self):
        order = orders.create_order(4, ["croque-monsieur", "cafe-creme"])
        self.assertEqual(order["items"], ["croque-monsieur", "cafe-creme"])
        self.assertEqual(order["total"], 17.0)

    def test_unknown_table_is_rejected(self):
        with self.assertRaisesRegex(orders.OrderError, "no table 13"):
            orders.create_order(13, ["espresso"])

    def test_unknown_item_is_rejected(self):
        with self.assertRaisesRegex(orders.OrderError, "not on the menu: pizza"):
            orders.create_order(2, ["pizza"])

    def test_empty_order_is_rejected(self):
        with self.assertRaises(orders.OrderError):
            orders.create_order(2, [])

    def test_ticket_groups_repeated_items(self):
        order = {"id": 42, "table": 7, "items": ["espresso", "moules", "espresso"]}
        self.assertEqual(orders.ticket(order, "19:05"),
                         "#0042  table 7   19:05\n  2 × Espresso\n  1 × Moules marinières\n")


if __name__ == "__main__":
    unittest.main()
