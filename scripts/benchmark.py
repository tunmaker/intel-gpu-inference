#!/usr/bin/env python3
"""
Reasoning Quality Benchmark for Gemma-3-4B local server
Tests: Logic, Math, Common Sense, Causal, Analogical, Multi-step, Spatial
"""

import httpx
import time
import json
from datetime import datetime

SERVER = "http://localhost:8080/v1/chat/completions"
MODEL = "local"

BENCHMARKS = [
    # ── LOGIC ──────────────────────────────────────────────────────────────
    {
        "id": "L1", "category": "Logic",
        "prompt": "All mammals are warm-blooded. All dogs are mammals. Is a dog warm-blooded? Explain step by step.",
        "expected_keywords": ["yes", "warm-blooded"],
        "max_tokens": 300
    },
    {
        "id": "L2", "category": "Logic",
        "prompt": "If A implies B, and B implies C, does A imply C? Prove it with an example.",
        "expected_keywords": ["yes", "transitiv"],
        "max_tokens": 400
    },
    {
        "id": "L3", "category": "Logic",
        "prompt": "There are 3 boxes: one with apples, one with oranges, one with both. All labels are wrong. You can pick one fruit from one box. Which box do you pick from to identify all boxes?",
        "expected_keywords": ["both", "labeled"],
        "max_tokens": 500
    },
    {
        "id": "L4", "category": "Logic",
        "prompt": "A is taller than B. C is shorter than B. Who is the tallest? Who is the shortest?",
        "expected_keywords": ["A", "C"],
        "max_tokens": 200
    },
    {
        "id": "L5", "category": "Logic",
        "prompt": "If today is Wednesday, what day was it 100 days ago?",
        "expected_keywords": ["tuesday", "tuesday"],
        "max_tokens": 300
    },

    # ── MATH ───────────────────────────────────────────────────────────────
    {
        "id": "M1", "category": "Math",
        "prompt": "A train travels 120 km in 2 hours. How long will it take to travel 450 km at the same speed?",
        "expected_keywords": ["7.5", "7 hours 30", "450"],
        "max_tokens": 300
    },
    {
        "id": "M2", "category": "Math",
        "prompt": "What is 15% of 840? Show your working.",
        "expected_keywords": ["126"],
        "max_tokens": 200
    },
    {
        "id": "M3", "category": "Math",
        "prompt": "A rectangle has a perimeter of 56cm. Its length is twice its width. What are its dimensions?",
        "expected_keywords": ["width", "length", "18.67", "18", "9.33", "9"],
        "max_tokens": 400
    },
    {
        "id": "M4", "category": "Math",
        "prompt": "If you invest $1000 at 5% annual compound interest, how much will you have after 3 years? Show the formula and calculation.",
        "expected_keywords": ["1157", "1158"],
        "max_tokens": 400
    },
    {
        "id": "M5", "category": "Math",
        "prompt": "A store sells apples for $0.50 each and oranges for $0.75 each. If you buy 4 apples and 6 oranges, what is the total cost?",
        "expected_keywords": ["6.50", "$6.50", "6.5"],
        "max_tokens": 200
    },

    # ── COMMON SENSE ───────────────────────────────────────────────────────
    {
        "id": "CS1", "category": "Common Sense",
        "prompt": "Why is it dangerous to use a mobile phone while driving?",
        "expected_keywords": ["distract", "attention", "accident"],
        "max_tokens": 300
    },
    {
        "id": "CS2", "category": "Common Sense",
        "prompt": "You left ice cream on a table in a warm room for 2 hours. What happened and why?",
        "expected_keywords": ["melt", "heat", "temperature"],
        "max_tokens": 200
    },
    {
        "id": "CS3", "category": "Common Sense",
        "prompt": "If you plant a seed today, will you have fruit tomorrow? Explain.",
        "expected_keywords": ["no", "time", "grow"],
        "max_tokens": 200
    },

    # ── CAUSAL REASONING ───────────────────────────────────────────────────
    {
        "id": "CR1", "category": "Causal",
        "prompt": "A company fired half its staff and then saw customer complaints double. What are three possible causal explanations?",
        "expected_keywords": ["workload", "service", "quality"],
        "max_tokens": 400
    },
    {
        "id": "CR2", "category": "Causal",
        "prompt": "Every time it rains, the roads get wet. Does wet roads cause rain? Explain the difference between correlation and causation.",
        "expected_keywords": ["no", "correlat", "caus"],
        "max_tokens": 400
    },
    {
        "id": "CR3", "category": "Causal",
        "prompt": "A patient takes a new medicine and feels better the next day. Can we conclude the medicine worked? What other factors should we consider?",
        "expected_keywords": ["placebo", "control", "other factor", "coincid"],
        "max_tokens": 400
    },

    # ── MULTI-STEP REASONING ───────────────────────────────────────────────
    {
        "id": "MS1", "category": "Multi-Step",
        "prompt": "Alice has twice as many apples as Bob. Bob has 3 more apples than Carol. Carol has 5 apples. How many apples does Alice have?",
        "expected_keywords": ["16"],
        "max_tokens": 300
    },
    {
        "id": "MS2", "category": "Multi-Step",
        "prompt": "A factory produces 200 widgets per day. It operates 5 days a week. How many widgets does it produce in a year (52 weeks)?",
        "expected_keywords": ["52000"],
        "max_tokens": 300
    },
    {
        "id": "MS3", "category": "Multi-Step",
        "prompt": "You have a 3-litre jug and a 5-litre jug. How do you measure exactly 4 litres of water? Give step by step instructions.",
        "expected_keywords": ["fill", "pour", "4"],
        "max_tokens": 500
    },

    # ── ANALOGICAL REASONING ───────────────────────────────────────────────
    {
        "id": "AR1", "category": "Analogical",
        "prompt": "Complete the analogy: Doctor is to Hospital as Teacher is to ___. Explain your reasoning.",
        "expected_keywords": ["school", "classroom"],
        "max_tokens": 200
    },
    {
        "id": "AR2", "category": "Analogical",
        "prompt": "How is the human brain similar to a computer? List at least 3 similarities and 2 differences.",
        "expected_keywords": ["memory", "process", "input"],
        "max_tokens": 500
    },

    # ── SPATIAL REASONING ──────────────────────────────────────────────────
    {
        "id": "SR1", "category": "Spatial",
        "prompt": "If you are facing North and turn 90 degrees clockwise, then 180 degrees counter-clockwise, which direction are you facing?",
        "expected_keywords": ["west"],
        "max_tokens": 300
    },
    {
        "id": "SR2", "category": "Spatial",
        "prompt": "A cube has 6 faces, 12 edges, and 8 corners. If you paint all faces red and cut it into 27 equal smaller cubes, how many small cubes have exactly 2 red faces?",
        "expected_keywords": ["12"],
        "max_tokens": 400
    },
]


def call_model(prompt: str, max_tokens: int) -> tuple[str, float, int]:
    """Returns (response_text, seconds_taken, tokens_generated)"""
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0.1,
        "stream": False
    }
    start = time.time()
    try:
        r = httpx.post(SERVER, json=payload, timeout=120)
        elapsed = time.time() - start
        data = r.json()
        text = data["choices"][0]["message"]["content"]
        tokens = data.get("usage", {}).get("completion_tokens", 0)
        return text, elapsed, tokens
    except Exception as e:
        return f"ERROR: {e}", time.time() - start, 0


def score_response(response: str, keywords: list[str]) -> tuple[bool, list[str]]:
    """Check if response contains expected keywords (case-insensitive)"""
    resp_lower = response.lower()
    found = [kw for kw in keywords if kw.lower() in resp_lower]
    passed = len(found) > 0
    return passed, found


def run_benchmark():
    print(f"\n{'='*65}")
    print(f"  REASONING BENCHMARK - Gemma-3-4B (131k ctx)")
    print(f"  Started: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"{'='*65}\n")

    results = []
    category_scores = {}

    for i, test in enumerate(BENCHMARKS):
        print(f"[{i+1:02d}/{len(BENCHMARKS)}] {test['id']} - {test['category']}: ", end="", flush=True)

        response, elapsed, tokens = call_model(test["prompt"], test["max_tokens"])
        passed, found_kw = score_response(response, test["expected_keywords"])

        tps = tokens / elapsed if elapsed > 0 and tokens > 0 else 0

        status = "✅ PASS" if passed else "❌ FAIL"
        print(f"{status} | {elapsed:.1f}s | {tps:.1f} t/s")

        result = {
            "id": test["id"],
            "category": test["category"],
            "passed": passed,
            "elapsed": elapsed,
            "tokens": tokens,
            "tps": tps,
            "found_keywords": found_kw,
            "response_preview": response[:200].replace('\n', ' ')
        }
        results.append(result)

        # Track by category
        cat = test["category"]
        if cat not in category_scores:
            category_scores[cat] = {"pass": 0, "total": 0}
        category_scores[cat]["total"] += 1
        if passed:
            category_scores[cat]["pass"] += 1

    # ── SUMMARY ────────────────────────────────────────────────────────────
    total = len(results)
    passed_total = sum(1 for r in results if r["passed"])
    avg_tps = sum(r["tps"] for r in results if r["tps"] > 0) / max(1, sum(1 for r in results if r["tps"] > 0))
    avg_time = sum(r["elapsed"] for r in results) / total

    print(f"\n{'='*65}")
    print(f"  RESULTS SUMMARY")
    print(f"{'='*65}")
    print(f"  Overall Score:    {passed_total}/{total} ({passed_total/total*100:.1f}%)")
    print(f"  Avg Speed:        {avg_tps:.1f} tokens/sec")
    print(f"  Avg Response:     {avg_time:.1f}s per prompt")
    print(f"\n  By Category:")
    for cat, scores in category_scores.items():
        pct = scores['pass'] / scores['total'] * 100
        bar = "█" * scores['pass'] + "░" * (scores['total'] - scores['pass'])
        print(f"    {cat:<18} {bar}  {scores['pass']}/{scores['total']} ({pct:.0f}%)")

    print(f"\n  Failed Tests:")
    failed = [r for r in results if not r["passed"]]
    if failed:
        for r in failed:
            print(f"    ❌ {r['id']} ({r['category']})")
            print(f"       Expected one of: {r['found_keywords'] or test['expected_keywords']}")
            print(f"       Response: {r['response_preview']}...")
    else:
        print("    🎉 None! Perfect score!")

    print(f"\n{'='*65}\n")

    # Save full results to JSON
    output = {
        "model": "Gemma-3-4B-VL-Heretic-Uncensored-Thinking-F16",
        "context": 131072,
        "timestamp": datetime.now().isoformat(),
        "summary": {
            "total": total,
            "passed": passed_total,
            "score_pct": round(passed_total/total*100, 1),
            "avg_tps": round(avg_tps, 1),
            "avg_response_time": round(avg_time, 1)
        },
        "category_scores": category_scores,
        "results": results
    }

    with open("/mnt/user-data/outputs/benchmark_results.json", "w") as f:
        json.dump(output, f, indent=2)

    print(f"  Full results saved to benchmark_results.json")


if __name__ == "__main__":
    run_benchmark()
