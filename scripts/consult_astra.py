#!/usr/bin/env python3
"""
consult_astra.py — Consult the Chief Architect / Critic model via OmniRoute.

Usage (all equivalent):
    python scripts/consult_astra.py "Prompt content"
    python scripts/consult_astra.py --prompt "Prompt content"
    cat prompt.txt | python scripts/consult_astra.py

Options:
    --system  Override the system prompt.
    --model   Force a specific model instead of the fallback chain.
    --timeout Seconds to wait (default 900; deep reasoning is slow).

Why the fallback chain: the `gpt-6-astra` upstream intermittently returns
HTTP 502 from the gateway. Previously that surfaced as a raw urllib traceback
and the consultation was simply lost. Now we transparently fail over to the
next reasoning-grade model and report on stderr which one answered.
"""

import argparse
import json
import sys
import urllib.error
import urllib.request

OMNIROUTE_URL = "http://127.0.0.1:20128/v1/chat/completions"

# Ordered by preference. `gpt-6-astra` stays first so the intended model is
# always tried; the rest are reasoning-grade stand-ins verified on this gateway.
MODEL_CHAIN = [
    "gpt-6-astra",
    "agentrouter/claude-opus-5-high",
    "gor/claude-opus-5-thinking-high",
    "antigravity/gemini-3.8-flash-high",
]

DEFAULT_SYSTEM = (
    "You are the Chief Architect and Critic. Provide deep reasoning, "
    "architectural critique, race condition checks, edge case analysis, and "
    "clean algorithms. Be direct: state verdicts and justify them with "
    "economics and failure modes, not preferences."
)


def _stream(model: str, prompt: str, system_prompt: str, timeout: int) -> str:
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": prompt},
        ],
        # NOTE: several models behind this gateway throw 502 on non-streaming
        # requests, so streaming is mandatory here, not an optimisation.
        "stream": True,
        "temperature": 0.2,
    }
    req = urllib.request.Request(
        OMNIROUTE_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer local",
        },
    )

    collected = []
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        for line in resp:
            line_str = line.decode("utf-8", "ignore").strip()
            if not line_str.startswith("data:"):
                continue
            data_str = line_str[5:].strip()
            if data_str == "[DONE]":
                break
            try:
                chunk = json.loads(data_str)
                delta = chunk.get("choices", [{}])[0].get("delta", {})
                content = delta.get("content", "")
            except Exception:
                continue
            if content:
                print(content, end="", flush=True)
                collected.append(content)
    print()
    text = "".join(collected)
    if not text.strip():
        raise RuntimeError("empty response")
    return text


def consult(prompt, system_prompt=DEFAULT_SYSTEM, model=None, timeout=900):
    chain = [model] if model else MODEL_CHAIN
    last_err = None
    for name in chain:
        try:
            text = _stream(name, prompt, system_prompt, timeout)
            print(f"\n[consulted: {name}]", file=sys.stderr)
            return text
        except (urllib.error.HTTPError, urllib.error.URLError, RuntimeError,
                TimeoutError, OSError) as exc:
            detail = getattr(exc, "code", None) or type(exc).__name__
            print(f"[{name} unavailable: {detail}] trying next model...",
                  file=sys.stderr)
            last_err = exc
    print(f"Error: every model failed. Last error: {last_err}", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Consult the architect model")
    # Positional so `consult_astra.py "text"` works — the old script rejected
    # that form with "unrecognized arguments" and lost the whole prompt.
    parser.add_argument("prompt_pos", nargs="*", help="Prompt (positional)")
    parser.add_argument("--prompt", type=str, default="", help="Prompt to send")
    parser.add_argument("--system", type=str, default=DEFAULT_SYSTEM)
    parser.add_argument("--model", type=str, default=None,
                        help="Force one model instead of the fallback chain")
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()

    prompt = args.prompt or " ".join(args.prompt_pos).strip()
    if not prompt and not sys.stdin.isatty():
        prompt = sys.stdin.read()
    if not prompt:
        print("Error: no prompt provided (positional, --prompt, or stdin)",
              file=sys.stderr)
        sys.exit(1)

    consult(prompt, args.system, args.model, args.timeout)
