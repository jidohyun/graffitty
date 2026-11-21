import unittest

from orders import OrderError
from reservations import Book


class ReservationTests(unittest.TestCase):
    def test_first_free_table_is_assigned(self):
        book = Book()
        self.assertEqual(book.reserve("Martin", 4, "19:30")["table"], 1)
        self.assertEqual(book.reserve("Okafor", 2, "19:30")["table"], 2)

    def test_same_table_is_free_at_another_slot(self):
        book = Book()
        book.reserve("Martin", 4, "19:30")
        self.assertEqual(book.reserve("Lee", 3, "20:00")["table"], 1)

    def test_party_size_is_limited(self):
        with self.assertRaisesRegex(OrderError, "party size must be 1-8"):
            Book().reserve("Big group", 12, "19:00")

    def test_party_size_must_be_a_number(self):
        with self.assertRaises(OrderError):
            Book().reserve("Martin", "4", "19:00")

    def test_unknown_slot_is_rejected(self):
        with self.assertRaisesRegex(OrderError, "no seating at 23:00"):
            Book().reserve("Late", 2, "23:00")

    def test_full_slot_is_rejected(self):
        book = Book()
        for table in range(12):
            book.reserve(f"Guest {table}", 2, "20:00")
        with self.assertRaisesRegex(OrderError, "fully booked at 20:00"):
            book.reserve("One more", 2, "20:00")


if __name__ == "__main__":
    unittest.main()
