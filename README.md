# VolumeBoostYT

Volume boost controls for the YouTube app on iOS.

## Features
- Middle-right edge swipe opens and closes the Volume Boost control
- Swipe again during the transition to reverse it from its current position
- Shake mode opens the manual boost slider
- Right Side and Shake gesture modes
- Adjustable shake sensitivity with cooldown protection
- Optional haptic feedback when a gesture activates
- One-time middle-right edge hint on first launch
- Animated top Volume Boost control with an early-close button
- Volume range from 0% to 2000%
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
