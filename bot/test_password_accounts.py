import os
import pathlib
import tempfile
import unittest

os.environ.setdefault("MOSAIC_BOT_TOKEN", "123456:test-token")
os.environ.setdefault("MOSAIC_REMNAWAVE_TOKEN", "test-remnawave-token")

import bot as service  # noqa: E402


class PasswordAccountTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.original_db = service.DB_PATH
        self.original_create = service.api_create_user
        self.original_sender = service._send_password_recovery_email
        service.DB_PATH = str(pathlib.Path(self.tempdir.name) / "bot.db")
        service.init_db()
        service.api_create_user = lambda username, days, account_id: {
            "shortUuid": f"short-{abs(account_id)}"
        }

    def tearDown(self):
        service.DB_PATH = self.original_db
        service.api_create_user = self.original_create
        service._send_password_recovery_email = self.original_sender
        self.tempdir.cleanup()

    def test_password_account_and_single_use_recovery(self):
        account, reason = service.create_website_account(
            "User@Example.test", "a secure test password"
        )
        self.assertIsNone(reason)
        self.assertEqual(account["account_id"], -1)

        authenticated = service.authenticate_website_account(
            "user@example.test", "a secure test password"
        )
        self.assertIsNotNone(authenticated)
        self.assertIsNone(service.authenticate_website_account(
            "user@example.test", "incorrect password"
        ))

        sent = {}
        service._send_password_recovery_email = lambda address, code: sent.update(
            address=address, code=code
        ) or True
        self.assertTrue(service.issue_password_reset("USER@example.test"))
        self.assertEqual(sent["address"], "user@example.test")
        self.assertTrue(service.reset_website_password(
            sent["code"], "replacement secure password"
        ))
        self.assertFalse(service.reset_website_password(
            sent["code"], "another replacement password"
        ))
        self.assertIsNotNone(service.authenticate_website_account(
            "user@example.test", "replacement secure password"
        ))
        self.assertIsNone(service.authenticate_website_account(
            "user@example.test", "a secure test password"
        ))


if __name__ == "__main__":
    unittest.main()
