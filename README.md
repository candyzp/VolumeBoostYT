# VolumeBoostYT

Volume boost controls for the YouTube app on iOS.

## Features
- Middle-right inward swipe drops a compact notch from the top; continue the same swipe up or down to adjust boost
- The notch updates as you drag, hides shortly after release, and can be dismissed with a rightward swipe
- Shake mode toggles the larger panel and its manual boost slider open and closed
- Right Side and Shake gesture modes
- Adjustable shake sensitivity with cooldown protection
- Optional haptic feedback when a gesture activates
- One-time middle-right edge hint on first launch
- Animated top controls; the larger shake panel has an early-close button
- Volume range from 0% to 2000%
- Saves and restores the selected boost level
- Reapplies the selected level when playback changes, ends, or loops
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
