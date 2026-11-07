# Octofury

One-button Berserker Stance DPS rotation for Fury warriors on the 1.12 client, tuned to Octowow's (Turtle) spell data.

## Install

Put this folder in `Interface/AddOns/` and make sure it's named `Octofury` (rename it if you downloaded a zip, which adds `-main`).

## Use

Bind `/dps` to a key with a macro and spam it in combat. Use `/dps sunder` to run the same rotation plus Sunder Armor whenever it's a DPS gain.

| Priority | Notes |
| --- | --- |
| Pummel | Interrupts casters when a cast is detected |
| Cooldowns | Trinkets, racials, Death Wish and Avatar, when the fight is worth it |
| Battle Shout | Refreshed in the last 3 seconds |
| Execute | Target at 20% health or below; Bloodthirst instead when it does more |
| Bloodthirst / Whirlwind | Bloodthirst first on one target, Whirlwind first on 2+ |
| Slam | Two-hander only, right after a main-hand swing |
| Berserker Rage | Filler, only with Improved Berserker Rage |

Bloodrage and Heroic Strike/Cleave are off the GCD and are used alongside the above when there's rage to spare.

## Commands

| Command | What it does |
| --- | --- |
| `/dps` | Run the rotation |
| `/dps sunder` | Run the rotation with Sunder Armor |
| `/dps aoe [on\|off\|auto]` | AoE mode; `auto` counts how many mobs Whirlwind/Cleave hit |
| `/dps hs <rage>` | Minimum rage to queue Heroic Strike/Cleave (default 40) |
| `/dps cds smart\|always\|elite\|boss\|off` | When to use cooldowns (default `smart`) |
| `/dps trinkets\|pummel\|shout\|sit\|slam\|debug [on\|off]` | Toggle a feature |
| `/dps sitlog [reset]` | Show or clear the log of sitting to take crits |
| `/dps procs [reset]` | Show or clear the Enrage / Blood Craze proc log |
| `/dps status` | Show current settings and detected talents |

`/octofury` works the same as `/dps`.

## Optional

If the [Fury](https://github.com/cubenicke/Fury) addon is installed, its `/fury aoe` setting also forces AoE mode here.
