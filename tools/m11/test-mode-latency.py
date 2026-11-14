#!/usr/bin/env python3
"""Parser/correlation checks with tiny xctrace-shaped fixtures; no app launch."""
import importlib.util
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("mode_latency", Path(__file__).with_name("mode-latency.py"))
latency = importlib.util.module_from_spec(spec)
spec.loader.exec_module(latency)


class ReaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def table(self, name, columns, rows):
        p = self.root / (name + ".xml")
        p.write_text('<trace-query-result><node><schema name="' + name + '">' + ''.join(
            '<col><mnemonic>' + x + '</mnemonic></col>' for x in columns) + '</schema>' +
            ''.join('<row>' + x + '</row>' for x in rows) + '</node></trace-query-result>')
        return str(p)

    def payload(self, phase, edge, media):
        return f"m11 id=1 phase={phase} edge={edge} media={media} event=-1 timestamp=-1 target=-1 detail=test"

    def test_interval_and_clock_bridge(self):
        path = self.table("os-signpost", ["start", "duration", "message", "end-message"], [
            '<start-time>1000000000</start-time><duration>20000000</duration><string>' +
            self.payload("SetMode", "begin", 101) + '</string><string>' + self.payload("SetMode", "end", 101.02) + '</string>'
        ])
        events, anchors = latency.signposts(path)
        self.assertEqual(len(events), 2)
        self.assertTrue(all(abs(x + 100) < 1e-10 for x in anchors))
        self.assertAlmostEqual(latency.timeline(events)[0]["end"] - 101, 0.02)

    def test_backdated_event_anchors_to_emission(self):
        payload = self.payload("Input", "event", 100).replace("event=-1", "emit=101 event=-1")
        path = self.table("os-signpost", ["start", "message"], [
            '<start-time>1000000000</start-time><string>' + payload + '</string>'
        ])
        events, anchors = latency.signposts(path)
        self.assertEqual(events[0]["time"], 100)
        self.assertEqual(anchors, [-100])

    def test_interval_duration_fallback(self):
        path = self.table("os-signpost", ["start", "duration", "message"], [
            '<start-time>1000000000</start-time><duration>20000000</duration><string>' + self.payload("SetMode", "begin", 101) + '</string>'
        ])
        events, _ = latency.signposts(path)
        self.assertEqual(events[-1]["source"], "signpost-duration")
        self.assertAlmostEqual(events[-1]["time"], 101.02)

    def test_refs_pid_and_no_cross_process_join(self):
        path = self.table("hitches-updates", ["start", "duration", "process", "display"], [
            '<start-time>1200000000</start-time><duration id="d">10000000</duration><process id="p" fmt="OrganicShell (42)"/><display-name id="v" fmt="Display 1"/>',
            '<start-time>1300000000</start-time><duration ref="d"/><process ref="p"/><display-name ref="v"/>',
            '<start-time>1400000000</start-time><duration ref="d"/><process fmt="OrganicShell (43)"/><display-name ref="v"/>'
        ])
        rows = latency.updates(path, 42)
        self.assertEqual(len(rows), 2)
        self.assertAlmostEqual(rows[1]["end"], 1.31)
        with self.assertRaises(ValueError):
            latency.updates(path, None)

    def test_multiple_displays_need_selection(self):
        path = self.table("display-vsyncs-interval", ["timestamp", "display-name"], [
            '<start-time>1000000000</start-time><display-name fmt="Built-In Display 1"/>',
            '<start-time>1010000000</start-time><display-name fmt="external-0"/>'
        ])
        with self.assertRaises(ValueError):
            latency.displays(path, None)
        self.assertEqual(len(latency.displays(path, "built-in")), 1)

    def test_receipt_is_primary_and_unhandled_input_not_a_switch(self):
        import json
        receipt = self.root / "receipt.json"
        receipt.write_text(json.dumps({"modeSwitchLog": {"events": [
            dict(id=1, phase="Input", edge="event", time=100, detail="keyboard"),
            dict(id=2, phase="Input", edge="event", time=101, detail="menu"),
            dict(id=2, phase="SetMode", edge="begin", time=101.01, detail="to=normie"),
            dict(id=2, phase="SetMode", edge="end", time=101.2),
            dict(id=2, phase="FirstDisplayLinkAfterCommitProxy", edge="event", time=101.21, targetTimestamp=101.23)
        ]}}))
        args = SimpleNamespace(receipt=str(receipt), signposts=None, trace_offset=None, updates=None,
                               display_table=None, motion_time=[], pid=None, display=None)
        report = latency.analyze(args)
        self.assertEqual(len(report["switches"]), 1)
        self.assertAlmostEqual(report["switches"][0]["predictedInputToDisplayMs"], 230)
        self.assertIsNone(report["switches"][0]["observedInputToMotionMs"])
        self.assertIn("unmeasured", latency.render(report))
        args.updates = "unused.xml"
        with self.assertRaisesRegex(ValueError, "unaligned"):
            latency.analyze(args)

    def test_main_thread_turn_includes_completion_and_never_proves_motion(self):
        import json
        receipt = self.root / "receipt.json"
        receipt.write_text(json.dumps({"modeSwitchLog":{"events":[
            dict(id=1,phase="Input",edge="event",time=100),
            dict(id=1,phase="SetMode",edge="begin",time=100),
            dict(id=1,phase="SetMode",edge="end",time=100.002),
            dict(id=1,phase="ModeAdmissionTurn",edge="begin",time=100.1),
            dict(id=1,phase="ModeAdmissionTurn",edge="end",time=100.148)
        ]}}))
        args=SimpleNamespace(receipt=str(receipt),signposts=None,trace_offset=None,updates=None,display_table=None,motion_time=[],pid=None,display=None)
        report=latency.analyze(args)
        self.assertAlmostEqual(report["switches"][0]["maxMeasuredMainThreadBlockMs"],48)
        self.assertIsNone(report["switches"][0]["observedInputToMotionMs"])

    def test_preparation_is_reported_without_claiming_a_switch(self):
        import json
        receipt = self.root / "receipt.json"
        receipt.write_text(json.dumps({"modeSwitchLog": {"events": [
            dict(id=3, phase="ModePrewarm", edge="begin", time=101, detail="idle"),
            dict(id=3, phase="PrewarmSidebarSnapshot", edge="begin", time=101.01),
            dict(id=3, phase="PrewarmSidebarSnapshot", edge="end", time=101.03),
            dict(id=3, phase="ModePrewarm", edge="end", time=101.04)
        ]}}))
        args = SimpleNamespace(receipt=str(receipt), signposts=None, trace_offset=None, updates=None,
                               display_table=None, motion_time=[], pid=None, display=None)
        report = latency.analyze(args)
        self.assertEqual(report["switches"], [])
        self.assertEqual(len(report["preparations"]), 1)
        self.assertIn("PrewarmSidebarSnapshot", latency.render(report))
        self.assertNotIn("input →", latency.render(report))

    def test_complete_join_and_observed_motion(self):
        import json
        receipt = self.root / "receipt.json"
        receipt.write_text(json.dumps({"pid": 42, "modeSwitchLog": {"events": [
            dict(id=1, phase="Input", edge="event", time=101, detail="keyboard"),
            dict(id=1, phase="SetMode", edge="begin", time=101.001, detail="to=normie"),
            dict(id=1, phase="FirstAnimation", edge="event", time=101.18),
            dict(id=1, phase="FirstDisplayLinkAfterCommitProxy", edge="event", time=101.20, targetTimestamp=101.216)
        ]}}))
        signs = self.table("os-signpost", ["start", "message"], [
            '<start-time>1000000000</start-time><string>' + self.payload("Input", "event", 101) + '</string>'])
        updates = self.table("hitches-updates", ["start", "duration", "process", "display"], [
            '<start-time>1170000000</start-time><duration>30000000</duration><process fmt="OrganicShell (42)"/><display-name fmt="Display 1"/>'])
        display = self.table("display-vsyncs-interval", ["timestamp", "display-name"], [
            '<start-time>1220000000</start-time><display-name fmt="Built-In"/>'])
        args = SimpleNamespace(receipt=str(receipt), signposts=signs, trace_offset=None, updates=updates,
                               display_table=display, motion_time=["1=1.225"], pid=None, display="Built-In")
        report = latency.analyze(args)
        switch = report["switches"][0]
        self.assertAlmostEqual(report["traceOffsetSeconds"], -100)
        self.assertAlmostEqual(switch["predictedInputToDisplayMs"], 216)
        self.assertAlmostEqual(switch["observedInputToMotionMs"], 225)
        self.assertEqual(len([s for s in switch["timeline"] if s["phase"] == "Input"]), 1)
        self.assertTrue(any(s["phase"] == "hitches.update [candidate]" for s in switch["timeline"]))
        self.assertTrue(any(s["phase"] == "VSync [opportunity]" for s in switch["timeline"]))

    def test_open_and_repeated_nested_phases(self):
        events = [dict(phase="Snapshot", edge=edge, time=t) for edge, t in [
            ("begin", 1), ("begin", 2), ("end", 3), ("end", 4), ("begin", 5)]]
        spans = latency.timeline(events)
        self.assertEqual([(s["start"], s["end"]) for s in spans], [(1, 4), (2, 3), (5, None)])


if __name__ == "__main__":
    unittest.main()
