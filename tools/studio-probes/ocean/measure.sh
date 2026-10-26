#!/bin/bash
# usage: measure.sh on|off
cd /home/user
MODE=$1
sed "s/__MODE__/$MODE/" ocean/measure.lua > /tmp/measure_$MODE.lua
for try in 1 2 3; do
  out=$(python3 ocean/run_client.py /tmp/measure_$MODE.lua 90)
  if echo "$out" | grep -q "MODE="; then echo "$out" | grep -o 'MODE=[^\\]*' | head -1; exit 0; fi
  sleep 3
done
echo "FAILED: $out" | head -c 300
