# annas-fetch

A KOReader plugin to search and download books from [Anna's Archive](https://annas-archive.org) directly on your e-reader.

> **This is a maintained fork of [fischer-hub/annas.koplugin](https://github.com/fischer-hub/annas.koplugin).**
> Key fix: resolved the Lua namespace conflict with `zlibrary.koplugin` so both plugins can coexist.

Tested on Kindle Paperwhite 11th gen running KOReader.

---

## What's Different from the Original

- ✅ **Conflict fix**: Internal modules renamed from `zlibrary.*` → `annas.*` — both Anna's Archive and Z-Library plugins can be installed simultaneously without crashing
- ✅ **Fresh codebase**: Clean git history, actively maintained
- ✅ Version: `0.1.8-r1`

---

## Installation

1. Download the latest release zip from the [Releases](https://github.com/right9code/annas-fetch/releases) page
2. Extract and rename the folder to `annas.koplugin` (remove any version suffix)
3. Copy `annas.koplugin/` to `koreader/plugins/` on your device
4. Restart KOReader

> ⚠️ **If you have Z-Library plugin installed too** — this fork fixes the conflict. You do NOT need to remove either plugin.

---

## Usage

1. Open the KOReader file browser
2. Go to the **Search** menu → **Anna's Archive**
3. Type your search query, adjust language/format filters, and tap **Search**
4. Tap a result → tap **Format: (tap to download)** → confirm with **Download**

---

## DNS Note

On some devices Anna's Archive may fail to load. If you see "All protocols failed" or no results:
- Change your DNS to `1.1.1.1` (Cloudflare) — either in your router or device network settings

---

## Credits

- Original plugin: [fischer-hub/annas.koplugin](https://github.com/fischer-hub/annas.koplugin)
- UI/frontend inspired by: [ZlibraryKO/zlibrary.koplugin](https://github.com/ZlibraryKO/zlibrary.koplugin)
- Scraper backend inspired by: [KindleFetch](https://github.com/justrals/KindleFetch)

---

## License

GPL-3.0 — see [LICENSE](LICENSE)
