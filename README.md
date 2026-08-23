# VolumeBoostYT

A powerful iOS tweak that provides an independent, gesture-based volume control for the YouTube app, completely separate from the system volume.

## Features
- **Independent Audio Amplification:** Boost the YouTube internal volume up to 2000% (20x multiplier) without touching the iOS system volume.
- **Native Screen Edge Gesture:** Seamlessly swipe inwards from the right edge of the screen, then drag up and down to adjust the volume.
- **HUD Indicator:** Displays a temporary visual percentage overlay so you know exactly how loud the volume is.
- **Universal Hooking:** Instead of placing a bloated UI overlay over the screen, the tweak hooks directly into `- [UIWindow sendEvent:]` to mathematically intercept screen touches. This perfectly preserves YouTube's native fullscreen auto-rotation and layout behaviors.
- **In-App Settings Integration:** Enable or disable the tweak natively from within the YouTube Settings menu, integrated perfectly into the Shared "Tweaks" category.
- **Universal Compatibility:** Works seamlessly with AVPlayer, AVAudioPlayer, and modern AVSampleBufferAudioRenderer pipelines. Includes fallback logic to survive sideloading app-sandbox modifications like LiveContainer.

## Tested Environments
- **Rootless Jailbreak Targets:** Compatible with standard Theos build processes.
- **Sideloaded Targets:** Can be injected via tools like LiveContainer into decrypted YouTube IPAs.

## Installation (Self-Build via GitHub Actions)
To ensure you always have the latest version compiled from source, you can build the tweak yourself directly on GitHub without installing any local tools:

1. Click the **Fork** button at the top right of this repository to create your own copy.
2. Go to the **Actions** tab in your forked repository.
3. Click on the **"Build Tweak"** workflow on the left sidebar.
4. You may need to click a button that says *"I understand my workflows, go ahead and enable them"*.
5. Click **Run workflow** -> **Run workflow** (green button).
6. Wait 1-2 minutes for the virtual Mac to compile the code.
7. Go to the **Releases** tab on the right side of your forked repository.
8. Download the raw `.dylib` or `.deb` files directly from the latest generated release.

- Use the `.dylib` file to inject into YouTube IPAs via sideloading (LiveContainer, TrollStore, etc.)
- Use the `.deb` file to install on jailbroken rootless devices (Sileo, Zebra, etc.)

fixed the issue where the volume boost didn’t apply across the videos
