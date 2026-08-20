# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

This repository is in the pre-implementation stage. It currently contains only:
- `README.md` — one-line project description
- `LICENSE` — MIT
- `design/mockups/devialet_tray_flyout_mockup.html` — a static, standalone HTML/CSS/JS mockup of the widget UI (open it directly in a browser; no build step)

There is no KDE Plasma widget code, build system, packaging (`metadata.json`, `contents/`, CMake, etc.), or test suite yet. Don't assume a Plasmoid project layout exists — check the current file tree before referencing paths, and don't invent build/lint/test commands that aren't present in the repo.

## What this project is

A KDE Plasma widget (system tray flyout) that acts as a remote control for a Devialet Expert Pro amplifier (e.g. Expert 140 Pro) over the local network. Core interactions, per the mockup:
- Discover and switch between multiple amplifiers on the network
- Show connection state, IP, and volume (in dB, roughly -60 to -15 range) with a slider/stepper and scroll-to-adjust support
- Mute / power toggle
- Select input source (Optical, UPnP, Roon Ready, AirPlay, Spotify, etc.)
- A settings pane (blur background, reduce motion, volume step size, launch at login)

## Companion Android app

Comments in the mockup's JS (`design/mockups/devialet_tray_flyout_mockup.html`) reference resolution logic mirrored from an existing Android app (`MainActivity.kt`, `AmpModelNameResolver`) that is **not** part of this repository:
- Each amplifier has a `udpName` (from a UDP status broadcast, always available once discovered) and an optional `modelName` (resolved later via mDNS).
- Display name falls back to `udpName` when `modelName` hasn't resolved yet.

When implementing real discovery/naming logic, replicate this same fallback behavior rather than inventing a different resolution strategy, since it's meant to match the existing Android client's behavior.

## Working with the mockup

`design/mockups/devialet_tray_flyout_mockup.html` is a self-contained design reference (fonts loaded from Google Fonts, inline CSS/JS, mock in-memory data for amplifiers/sources) — it simulates a KDE system tray icon and its flyout panel in a browser, not the real widget runtime. Treat it as the visual/interaction spec (styling tokens, layout, state transitions like amp list / source list expansion and the settings view swap) when building the actual Plasma widget, not as code to be reused as-is.

## KDE Plasma Widget Basis
- Based on an Android app developed in Kotlin.
- The Android app is available in repo: https://github.com/ekmanch/devialet-expert-remote