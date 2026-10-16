#!/bin/bash
# Runs in the guest while Blackout runs: goes through every transition that moves or hides
# the menu bar, recording the top of the screen and writing "<epoch> <label>" marks to
# /tmp/rec/marks. Uses the GUI helper at /usr/local/bin/gui and Terminal as the
# full-screen app.
cd "$(dirname "$0")"
G=/usr/local/bin/gui
width=$($G size | cut -d' ' -f1)
mark() { echo "$(perl -MTime::HiRes=time -e 'printf "%.3f", time') $*" >> /tmp/marks; }
fullscreen() {
  osascript -e "tell application \"System Events\" to tell process \"Terminal\" to set value of attribute \"AXFullScreen\" of window 1 to $1"
}
rm -f /tmp/marks
./record.sh & sleep 1.5
mark baseline; sleep 1.5
mark mission-control; open -a "Mission Control"; sleep 2.5; mark mission-control-close; open -a "Mission Control"; sleep 2.5
mark app-expose; open -a "Mission Control" --args 2; sleep 2.5; mark app-expose-close; open -a "Mission Control" --args 2; sleep 2.5
mark show-desktop; open -a "Mission Control" --args 1; sleep 2.5; mark show-desktop-close; open -a "Mission Control" --args 1; sleep 2.5
mark app-switch; open -a Finder; sleep 1.5; open -a Terminal; sleep 2
mark full-screen; fullscreen true; sleep 3.5
mark reveal; $G move 500 1; sleep 0.2; $G move 501 0; sleep 0.2; $G move 502 0; sleep 2.5
mark hide; $G move 500 300; sleep 0.2; $G move 501 310; sleep 2.5
mark full-screen-mission-control; open -a "Mission Control"; sleep 2.5; mark full-screen-mission-control-close; open -a "Mission Control"; sleep 2.5
mark to-desktop; open -a Finder; sleep 3
mark to-full-screen; open -a Terminal; sleep 3
mark leave-full-screen; fullscreen false; sleep 3.5
mark notification-center; $G click $((width - 84)) 12; sleep 2.5; mark notification-center-close; $G key escape; sleep 2.5
mark end; touch /tmp/rec/stop; sleep 1
mv /tmp/marks /tmp/rec/marks
