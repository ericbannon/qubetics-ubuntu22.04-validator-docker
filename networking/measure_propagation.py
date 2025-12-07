#!/usr/bin/env python3
import time
import json
import signal
import sys
from urllib.request import urlopen, Request
from urllib.error import URLError, HTTPError
from statistics import mean

REMOTE_RPC = "https://tendermint.qubetics.com"
LOCAL_RPC  = "http://127.0.0.1:26657"

POLL_INTERVAL = 0.25   # seconds between polls
PRINT_EVERY   = 60.0   # print stats every 60s

_running = True

def handle_sigint(signum, frame):
    global _running
    _running = False
    print("\nStopping measurement...")

signal.signal(signal.SIGINT, handle_sigint)

def get_status_height(rpc):
    url = rpc.rstrip("/") + "/status"
    req = Request(url, headers={"User-Agent": "delay-measurer/1.0"})
    try:
        with urlopen(req, timeout=2) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        h = int(data["result"]["sync_info"]["latest_block_height"])
        return h
    except (URLError, HTTPError, KeyError, ValueError, TimeoutError) as e:
        # On error, return None but don't crash
        return None

def main():
    print("Measuring block *propagation delay* vs reference RPC")
    print(f"  Remote RPC: {REMOTE_RPC}")
    print(f"  Local  RPC: {LOCAL_RPC}")
    print(f"  Poll interval: {POLL_INTERVAL}s\n")
    sys.stdout.flush()

    last_remote_h = None
    last_local_h  = None

    # height -> time first seen on remote
    first_seen_remote = {}
    # list of delay samples (seconds)
    delays = []

    start_time = time.time()
    last_print = start_time

    while _running:
        now = time.time()
        remote_h = get_status_height(REMOTE_RPC)
        local_h  = get_status_height(LOCAL_RPC)

        if remote_h is None or local_h is None:
            time.sleep(POLL_INTERVAL)
            continue

        # First iteration init
        if last_remote_h is None:
            last_remote_h = remote_h
            last_local_h  = local_h
            print(f"Initial heights: remote={remote_h}, local={local_h}")
            sys.stdout.flush()
            time.sleep(POLL_INTERVAL)
            continue

        # Detect new blocks seen on remote since last iteration
        if remote_h > last_remote_h:
            for h in range(last_remote_h + 1, remote_h + 1):
                first_seen_remote[h] = now

        # For any heights we've seen on remote, see if local has caught up
        to_delete = []
        for h, t_remote in first_seen_remote.items():
            if local_h >= h:
                delay = now - t_remote
                delays.append(delay)
                to_delete.append(h)
        for h in to_delete:
            del first_seen_remote[h]

        last_remote_h = remote_h
        last_local_h  = local_h

        # Periodic stats
        if now - last_print >= PRINT_EVERY and delays:
            elapsed = now - start_time
            avg_delay = mean(delays)
            max_delay = max(delays)
            p95_delay = sorted(delays)[int(0.95 * len(delays)) - 1] if len(delays) >= 20 else max_delay
            latest_delay = delays[-1]

            print(
                f"[DELAY] t={int(elapsed)}s "
                f"samples={len(delays)} "
                f"last={latest_delay*1000:.1f}ms "
                f"avg={avg_delay*1000:.1f}ms "
                f"p95={p95_delay*1000:.1f}ms "
                f"max={max_delay*1000:.1f}ms "
                f"(remote_h={remote_h}, local_h={local_h})"
            )
            sys.stdout.flush()
            last_print = now

        time.sleep(POLL_INTERVAL)

    # Final summary
    if delays:
        avg_delay = mean(delays)
        max_delay = max(delays)
        p95_delay = sorted(delays)[int(0.95 * len(delays)) - 1] if len(delays) >= 20 else max_delay
        print(
            f"\nFinal summary: samples={len(delays)}, "
            f"avg={avg_delay*1000:.1f}ms, p95={p95_delay*1000:.1f}ms, max={max_delay*1000:.1f}ms"
        )
    else:
        print("\nNo delay samples collected (heights may have been static).")

if __name__ == "__main__":
    main()
