---
name: btw
description: Ask a side question during duo mode - Claude answers without sending the working diff to Cursor for review. Use when the user prefixes a message with /btw or btw, or asks something alongside the implementation (a decision, a clarification, "why did you...").
---

!`"$HOME/.config/ai/duo/duo-mode.sh" aside`

This message is a **side question**, not a step of the implementation. For this turn:

- Answer the question directly. Keep it short unless the user asks for depth.
- Do not start or continue implementing. If the answer implies code changes, say what you would change and wait — the user will ask in a normal message.
- Editing the plan file is fine when the question settles a planning decision; record the decision there so the reviewer sees it later.
- The Stop hook skips the Cursor diff review for this turn only. Any code already in the working tree stays unreviewed and goes to Cursor on the next normal turn, so nothing is lost.
