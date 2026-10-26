---
name: duo-off
description: Turn OFF the Claude+Cursor duo review loop for the current slot (the git checkout of this session). Use when the user says "duo off" or wants plain Claude again.
---

!`"$HOME/.config/ai/duo/duo-mode.sh" off`

Duo mode is now OFF for this slot: the Cursor review hooks and the git-staging block are inert here. Other slots keep their own setting. Confirm this to the user in one line. Normal workflow applies again.
