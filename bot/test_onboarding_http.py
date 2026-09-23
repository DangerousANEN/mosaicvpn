"""Real local HTTP/SQLite onboarding integration; provider calls are isolated."""
import datetime
import json
import os
import sys
import tempfile
import unittest
from http.client import HTTPConnection
from http.server import HTTPServer
from threading import Thread
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

os.environ.setdefault('MOSAIC_BOT_TOKEN', '123456:abcdefghijklmnopqrstuvwxyzABCDEF')
os.environ.setdefault('MOSAIC_REMNAWAVE_TOKEN', 'test_remnawave_token')
import requests
import bot.bot as app
from bot.sponsored_invites import SponsoredInviteStore


class OnboardingHTTPTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self.tmp.name, 'test.db')
        self.db_patch = patch.object(app, 'DB_PATH', self.db_path)
        self.db_patch.start()
        app.init_db()

        self.user_id = 707101
        self.username = 'tg_707101'
        app.save_user(self.user_id, self.username, 'test_profile')
        self.token, _ = app.create_web_session(self.user_id, self.username)

        self.admin_id = 999001
        self.admin_username = 'admin_user'
        app.save_user(self.admin_id, self.admin_username, 'admin_profile')
        self.admin_token, _ = app.create_web_session(self.admin_id, self.admin_username)
        self.admin_patch = patch.object(app, 'ADMIN_IDS', {self.admin_id})
        self.admin_patch.start()

        self.server = HTTPServer(('127.0.0.1', 0), app.StatsRequestHandler)
        self.thread = Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.admin_patch.stop()
        self.server.shutdown()
        self.thread.join(3)
        self.server.server_close()
        self.db_patch.stop()
        try:
            self.tmp.cleanup()
        except Exception:
            pass

    def request(self, path, payload=None, token=None):
        conn = HTTPConnection('127.0.0.1', self.server.server_port, timeout=10)
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        conn.request('POST' if payload is not None else 'GET', path,
                     json.dumps(payload) if payload is not None else None, headers)
        response = conn.getresponse()
        text = response.read()
        status, cache = response.status, response.getheader('Cache-Control')
        conn.close()
        return status, json.loads(text) if text else {}, cache

    def test_profile_alias_accepts_bearer_not_public_capability(self):
        profile = {'telegram_id': self.user_id, 'days_left': 30, 'status': 'active'}
        with patch.object(app.StatsRequestHandler, '_account_payload', return_value=profile):
            status, body, cache = self.request('/api/profile', token=self.token)
            self.assertEqual(status, 200)
            self.assertEqual(body['telegram_id'], self.user_id)
            self.assertEqual(cache, 'no-store')
        self.assertEqual(self.request('/api/profile', token='test_profile')[0], 401)

    def test_checkout_options_accepts_bearer_header(self):
        status, body, _ = self.request('/api/checkout/options', token=self.token)
        self.assertEqual(status, 200)
        self.assertIn('providers', body)
        self.assertTrue(any(p.get('id') == 'lava' for p in body['providers']))

    def test_checkout_create_accepts_bearer_header(self):
        fake_invoice = {
            'internal_id': 1001,
            'provider_id': 'prov_1001',
            'order_id': 'ord_1001',
            'payment_url': 'https://pay.lava.ru/invoice/1001',
        }
        with patch.object(app, 'create_lava_invoice', return_value=fake_invoice):
            status, body, _ = self.request(
                '/api/checkout/create',
                payload={'amount_rub': 100, 'provider': 'lava'},
                token=self.token,
            )
            self.assertEqual(status, 200)
            self.assertEqual(body.get('provider'), 'lava')
            self.assertEqual(body.get('checkout_url'), fake_invoice['payment_url'])

    def test_admin_invites_create_and_get(self):
        # Unauthenticated / forbidden checks
        self.assertEqual(self.request('/api/admin/invites')[0], 401)
        self.assertEqual(self.request('/api/admin/invites', token=self.token)[0], 403)
        self.assertEqual(self.request('/api/admin/invites/create', payload={'amount': 30})[0], 401)
        self.assertEqual(self.request('/api/admin/invites/create', payload={'amount': 30}, token=self.token)[0], 403)

        # Validation errors
        st, err, _ = self.request('/api/admin/invites/create', payload={'amount': 0, 'label': 'x', 'request_id': 'r1'}, token=self.admin_token)
        self.assertEqual(st, 400)
        st, err, _ = self.request('/api/admin/invites/create', payload={'amount': 30, 'label': '', 'request_id': 'r1'}, token=self.admin_token)
        self.assertEqual(st, 400)
        st, err, _ = self.request('/api/admin/invites/create', payload={'amount': 30, 'label': 'x', 'request_id': ''}, token=self.admin_token)
        self.assertEqual(st, 400)

        # Successful creation
        req_id = 'req-gift-test-01'
        status, body, _ = self.request(
            '/api/admin/invites/create',
            payload={'amount': 30, 'label': 'Промо весна', 'request_id': req_id},
            token=self.admin_token,
        )
        self.assertEqual(status, 200)
        self.assertIn('invite', body)
        self.assertIn('gift_url', body)
        self.assertTrue(body['gift_url'].startswith('http'))
        self.assertIn('#gift=', body['gift_url'])
        self.assertEqual(body['invite']['amount'], 30)
        self.assertEqual(body['invite']['label'], 'Промо весна')
        self.assertEqual(body['invite']['status'], 'pending')

        # Idempotent re-creation with identical payload
        status_rep, body_rep, _ = self.request(
            '/api/admin/invites/create',
            payload={'amount': 30, 'label': 'Промо весна', 'request_id': req_id},
            token=self.admin_token,
        )
        self.assertEqual(status_rep, 200)
        self.assertTrue(body_rep.get('already_processed'))
        self.assertIsNone(body_rep.get('gift_url'))
        self.assertEqual(body_rep['invite']['id'], body['invite']['id'])

        # Conflict on same request_id with differing amount
        status_conf, _, _ = self.request(
            '/api/admin/invites/create',
            payload={'amount': 60, 'label': 'Промо весна', 'request_id': req_id},
            token=self.admin_token,
        )
        self.assertEqual(status_conf, 409)

        # Listing invites via GET
        status_list, list_body, _ = self.request('/api/admin/invites', token=self.admin_token)
        self.assertEqual(status_list, 200)
        self.assertIn('invites', list_body)
        self.assertEqual(len(list_body['invites']), 1)
        self.assertEqual(list_body['invites'][0]['id'], body['invite']['id'])
        self.assertNotIn('token_hash', list_body['invites'][0])

    def test_admin_invites_revoke(self):
        status, body, _ = self.request(
            '/api/admin/invites/create',
            payload={'amount': 15, 'label': 'Отозвать тест', 'request_id': 'req-revoke-01'},
            token=self.admin_token,
        )
        self.assertEqual(status, 200)
        invite_id = body['invite']['id']

        # Revoke by other user -> 403
        st_forbidden, _, _ = self.request(
            '/api/admin/invites/revoke',
            payload={'invite_id': invite_id},
            token=self.token,
        )
        self.assertEqual(st_forbidden, 403)

        # Successful revoke
        st_rev, body_rev, _ = self.request(
            '/api/admin/invites/revoke',
            payload={'invite_id': invite_id},
            token=self.admin_token,
        )
        self.assertEqual(st_rev, 200)
        self.assertTrue(body_rev.get('ok'))
        self.assertEqual(body_rev.get('status'), 'revoked')

        # Revoking again -> 400
        st_rev2, _, _ = self.request(
            '/api/admin/invites/revoke',
            payload={'invite_id': invite_id},
            token=self.admin_token,
        )
        self.assertEqual(st_rev2, 400)

    def test_invites_redeem_success_and_idempotent_replay(self):
        # Admin creates invite
        status, body, _ = self.request(
            '/api/admin/invites/create',
            payload={'amount': 20, 'label': 'Успешный подарок', 'request_id': 'req-redeem-succ-01'},
            token=self.admin_token,
        )
        self.assertEqual(status, 200)
        gift_token = body['gift_url'].split('#gift=')[1]

        mock_provider_extend = MagicMock(return_value={
            'shortUuid': 'remna_uuid_707101',
            'expireAt': '2026-10-15T00:00:00.000Z',
        })
        mock_provider_get = MagicMock(return_value={'username': self.username, 'expireAt': '2026-09-25T00:00:00.000Z'})

        with patch.object(app, 'api_get_user', mock_provider_get), \
             patch.object(app, 'api_extend_user', mock_provider_extend):

            # Initial claim
            st, res_body, _ = self.request(
                '/api/invites/redeem',
                payload={'invite_token': gift_token},
                token=self.token,
            )
            self.assertEqual(st, 200)
            self.assertTrue(res_body.get('ok'))
            self.assertEqual(res_body.get('status'), 'succeeded')
            self.assertEqual(res_body.get('days'), 20)
            self.assertEqual(mock_provider_extend.call_count, 1)

            # Check database user updated
            db_user = app.get_user(self.user_id)
            self.assertEqual(db_user['short_uuid'], 'remna_uuid_707101')
            self.assertEqual(db_user['trial_used'], 1)

            # Replay redemption by same claimant -> should return 200 already_processed without re-calling provider
            st_rep, rep_body, _ = self.request(
                '/api/invites/redeem',
                payload={'invite_token': gift_token},
                token=self.token,
            )
            self.assertEqual(st_rep, 200)
            self.assertTrue(rep_body.get('already_processed'))
            self.assertEqual(rep_body.get('status'), 'already_redeemed')
            # Provider double must NOT be called again
            self.assertEqual(mock_provider_extend.call_count, 1)

    def test_invites_redeem_uncertain_external_write_never_retried(self):
        # Admin creates invite
        status, body, _ = self.request(
            '/api/admin/invites/create',
            payload={'amount': 10, 'label': 'Неопределённая запись', 'request_id': 'req-uncertain-01'},
            token=self.admin_token,
        )
        self.assertEqual(status, 200)
        gift_token = body['gift_url'].split('#gift=')[1]

        # Simulate timeout during provider write
        mock_provider_get = MagicMock(return_value={'username': self.username})
        mock_provider_extend = MagicMock(side_effect=requests.Timeout("connection timed out to remnawave"))

        with patch.object(app, 'api_get_user', mock_provider_get), \
             patch.object(app, 'api_extend_user', mock_provider_extend):

            # First attempt triggers timeout -> uncertain status saved
            st1, body1, _ = self.request(
                '/api/invites/redeem',
                payload={'invite_token': gift_token},
                token=self.token,
            )
            self.assertEqual(st1, 504)
            self.assertEqual(mock_provider_extend.call_count, 1)

            # Verify store state is uncertain
            store = SponsoredInviteStore(self.db_path)
            invite_record = store.get(body['invite']['id'])
            self.assertEqual(invite_record['status'], 'uncertain')

            # Repeat attempt must NEVER retry external write
            st2, body2, _ = self.request(
                '/api/invites/redeem',
                payload={'invite_token': gift_token},
                token=self.token,
            )
            self.assertEqual(st2, 409)
            self.assertEqual(body2.get('status'), 'uncertain')
            # Critical guarantee: call count must still be 1!
            self.assertEqual(mock_provider_extend.call_count, 1)

    def test_invites_redeem_revoked_and_expired(self):
        # Revoked invite
        st, body, _ = self.request(
            '/api/admin/invites/create',
            payload={'amount': 10, 'label': 'Отозванный', 'request_id': 'req-rev-red-01'},
            token=self.admin_token,
        )
        gift_token = body['gift_url'].split('#gift=')[1]
        self.request('/api/admin/invites/revoke', payload={'invite_id': body['invite']['id']}, token=self.admin_token)

        st_rev, _, _ = self.request('/api/invites/redeem', payload={'invite_token': gift_token}, token=self.token)
        self.assertEqual(st_rev, 410)

        # Expired invite (past timestamp)
        store = SponsoredInviteStore(self.db_path)
        past_time = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=1)).isoformat()
        with store._get_connection() as conn:
            conn.execute("UPDATE sponsored_invites SET expires_at = ?, status = 'pending' WHERE id = ?",
                         (past_time, body['invite']['id']))
            conn.commit()

        st_exp, _, _ = self.request('/api/invites/redeem', payload={'invite_token': gift_token}, token=self.token)
        self.assertEqual(st_exp, 410)


if __name__ == '__main__':
    unittest.main()
