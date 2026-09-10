#!/usr/bin/env python3
"""
consult_astra.py — Helper to consult gpt-6-astra (Brain & Critic) via OmniRoute.
Usage:
    python scripts/consult_astra.py --system "System prompt" --prompt "Prompt content"
Or stream from stdin:
    cat prompt.txt | python scripts/consult_astra.py
"""

import sys
import json
import argparse
import urllib.request

OMNIROUTE_URL = "http://127.0.0.1:20128/v1/chat/completions"
MODEL_NAME = "gpt-6-astra"

def consult(prompt: str, system_prompt: str = "You are GPT-6 Astra, Chief Architect and Critic. Provide deep reasoning, architectural critique, race condition checks, edge cases analysis, and clean algorithms.") -> str:
    payload = {
        "model": MODEL_NAME,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": prompt}
        ],
        "stream": True,
        "temperature": 0.2
    }
    
    req = urllib.request.Request(
        OMNIROUTE_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"}
    )
    
    collected_text = []
    with urllib.request.urlopen(req, timeout=120) as resp:
        for line in resp:
            line_str = line.decode("utf-8").strip()
            if not line_str.startswith("data: "):
                continue
            data_str = line_str[6:].strip()
            if data_str == "[DONE]":
                break
            try:
                chunk = json.loads(data_str)
                delta = chunk.get("choices", [{}])[0].get("delta", {})
                content = delta.get("content", "")
                if content:
                    print(content, end="", flush=True)
                    collected_text.append(content)
            except Exception:
                continue
    print()
    return "".join(collected_text)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Consult GPT-6 Astra")
    parser.add_argument("--prompt", type=str, default="", help="Prompt to send")
    parser.add_argument("--system", type=str, default="You are GPT-6 Astra, Chief Architect and Critic. Analyze code for race conditions, edge cases, deadlocks, resource leaks, and propose bulletproof algorithms.", help="System prompt")
    args = parser.parse_args()
    
    prompt = args.prompt
    if not prompt and not sys.stdin.isatty():
        prompt = sys.stdin.read()
        
    if not prompt:
        print("Error: No prompt provided via --prompt or stdin", file=sys.stderr)
        sys.exit(1)
        
    consult(prompt, args.system)
