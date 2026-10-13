#!/bin/bash
cd "$(dirname "$0")"
{
  PID=$(pgrep -x Levels)
  echo "PID: $PID"
  ps -o pid,rss,vsz,%cpu,%mem -p "$PID"
  echo "--- footprint"
  footprint "$PID" 2>&1 | grep -E "Footprint|phys_footprint|TOTAL" | head -5
  echo "--- top (5 samples, 1s)"
  top -l 6 -s 1 -pid "$PID" -stats pid,cpu,mem,threads,idlew 2>&1 | grep -E "^ *$PID"
  echo "--- binary"
  ls -l /Applications/Levels.app/Contents/MacOS/Levels
} > measure.log 2>&1
echo "done" >> measure.log
