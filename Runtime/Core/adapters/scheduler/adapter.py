"""Persistent scheduling and in-app notifications on the existing Core RPC."""
import asyncio
import datetime as dt
import json
import pathlib
import re
import secrets
import time

if __package__:
    from .calendar_rules import next_calendar_run
else:
    from calendar_rules import next_calendar_run


class Scheduler:
    def __init__(self, core):
        self.core = core
        self.path = core.data / 'scheduler.json'
        self.state = json.loads(self.path.read_text()) if self.path.exists() else {'jobs': {}, 'runs': [], 'notifications': []}
        self.task = None
        changed = False
        now = time.time()
        for run in self.state['runs']:
            if run['status'] == 'submitting':
                run.update(status='submissionUnknown', recoveryReason='Core stopped before the turn/start acknowledgement was stored')
                changed = True
            elif run['status'] == 'preparingThread':
                # turn/start is reached only after submitting has been persisted.
                run.update(status='notSubmitted', completedAt=now, recoveryReason='Core stopped before turn dispatch')
                changed = True
        for job in self.state['jobs'].values():
            if job.get('rrule') and job.get('enabled') and (job.get('nextRun') is None or job['nextRun'] < now):
                self.advance_calendar(job, now, inclusive=True)
                changed = True
        if changed:
            self.persist()

    def advance_calendar(self, job, now, inclusive=False):
        exhausted = job.get('maxRuns') and job.get('runCount', 0) >= job['maxRuns']
        job['nextRun'] = None if exhausted else next_calendar_run(job, now, inclusive=inclusive)
        if job['nextRun'] is None:
            job['enabled'] = False

    def persist(self):
        temporary = self.path.with_suffix('.tmp')
        temporary.write_text(json.dumps(self.state, ensure_ascii=False), encoding='utf-8')
        temporary.replace(self.path)

    def notify(self, title, message, **context):
        notification = {'id': secrets.token_hex(8), 'time': time.time(), 'title': title, 'message': message, 'read': False, **context}
        self.state['notifications'].append(notification)
        self.persist()
        self.core.emit('core/notification', notification)
        return notification

    async def jobs(self, body, query):
        return list(self.state['jobs'].values())

    async def upsert(self, body, query):
        identifier = body.get('id') or secrets.token_hex(8)
        previous = self.state['jobs'].get(identifier, {})
        job = {**previous, **body, 'id': identifier}
        job.setdefault('name', identifier)
        job.setdefault('enabled', True)
        job.setdefault('runCount', 0)
        schedule_changed = not previous or any(key in body for key in ('at', 'nextRun', 'everySeconds', 'rrule', 'dtstart', 'timezone'))
        resuming = previous and not previous.get('enabled') and body.get('enabled') is True
        if job.get('rrule') and (schedule_changed or resuming):
            self.advance_calendar(job, time.time(), inclusive=True)
        elif not job.get('rrule') and schedule_changed:
            if 'at' in body or not previous and 'at' in job:
                value = job['at']
                job['nextRun'] = dt.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp() if isinstance(value, str) else float(value)
            elif 'nextRun' in body:
                job['nextRun'] = None if body['nextRun'] is None else float(body['nextRun'])
            elif previous and job.get('everySeconds') and 'everySeconds' in body:
                job['nextRun'] = time.time() + float(job['everySeconds'])
            elif not previous:
                job['nextRun'] = time.time()
        elif resuming and job.get('everySeconds'):
            job['nextRun'] = time.time() + float(job['everySeconds'])
        if job.get('maxRuns') and job['runCount'] >= job['maxRuns']:
            job['enabled'] = False
        self.state['jobs'][identifier] = job
        self.persist()
        self.core.emit('scheduler/jobUpdated', job)
        return job

    async def pause(self, body, query):
        job = self.state['jobs'][body['id']]
        job['enabled'] = not body.get('paused', True)
        if job.get('maxRuns') and job.get('runCount', 0) >= job['maxRuns']:
            job['enabled'] = False
        if job['enabled']:
            if job.get('rrule'):
                self.advance_calendar(job, time.time(), inclusive=True)
            elif job.get('everySeconds'):
                job['nextRun'] = time.time() + float(job['everySeconds'])
        self.persist()
        self.core.emit('scheduler/jobUpdated', job)
        return job

    async def runs(self, body, query):
        job_id = query.get('jobId', [None])[0]
        return [r for r in self.state['runs'] if job_id is None or r['jobId'] == job_id]

    async def notifications(self, body, query):
        return self.state['notifications']

    async def acknowledge(self, body, query):
        notification = next(n for n in self.state['notifications'] if n['id'] == body['id'])
        notification['read'] = True
        self.persist()
        return notification

    async def official_records(self, body, query):
        # Compatibility inventory only. Reading existing jobs never enables them.
        result = []
        folder = pathlib.Path.home() / '.codex' / 'automations'
        for config in sorted(folder.glob('*/automation.toml')):
            source = config.read_text(encoding='utf-8')
            fields = {}
            for key in ('id', 'name', 'status', 'kind', 'rrule', 'dtstart', 'timezone', 'notification_policy'):
                match = re.search(r'^' + key + r'\s*=\s*"([^"\n]*)"', source, re.M)
                if match:
                    fields[key] = match.group(1)
            result.append({'id': config.parent.name, 'sourcePath': str(config), 'configuration': fields, 'enabledInOrganic': False})
        return result

    async def launch(self, job):
        run = {'id': secrets.token_hex(8), 'jobId': job['id'], 'startedAt': time.time(), 'status': 'preparingThread'}
        # Persist a correlation marker before dispatch. It is ordinary input text,
        # never a fabricated turn ID or an authorization/metadata claim.
        run['correlationMarker'] = '[Organic scheduler run: ' + run['id'] + ']'
        self.state['runs'].append(run)
        job['runCount'] += 1
        job['lastRunId'] = run['id']
        interval = job.get('everySeconds')
        if job.get('rrule'):
            self.advance_calendar(job, time.time())
        elif interval and (not job.get('maxRuns') or job['runCount'] < job['maxRuns']):
            job['nextRun'] = time.time() + float(interval)
        else:
            job['enabled'] = False
        self.persist()
        try:
            tid = job.get('threadId')
            if not tid:
                response = await self.core.rpc('thread/start', job.get('threadParams', {}))
                tid = response['thread']['id']
                job['threadId'] = tid
            run['threadId'] = tid
            run['status'] = 'submitting'
            self.persist()
            response = await self.core.rpc('turn/start', {'threadId': tid, 'input': [{'type': 'text', 'text': job['prompt'] + '\n\n' + run['correlationMarker']}]})
            run.update(turnId=response['turn']['id'], status='inProgress')
            self.persist()
            self.core.emit('scheduler/runStarted', run)
        except Exception as error:
            if run['status'] == 'submitting':
                run.update(status='submissionUnknown', error=str(error), recoveryReason='turn/start failed before its acknowledgement was stored')
                self.persist()
                self.core.emit('scheduler/runSubmissionUnknown', run)
            else:
                run.update(status='submissionFailed', error=str(error), completedAt=time.time())
                self.notify(job['name'], str(error), jobId=job['id'], runId=run['id'], status=run['status'])

    async def recover_submission(self, run):
        """Read back one known thread; recovery never calls turn/start."""
        job = self.state['jobs'][run['jobId']]
        tid = run.get('threadId') or job.get('threadId')
        matches = []
        if tid:
            if time.time() - run.get('lastRecoveryReadback', 0) < 5:
                return None
            run['lastRecoveryReadback'] = time.time()
            try:
                response = await self.core.rpc('thread/turns/list', {'threadId': tid, 'limit': 20, 'itemsView': 'full'})
            except Exception as error:
                run['recoveryError'] = str(error)
                self.persist()
                return None
            for turn in response['data']:
                if run.get('turnId'):
                    matched = turn['id'] == run['turnId']
                else:
                    marker = run.get('correlationMarker')
                    matched = bool(marker) and any(
                        item.get('type') == 'userMessage' and any(
                            part.get('type') == 'text' and marker in part.get('text', '')
                            for part in item.get('content', []))
                        for item in turn.get('items', []))
                if matched:
                    matches.append(turn)
            run['recoveryReadback'] = {'threadId': tid, 'turnsExamined': len(response['data']), 'hasOlderTurns': bool(response.get('nextCursor'))}
        if len(matches) == 1:
            turn = matches[0]
            run.update(threadId=tid, turnId=turn['id'], status='inProgress', recoveredAt=time.time())
            run.pop('recoveryError', None)
            self.persist()
            self.core.emit('scheduler/runRecovered', run)
            return turn
        run.update(status='submissionUnconfirmed', completedAt=time.time(), recoveryReason='No unique saved turn ID or run marker in the bounded readback; delivery remains unknown')
        job['enabled'] = False
        job['submissionRecoveryRunId'] = run['id']
        self.notify(job['name'], 'Submission could not be confirmed. Job paused; inspect the stored thread before resuming. No automatic retry was sent.', jobId=job['id'], runId=run['id'], threadId=tid, status=run['status'])
        self.core.emit('scheduler/runSubmissionUnconfirmed', run)
        return None

    async def reconcile(self):
        for run in self.state['runs']:
            recovered_turn = None
            if run['status'] == 'submissionUnknown':
                recovered_turn = await self.recover_submission(run)
            if run['status'] != 'inProgress':
                continue
            session = self.core.sessions.get(run['threadId'], {})
            turn = recovered_turn or session.get('lastTurn') or {}
            if turn.get('id') != run['turnId'] or turn.get('status') == 'inProgress':
                if time.time() - run.get('lastReadback', 0) < 5:
                    continue
                run['lastReadback'] = time.time()
                response = await self.core.rpc('thread/turns/list', {'threadId': run['threadId'], 'limit': 10, 'itemsView': 'summary'})
                turn = next((t for t in response['data'] if t['id'] == run['turnId']), {})
            if turn.get('status') in ('completed', 'failed', 'interrupted'):
                run.update(status=turn['status'], completedAt=time.time(), result=turn)
                job = self.state['jobs'][run['jobId']]
                self.notify(job['name'], 'Task ' + run['status'], jobId=job['id'], runId=run['id'], threadId=run['threadId'], turnId=run['turnId'], status=run['status'])
                self.core.emit('scheduler/runCompleted', run)

    async def loop(self):
        while True:
            try:
                await self.reconcile()
                for job in list(self.state['jobs'].values()):
                    busy = any(r['jobId'] == job['id'] and r['status'] in ('preparingThread', 'submitting', 'submissionUnknown', 'inProgress') for r in self.state['runs'])
                    if job.get('threadId'):
                        busy = busy or bool(self.core.sessions.get(job['threadId'], {}).get('active'))
                    now = time.time()
                    if busy and job.get('rrule') and job['enabled'] and job.get('nextRun') is not None and job['nextRun'] <= now:
                        self.advance_calendar(job, now)
                        self.persist()
                    if job['enabled'] and job.get('nextRun') is not None and job['nextRun'] <= now and not busy:
                        await self.launch(job)
            except Exception as error:
                self.core.emit('scheduler/error', {'message': str(error)})
            await asyncio.sleep(1)

    async def close(self):
        self.task.cancel()
        try:
            await self.task
        except asyncio.CancelledError:
            pass
        self.persist()

    async def tool(self, message):
        params = message['params']
        args = params['arguments']
        result = await self.upsert(args, {}) if params['tool'] == 'schedule' else await self.jobs({}, {})
        return {'success': True, 'contentItems': [{'type': 'inputText', 'text': json.dumps(result, ensure_ascii=False)}]}


async def register(core):
    service = Scheduler(core)
    specs = [
        {'type': 'function', 'name': 'list_jobs', 'description': 'List Organic scheduled jobs.', 'inputSchema': {'type': 'object', 'properties': {}}},
        {'type': 'function', 'name': 'schedule', 'description': 'Schedule a task only when the user requests scheduling. Use at for one-shot/everySeconds, or rrule plus ISO dtstart and an IANA timezone (or offset-aware dtstart) for calendar recurrence. Missed calendar occurrences are skipped.', 'inputSchema': {'type': 'object', 'properties': {'id': {'type': 'string'}, 'name': {'type': 'string'}, 'prompt': {'type': 'string'}, 'at': {'type': ['string', 'number']}, 'everySeconds': {'type': 'number'}, 'rrule': {'type': 'string'}, 'dtstart': {'type': 'string'}, 'timezone': {'type': 'string'}, 'enabled': {'type': 'boolean'}, 'maxRuns': {'type': 'integer'}, 'threadId': {'type': 'string'}}, 'required': ['prompt'], 'anyOf': [{'required': ['at']}, {'required': ['rrule', 'dtstart']}]}}
    ]
    core.register_adapter('organic_scheduler', 'Organic-owned persistent scheduling and notifications.', specs, service.tool, close=service.close)
    for method, path, handler in [
        ('GET', '/scheduler/jobs', service.jobs), ('POST', '/scheduler/jobs', service.upsert),
        ('POST', '/scheduler/pause', service.pause), ('GET', '/scheduler/runs', service.runs),
        ('GET', '/notifications', service.notifications), ('POST', '/notifications/ack', service.acknowledge),
        ('GET', '/scheduler/official-records', service.official_records)
    ]:
        core.register_route(method, path, handler)
    service.task = asyncio.create_task(service.loop())
    core.emit('scheduler/ready', {'jobs': len(service.state['jobs']), 'runs': len(service.state['runs'])})
