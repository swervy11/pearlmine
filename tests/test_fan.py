#!/usr/bin/env python3
"""Checks the fan-curve maths. Does not touch any GPU."""
import importlib.util
import os
import unittest

spec = importlib.util.spec_from_file_location(
    "fan", os.path.join(os.path.dirname(__file__), "..", "lib", "fan.py"))
fan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fan)

CURVE = fan.parse_curve("50:45 60:55 65:65 70:75 75:85 80:100")


class Curve(unittest.TestCase):
    def test_parse_sorts_and_accepts_commas(self):
        self.assertEqual(fan.parse_curve("80:100, 50:40"), [(50, 40), (80, 100)])

    def test_parse_rejects_bad_input(self):
        for bad in ("", "60:50", "60:50 60:70", "60:150 70:80", "200:50 70:80", "a:b c:d"):
            with self.assertRaises(ValueError, msg=bad):
                fan.parse_curve(bad)

    def test_flat_below_first_and_above_last(self):
        self.assertEqual(fan.target(CURVE, 20), 45)
        self.assertEqual(fan.target(CURVE, 50), 45)
        self.assertEqual(fan.target(CURVE, 95), 100)

    def test_exact_points_and_midpoints(self):
        self.assertEqual(fan.target(CURVE, 65), 65)
        self.assertEqual(fan.target(CURVE, 55), 50)
        self.assertEqual(fan.target(CURVE, 78), 94)

    def test_never_decreases_as_it_gets_hotter(self):
        speeds = [fan.target(CURVE, t) for t in range(0, 111)]
        self.assertEqual(speeds, sorted(speeds))

    def test_clamp(self):
        self.assertEqual(fan.clamp(10, 30), 30)       # config floor
        self.assertEqual(fan.clamp(10, 0), fan.HARD_FLOOR)   # floor of 0 is not honoured
        self.assertEqual(fan.clamp(140, 30), 100)
        self.assertEqual(fan.clamp(70, 30), 70)


if __name__ == "__main__":
    unittest.main()
