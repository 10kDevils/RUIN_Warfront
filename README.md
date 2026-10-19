# RUIN Warfront (retired)

> **Retired in October 2026.** The RUIN Gaming Companion App uses **Overlord Forever** for world PvP: its campaign, keeps, captures, call to arms, Most Wanted and leaderboards. What Overlord has no match for moved to **RUIN Muster** 0.3.3: bounties on rival guilds and players confirmed by a RUIN witness, and rally points (an event's meeting place on everyone's map, contested when RUIN Intel sees enemies nearby). Disable or remove this addon. The text below describes the last version.

RUIN's own war in the open world: officer-set objectives captured by standing on them together, Call to Arms, bounties on rival guilds, and a weekly war record.

Part of the RUIN addon suite. Requires **RUIN Core** (0.3.0 or later). With **RUIN Intel** installed, enemy sightings near an objective mark it contested and "under attack" calls show on your HUD.

## The experience
- **Where it lives:** the Warfront tab in the RUIN window (Objectives, Bounties, War record), the on-screen HUD, pins on the world map and minimap, `/wf`, and key bindings for Call to Arms and opening the page.
- **Objectives:** an officer stands somewhere that matters and presses *Mark objective here*. Everyone gets an alert; the HUD's arrow points to the nearest objective, and a radar shows the circle as you get close.
- **Capturing:** enough RUIN members inside the circle (2 by default) for 60 seconds take it. The guild with the most members present gets the credit.
- **Contested:** an Intel enemy sighting within about 300 yards of an objective marks it CONTESTED on the HUD, list and map for ten minutes.
- **Call to Arms:** one press (bind it to a Steam Deck back button) alerts the org with your position; their HUD and map point to you for two minutes.
- **Bounties:** officers post a bounty on a rival guild or player, with an optional reward. Kill one, target the body and press *Claim kill on target* (or `/wf claim`). Another RUIN member nearby confirms it (`/wf confirm` or the Confirm button); you can't confirm your own.
- **War record:** captures (3 points) and confirmed bounties (2 points) add up per guild and per player each week, starting Tuesday. Officers share the week's record with members who log in later.
- **Practice mode:** tick *Practice mode* or `/wf practice` to mark, capture and post bounties alone; practice items never leave your screen.
- **Commands:** `/wf mark <name>`, `/wf help`, `/wf hud`, `/wf pins`, `/wf practice`, `/wf quorum <n>`, `/wf bounty guild|player <name> (reward)`, `/wf claim`, `/wf confirm`.

## What it shares with RUIN
Objectives, your presence while you're inside an objective's circle (with your name, for capture credit), captures, Call to Arms with your position, bounties, kill claims with where they happened, confirmations, and the weekly record.

## Notes
Map pins are drawn on the map canvas and the minimap without changing Blizzard's map. The capture quorum, contest radius and points are first guesses for testing.
