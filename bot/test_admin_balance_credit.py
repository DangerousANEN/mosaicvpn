import importlib.util
import os
import tempfile

os.environ.setdefault("MOSAIC_BOT_TOKEN", "123456:abcdefghijklmnopqrstuvwxyzABCDEF")
os.environ.setdefault("MOSAIC_REMNAWAVE_TOKEN", "test-token")

source = os.path.join(os.path.dirname(__file__), "bot.py")
spec = importlib.util.spec_from_file_location("mosaic_bot_ledger_test", source)
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)

with tempfile.TemporaryDirectory() as temp_dir:
    bot.DB_PATH = os.path.join(temp_dir, "bot.db")
    bot.init_db()

    first, first_claimed = bot.claim_admin_balance_credit(
        "credit_test_request_0001", 831992162, 100000001, 30, "Тест идемпотентности"
    )
    assert first_claimed is True
    assert first["status"] == "processing"

    duplicate, duplicate_claimed = bot.claim_admin_balance_credit(
        "credit_test_request_0001", 831992162, 100000001, 30, "Тест идемпотентности"
    )
    assert duplicate_claimed is False
    assert duplicate["status"] == "processing"

    assert bot.finish_admin_balance_credit("credit_test_request_0001", "succeeded", resulting_short_uuid="abc") is True
    assert bot.finish_admin_balance_credit("credit_test_request_0001", "failed", "must_not_overwrite") is False

    history = bot.get_admin_balance_credit_history()
    assert len(history) == 1
    assert history[0]["status"] == "succeeded"
    assert history[0]["target_telegram_id"] == 100000001
    assert history[0]["amount"] == 30

print("admin credit ledger smoke test: OK")
