# RUIN Warfront changelog

Versioning: the third number counts the meaningful changes made since the second number last went up.

## Unreleased

(nothing yet)

## 0.3.0 — 2026-10-18

- Suite release: every RUIN addon moves to 0.3.0 together, bringing everything from the 0.2.x entries below. No further code changes.
- Needs RUIN Core 0.3.0.
- From now on a RUIN addon's 0.3.x number counts its own changes since this release.

## 0.2.5 — 2026-10-18

5 changes since 0.2.0:

Needs RUIN Core 0.2.6 or later.

1. Objectives and calls for help are pinned on the world map and minimap (`/wf pins`).
2. Contested objectives: a RUIN Intel enemy sighting within about 300 yards marks an objective CONTESTED for ten minutes on the HUD, list and map. Intel "under attack" calls point your HUD at that member.
3. Bounties: officers post a bounty on a rival guild or player. A kill is claimed by targeting the body (`/wf claim`) and counts once another RUIN member confirms it (`/wf confirm`).
4. Weekly war record: captures and confirmed bounties score points per guild and per player, with a leaderboard for this week and last week. Captures now credit the players who were in the circle.
5. The page is split into Objectives, Bounties and War record, and the HUD uses the Warfront colours and follows couch mode.

## 0.2.0 — 2026-10-18

- Suite milestone: every RUIN addon moves to 0.2.0 together. No code changes since the last 0.1 release.
- With RUIN Core 0.2.0, this module's page opens in the new RUIN window with its own themed header: crossed swords over drifting embers.

## 0.1.3 — 2026-10-18

- The HUD has an arrow that points to the objective (or to whoever called for help) and turns as you turn. It is green when you're inside the circle.
- New radar under the HUD as you get close: a top-down view of the objective's circle around you, forward at the top, drawn as a slowly spinning ring that turns green when you're inside, with the distance to the edge.

## 0.1.2 — 2026-10-18

- Fixed: "Binding header RUIN was attempted to be loaded more than once". Each module now has its own section under Key Bindings, and all of its bindings load.
- Practice mode: while not connected to RUIN, anyone can mark objectives and capture them alone. Practice objectives stay on your own screen.
- Practice mode switch: a "Practice mode" checkbox on the Warfront page and /wf practice. Practice objectives are never sent to anyone, a capture needs only you, and switching practice off clears them.

## 0.1.0 — 2026-10-18

First proof of concept.
