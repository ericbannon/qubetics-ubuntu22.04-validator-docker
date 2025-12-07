#!/bin/bash
# NIC/IRQ + RPS tuning for enp3s0

IRQ=81        # from: grep enp3s0 /proc/interrupts
MASK=ffff     # CPUs 0–15 (16 cores)

# Spread NIC IRQ across all CPU cores
if [ -f /proc/irq/$IRQ/smp_affinity ]; then
  echo $MASK > /proc/irq/$IRQ/smp_affinity || true
fi

# RPS on RX queue: spread RX work across all cores
if [ -f /sys/class/net/enp3s0/queues/rx-0/rps_cpus ]; then
  echo $MASK > /sys/class/net/enp3s0/queues/rx-0/rps_cpus || true
fi

if [ -f /sys/class/net/enp3s0/queues/rx-0/rps_flow_cnt ]; then
  echo 4096 > /sys/class/net/enp3s0/queues/rx-0/rps_flow_cnt || true
fi
