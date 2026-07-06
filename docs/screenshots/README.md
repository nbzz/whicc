# Screenshots & Demos

This directory hosts README-facing visual assets. **All files here are
referenced from the root `README.md`** — when you add a new asset, update
README.md to point at it.

## File convention

| File | Type | Recommended size | Purpose |
|---|---|---|---|
| `demo.png` | Static screenshot | ≤ 600 KB | Hero shot — main subtitle overlay on a video |
| `demo.gif` | Animation | ≤ 1.5 MB (GitHub README size limit is 10 MB but smaller = faster load) | ~15s loop showing live translation cycling |

If you want per-feature screenshots later (e.g. `settings.png`, `glossary.png`),
follow the same `<feature>.png` convention.

## How to capture

### Static screenshot
1. Run `whicc.app`
2. Open any foreign-language video (YouTube / 直播 etc.) — `demo.png`
   should show the bilingual subtitle clearly
3. `⌘⇧4` → drag region over the subtitle area (avoid capturing personal
   content like browser tabs)
4. Crop / compress with `sips -Z 1600 file.png` (down to 1600px max
   dimension)
5. Save as `docs/screenshots/demo.png`

### Animated GIF
1. Run `whicc.app` over a foreign-language video
2. Record with macOS `⌘⇧5` → "Record Selected Portion" → 15 seconds
3. Convert to GIF with ffmpeg:
   ```bash
   ffmpeg -i input.mov -vf "fps=15,scale=1200:-1" \
     -loop 0 -t 15 docs/screenshots/demo.gif
   ```
4. Verify with `gifsicle --info demo.gif` (target < 1.5 MB)

## Don't commit

- Personal / identifying content (browser tabs, browser bookmarks)
- Personal LAN URLs (e.g. `http://192.168.1.42:1234`) — the screenshot
  should show generic placeholder URLs
