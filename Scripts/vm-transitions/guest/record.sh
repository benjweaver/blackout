#!/bin/bash
# Runs in the guest: captures the top 26 pt of the main screen into /tmp/rec/<epoch>.png,
# about ten times a second, until /tmp/rec/stop exists.
rm -rf /tmp/rec; mkdir -p /tmp/rec
width=$(/usr/local/bin/gui size | cut -d' ' -f1)
while [ ! -e /tmp/rec/stop ]; do
  t=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  screencapture -x -R0,0,$width,26 "/tmp/rec/$t.png"
done
