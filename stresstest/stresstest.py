# stress_test.py
# VCC Assignment 2 - Local Stress Test
# Mahantesh Hiremath | IIT Jodhpur | MTech AI
# Run: python3 stress_test.py

import threading
import urllib.request
import time
import sys
from collections import defaultdict

# ── CONFIG ──────────────────────────────────────────────
ALB_URL      = "http://vcc-alb-1242134358.us-east-1.elb.amazonaws.com"
THREADS      = 100      # concurrent users
DURATION_SEC = 300      # run for 5 minutes (covers ASG 70% trigger window)
REPORT_EVERY = 10       # print stats every N seconds
# ────────────────────────────────────────────────────────

stats = defaultdict(int)
instance_hits = defaultdict(int)
lock = threading.Lock()
stop_flag = threading.Event()

def send_request():
    while not stop_flag.is_set():
        try:
            start = time.time()
            req = urllib.request.urlopen(ALB_URL, timeout=5)
            body = req.read().decode()
            elapsed = (time.time() - start) * 1000  # ms

            # Extract instance ID from response
            iid = "unknown"
            if "i-0" in body:
                idx = body.find("i-0")
                iid = body[idx:idx+19].split("<")[0].strip()

            with lock:
                stats["success"] += 1
                stats["total_ms"] += elapsed
                instance_hits[iid] += 1

        except Exception as e:
            with lock:
                stats["error"] += 1

def print_report(start_time):
    while not stop_flag.is_set():
        time.sleep(REPORT_EVERY)
        elapsed = int(time.time() - start_time)
        with lock:
            total = stats["success"] + stats["error"]
            avg_ms = (stats["total_ms"] / stats["success"]) if stats["success"] > 0 else 0
            rps = stats["success"] / elapsed if elapsed > 0 else 0

            print(f"\n{'='*55}")
            print(f"  Time Elapsed : {elapsed}s / {DURATION_SEC}s")
            print(f"  Total Req    : {total}")
            print(f"  Success      : {stats['success']}")
            print(f"  Errors       : {stats['error']}")
            print(f"  Avg Latency  : {avg_ms:.1f} ms")
            print(f"  Req/sec      : {rps:.1f}")
            print(f"\n  -- ALB Instance Distribution --")
            for iid, count in sorted(instance_hits.items(),
                                     key=lambda x: -x[1]):
                pct = count / stats["success"] * 100 if stats["success"] > 0 else 0
                bar = "█" * int(pct / 5)
                print(f"  {iid[:22]:<22} {count:>5} hits  {pct:>5.1f}%  {bar}")
            print(f"{'='*55}")

def main():
    print(f"""
╔══════════════════════════════════════════════════════╗
║       VCC Auto-Scaling Stress Test                   ║
║       IIT Jodhpur | MTech AI | Mahantesh Hiremath    ║
╠══════════════════════════════════════════════════════╣
║  Target  : {ALB_URL[:44]}  ║
║  Threads : {THREADS:<44} ║
║  Duration: {DURATION_SEC}s{'':<41} ║
╚══════════════════════════════════════════════════════╝
    """)

    start_time = time.time()

    # Start worker threads
    threads = []
    for _ in range(THREADS):
        t = threading.Thread(target=send_request, daemon=True)
        t.start()
        threads.append(t)

    # Start reporter thread
    reporter = threading.Thread(target=print_report,
                                args=(start_time,), daemon=True)
    reporter.start()

    # Run for DURATION_SEC
    try:
        time.sleep(DURATION_SEC)
    except KeyboardInterrupt:
        print("\n[!] Interrupted by user")

    stop_flag.set()
    time.sleep(2)

    # Final summary
    total = stats["success"] + stats["error"]
    avg_ms = (stats["total_ms"] / stats["success"]) if stats["success"] > 0 else 0

    print(f"""
╔══════════════════════════════════════════════════════╗
║                 FINAL SUMMARY                        ║
╠══════════════════════════════════════════════════════╣
║  Total Requests : {total:<35} ║
║  Successful     : {stats['success']:<35} ║
║  Failed         : {stats['error']:<35} ║
║  Avg Latency    : {avg_ms:.1f} ms{'':<31} ║
╚══════════════════════════════════════════════════════╝

  Instance Hit Distribution (ALB Load Balancing Proof):
    """)
    for iid, count in sorted(instance_hits.items(), key=lambda x: -x[1]):
        pct = count / stats["success"] * 100 if stats["success"] > 0 else 0
        print(f"  {iid:<25} → {count:>6} requests ({pct:.1f}%)")

    print("\n✅ Done! Check AWS Console → CloudWatch for CPU spike")
    print("✅ Check ASG Activity tab for new instances launched")

if __name__ == "__main__":
    main()
