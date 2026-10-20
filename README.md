# levels

Per-app volume control in the Mac menu bar. I wanted FaceTime quieter so music and YouTube could sit at the same level as the call, and Background Music kept breaking on me.

Each app gets a slider from 0 to 200%: Chrome, Brave, Spotify, Discord, and so on. FaceTime and phone calls share one row. Settings are saved per app, so a level you set once applies to every call after that.

## Setup

Needs macOS 14.2+ and the Xcode command line tools. If you don't have the tools yet, run `xcode-select --install` first.

```
git clone https://github.com/rpandey672/levels.git
cd levels
./build.sh --install
```

That builds `Levels.app`, copies it to /Applications and launches it. Look for the slider icon in the menu bar. The first time you move a slider, macOS asks for System Audio Recording access. If you miss the prompt, turn Levels on under System Settings → Privacy & Security → Screen & System Audio Recording.

If you'd rather not use Terminal, double-click `Build Levels.command`. It does the same thing and writes the output to `build.log`.

`./build.sh` on its own builds into `build/` without installing.

### Signing

If you have a code signing identity in your keychain (a free Apple Development certificate from Xcode works), the build uses it. Otherwise it signs ad-hoc. Ad-hoc signatures change on every build, so macOS forgets the audio permission each time you rebuild and adjusted apps, including calls, go silent until you turn it back on.

## Using it

- Drag a slider to change an app's level, or click the speaker to mute it.
- Right-click a row to reset it to 100%. "Reset All" puts every app back.
- "Open at login" starts Levels when you log in.
- Only apps that are playing are listed. If an app doesn't show up, tick "Show all audio apps".

## How it works

It uses Core Audio process taps (14.2+) instead of a virtual audio driver.

- Moving an app off 100% creates a tap on that app's processes, which mutes it at the source.
- A private aggregate device plays the tapped audio back to your output at the new gain.
- Apps at 100% aren't touched.

Taps are owned by the app, so if Levels quits or crashes your audio goes back to normal. It follows output changes (AirPods, speakers) on its own. It also rebuilds the taps when Bluetooth headphones switch between normal and headset mode for a call, since the device keeps its ID but changes format.

Idle it uses about 13 MB, 0% CPU, and no timers. The audio thread for an adjusted app only runs while that app is actually playing. `Measure Levels.command` writes the running app's memory and CPU to `measure.log` if you want to check.

## Notes

- Adjusted apps always play through the default output device.
- Going above 100% boosts the app (about +12 dB at the top). A soft clipper stops it from crackling.
- Levels doesn't change your input device. With Bluetooth headphones, macOS uses their mic during calls, which drops them into lower-quality headset mode. FaceTime goes silent if you force the Mac mic instead.
