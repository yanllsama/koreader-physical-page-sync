<p align="center">
  <img src="Reader_Sari Yuz - R. F. Kuang.epub_p.png" alt="Hata Ekranı">
</p>

# KOReader Physical Page Sync (Ninja Engine v4)

A non-destructive KOReader User Patch that synchronizes e-reader page turns with the actual physical pages of a printed book. If you care about reading statistics and tracking the real number of pages you have read, this patch is designed for you!

Tired of the default "1 screen = 1 page" or the generic 1500 characters per page (cpp) calculation? This patch dynamically links your screen turns to the printed book's actual page count, perfectly handles reading durations, and survives KOReader updates without touching core files.

## Features

* **Zero-Touch User Patch Architecture:** Does NOT overwrite any core KOReader or plugin files. It loads safely into memory at runtime and survives KOReader updates without breaking.
* **True Physical Page Count:** Aligns the bottom progress bar, reading statistics, and database records to the exact page count of the printed book.
* **Smart Ninja Engine v4:** Accurately maps screen turns to physical pages. Intermediate reading durations between multiple screen turns are accumulated and recorded into the correct physical page without losing a single second.
* **Instant 0-Second Startup:** Precalculates and caches the optimal synthetic page layout (CPP), eliminating the 5–10 second freeze on book open.
* **Font Size Lock & Protection:** Once synchronized, your font size is locked to prevent accidental pinch-to-zoom or layout changes from disrupting your page ratio. Unlock anytime with a single tap from the menu.
* **Full Book Map Integration:** Fixes the Book Map widget! Tick marks scale 1:1 to physical pages, TOC chapters and reading position arrows align properly, and tapping a tick takes you to the exact page in the book.
* **Optional Multilingual Support:** Clean, standard gettext English base with an optional drop-in Turkish localization patch (1-physical-page-sync-custom-locale.lua).
* **One-Tap Reset:** Restore KOReader's default pagination settings for any book instantly.

## Installation

No file replacing, no backing up main.lua! Installing is as simple as dragging and dropping files into your patches/ folder:

1. Connect your e-reader to your computer via USB (or SSH/SFTP).
2. Open your KOReader directory:
   * **Kindle:** `extensions/koreader/patches/` (or `koreader/patches/`)
   * **Kobo:** `.koreader/patches/`
   * **Android / Other:** `koreader/patches/`
   *(If the patches directory doesn't exist, simply create a new folder named patches)*.
3. Copy `2-physical-page-sync.lua` into the `patches/` folder.
4. Restart KOReader.

## Usage

1. **Set Your Preferred Font Size First:** When opening a book for the first time, choose your desired font size and layout. Wait a brief moment for KOReader to finish background page recalculation for the new font.
2. Open the top menu and navigate to the **Reading Statistics** tab.
3. Tap on **Physical Page Sync** and make sure it is set to **Active (On)**.
4. Tap **1. Enter Page Count**, type in the total physical pages of your printed edition, and select **"Calculate & Save"**.
5. The patch will instantly compute the optimal ratio, auto-lock the font size, and lock your reading progress bar to the printed book!

### Useful Menu Actions:
* **Lock Font Size:** Toggle font protection on or off to freely adjust font size when needed.
* **2. Sync for Font Size:** If you change your font size later on, wait for the book to re-render, then tap this to re-calibrate the screen-to-page ratio for the new font.
* **3. Enter Manual Ratio:** Set a custom tap multiplier if preferred (e.g., 56 for 0.56 taps per page).
* **4. Reset All Settings:** Clears all custom physical page parameters for the current book and restores default KOReader pagination.

## License

This project inherits the GNU AGPLv3 license from the original KOReader project. All original credits go to the KOReader development team.
