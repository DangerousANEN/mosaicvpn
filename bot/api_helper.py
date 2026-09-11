import requests
import datetime
import dateutil.parser
import sys
import json

API_TOKEN = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1dWlkIjoiYzhkNjZmZjYtZjAyYi00MDRjLWFlZTAtNzEyOTE0ZGFmN2RmIiwidXNlcm5hbWUiOm51bGwsInJvbGUiOiJBUEkiLCJpYXQiOjE3ODIxMTc4MzQsImV4cCI6MTA0MjIwMzE0MzR9.1iUP4EmmPvOs4pKS83D8ZEu2DR2oXnai1htdp2J5qZ8"
BASE_URL = "http://localhost:3000"
SQUAD_UUID = "7eea96e4-e8f1-4340-ab81-234fd8a24a85" # Default-Squad

def get_headers():
    return {
        "Authorization": f"Bearer {API_TOKEN}",
        "Content-Type": "application/json",
        "X-Forwarded-Proto": "https",
        "X-Forwarded-For": "127.0.0.1"
    }

def get_user_by_username(username):
    url = f"{BASE_URL}/api/users/by-username/{username}"
    try:
        res = requests.get(url, headers=get_headers())
        if res.status_code == 200:
            return res.json().get("response")
    except Exception as e:
        print(f"Error fetching user by username: {e}")
    return None

def get_user_by_telegram_id(telegram_id):
    url = f"{BASE_URL}/api/users/by-telegram-id/{telegram_id}"
    try:
        res = requests.get(url, headers=get_headers())
        if res.status_code == 200:
            users = res.json().get("response", [])
            if users:
                return users[0]
    except Exception as e:
        print(f"Error fetching user by telegram ID: {e}")
    return None

def create_user(username, months, telegram_id=None):
    url = f"{BASE_URL}/api/users"
    now = datetime.datetime.now(datetime.timezone.utc)
    expire_at = now + datetime.timedelta(days=30 * months)
    expire_str = expire_at.strftime("%Y-%m-%dT%H:%M:%S.000Z")
    
    payload = {
        "username": username,
        "expireAt": expire_str,
        "trafficLimitBytes": 0,
        "activeInternalSquads": [SQUAD_UUID]
    }
    if telegram_id:
        payload["telegramId"] = int(telegram_id)
        
    try:
        res = requests.post(url, headers=get_headers(), json=payload)
        if res.status_code in [200, 201]:
            return res.json().get("response")
        else:
            print(f"Create user failed: {res.status_code} - {res.text}")
    except Exception as e:
        print(f"Error creating user: {e}")
    return None

def extend_user(username, months):
    user = get_user_by_username(username)
    if not user:
        return None
        
    current_expire_str = user.get("expireAt")
    now = datetime.datetime.now(datetime.timezone.utc)
    
    try:
        current_expire = dateutil.parser.isoparse(current_expire_str)
    except Exception as e:
        current_expire = now
        
    if current_expire < now:
        new_expire = now + datetime.timedelta(days=30 * months)
    else:
        new_expire = current_expire + datetime.timedelta(days=30 * months)
        
    new_expire_str = new_expire.strftime("%Y-%m-%dT%H:%M:%S.000Z")
    
    url = f"{BASE_URL}/api/users"
    payload = {
        "username": username,
        "expireAt": new_expire_str
    }
    
    try:
        res = requests.patch(url, headers=get_headers(), json=payload)
        if res.status_code == 200:
            return res.json().get("response")
        else:
            print(f"Extend user failed: {res.status_code} - {res.text}")
    except Exception as e:
        print(f"Error extending user: {e}")
    return None

if __name__ == "__main__":
    # Test script if executed directly
    if len(sys.argv) > 2:
        action = sys.argv[1]
        val = sys.argv[2]
        if action == "get":
            print(json.dumps(get_user_by_username(val)))
        elif action == "get_tg":
            print(json.dumps(get_user_by_telegram_id(val)))
        elif action == "create":
            months = int(sys.argv[3]) if len(sys.argv) > 3 else 1
            tg = int(sys.argv[4]) if len(sys.argv) > 4 else None
            print(json.dumps(create_user(val, months, tg)))
        elif action == "extend":
            months = int(sys.argv[3]) if len(sys.argv) > 3 else 1
            print(json.dumps(extend_user(val, months)))
