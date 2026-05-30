<p align="center">
  <img src="Reader_Sari Yuz - R. F. Kuang.epub_p.png" alt="Hata Ekranı">
</p>

# KOReader Physical Page Sync (yanllsama)

A custom modification for the official KOReader `statistics.koplugin` that synchronizes e-reader page turns with the actual physical pages of a printed book. If you care about statistics and the real number of pages you have read, just like I do, this modification is for you!

If you are tired of the default "1 screen = 1 page" or the generic 1500 characters per page (cpp) calculation, this mod dynamically calculates the page ratio based on your font size and locks your reading progress to the real book's page count.

*(Note: This mod is still in the testing phase. We will continue to improve the project and fix any bugs that may arise with your valuable feedback.)*

## ✨ Features
* **True Physical Page Count:** Lock the bottom progress bar and reading statistics to the exact number of pages in the printed version of your book.
* **Smart Ninja Engine:** Automatically calculates how many screen taps (page turns) equal one physical page based on your current font size and formatting.
* **Google Books Integration:** Fetch the physical page count directly from Google Books API using the book's metadata.
* **Reset Anytime:** Easily revert back to KOReader's default synthetic page calculation with a single tap.

## ⚙️ Installation
This mod replaces the default `main.lua` file inside the statistics plugin folder. **Always backup your original file first!**

1. Connect your e-reader to your computer via USB (or SSH).
2. Navigate to your KOReader installation directory.
3. Go to `koreader/plugins/statistics.koplugin/`.
4. Locate the existing `main.lua` file and rename it to `main.lua.bak` (This is your backup).
5. Download the `main.lua` from this repository and place it inside the `statistics.koplugin` folder.
6. Restart KOReader.

## 🚀 Usage
1. Open any book in KOReader.
2. Open the top menu and go to the **Reading Statistics** tab.
3. Tap on **⚙️ Physical Page Sync** and set it to **Active**.
4. Choose your preferred method:
   * **1. Manual Entry:** Enter the exact page count from your physical copy.
   * **2. Fetch from Web:** Let the plugin find the page count via Google Books.
5. **Important Tip:** If you change your font size or style, wait a short while for the reader to finish re-rendering the pages. Then, return to the menu and select **"3. Sync for Font Size"** to update the data.
6. Confirm the prompt. The plugin will instantly recalculate the optimal characters-per-page (cpp) ratio and lock your pages!

## 📜 License
This project inherits the GNU AGPLv3 license from the original KOReader project. All original credits go to the KOReader development team.
