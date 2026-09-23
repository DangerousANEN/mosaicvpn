"""Group starvation alert: suppression, recovery, floor detection.

The alert must fire when a group drops below the floor, stay quiet for the
suppression window when the same groups starve again next cycle, alert again
when a NEW group joins the starved set, and clear state on recovery.
"""
import json
import os
import time
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest import mock

import mosaic_pool_collector as mpc

ENV = {'MOSAIC_BOT_TOKEN': '123456:ABC', 'MOSAIC_ADMIN_IDS': '831992162'}


@contextmanager
def alert_env(snapshot, env=ENV):
    with mock.patch.object(mpc, 'group_health_snapshot', return_value=snapshot), \
         mock.patch.dict(os.environ, env, clear=False), \
         mock.patch.object(mpc.urllib.request, 'urlopen') as urlopen:
        yield urlopen


class GroupStarvationAlertTest(unittest.TestCase):
    def setUp(self):
        self.state_file = Path(f'test_alert_state_{id(self)}.json')
        self._orig_state = mpc.ALERT_STATE_FILE
        mpc.ALERT_STATE_FILE = self.state_file

    def tearDown(self):
        mpc.ALERT_STATE_FILE = self._orig_state
        if self.state_file.exists():
            self.state_file.unlink()

    def test_no_starvation_no_alert(self):
        with alert_env([('germany', 40), ('usa', 30)]) as urlopen:
            result = mpc.send_group_starvation_alert(min_nodes=15)
        self.assertIsNone(result)
        self.assertEqual(urlopen.call_count, 0)
        self.assertFalse(self.state_file.exists())

    def test_alert_fires_and_suppresses_repeat(self):
        snap = [('germany', 3), ('usa', 40)]
        with alert_env(snap) as urlopen:
            first = mpc.send_group_starvation_alert(min_nodes=15)
            self.assertIsNotNone(first)
            self.assertEqual(urlopen.call_count, 1)
            # Same set, immediately after: suppressed
            second = mpc.send_group_starvation_alert(min_nodes=15)
            self.assertIsNone(second)
            self.assertEqual(urlopen.call_count, 1)
        state = json.loads(self.state_file.read_text(encoding='utf-8'))
        self.assertEqual(state['groups'], ['germany'])

    def test_new_group_escalates_even_within_window(self):
        with alert_env([('germany', 3)]) as urlopen:
            mpc.send_group_starvation_alert(min_nodes=15)
            self.assertEqual(urlopen.call_count, 1)
            # A new group degrades within the window: alert must NOT be suppressed
            with alert_env([('germany', 3), ('usa', 2)]) as urlopen2:
                escalated = mpc.send_group_starvation_alert(min_nodes=15)
            self.assertIsNotNone(escalated)
        self.assertEqual(urlopen.call_count, 1)
        state = json.loads(self.state_file.read_text(encoding='utf-8'))
        self.assertEqual(set(state['groups']), {'germany', 'usa'})

    def test_recovery_clears_state(self):
        with alert_env([('germany', 3)]) as urlopen:
            mpc.send_group_starvation_alert(min_nodes=15)
        self.assertTrue(self.state_file.exists())
        # Groups recover
        with alert_env([('germany', 50)]) as urlopen:
            result = mpc.send_group_starvation_alert(min_nodes=15)
        self.assertIsNone(result)
        self.assertFalse(self.state_file.exists())

    def test_window_expiry_re_alerts(self):
        with alert_env([('germany', 3)]) as urlopen:
            mpc.send_group_starvation_alert(min_nodes=15)
            self.assertEqual(urlopen.call_count, 1)
            # Age the state past the suppression window
            state = json.loads(self.state_file.read_text(encoding='utf-8'))
            state['sent_at'] = time.time() - (mpc.ALERT_REPEAT_HOURS + 1) * 3600
            self.state_file.write_text(json.dumps(state), encoding='utf-8')
            again = mpc.send_group_starvation_alert(min_nodes=15)
            self.assertIsNotNone(again)
            self.assertEqual(urlopen.call_count, 2)

    def test_missing_credentials_skip_silently(self):
        env = {'MOSAIC_BOT_TOKEN': '', 'MOSAIC_ADMIN_IDS': ''}
        with alert_env([('germany', 3)], env=env) as urlopen:
            result = mpc.send_group_starvation_alert(min_nodes=15)
        self.assertIsNone(result)
        self.assertEqual(urlopen.call_count, 0)
        self.assertFalse(self.state_file.exists())


if __name__ == '__main__':
    unittest.main()
