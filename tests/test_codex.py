import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


probe = load('codex_probe', ROOT / 'codex-collector.py')
app = load('menubar', ROOT / 'cc-menubar.py')


def record(kind, payload, ts='2026-11-12T10:00:00Z'):
    return json.dumps(dict(type=kind, payload=payload, timestamp=ts)) + '\n'


class CodexTests(unittest.TestCase):
    def test_visibility_defaults_config_and_filtering(self):
        cfg = app.Config()
        self.assertTrue(all(app.tool_enabled(cfg, tool) for tool in ('cc', 'agy', 'codex')))
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / 'config.json'
            config_path.write_text(json.dumps({'hosts': [{'name': 'local'}], 'showClaude': False,
                                               'showAgy': False, 'showCodex': True}))
            with patch.object(app, 'CONFIG_PATH', config_path):
                cfg = app.load_config()
        sessions = [app.Session('local', None, kind, kind, 'busy', None, '', '/tmp', time.time(), kind)
                    for kind in ('claude', 'agy', 'codex')]
        original = app.HostResult(app.HostConfig('local'), sessions=sessions, usage=(b'{}', 1),
                                  agy_usage=(b'{}', 1), codex_usage=(b'{}', 1), hook='none')
        visible = app.visible_results([original], cfg)
        self.assertEqual([s.entrypoint for s in visible[0].sessions], ['codex'])
        self.assertEqual(len(original.sessions), 3)
        self.assertIsNone(visible[0].usage)
        self.assertIsNone(visible[0].agy_usage)
        self.assertIsNone(visible[0].hook)
        self.assertIsNotNone(visible[0].codex_usage)
        self.assertEqual(app.shown_tools(visible, cfg), {'cc': False, 'agy': False, 'codex': True})
        cfg.showCodex = False
        self.assertFalse(any(app.shown_tools(visible, cfg).values()))

    def test_status_shapes(self):
        self.assertEqual(app.status_dot('green', 'cc'), '🟩')
        self.assertEqual(app.status_dot('orange', 'codex'), '🟠')
        self.assertEqual(app.status_dot('red', 'agy'), '🔴◆')

    def test_lifecycle_and_partial_tail(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'rollout.jsonl'
            path.write_text(record('event_msg', {'type': 'task_started'}) +
                            record('response_item', {'output': 'x' * 150000}) +
                            record('event_msg', {'type': 'task_complete'}, '2026-11-12T10:01:00Z') +
                            record('event_msg', {'type': 'task_started'}, '2026-11-12T10:02:00Z') + '{"partial":')
            state, since, _ = probe.activity_and_limits(path)
            self.assertEqual(state, 'busy')
            self.assertEqual(since, probe.timestamp('2026-11-12T10:02:00Z'))
            with path.open('a') as stream:
                stream.write('\n' + record('event_msg', {'type': 'turn_aborted'}))
            self.assertEqual(probe.activity_and_limits(path)[0], 'idle')
            path.write_text(record('event_msg', {'type': 'token_count'}))
            self.assertEqual(probe.activity_and_limits(path)[0], 'unknown')

    def test_stale_lock_is_not_presence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            locks = root / 'thread-writer-locks'
            locks.mkdir()
            (locks / 'closed.lock').touch()
            self.assertEqual(probe.live_writers(root), {})

    def test_collector_excludes_closed_sessions_and_normalizes_quota(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / 'live.jsonl'
            limits = dict(primary=dict(used_percent=23, window_minutes=300, resets_at=time.time()+1000),
                          secondary=dict(used_percent=7, window_minutes=10080, resets_at=time.time()+10000))
            path.write_text(record('event_msg', {'type': 'task_started'}) +
                            record('event_msg', {'type': 'token_count', 'rate_limits': limits}))
            with sqlite3.connect(root / 'state_5.sqlite') as db:
                db.execute('CREATE TABLE threads(id, rollout_path, cwd, title, archived, updated_at)')
                db.executemany('INSERT INTO threads VALUES(?,?,?,?,0,1)',
                               [('live', str(path), '/tmp/project', 'Title\nline'), ('closed', str(path), '/tmp/old', 'Old')])
            output = io.StringIO()
            with patch.dict(os.environ, CODEX_HOME=tmp), patch.object(probe, 'live_writers', return_value={'live': 123}), contextlib.redirect_stdout(output):
                probe.collect()
            lines = output.getvalue().splitlines()
            self.assertEqual(len(lines), 2)
            session = json.loads(lines[0].split('\t')[0])
            self.assertEqual(session['entrypoint'], 'codex')
            self.assertEqual(session['status'], 'busy')
            self.assertIsNone(session['tmux'])
            self.assertEqual(json.loads(lines[1].split('\t')[2])['rate_limits']['five_hour']['used_percentage'], 23)

    def test_tool_separation_and_latest_quota(self):
        sessions = [app.Session('local', None, kind, kind, 'busy', None, '', '/tmp', time.time(), kind)
                    for kind in ('claude', 'agy', 'codex')]
        host = app.HostResult(app.HostConfig('local'), sessions=sessions)
        for tool, expected in [('cc', 'claude'), ('agy', 'agy'), ('codex', 'codex')]:
            title = app.build_tool_title([host], {}, tool)
            self.assertIn(expected, title)
            for other in ('claude', 'agy', 'codex'):
                if other != expected:
                    self.assertNotIn(other, title)
        def usage(pct):
            return json.dumps({'rate_limits': {'five_hour': {'used_percentage': pct, 'resets_at': time.time()+1000}}}).encode()
        host.codex_usage = (usage(90), 1)
        remote = app.HostResult(app.HostConfig('remote'), codex_usage=(usage(10), 2))
        five, weekly, ts, source = app.read_usage([host, remote], tool='codex')
        self.assertEqual((five.pct, weekly, ts, source), (10, None, 2, 'remote'))
        self.assertIn('wk ?', app.build_tool_title([host, remote], {}, 'codex'))


if __name__ == '__main__':
    unittest.main()
