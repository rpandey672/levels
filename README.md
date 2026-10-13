# levels

Per-app volume control in the Mac menu bar. I wanted FaceTime quieter so music and YouTube could sit at the same level as the call, and Background Music kept breaking on me.

Each app gets a slider from 0 to 200%: Chrome, Brave, Spotify, Discord, and so on. FaceTime and phone calls share one row. Settings are saved per app, so a level you set once applies to every call after that.

## Build

Needs macOS 14.2+ and the Xcode command line tools.

```
./build.sh --install
```

That builds `Levels.app`, copies it to /Applications and launches it. The first time you move a slider, macOS asks for System Audio Recording access.

## How it works

It uses Core Audio process taps (14.2+) instead of a virtual audio driver.

- Moving an app off 100% creates a tap on that app's processes, which mutes it at the source.
- A private aggregate device plays the tapped audio back to your output at the new gain.
- Apps at 100% aren't touched.

Taps are owned by the app, so if Levels quits or crashes your audio goes back to normal. It follows output changes (AirPods, speakers) on its own.

Idle it uses about 13 MB, 0% CPU, and no timers. The audio thread for an adjusted app only runs while that app is actually playing.

## Notes

- Adjusted apps always play through the default output device.
- Going above 100% boosts the app (about +12 dB at the top). A soft clipper stops it from crackling.
- If an app doesn't show up, tick "Show all audio apps".
