#!/usr/bin/env python3
"""Join M11 signposts/receipts to xctrace updates and display tables (stdlib only).

All trace times are seconds relative to trace start; receipt times are CACurrentMediaTime.
An os-signpost payload's emit field supplies the clock bridge (media is the semantic event time). Never infer it from launch time.
Display-link targetTimestamp and VSync are estimates/opportunities, not proof of changed pixels.
"""
import argparse
import json
import re
import statistics
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

PAYLOAD = re.compile(
    r"m11 id=(\d+) phase=(\S+) edge=(begin|end|event) media=([-+\d.eE]+) "
    r"(?:emit=([-+\d.eE]+) )?event=([-+\d.eE]+) timestamp=([-+\d.eE]+) target=([-+\d.eE]+) detail=([^\r\n]*)")


def table_rows(path):
    """Resolve xctrace's id/ref cells, using schema mnemonics rather than positional assumptions."""
    root = ET.parse(path).getroot()
    ids = {e.get("id"): e for e in root.iter() if e.get("id")}

    def resolve(e):
        seen = set()
        while e is not None and e.get("ref"):
            key = e.get("ref")
            if key in seen or key not in ids:
                raise ValueError(f"{path}: unresolved/cyclic xctrace reference {key}")
            seen.add(key)
            e = ids[key]
        return e

    def value(e):
        e = resolve(e)
        if e is None:
            return ""
        return e.get("fmt") or e.text or "".join(e.itertext())

    result = []
    for node in root.iter("node"):
        schema = node.find("schema")
        if schema is None:
            continue
        columns = [c.findtext("mnemonic") for c in schema.findall("col")]
        for row in node.findall("row"):
            cells = {name: resolve(e) for name, e in zip(columns, row)}
            result.append((cells, value, resolve))
    return result


def numeric(cell):
    return float(cell.text) / 1e9 if cell is not None and cell.text else None


def signposts(path, pid=None):
    events, anchors, processes = [], [], set()
    for cells, value, resolve in table_rows(path):
        process = value(cells.get("process"))
        if pid is not None and process and not re.search(rf"\({pid}\)$", process):
            continue
        start = next((numeric(e) for e in cells.values() if e.tag == "start-time"), None)
        duration = next((numeric(e) for e in cells.values() if e.tag == "duration"), None)
        payloads = set()
        for cell in cells.values():
            for element in cell.iter():
                e = resolve(element)
                for text in (e.text or "", e.get("fmt", "")):
                    payloads.update(m.group(0) for m in PAYLOAD.finditer(text))
        if payloads and process:
            processes.add(process)
        row_events = []
        for payload in sorted(payloads):
            match = PAYLOAD.fullmatch(payload)
            ident, phase, edge, media, emitted, event, timestamp, target, detail = match.groups()
            item = dict(id=int(ident), phase=phase, edge=edge, time=float(media), detail=detail, emitTime=float(emitted or media), source="signpost")
            for key, number in [("eventTimestamp", event), ("timestamp", timestamp), ("targetTimestamp", target)]:
                if float(number) >= 0:
                    item[key] = float(number)
            if start is not None:
                # An interval table can put both messages in ONE row. Its end message anchors to start+duration.
                trace_time = start + (duration or 0) if edge == "end" else start
                anchors.append(trace_time - item["emitTime"])
                item["traceTime"] = trace_time
            row_events.append(item)
        events.extend(row_events)
        # Some exports keep only an interval's begin message. Preserve that measured duration with explicit provenance.
        for begin in row_events:
            if begin["edge"] == "begin" and duration is not None and duration > 0 and not any(
                    e["id"] == begin["id"] and e["phase"] == begin["phase"] and e["edge"] == "end" for e in row_events):
                events.append(dict(begin, edge="end", time=begin["emitTime"] + duration,
                                   source="signpost-duration", detail="end inferred from os-signpost interval duration"))
    if len(processes) > 1:
        raise ValueError("multiple processes in M11 signposts: supply --pid or a matching receipt")
    return events, anchors


def updates(path, pid):
    result = []
    for cells, value, _ in table_rows(path):
        process = value(cells.get("process"))
        if pid is not None and not re.search(rf"\({pid}\)$", process):
            continue
        if pid is None and "OrganicShell" not in process:
            continue
        start = numeric(cells.get("start"))
        duration = numeric(cells.get("duration"))
        if start is not None and duration is not None:
            result.append(dict(start=start, end=start + duration, process=process,
                               display=value(cells.get("display")), swap=value(cells.get("swap-id"))))
    processes = {r["process"] for r in result}
    if len(processes) > 1:
        raise ValueError("multiple OrganicShell processes in updates: supply --pid or a matching receipt")
    return sorted(result, key=lambda r: r["start"])


def displays(path, display):
    result = []
    for cells, value, _ in table_rows(path):
        name = value(cells.get("display-name")) or value(cells.get("display"))
        if display and display.lower() not in name.lower():
            continue
        start = numeric(cells.get("timestamp"))
        if start is None:
            start = numeric(cells.get("start"))
        if start is not None:
            result.append(dict(time=start, display=name))
    names = {r["display"] for r in result}
    if len(names) > 1:
        raise ValueError("multiple displays in display table: select one explicitly with --display (e.g. 'Built-In')")
    return sorted(result, key=lambda r: r["time"])


def merge_events(receipt, exported):
    result = [dict(e, source="receipt") for e in receipt]
    for event in exported:
        existing = next((r for r in result if r["id"] == event["id"] and r["phase"] == event["phase"]
                         and r["edge"] == event["edge"] and abs(r["time"] - event["time"]) < 2e-6), None)
        if existing is None:
            result.append(event)
        elif "traceTime" in event:
            existing["traceTime"] = event["traceTime"]
    return sorted(result, key=lambda e: e["time"])


def timeline(events):
    spans, stacks = [], defaultdict(list)
    for event in events:
        if event["edge"] == "begin":
            stacks[event["phase"]].append(event)
        elif event["edge"] == "end" and stacks[event["phase"]]:
            begin = stacks[event["phase"]].pop()
            spans.append(dict(phase=event["phase"], start=begin["time"], end=event["time"],
                              detail=begin.get("detail", ""), source=begin.get("source", "")))
        else:
            detail = event.get("detail", "")
            if "DisplayLink" in event["phase"]:
                detail += f" timestamp={event.get('timestamp', '?')} targetTimestamp={event.get('targetTimestamp', '?')}"
            spans.append(dict(phase=event["phase"] + (" [unpaired end]" if event["edge"] == "end" else ""),
                              start=event["time"], end=None, detail=detail, source=event.get("source", "")))
    for stack in stacks.values():
        for event in stack:
            spans.append(dict(phase=event["phase"] + " [open]", start=event["time"], end=None,
                              detail=event.get("detail", ""), source=event.get("source", "")))
    return sorted(spans, key=lambda s: s["start"])


def analyze(args):
    receipt = json.loads(Path(args.receipt).read_text()) if args.receipt else {}
    log = receipt.get("modeSwitchLog", {})
    if isinstance(log, list):
        log = {"events": log}
    exported, anchors = signposts(args.signposts, args.pid or receipt.get("pid")) if args.signposts else ([], [])
    events = merge_events(log.get("events", []), exported)
    if not events:
        raise ValueError("no M11 events; use an instrumented receipt or export the os-signpost table with messages")
    offset = statistics.median(anchors) if anchors else args.trace_offset
    if (args.updates or args.display_table or args.motion_time) and offset is None:
        raise ValueError("trace clock unaligned: supply --signposts or explicit --trace-offset (trace seconds minus media seconds)")
    actual_updates = updates(args.updates, args.pid or receipt.get("pid")) if args.updates else []
    vsyncs = displays(args.display_table, args.display) if args.display_table else []
    motion = dict((int(x.split("=", 1)[0]), float(x.split("=", 1)[1])) for x in args.motion_time)
    groups = defaultdict(list)
    for event in events:
        groups[event["id"]].append(event)
    results = []
    preparations = []
    inputs = sorted((e["time"], e["id"]) for e in events if e["phase"] == "Input")
    for ident, group in sorted(groups.items()):
        switch = next((e for e in group if e["phase"] == "SetMode" and e["edge"] == "begin"), None)
        if switch is None:
            warm = next((e for e in group if e["phase"] == "ModePrewarm" and e["edge"] == "begin"), None)
            if warm:
                preparations.append(dict(id=ident, start=warm["time"], detail=warm.get("detail", ""), timeline=timeline(group)))
            continue  # An unhandled shortcut is an input, never a successful mode switch.
        origin = next((e for e in group if e["phase"] == "Input"), switch)
        spans = timeline(group)
        callback = next((e for e in group if e["phase"] == "FirstDisplayLinkAfterCommitProxy"), None)
        first_link = next((e for e in group if e["phase"] == "FirstDisplayLink"), None)
        if callback and "targetTimestamp" in callback:
            spans.append(dict(phase="DisplayLink.target [estimate]", start=callback["targetTimestamp"], end=None,
                              detail="first callback after commit proxy; predicted display time", source="display-link"))
        first_animation = next((e["time"] for e in group if e["phase"] == "FirstAnimation"), None)
        next_input = next((t for t, i in inputs if t > origin["time"] and i != ident), origin["time"] + 5)
        candidate = None
        if offset is not None and first_animation is not None:
            candidate = next((u for u in actual_updates if u["end"] >= first_animation + offset
                              and u["start"] < next_input + offset), None)
        if candidate:
            spans.append(dict(phase="hitches.update [candidate]", start=candidate["start"] - offset,
                              end=candidate["end"] - offset, source="hitches-updates", detail=f"{candidate['process']} {candidate['display']} swap={candidate['swap']}"))
        # Never substitute an arbitrary VSync for a surface presentation or for first pixel motion.
        lower = max(candidate["end"] if candidate else float("-inf"),
                    callback["targetTimestamp"] + offset if callback and offset is not None else float("-inf"))
        opportunity = next((v for v in vsyncs if lower != float("-inf") and lower <= v["time"] < next_input + offset), None)
        if opportunity:
            spans.append(dict(phase="VSync [opportunity]", start=opportunity["time"] - offset, end=None,
                              source="display", detail=opportunity["display"] + "; not evidence of changed pixels"))
        if ident in motion:
            spans.append(dict(phase="FirstMotion [observed]", start=motion[ident] - offset, end=None,
                              source="manual", detail="explicit --motion-time in trace clock (align video first)"))
        blocking = [s for s in spans if s["phase"] in {"SetMode", "ModeAdmissionTurn", "ModeNativeAdmission", "ModeFlightTick", "ModeFlightFirstTick"}
                    and s["end"] is not None and s["start"] >= origin["time"]]
        worst = max(blocking, key=lambda s: s["end"]-s["start"], default=None)
        results.append(dict(maxMeasuredMainThreadBlockMs=(worst["end"]-worst["start"])*1000 if worst else None,
                            maxMeasuredMainThreadBlockPhase=worst["phase"] if worst else None,
                            id=ident, switch=switch.get("detail", ""), input=origin,
                            timeline=sorted(spans, key=lambda s: s["start"]), firstDisplayLink=first_link,
                            predictedInputToDisplayMs=(callback["targetTimestamp"] - origin["time"]) * 1000 if callback and "targetTimestamp" in callback else None,
                            observedInputToMotionMs=(motion[ident] - offset - origin["time"]) * 1000 if ident in motion else None))
    return dict(synthetic=receipt.get("synthetic", False), traceOffsetSeconds=offset,
                alignmentMaxResidualMs=max((abs(a - offset) * 1000 for a in anchors), default=None),
                droppedEvents=log.get("dropped", 0), preparations=preparations, switches=results)


def render(report):
    out = ["M11 mode latency" + (" — SYNTHETIC OFFSCREEN FIXTURE; NOT A LIVE MEASUREMENT" if report["synthetic"] else "")]
    offset = report["traceOffsetSeconds"]
    out.append(f"Clock bridge (trace − CACurrentMediaTime): {offset:.9f} s" if offset is not None else "Receipt clock only; no trace alignment.")
    if report["alignmentMaxResidualMs"] is not None:
        out.append(f"Clock bridge maximum residual: {report['alignmentMaxResidualMs']:.3f} ms")
    if report["droppedEvents"]:
        out.append(f"WARNING: receipt dropped {report['droppedEvents']} events.")
    for preparation in report.get("preparations", []):
        origin = preparation["start"]
        out.extend(["", f"Preparation {preparation['id']}: {preparation['detail']} (outside SetMode)", "",
                    "| Phase | Start ms | End ms | Duration ms |", "| --- | ---: | ---: | ---: |"])
        for span in preparation["timeline"]:
            start = (span["start"] - origin) * 1000
            end = f"{(span['end']-origin)*1000:.3f}" if span["end"] is not None else "—"
            duration = f"{(span['end']-span['start'])*1000:.3f}" if span["end"] is not None else "—"
            out.append(f"| {span['phase']} | {start:.3f} | {end} | {duration} |")
    for switch in report["switches"]:
        origin = switch["input"]["time"]
        out.extend(["", f"Switch {switch['id']}: {switch['switch']}", f"Input: {switch['input'].get('detail', '')}", "",
                    "| Phase | Input → start ms | Input → end ms | Duration ms | Detail |",
                    "| --- | ---: | ---: | ---: | --- |"])
        event_time = switch["input"].get("eventTimestamp")
        if event_time is not None:
            out.append(f"| NSEvent.timestamp | {(event_time-origin)*1000:.3f} | — | — | uptime {event_time:.9f} s |")
        for span in switch["timeline"]:
            start = (span["start"] - origin) * 1000
            end = f"{(span['end']-origin)*1000:.3f}" if span["end"] is not None else "—"
            duration = f"{(span['end']-span['start'])*1000:.3f}" if span["end"] is not None else "—"
            detail = span["detail"].replace("|", "\\|")
            out.append(f"| {span['phase']} | {start:.3f} | {end} | {duration} | {detail} |")
        block = switch.get("maxMeasuredMainThreadBlockMs")
        out.append(f"Maximum instrumented main-thread block after input: {block:.3f} ms ({switch['maxMeasuredMainThreadBlockPhase']}); excludes uninstrumented app work." if block is not None else "Maximum main-thread block: unavailable.")
        estimate, observed = switch["predictedInputToDisplayMs"], switch["observedInputToMotionMs"]
        out.extend(["", f"Input → first motion: {observed:.3f} ms (observed)." if observed is not None else "Input → first motion: unmeasured (no aligned changed-pixel evidence).",
                    f"Input → predicted display after commit proxy: {estimate:.3f} ms (estimate)." if estimate is not None else "Input → predicted display after commit proxy: unavailable."])
    out.extend(["", "Commit observer brackets, display-link predictions, update intervals and VSync are distinct evidence. Nested stage durations are inclusive; do not sum them."])
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", help="app/receipt.json; sufficient for a receipt-only timeline")
    parser.add_argument("--signposts", help="xctrace os-signpost XML, including public event messages")
    parser.add_argument("--updates", help="xctrace hitches-updates XML")
    parser.add_argument("--display-table", help="xctrace display-vsyncs-interval XML")
    parser.add_argument("--display", help="case-insensitive display name substring; required when the table has multiple displays")
    parser.add_argument("--pid", type=int, help="override receipt PID when filtering updates")
    parser.add_argument("--trace-offset", type=float, help="explicit trace seconds minus CACurrentMediaTime seconds")
    parser.add_argument("--motion-time", action="append", default=[], metavar="ID=TRACE_SECONDS", help="optional first changed-pixel time from aligned video; repeat per switch")
    parser.add_argument("--json", dest="json_output", help="also save the joined, inspectable result as JSON")
    args = parser.parse_args()
    try:
        report = analyze(args)
        if not report["switches"] and not report["preparations"]:
            raise ValueError("no SetMode or ModePrewarm begin events; input may have been unhandled")
        if args.json_output:
            Path(args.json_output).write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
        print(render(report))
    except (ValueError, OSError, ET.ParseError, KeyError) as error:
        print(f"mode-latency: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
