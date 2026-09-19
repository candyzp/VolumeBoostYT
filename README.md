# VolumeBoostYT

Volume boost controls for the YouTube app on iOS.

## Features
- Double tap, hold, and slide vertically to adjust boost
- Optional shake gesture that opens a manual boost slider
- Double Tap & Slide, Shake, Both, and Off gesture modes
- Adjustable shake sensitivity with cooldown protection
- Animated top volume boost indicator
- Volume range from 100% to 2000%
- Saves and restores the selected boost level
- Reapplies the selected level when playback changes
- Native YouTube settings integration
- Supports AVPlayer, AVAudioPlayer, AVAudioPlayerNode, and AVSampleBufferAudioRenderer

## Building
1. Fork the repo.
2. Open the **Actions** tab.
3. Select **Build Tweak**.
4. Enable workflows if GitHub asks.
5. Run the workflow.
6. When it finishes, open the latest release.
7. Download the `.dylib` or `.deb`.

The `.dylib` can be used for sideloaded YouTube builds. The `.deb` is for rootless jailbreak installs.
