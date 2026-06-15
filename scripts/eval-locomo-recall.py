#!/usr/bin/env python3
"""
eval-locomo-recall.py — run Pace's recall against the public LoCoMo benchmark.

LoCoMo (github.com/snap-research/locomo) is a long-term conversational-memory
benchmark: multi-session dialogues + QA pairs whose `evidence` cites the gold
dialog turns (e.g. "D1:3") that hold the answer. This harness measures the part
Pace owns — RETRIEVAL recall: index every dialog turn as a memory, embed each
question with Pace's production embedding model (LM Studio), cosine-rank, and
check whether a gold-evidence turn lands in the top-k. That's exactly what
`PaceMemoryRetriever` does at recall time, scored on a real third-party set
instead of hand-written fixtures.

Not measured here: the downstream answer-generation step (that needs the
planner). Retrieval recall is the upstream bottleneck — if the right turn never
surfaces, the planner can't answer.

Usage:
  python3 scripts/eval-locomo-recall.py                       # 2 conversations
  python3 scripts/eval-locomo-recall.py --conversations 10    # full set
  python3 scripts/eval-locomo-recall.py --data /tmp/locomo10.json
"""

import argparse
import json
import math
import re
import sys
import urllib.error
import urllib.request
from collections import defaultdict

DIA_ID = re.compile(r"D\d+:\d+")
# LoCoMo category 5 is adversarial / unanswerable (no single gold turn), so it's
# excluded from a retrieval-recall measurement.
CATEGORY_NAMES = {1: "multi-hop", 2: "temporal", 3: "open-domain", 4: "single-hop"}


def embed(texts, base_url, model, chunk=64, timeout=120):
    vectors = []
    for start in range(0, len(texts), chunk):
        batch = texts[start:start + chunk]
        body = json.dumps({"model": model, "input": batch}).encode()
        req = urllib.request.Request(
            base_url.rstrip("/") + "/embeddings",
            data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.load(resp)
        vectors.extend(item["embedding"]
                       for item in sorted(data["data"], key=lambda d: d["index"]))
    return vectors


def cosine(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na and nb else 0.0


def gold_ids(evidence):
    return set(DIA_ID.findall(json.dumps(evidence)))


def conversation_turns(conv):
    turns = []
    for key in conv:
        if key.startswith("session_") and not key.endswith("date_time") \
                and isinstance(conv[key], list):
            for turn in conv[key]:
                if turn.get("dia_id") and turn.get("text"):
                    turns.append((turn["dia_id"],
                                  f"{turn.get('speaker','')}: {turn['text']}"))
    return turns


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", default="/tmp/locomo10.json")
    parser.add_argument("--base-url", default="http://localhost:1234/v1")
    parser.add_argument("--model", default="text-embedding-nomic-embed-text-v1.5")
    parser.add_argument("--conversations", type=int, default=2)
    parser.add_argument("--ks", default="1,3,5,10")
    args = parser.parse_args()
    ks = [int(k) for k in args.ks.split(",")]

    try:
        dataset = json.load(open(args.data))
    except FileNotFoundError:
        print(f"❌ {args.data} not found. Download LoCoMo first:\n"
              "  curl -s -o /tmp/locomo10.json "
              "https://raw.githubusercontent.com/snap-research/locomo/main/data/locomo10.json")
        sys.exit(1)

    try:
        embed(["probe"], args.base_url, args.model, timeout=8)
    except (urllib.error.URLError, OSError, KeyError, ValueError) as exc:
        print(f"❌ LM Studio embeddings unreachable ({exc}). Load the embedding "
              f"model ({args.model}) and retry.")
        sys.exit(1)

    samples = dataset[:args.conversations]
    print(f"# Pace recall vs. LoCoMo — {len(samples)} conversation(s), "
          f"model={args.model}\n")

    hits = {k: 0 for k in ks}
    by_cat_hits = defaultdict(lambda: {k: 0 for k in ks})
    by_cat_total = defaultdict(int)
    scored = 0

    for sample in samples:
        turns = conversation_turns(sample["conversation"])
        turn_ids = [t[0] for t in turns]
        turn_vecs = embed([t[1] for t in turns], args.base_url, args.model)

        questions, q_meta = [], []
        for qa in sample.get("qa", []):
            if qa.get("category") == 5:
                continue
            gold = gold_ids(qa.get("evidence", ""))
            if not gold:
                continue
            questions.append(qa["question"])
            q_meta.append((gold, qa.get("category")))
        if not questions:
            continue
        q_vecs = embed(questions, args.base_url, args.model)

        for q_vec, (gold, category) in zip(q_vecs, q_meta):
            ranked = sorted(zip(turn_ids, (cosine(v, q_vec) for v in turn_vecs)),
                            key=lambda x: -x[1])
            ranked_ids = [tid for tid, _ in ranked]
            scored += 1
            by_cat_total[category] += 1
            for k in ks:
                if gold & set(ranked_ids[:k]):
                    hits[k] += 1
                    by_cat_hits[category][k] += 1

    print(f"Scored {scored} retrieval questions (excluding adversarial cat-5).\n")
    print("| recall@k | " + " | ".join(f"@{k}" for k in ks) + " |")
    print("|---|" + "|".join("---" for _ in ks) + "|")
    print("| **overall** | " +
          " | ".join(f"{hits[k]/scored:.0%}" for k in ks) + " |")
    for category in sorted(by_cat_total):
        name = CATEGORY_NAMES.get(category, f"cat-{category}")
        total = by_cat_total[category]
        print(f"| {name} ({total}) | " +
              " | ".join(f"{by_cat_hits[category][k]/total:.0%}" for k in ks) + " |")

    print("\nRecall@k = fraction of questions whose gold-evidence turn is in the "
          "top-k embedding-ranked turns — the upstream bound on what Pace can "
          "answer from memory.")


if __name__ == "__main__":
    main()
