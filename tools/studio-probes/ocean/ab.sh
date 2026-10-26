#!/bin/bash
cd /home/user
for round in 1 2; do
for v in 1 3; do
  python3 ocean/push_file.py ReplicatedStorage.Gerstner Settings ModuleScript ocean/variants/settings_$v.luau >/dev/null
  ocean/restart_play.sh >/dev/null 2>&1
  on=$(ocean/measure.sh on); off=$(ocean/measure.sh off)
  echo "round=$round variant=$v $on | $off"
done
done
