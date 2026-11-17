# Original High-Resolution Artwork & Screenshots

This directory preserves the untouched high-resolution source masters for icons, remote hardware illustrations, and onboarding screenshots outside `Resources/`.

Runtime bundles (`Remote Buddy.app` and `RemoteBuddyMic.driver`) consume the pre-optimized static assets in `Resources/`, keeping the shipped application and installer lightweight without requiring build-time image processing tools.

## Runtime export policy

Reduce pixel dimensions only where the UI does not need the source resolution. Resize PNGs directly from these masters with Lanczos resampling, retain RGB/RGBA color and full alpha, and encode the result as lossless PNG. Do not apply palette quantization or reduced-color exports. Keep unchanged-size assets and JPEGs byte-for-byte identical to their masters rather than applying additional lossy compression. Keep the complete icon size set.
