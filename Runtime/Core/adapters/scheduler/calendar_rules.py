"""Calendar recurrence via python-dateutil; no second scheduling engine."""
import datetime as dt
import importlib
import importlib.util
import pathlib
import sys


def dateutil_modules():
    """Reuse the official pure-Python packages if the Core interpreter lacks them.

    Load only dateutil and its six.py dependency, without changing sys.path or
    installing anything into the system interpreter.
    """
    if importlib.util.find_spec('dateutil') is None:
        python = pathlib.Path.home() / '.cache/codex-runtimes/codex-primary-runtime/dependencies/python'
        candidates = [python / 'Lib/site-packages', *sorted(python.glob('lib/python*/site-packages'))]
        site = next((p for p in candidates if (p / 'dateutil/__init__.py').is_file()), None)
        if site is None:
            raise ModuleNotFoundError('Calendar jobs require python-dateutil; use the existing official Python bundle or a Core-local venv, not a system Python install.')
        if importlib.util.find_spec('six') is None:
            spec = importlib.util.spec_from_file_location('six', site / 'six.py')
            module = importlib.util.module_from_spec(spec)
            sys.modules['six'] = module
            spec.loader.exec_module(module)
        spec = importlib.util.spec_from_file_location('dateutil', site / 'dateutil/__init__.py', submodule_search_locations=[str(site / 'dateutil')])
        module = importlib.util.module_from_spec(spec)
        sys.modules['dateutil'] = module
        spec.loader.exec_module(module)
    return importlib.import_module('dateutil.rrule'), importlib.import_module('dateutil.tz')


def calendar_rule(job):
    recurrence, zones = dateutil_modules()
    text, raw_start = job.get('rrule'), job.get('dtstart')
    if not isinstance(text, str) or not text.strip() or '\n' in text or '\r' in text:
        raise ValueError('rrule must be one RRULE line; provide dtstart separately')
    if not isinstance(raw_start, str):
        raise ValueError('Calendar jobs require an ISO dtstart string')
    if job.get('everySeconds') is not None:
        raise ValueError('Use either rrule/dtstart or everySeconds, not both')
    start = dt.datetime.fromisoformat(raw_start.replace('Z', '+00:00'))
    name = job.get('timezone')
    if name is not None:
        if not isinstance(name, str) or not name:
            raise ValueError('timezone must be an IANA timezone name')
        zone = zones.gettz(name)
        if zone is None:
            raise ValueError('Unknown timezone: ' + name)
        start = start.replace(tzinfo=zone) if start.tzinfo is None else start.astimezone(zone)
    if start.tzinfo is None or start.utcoffset() is None:
        raise ValueError('dtstart needs an explicit offset or a timezone field')
    if not zones.datetime_exists(start):
        raise ValueError('dtstart is a nonexistent local time during a timezone transition')
    return recurrence.rrulestr(text.strip(), dtstart=start), zones


def next_calendar_run(job, now, inclusive=False):
    """Return one next UTC epoch, skipping old and nonexistent local candidates.

    Ambiguous local recurrence times use dateutil's first occurrence. COUNT keeps
    dateutil's nominal-candidate semantics, including its DST-gap limitation.
    """
    rule, zones = calendar_rule(job)
    anchor = dt.datetime.fromtimestamp(now, dt.timezone.utc)
    candidate = rule.after(anchor, inc=inclusive)
    while candidate is not None:
        stamp = candidate.timestamp()
        if zones.datetime_exists(candidate) and (stamp > now or inclusive and stamp == now):
            return stamp
        candidate = rule.after(candidate, inc=False)
    return None
