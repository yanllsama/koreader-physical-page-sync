--[[--
    2-physical-page-sync.lua
    Ninja Engine v4 + Physical Page Sync + Font Size Lock + Book Map Repair
    KOReader User Patch

    This patch dynamically extends KOReader's builtin 'statistics.koplugin' and
    'bookmapwidget' in memory without modifying core files:
    - Physical page synchronization for reflowable (EPUB, etc.) books (Ninja Engine v4)
    - Multi-screen reading time aggregation into accurate physical page statistics
    - Instant smart CPP caching on book open (zero-second delay)
    - Font size lock while physical page sync is active (prevents accidental changes)
    - Full physical page tick marks on book map and accurate tap navigation
    - Safe query engine preventing SQLite strftime("%s", "now") crashes
--]]--

local logger = require("logger")
logger.info("PhysicalPageSync: Initializing patch...")

local BD = require("ui/bidi")
local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local KeyValuePage = require("ui/widget/keyvaluepage")
local Math = require("optmath")
local datetime = require("datetime")
local ffiUtil = require("ffi/util")
local util = require("util")
local _ = require("gettext")
local T = ffiUtil.template
local N_ = _.ngettext

local db_location = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
local MAX_PAGETURNS_BEFORE_FLUSH = 1

local STATISTICS_SQL_BOOK_CAPPED_TOTALS_QUERY = [[
    SELECT count(*),
           sum(durations)
    FROM (
        SELECT min(sum(duration), %d) AS durations
        FROM page_stat
        WHERE id_book = %d
        GROUP BY page
    );
]]

local STATISTICS_SQL_BOOK_TOTALS_QUERY = [[
    SELECT count(DISTINCT page),
           sum(duration)
    FROM   page_stat
    WHERE  id_book = %d;
]]

-- =============================================================================
-- 1. Font Size Locking and Protection Engine Helpers
-- =============================================================================

local last_font_lock_notify_time = 0
local function showFontLockedNotification()
    local now = os.time()
    if (now - last_font_lock_notify_time) >= 2 then
        last_font_lock_notify_time = now
        local UIManager = require("ui/uimanager")
        local Notification = require("ui/widget/notification")
        local _ = require("gettext")
        UIManager:show(Notification:new{
            text = _("🔒 Font size locked! (Physical page sync active)\nUnlock from Statistics menu to change."),
        })
    end
end

local function isFontLocked(ui)
    if not ui or not ui.doc_settings then return false end
    local sync_enabled = ui.doc_settings:readSetting("yanllsama_sync_enabled")
    if sync_enabled == false then return false end
    local font_locked = ui.doc_settings:readSetting("yanllsama_font_locked")
    if font_locked == true then return true end
    if font_locked == false then return false end
    local phys_pages = ui.doc_settings:readSetting("yanllsama_physical_pages")
    if phys_pages and tonumber(phys_pages) and tonumber(phys_pages) > 0 then
        return true
    end
    return false
end

local function installFontProtection(statistics_instance)
    local ui = statistics_instance and statistics_instance.ui

    -- 1. Hook ReaderFont (onSetFontSize, onChangeSize, onIncreaseFontSize, onDecreaseFontSize)
    local ok_font, ReaderFont = pcall(require, "apps/reader/modules/readerfont")
    if ok_font and ReaderFont then
        if not ReaderFont._yanllsama_orig_onSetFontSize then
            ReaderFont._yanllsama_orig_onSetFontSize = ReaderFont.onSetFontSize
            ReaderFont.onSetFontSize = function(self_font, size)
                local font_ui = self_font.ui or (self_font.view and self_font.view.ui) or ui
                if isFontLocked(font_ui) then
                    local locked_size = font_ui and font_ui.doc_settings and font_ui.doc_settings:readSetting("yanllsama_locked_font_size")
                    if locked_size and self_font.configurable then
                        self_font.configurable.font_size = locked_size
                    elseif self_font.configurable and self_font.configurable.font_size then
                        if font_ui and font_ui.doc_settings then
                            font_ui.doc_settings:saveSetting("yanllsama_locked_font_size", self_font.configurable.font_size)
                        end
                    end
                    showFontLockedNotification()
                    return true
                end
                return ReaderFont._yanllsama_orig_onSetFontSize(self_font, size)
            end
        end

        if not ReaderFont._yanllsama_orig_onChangeSize then
            ReaderFont._yanllsama_orig_onChangeSize = ReaderFont.onChangeSize
            ReaderFont.onChangeSize = function(self_font, delta)
                local font_ui = self_font.ui or (self_font.view and self_font.view.ui) or ui
                if isFontLocked(font_ui) then
                    showFontLockedNotification()
                    return true
                end
                return ReaderFont._yanllsama_orig_onChangeSize(self_font, delta)
            end
        end

        if not ReaderFont._yanllsama_orig_onIncreaseFontSize then
            ReaderFont._yanllsama_orig_onIncreaseFontSize = ReaderFont.onIncreaseFontSize
            ReaderFont.onIncreaseFontSize = function(self_font, ges)
                local font_ui = self_font.ui or (self_font.view and self_font.view.ui) or ui
                if isFontLocked(font_ui) then
                    showFontLockedNotification()
                    return true
                end
                return ReaderFont._yanllsama_orig_onIncreaseFontSize(self_font, ges)
            end
        end

        if not ReaderFont._yanllsama_orig_onDecreaseFontSize then
            ReaderFont._yanllsama_orig_onDecreaseFontSize = ReaderFont.onDecreaseFontSize
            ReaderFont.onDecreaseFontSize = function(self_font, ges)
                local font_ui = self_font.ui or (self_font.view and self_font.view.ui) or ui
                if isFontLocked(font_ui) then
                    showFontLockedNotification()
                    return true
                end
                return ReaderFont._yanllsama_orig_onDecreaseFontSize(self_font, ges)
            end
        end

        if ui and ui.font then
            ui.font.onSetFontSize = ReaderFont.onSetFontSize
            ui.font.onChangeSize = ReaderFont.onChangeSize
            ui.font.onIncreaseFontSize = ReaderFont.onIncreaseFontSize
            ui.font.onDecreaseFontSize = ReaderFont.onDecreaseFontSize
        end
    end

    -- 2. Hook ReaderCoptListener (prevents ConfigDialog ConfigChange event from altering document.configurable.font_size)
    local ok_copt, ReaderCoptListener = pcall(require, "apps/reader/modules/readercoptlistener")
    if ok_copt and ReaderCoptListener then
        if not ReaderCoptListener._yanllsama_orig_onConfigChange then
            ReaderCoptListener._yanllsama_orig_onConfigChange = ReaderCoptListener.onConfigChange
            ReaderCoptListener.onConfigChange = function(self_copt, option_name, option_value)
                local copt_ui = self_copt.ui or (self_copt.view and self_copt.view.ui) or ui
                if option_name == "font_size" and isFontLocked(copt_ui) then
                    local locked_size = copt_ui and copt_ui.doc_settings and copt_ui.doc_settings:readSetting("yanllsama_locked_font_size")
                    if locked_size and self_copt.document and self_copt.document.configurable then
                        self_copt.document.configurable.font_size = locked_size
                    end
                    showFontLockedNotification()
                    return true
                end
                return ReaderCoptListener._yanllsama_orig_onConfigChange(self_copt, option_name, option_value)
            end
        end

        if ui and ui.crelistener then
            ui.crelistener.onConfigChange = ReaderCoptListener.onConfigChange
        end
    end
end
-- ==========================================


-- =============================================================================
-- 2. ReaderStatistics Method Extensions (Ninja Engine v4)
-- =============================================================================
local function patchReaderStatistics(ReaderStatistics)
    if not ReaderStatistics or rawget(ReaderStatistics, "_ninja_patch_applied") then
        return
    end
    rawset(ReaderStatistics, "_ninja_patch_applied", true)
    logger.info("PhysicalPageSync: Patching ReaderStatistics methods with Ninja Engine v4...")


-- === FLAWLESS SYNC ENGINE ===
function ReaderStatistics:applyPerfectSync(physical_pages, force_recalc)
    local document = self.document
    local doc_settings = self.ui.doc_settings
    
    local pagemap = (self.view and self.view.pagemap) or (self.ui and self.ui.pagemap)
    
    local result_pages = physical_pages
    local cpp = 1500
    
    -- Check if precalculated synthetic page value exists
    local saved_cpp = doc_settings:readSetting("pagemap_chars_per_synthetic_page")
    local saved_phys = doc_settings:readSetting("pagemap_doc_pages")
    
    if not force_recalc and saved_cpp and saved_phys == physical_pages then
        -- Load instantly without binary search on book open (reduces wait time to 0s)
        cpp = saved_cpp
        if document and document.buildSyntheticPageMap and (not document.hasPageMap or not document:hasPageMap()) then
            document:buildSyntheticPageMap(cpp)
        end
    elseif document and document.buildSyntheticPageMap then
        -- Calculate only when a new page count is entered or value is absent
        local lo, hi = 100, 10000
        local best_diff = math.huge
        local best_cpp = 1500
        
        -- Quick estimate
        document:buildSyntheticPageMap(1500)
        local est = document.getPageMap and #document:getPageMap() or physical_pages
        if est > 0 then
            local ratio_guess = math.floor(1500 * est / physical_pages)
            lo = math.max(100, ratio_guess - 2000)
            hi = ratio_guess + 2000
        end
        
        while lo <= hi do
            local mid = math.floor((lo + hi) / 2)
            document:buildSyntheticPageMap(mid)
            result_pages = document.getPageMap and #document:getPageMap() or physical_pages
            local diff = math.abs(result_pages - physical_pages)
            if diff < best_diff then
                best_diff = diff
                best_cpp = mid
                cpp = mid
            end
            if result_pages == physical_pages then
                break
            elseif result_pages < physical_pages then
                hi = mid - 1
            else
                lo = mid + 1
            end
        end
        -- Apply best cpp value
        document:buildSyntheticPageMap(cpp)
        result_pages = document.getPageMap and #document:getPageMap() or physical_pages
    end

    -- Save to KOReader settings
    doc_settings:saveSetting("pagemap_chars_per_synthetic_page", cpp)
    doc_settings:saveSetting("pagemap_use_page_labels", true)
    doc_settings:saveSetting("show_page_overlap_marker", true)
    
    if pagemap then
        pagemap.chars_per_synthetic_page = cpp
        pagemap.use_page_labels = true
        pagemap.page_labels_cache = nil
        if not pagemap.has_pagemap then
            pagemap.has_pagemap = true
            if self.view and self.view.registerViewModule then
                pcall(function()
                    self.view:registerViewModule("pagemap", pagemap)
                end)
            end
        end
    end
    
    doc_settings:saveSetting("pagemap_doc_pages", physical_pages)
    if self.data then self.data.pages = physical_pages end
    
    local total_screens = document and document:getPageCount() or physical_pages
    local calculated_ratio = (total_screens / physical_pages)
    calculated_ratio = math.floor(calculated_ratio * 100 + 0.5) / 100
    doc_settings:saveSetting("yanllsama_screen_ratio", calculated_ratio)
    -- Automatically lock font size after sync
    doc_settings:saveSetting("yanllsama_font_locked", true)
    local cur_size = (self.ui and self.ui.font and self.ui.font.configurable and self.ui.font.configurable.font_size)
        or (document and document.configurable and document.configurable.font_size)
    if cur_size then
        doc_settings:saveSetting("yanllsama_locked_font_size", cur_size)
    end
    self._yanllsama_phys_label_prev = nil
    self._phys_curr = nil
    self._phys_next = nil

    return calculated_ratio
end

function ReaderStatistics:promptEnterPhysicalPages()
    local SpinWidget = require("ui/widget/spinwidget")
    local InfoMessage = require("ui/widget/infomessage")
    local UIManager = require("ui/uimanager")
    local Event = require("ui/event")
    
    if self.ui.doc_settings:readSetting("yanllsama_sync_enabled") == false then
        UIManager:show(InfoMessage:new{ text = _("Please set the module to 'Active' first."), timeout = 3 })
        return
    end
    
    local default_val = self.ui.doc_settings:readSetting("yanllsama_physical_pages") or (self.data and self.data.pages) or 1
    UIManager:show(SpinWidget:new{
        value = default_val, value_min = 1, value_max = 15000,
        ok_text = _("Calculate & Save"),
        title_text = _("Physical Page Count"),
        callback = function(spin)
            local physical_pages = spin.value
            self.ui.doc_settings:saveSetting("yanllsama_physical_pages", physical_pages)
            self.ui.doc_settings:saveSetting("yanllsama_sync_prompt_dismissed", true)
            
            local calculated_ratio = self:applyPerfectSync(physical_pages, true)
            
            if type(self.resetLayout) == "function" then self:resetLayout() end
            if self.view and type(self.view.refresh) == "function" then self.view:refresh() end
            UIManager:broadcastEvent(Event:new("UsePageLabelsUpdated"))
            
            UIManager:show(InfoMessage:new{ 
                text = string.format(_("Fixed pages locked!\nRatio: %.2f taps per page.\nFont auto-locked."), calculated_ratio), 
                timeout = 4 
            })
        end,
    })
end

function ReaderStatistics:initData()
    self.is_doc = true

    -- If book was marked complete at e.g. 265 pages,
    -- setting physical pages to 384 keeps it complete and stats freeze without this check!
    local summary = self.ui.doc_settings:readSetting("summary")
    local physical_pages = self.ui.doc_settings:readSetting("yanllsama_physical_pages")
    if physical_pages and summary.status == "complete" then
        if self.ui.paging and self.ui.paging.current_page and self.ui.paging.current_page < self.ui.document:getPageCount() then
            summary.status = "reading"
            self.ui.doc_settings:saveSetting("summary", summary)
        end
    end

    self.is_doc_not_finished = summary.status ~= "complete"
    self.is_doc_not_frozen = self.is_doc_not_finished or not self.settings.freeze_finished_books

    local book_properties = self.ui.doc_props
    self.data.title = book_properties.display_title
    self.data.authors = book_properties.authors or "N/A"
    self.data.language = book_properties.language or "N/A"
    local series
    if book_properties.series then
        series = book_properties.series
        if book_properties.series_index then
            series = series .. " #" .. book_properties.series_index
        end
    end
    self.data.series = series or "N/A"

    -- ==========================================
    -- ==========================================
    local physical_pages = self.ui.doc_settings:readSetting("yanllsama_physical_pages")
    if physical_pages then
        self.data.pages = physical_pages
        _G.yanllsama_current_physical_pages = physical_pages
        if self.document and self.document.getPageCount and physical_pages > 0 then
            self:applyPerfectSync(physical_pages)
        end
    else
        self.data.pages = self.document:getPageCount()
        _G.yanllsama_current_physical_pages = nil
    end

    local BookStatusWidget = require("ui/widget/bookstatuswidget")
    if not BookStatusWidget._yanllsama_orig_getStatReadPages then
        BookStatusWidget._yanllsama_orig_getStatReadPages = BookStatusWidget.getStatReadPages
        BookStatusWidget.getStatReadPages = function(this)
            local p = this.ui and this.ui.doc_settings and this.ui.doc_settings:readSetting("yanllsama_physical_pages")
            local stats_book = this.ui and this.ui.statistics and this.ui.statistics:getStatsBookStatus() or {}
            if p and stats_book.pages then
                return string.format("%s/%s", stats_book.pages, p)
            end
            return this:_yanllsama_orig_getStatReadPages()
        end
    end
    -- ==========================================
    -- Book Map Physical Page Synchronization
    -- Exactly physical_pages ticks are rendered on the map,
    -- TOC (chapters), bookmarks, ▲ pointer are scaled to physical pages,
    -- Tapping a page on the map correctly translates to the CRE screen page.
    -- ==========================================
    local function getPageConverters(ui, physical_pages)
        local doc = ui and ui.document
        local native_count = doc and doc.getPageCount and doc:getPageCount() or physical_pages
        local pmap = nil
        if doc and doc.getPageMap then
            pcall(function() pmap = doc:getPageMap() end)
        end
        local pmap_valid = pmap and #pmap > 0

        local function cre_to_phys(cre_p)
            if not cre_p or cre_p <= 0 then return 1 end
            if cre_p > native_count then return physical_pages end
            if pmap_valid then
                local lo, hi = 1, #pmap
                local ans = 1
                while lo <= hi do
                    local mid = math.floor((lo + hi) / 2)
                    if pmap[mid].page <= cre_p then
                        ans = mid
                        lo = mid + 1
                    else
                        hi = mid - 1
                    end
                end
                local lbl = tonumber(pmap[ans].label and pmap[ans].label:match("%d+"))
                return math.max(1, math.min(physical_pages, lbl or ans))
            else
                local ratio = native_count / physical_pages
                return math.max(1, math.min(physical_pages, math.floor((cre_p - 1) / ratio) + 1))
            end
        end

        local function phys_to_cre(phys_p)
            if not phys_p or phys_p <= 0 then return 1 end
            if phys_p >= physical_pages then
                if pmap_valid and pmap[#pmap] and pmap[#pmap].page then
                    return pmap[#pmap].page
                end
                return native_count
            end
            if pmap_valid then
                if pmap[phys_p] and pmap[phys_p].page then
                    return pmap[phys_p].page
                else
                    for i = 1, #pmap do
                        local lbl = tonumber(pmap[i].label and pmap[i].label:match("%d+"))
                        if lbl == phys_p then
                            return pmap[i].page
                        end
                    end
                    local ratio = native_count / physical_pages
                    return math.max(1, math.min(native_count, math.floor((phys_p - 1) * ratio) + 1))
                end
            else
                local ratio = native_count / physical_pages
                return math.max(1, math.min(native_count, math.floor((phys_p - 1) * ratio) + 1))
            end
        end

        return cre_to_phys, phys_to_cre
    end

    local BookMapWidget = require("ui/widget/bookmapwidget")
    if not BookMapWidget._yanllsama_orig_update then
        BookMapWidget._yanllsama_orig_update = BookMapWidget.update
        BookMapWidget.update = function(self_bm, ...)
            local doc_settings = self_bm.ui and self_bm.ui.doc_settings
            local phys_pages = doc_settings and doc_settings:readSetting("yanllsama_physical_pages")
            local sync_enabled = doc_settings and doc_settings:readSetting("yanllsama_sync_enabled")
            if sync_enabled == nil then sync_enabled = true end

            if phys_pages and sync_enabled and phys_pages > 0 and self_bm.ui and self_bm.ui.document then
                local cre_to_phys, phys_to_cre = getPageConverters(self_bm.ui, phys_pages)
                self_bm._yanllsama_active = true
                self_bm._yanllsama_phys_to_cre = phys_to_cre
                self_bm._yanllsama_cre_to_phys = cre_to_phys

                -- 1. Match total tick count to physical page count (e.g., 750)
                local orig_nb_pages = self_bm.nb_pages
                self_bm.nb_pages = phys_pages

                -- 2. Map current reading location (▲ pointer) to physical tick
                local orig_cur_page = self_bm.cur_page
                local orig_focus_page = self_bm.focus_page
                local phys_cur_page = cre_to_phys(orig_cur_page or (self_bm.ui.toc and self_bm.ui.toc.pageno))
                self_bm.cur_page = phys_cur_page
                if not orig_focus_page or orig_focus_page == orig_cur_page then
                    self_bm.focus_page = phys_cur_page
                else
                    self_bm.focus_page = cre_to_phys(orig_focus_page)
                end

                -- 3. Scale Table of Contents (TOC) to physical page range
                local orig_toc = self_bm.ui.toc and self_bm.ui.toc.toc
                local mapped_toc = nil
                if orig_toc then
                    mapped_toc = {}
                    for idx, item in ipairs(orig_toc) do
                        local cloned = {}
                        for k, v in pairs(item) do cloned[k] = v end
                        cloned.page = cre_to_phys(item.page)
                        mapped_toc[idx] = cloned
                    end
                    self_bm.ui.toc.toc = mapped_toc
                end

                -- 4. Map bookmarks and previous/next locations to physical pages
                local orig_bookmarks = self_bm.bookmarked_pages
                local mapped_bookmarks = {}
                if orig_bookmarks then
                    for cre_p, v in pairs(orig_bookmarks) do
                        mapped_bookmarks[cre_to_phys(cre_p)] = v
                    end
                    self_bm.bookmarked_pages = mapped_bookmarks
                end

                local orig_prev_loc = self_bm.previous_locations
                local mapped_prev_loc = {}
                if orig_prev_loc then
                    for cre_p, v in pairs(orig_prev_loc) do
                        mapped_prev_loc[cre_to_phys(cre_p)] = v
                    end
                    self_bm.previous_locations = mapped_prev_loc
                end

                local orig_next_loc = self_bm.next_locations
                local mapped_next_loc = {}
                if orig_next_loc then
                    for cre_p, v in pairs(orig_next_loc) do
                        mapped_next_loc[cre_to_phys(cre_p)] = v
                    end
                    self_bm.next_locations = mapped_next_loc
                end

                local orig_pinned = self_bm.pinned_page
                if orig_pinned then
                    self_bm.pinned_page = cre_to_phys(orig_pinned)
                end

                -- 5. Clear page labels so row headers display physical page numbers
                local orig_page_labels = self_bm.page_labels
                self_bm.page_labels = nil

                -- 6. read_pages from DB is already keyed 1..phys_pages, mapping 1:1 to ticks
                local res = self_bm:_yanllsama_orig_update(...)

                -- Restore original references
                if orig_toc then self_bm.ui.toc.toc = orig_toc end
                self_bm.page_labels = orig_page_labels
                return res
            else
                self_bm._yanllsama_active = false
                return self_bm:_yanllsama_orig_update(...)
            end
        end
    end

    if not BookMapWidget._yanllsama_orig_onTap then
        BookMapWidget._yanllsama_orig_onTap = BookMapWidget.onTap
        BookMapWidget.onTap = function(self_bm, arg, ges)
            if not self_bm._yanllsama_active or not self_bm._yanllsama_phys_to_cre then
                return BookMapWidget._yanllsama_orig_onTap(self_bm, arg, ges)
            end

            if ges.pos:notIntersectWith(self_bm.cropping_widget.dimen) then
                return true
            end
            local x, y = ges.pos.x, ges.pos.y
            local row, row_idx, row_y, row_h = self_bm:getVGroupRowAtY(y - self_bm.title_bar_h)
            if not row then
                return true
            end
            local page = row.toc_item_page
            if not page and row.start_page then
                local BD = require("ui/bidi")
                if BD.mirroredUILayout() then
                    x = x - self_bm.scrollbar_width
                end
                page = row:getPageAtX(x, true)
            end
            if page then
                -- Convert physical page to CRE screen page before navigating!
                local cre_page = self_bm._yanllsama_phys_to_cre(page)
                local G_reader_settings = _G.G_reader_settings
                local Event = require("ui/event")
                local UIManager = require("ui/uimanager")
                if (self_bm.overview_mode and G_reader_settings and G_reader_settings:isFalse("book_map_overview_tap_to_page_browser"))
                    or (not self_bm.overview_mode and G_reader_settings and G_reader_settings:isFalse("book_map_tap_to_page_browser")) then
                    self_bm:onClose(true)
                    self_bm.ui.link:addCurrentLocationToStack()
                    self_bm.ui:handleEvent(Event:new("GotoPage", cre_page))
                    return true
                end
                local PageBrowserWidget = require("ui/widget/pagebrowserwidget")
                UIManager:show(PageBrowserWidget:new{
                    launcher = self_bm,
                    ui = self_bm.ui,
                    focus_page = cre_page,
                })
            end
            return true
        end
    end

    if not BookMapWidget._yanllsama_orig_onGoToFocusedPage then
        BookMapWidget._yanllsama_orig_onGoToFocusedPage = BookMapWidget.onGoToFocusedPage
        BookMapWidget.onGoToFocusedPage = function(self_bm)
            if not self_bm._yanllsama_active or not self_bm._yanllsama_phys_to_cre then
                return BookMapWidget._yanllsama_orig_onGoToFocusedPage(self_bm)
            end
            if not self_bm.enable_focus_navigation or not self_bm.cur_focused_widget then
                return true
            end
            local target_page = nil
            local row = self_bm:getVGroupRowAtY(self_bm.cur_focused_widget.dimen.y - self_bm.title_bar_h)
            if row and row.start_page and row.focus_layout then
                local invisible_page_slots = row.focus_layout[#row.focus_layout]
                if type(invisible_page_slots) == "table" then
                    for i, widget in ipairs(invisible_page_slots) do
                        if widget == self_bm.cur_focused_widget then
                            target_page = row.start_page + i - 1
                            break
                        end
                    end
                end
                if not target_page then
                    for _, sub_layout in ipairs(row.focus_layout) do
                        if type(sub_layout) == "table" then
                            for i, widget in ipairs(sub_layout) do
                                if widget == self_bm.cur_focused_widget then
                                    target_page = row.start_page + i - 1
                                    break
                                end
                            end
                        end
                    end
                end
            end
            if target_page then
                local cre_page = self_bm._yanllsama_phys_to_cre(target_page)
                local G_reader_settings = _G.G_reader_settings
                local should_go_to_page_browser = false
                if G_reader_settings then
                    if self_bm.overview_mode then
                        should_go_to_page_browser = G_reader_settings:isFalse("book_map_overview_tap_to_page_browser")
                    else
                        should_go_to_page_browser = G_reader_settings:isFalse("book_map_tap_to_page_browser")
                    end
                end
                if should_go_to_page_browser then
                    local PageBrowserWidget = require("ui/widget/pagebrowserwidget")
                    local UIManager = require("ui/uimanager")
                    UIManager:show(PageBrowserWidget:new{
                        launcher = self_bm,
                        ui = self_bm.ui,
                        focus_page = cre_page,
                    })
                else
                    local Event = require("ui/event")
                    self_bm:onClose(true)
                    self_bm.ui.link:addCurrentLocationToStack()
                    self_bm.ui:handleEvent(Event:new("GotoPage", cre_page))
                end
                return true
            end
            return true
        end
    end

    -- ==========================================
    -- Font Size Locking Protection
    -- ==========================================
    installFontProtection(self)
    if isFontLocked(self.ui) then
        local locked_size = self.ui.doc_settings:readSetting("yanllsama_locked_font_size")
        local cur_size = (self.ui.font and self.ui.font.configurable and self.ui.font.configurable.font_size)
            or (self.document and self.document.configurable and self.document.configurable.font_size)
        if not locked_size and cur_size then
            self.ui.doc_settings:saveSetting("yanllsama_locked_font_size", cur_size)
        elseif locked_size and cur_size and cur_size ~= locked_size then
            if self.ui.font and self.ui.font.configurable then
                self.ui.font.configurable.font_size = locked_size
            end
            if self.document and self.document.configurable then
                self.document.configurable.font_size = locked_size
            end
        end
    end
    -- ==========================================
    self.data.highlights, self.data.notes = self.ui.annotation:getNumberOfHighlightsAndNotes()
    self.id_curr_book = self:getIdBookDB()
    if not self.id_curr_book then return end
    
    -- ==========================================
    -- Database Update (Persist physical pages in DB)
    -- ==========================================
    if physical_pages then
        local SQ3 = require("sq3")
        local db_location = self.settings.db_file
        if db_location then
            local conn = SQ3.open(db_location)
            if conn then
                conn:exec(string.format("UPDATE book SET pages = %d WHERE id = %d;", physical_pages, self.id_curr_book))
                conn:close()
            end
        end
    end
    -- ==========================================

    self.book_read_pages, self.book_read_time = self:getPageTimeTotalStats(self.id_curr_book)
    if self.book_read_pages > 0 then
        self.avg_time = self.book_read_time / self.book_read_pages
    else
        self.avg_time = math.floor(0.50 * self.settings.max_sec)
        logger.dbg("ReaderStatistics: Initializing average time per page at 50% of the max value, i.e.,", self.avg_time)
    end
end

function ReaderStatistics:onDocumentRerendered()
    local new_pagecount = self.document:getPageCount()

    -- ==========================================
    -- Physical Page Lock (2)
    -- ==========================================
    local physical_pages = self.ui.doc_settings:readSetting("yanllsama_physical_pages")
    if physical_pages then
        new_pagecount = physical_pages
    end
    -- ==========================================

    if new_pagecount ~= self.data.pages then
        logger.dbg("ReaderStatistics: Pagecount change, flushing volatile book statistics")
        self:insertDB(new_pagecount)
    end

    self.data.pages = new_pagecount
    -- Reset Ninja Engine v4 caches after rerender
    self._yanllsama_pagemap_list = nil
    self._yanllsama_phys_label_prev = nil
end

function ReaderStatistics:resetVolatileStats(now_ts)
    -- Computed by onPageUpdate
    self.pageturn_count = 0
    self.mem_read_time = 0
    self.mem_read_pages = 0

    -- Volatile storage pending flush to db
    self.page_stat = {}

    -- Re-seed the volatile stats with minimal data about the current page.
    -- If a timestamp is passed, it's the caller's responsibility to ensure that self.curr_page is accurate.
    if now_ts then
        -- Ninja Engine v4: When sync_enabled, the correct key is the physical page number
        -- In Pagemap mode use getCurrentPageLabel(); otherwise estimate via ratio.
        local stat_key = self.curr_page
        if self.ui and self.ui.doc_settings then
            local se = self.ui.doc_settings:readSetting("yanllsama_sync_enabled")
            if se == nil then se = true end
            if se and type(self.curr_page) == "number" then
                if self._phys_next then
                    stat_key = self._phys_next
                elseif self._phys_curr then
                    stat_key = self._phys_curr
                else
                    -- Check if pagemap mode is active
                    local use_pm = self.ui.pagemap and self.ui.pagemap.has_pagemap
                                   and self.ui.pagemap.use_page_labels
                    if use_pm then
                        local lbl = self.ui.pagemap:getCurrentPageLabel(true)
                        local phys = lbl and tonumber(lbl)
                        if phys then
                            stat_key = phys
                        end
                    else
                        local ratio   = self.ui.doc_settings:readSetting("yanllsama_screen_ratio") or 1.0
                        if self.ui.doc_settings:readSetting("pagemap_chars_per_synthetic_page") then ratio = 1.0 end
                        local max_phys = (self.ui.doc_settings:readSetting("yanllsama_physical_pages"))
                                         or (self.data and self.data.pages) or 9999
                        if ratio < 1.0 then
                            stat_key = math.max(1, math.min(max_phys, math.floor((self.curr_page - 1) / ratio + 1.5)))
                        else
                            stat_key = math.max(1, math.min(max_phys, math.ceil(self.curr_page / ratio)))
                        end
                    end
                end
            end
        end
        self.page_stat[stat_key] = { { now_ts, 0 } }
        if not self._yanllsama_screen_last_ts then
            self._yanllsama_screen_last_ts = now_ts
        end
    else
        self._yanllsama_screen_last_ts = nil
        self._yanllsama_phys_curr_acc_dur = nil
    end
end

function ReaderStatistics:getStatsBookStatus()
    if not (self.settings.is_enabled and self.id_curr_book) then return end
    self:insertDB()
    local conn = SQ3.open(db_location)
    local sql_stmt = [[
        SELECT count(*)
        FROM   (
                    SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') AS dates
                    FROM   page_stat
                    WHERE  id_book = %d
                    GROUP  BY dates
               );
    ]]
    local total_days = conn:rowexec(string.format(sql_stmt, self.id_curr_book))
    local total_read_pages, total_time_book = conn:rowexec(string.format(STATISTICS_SQL_BOOK_TOTALS_QUERY, self.id_curr_book))
    conn:close()

    total_read_pages = tonumber(total_read_pages) or 0
    local p = self.ui and self.ui.doc_settings and self.ui.doc_settings:readSetting("yanllsama_physical_pages")
    if p then
        if total_read_pages > p then total_read_pages = p end
    end

    return {
        days = tonumber(total_days),
        time = tonumber(total_time_book) or 0,
        pages = total_read_pages,
    }
end

function ReaderStatistics:insertDB(updated_pagecount)
    if not (self.id_curr_book and self.is_doc_not_frozen) then
        return
    end
    local id_book = self.id_curr_book
    local now_ts = os.time()

    -- The current page stat, having yet no duration, will be ignored
    -- in the insertion, and its start ts would be lost. We'll give it
    -- to resetVolatileStats() so it can restore it
    local cur_page_start_ts = now_ts
    -- When sync_enabled, page_stat is keyed by physical numbers;
    -- curr_page is screen number so calculate the correct key.
    local _stat_curr_key = self.curr_page
    do
        local ratio = self.ui and self.ui.doc_settings and
            self.ui.doc_settings:readSetting("yanllsama_screen_ratio")
        local se = self.ui and self.ui.doc_settings and
            self.ui.doc_settings:readSetting("yanllsama_sync_enabled")
        if se == nil then se = true end
        if se and type(self.curr_page) == "number" then
            if self._phys_next then
                _stat_curr_key = self._phys_next
            elseif self._phys_curr then
                _stat_curr_key = self._phys_curr
            else
                local use_pm = self.ui.pagemap and self.ui.pagemap.has_pagemap
                               and self.ui.pagemap.use_page_labels
                if use_pm then
                    local lbl = self.ui.pagemap:getCurrentPageLabel(true)
                    local phys = lbl and tonumber(lbl)
                    if phys then
                        _stat_curr_key = phys
                    end
                else
                    local max_phys = (self.ui.doc_settings:readSetting("yanllsama_physical_pages"))
                                     or (self.data and self.data.pages) or 9999
                    ratio = ratio or 1.0
                    if ratio < 1.0 then
                        _stat_curr_key = math.max(1, math.min(max_phys, math.floor((self.curr_page - 1) / ratio + 1.5)))
                    else
                        _stat_curr_key = math.max(1, math.min(max_phys, math.ceil(self.curr_page / ratio)))
                    end
                end
            end
        end
    end
    local cur_page_data = self.page_stat[_stat_curr_key]
    local cur_page_data_tuple = cur_page_data and cur_page_data[#cur_page_data]
    if cur_page_data_tuple and cur_page_data_tuple[2] == 0 then -- should always be true
        cur_page_start_ts = cur_page_data_tuple[1]
    end

    local conn = SQ3.open(db_location)
    conn:exec('BEGIN;')
    local stmt = conn:prepare("INSERT OR IGNORE INTO page_stat_data VALUES(?, ?, ?, ?, ?);")
    for page, data_list in pairs(self.page_stat) do
        for _, data_tuple in ipairs(data_list) do
            -- See self.page_stat declaration above about the tuple's layout
            local ts = data_tuple[1]
            local duration = data_tuple[2]
            -- Skip placeholder durations
            if duration > 0 then
                -- NOTE: The fact that we update self.data.pages *after* this call on layout changes
                --       should ensure that it matches the layout in which said data was collected.
                --       Said data is used to re-scale page numbers, regardless of the document layout,
                --       at query time, via a fancy SQL view.
                --       This allows the progress tracking to be accurate even in the face of wild
                --       document layout changes (e.g., after font size changes).
                stmt:reset():bind(id_book, page, ts, duration, self.data.pages):step()
            end
        end
    end
    conn:exec('COMMIT;')

    -- Update the new pagecount now, so that subsequent queries against the view are accurate
    local sql_stmt = [[
        UPDATE book
        SET    pages = ?
        WHERE  id = ?;
    ]]
    stmt = conn:prepare(sql_stmt)
    -- If physical page lock is active, ignore updated_pagecount and preserve lock
    local physical_pages_lock = self.ui and self.ui.doc_settings and
        self.ui.doc_settings:readSetting("yanllsama_physical_pages")
    local effective_pagecount = physical_pages_lock or (updated_pagecount and updated_pagecount or self.data.pages)
    stmt:reset():bind(effective_pagecount, id_book):step()

    -- NOTE: See the tail end of the discussions in #6761 for more context on the choice of this heuristic.
    --       Basically, we're counting distinct pages,
    --       while making sure the sum of durations per distinct page is clamped to self.settings.max_sec
    --       This is expressly tailored to a fairer computation of self.avg_time ;).
    local book_read_pages, book_read_time = conn:rowexec(string.format(STATISTICS_SQL_BOOK_CAPPED_TOTALS_QUERY, self.settings.max_sec, id_book))
    -- NOTE: What we cache in the book table is the plain uncapped sum (mainly for deleteBooksByTotalDuration's benefit)...
    local total_read_pages, total_read_time = conn:rowexec(string.format(STATISTICS_SQL_BOOK_TOTALS_QUERY, id_book))

    -- And now update the rest of the book table...
    sql_stmt = [[
        UPDATE book
        SET    last_open = ?,
               notes = ?,
               highlights = ?,
               total_read_time = ?,
               total_read_pages = ?
        WHERE  id = ?;
    ]]
    stmt = conn:prepare(sql_stmt)
    stmt:reset():bind(now_ts, self.data.notes, self.data.highlights, total_read_time, total_read_pages, id_book):step()
    stmt:close()
    conn:close()

    -- NOTE: On the other hand, this is used for the average time estimate, so we use the capped variants here!
    if book_read_pages then
        self.book_read_pages = tonumber(book_read_pages)
    else
        self.book_read_pages = 0
    end
    if book_read_time then
        self.book_read_time = tonumber(book_read_time)
    else
        self.book_read_time = 0
    end
    self.avg_time = self.book_read_time / self.book_read_pages

    self:resetVolatileStats(cur_page_start_ts)
end

function ReaderStatistics:getCurrentStat()
    self:insertDB()
    local id_book = self.id_curr_book
    local today_duration, today_pages = self:getTodayBookStats()
    local current_duration, current_pages = self:getCurrentBookStats()

    local conn = SQ3.open(db_location)
    local highlights, notes = conn:rowexec(string.format("SELECT highlights, notes FROM book WHERE id = %d;", id_book))
    local sql_stmt = [[
        SELECT count(*)
        FROM   (
                    SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') AS dates
                    FROM   page_stat
                    WHERE  id_book = %d
                    GROUP  BY dates
               );
    ]]
    local total_days = conn:rowexec(string.format(sql_stmt, id_book))

    sql_stmt = [[
        SELECT sum(duration),
               count(DISTINCT page),
               min(start_time)
        FROM   page_stat
        WHERE  id_book = %d;
    ]]
    local total_time_book, total_read_pages, first_open = conn:rowexec(string.format(sql_stmt, id_book))
    conn:close()

    local __, book_read_time = self:getPageTimeTotalStats(id_book)
    local now_ts = os.time()

    total_time_book = tonumber(total_time_book) or 0
    total_read_pages = tonumber(total_read_pages) or 0
    first_open = first_open or now_ts
    
    local physical_pages = self.ui.doc_settings:readSetting("yanllsama_physical_pages")
    if physical_pages then
        self.data.pages = physical_pages
        if total_read_pages > physical_pages then total_read_pages = physical_pages end
    else
        self.data.pages = self.document:getPageCount()
    end

    local current_page
    local total_pages
    local page_progress_string
    local percent_read
    if self.ui.pagemap and self.ui.pagemap:wantsPageLabels() then
        current_page = self.ui:getCurrentPage()
        total_pages = self.data.pages
        local current_page_label, current_page_idx, total_pages_idx = self.ui.pagemap:getCurrentPageLabel()
        local last_page_label = self.ui.pagemap:getLastPageLabel()
        percent_read = Math.round(100*current_page_idx/total_pages_idx)
        page_progress_string = ("%s / %s (%d%%)"):format(current_page_label, last_page_label, percent_read)
    elseif self.document:hasHiddenFlows() then
        current_page = self.ui:getCurrentPage()
        local flow = self.document:getPageFlow(current_page)
        current_page = self.document:getPageNumberInFlow(current_page)
        total_pages = self.document:getTotalPagesInFlow(flow)
        percent_read = Math.round(100*current_page/total_pages)
        if flow == 0 then
            page_progress_string = ("%d // %d (%d%%)"):format(current_page, total_pages, percent_read)
        else
            page_progress_string = ("[%d / %d]%d (%d%%)"):format(current_page, total_pages, flow, percent_read)
        end
    else
        current_page = self.ui:getCurrentPage()
        
        if physical_pages then
            local ratio = self.ui.doc_settings:readSetting("yanllsama_screen_ratio") or 1
            if self.ui.doc_settings:readSetting("pagemap_chars_per_synthetic_page") then ratio = 1.0 end
            current_page = math.max(1, math.ceil(current_page / ratio))
            if current_page > physical_pages then current_page = physical_pages end
        end

        total_pages = self.data.pages
        percent_read = Math.round(100*current_page/total_pages)
        page_progress_string = ("%d / %d (%d%%)"):format(current_page, total_pages, percent_read)
    end

    local first_open_days_ago = math.floor(tonumber(now_ts - first_open)/86400)
    local time_to_read = current_page and ((total_pages - current_page) * self.avg_time) or 0
    local estimate_days_to_read = math.ceil(time_to_read/(book_read_time/tonumber(total_days)))
    local estimate_end_of_read_date = datetime.secondsToDate(tonumber(now_ts + estimate_days_to_read * 86400), true)
    local estimates_valid = time_to_read > 0
    local user_duration_format = G_reader_settings:readSetting("duration_format", "classic")
    local avg_page_time_string = datetime.secondsToClockDuration(user_duration_format, self.avg_time, false)
    local avg_day_time_string = datetime.secondsToClockDuration(user_duration_format, book_read_time/tonumber(total_days), false)
    local time_to_read_string = estimates_valid and datetime.secondsToClockDuration(user_duration_format, time_to_read, false) or _("N/A")

    local more_arrow = BD.mirroredUILayout() and "◂" or "▸"

    local estimated_popup = function()
        UIManager:show(InfoMessage:new{
            text = T(N_("There is 1 page (%2%) left to read.", "There are %1 pages (%2%) left to read.", total_pages - current_page), total_pages - current_page, 100 - percent_read) ..
                "\n\n" .. T(_("At the current rate of %1 per page, that will take %2 of reading time."), avg_page_time_string, time_to_read_string) ..
                "\n\n" .. T(N_("At the current rate of %1 per day, that will take 1 day.", "At the current rate of %1 per day, that will take %2 days.", estimate_days_to_read), avg_day_time_string, estimate_days_to_read),
            icon = "book.opened"
        })
    end

    local estimated_time_left, estimated_finish_date
    if self.is_doc_not_frozen then
        estimated_time_left = { _("Estimated reading time left") .. " ⓘ", time_to_read_string, callback = estimated_popup }
        estimated_finish_date = { _("Estimated finish date") .. " ⓘ", estimates_valid and T(N_("(in 1 day) %2", "(in %1 days) %2", estimate_days_to_read), estimate_days_to_read, estimate_end_of_read_date) or _("N/A"), callback = estimated_popup }
    else
        estimated_time_left = { _("Estimated reading time left"), _("finished") }
        local mark_date = self.ui.doc_settings:readSetting("summary").modified
        estimated_finish_date = { _("Book marked as finished"), datetime.secondsToDate(datetime.stringToSeconds(mark_date), true) }
    end
    estimated_time_left.separator = true
    estimated_finish_date.separator = true

    return {
        { _("Time spent reading this session"), datetime.secondsToClockDuration(user_duration_format, current_duration, false) },
        { _("Pages read this session"), tonumber(current_pages), separator = true },

        { _("Time spent reading today") .. " " .. more_arrow, datetime.secondsToClockDuration(user_duration_format, today_duration, false),
            callback = function()
                local CalendarView = require("calendarview")
                local title_callback = function(this)
                    return T(_("Today (%1)"), datetime.secondsToDate(now_ts, true))
                end
                CalendarView:showCalendarDayView(self, title_callback)
            end,
        },
        { _("Pages read today"), tonumber(today_pages), separator = true },

        { _("Total time spent on this book"), datetime.secondsToClockDuration(user_duration_format, total_time_book, false) },
        { _("Time spent reading"), datetime.secondsToClockDuration(user_duration_format, book_read_time, false) },
        estimated_time_left,

        { _("Days reading this book") .. " " .. more_arrow, tonumber(total_days),
            callback = function()
                local kv = self.kv
                UIManager:close(self.kv)
                self.kv = KeyValuePage:new{
                    title = T(_("Days reading %1"), self.data.title),
                    value_overflow_align = "right",
                    kv_pairs = self:getDatesForBook(id_book),
                    callback_return = function()
                        UIManager:show(kv)
                        self.kv = kv
                    end,
                    close_callback = function() self.kv = nil end,
                }
                UIManager:show(self.kv)
            end,
        },
        { _("Average time per day"), avg_day_time_string, separator = true },

        { _("Book start date"), T(N_("(1 day ago) %2", "(%1 days ago) %2", first_open_days_ago), first_open_days_ago, datetime.secondsToDate(tonumber(first_open), true)) },
        estimated_finish_date,

        { _("Current page/Total pages"), page_progress_string },
        { _("Pages read"), string.format("%d (%d%%)", total_read_pages, Math.round(100*total_read_pages/self.data.pages)) },
        { _("Average time per page"), avg_page_time_string, separator = true },

        { _("Book highlights"), tonumber(highlights) },
        { _("Book notes"), tonumber(notes) },
    }
end

function ReaderStatistics:getBookStat(id_book)
    if id_book == nil then return end
    local conn = SQ3.open(db_location)
    local sql_stmt = [[
        SELECT title, authors, pages, last_open, highlights, notes
        FROM book
        WHERE id = %d;
    ]]
    local title, authors, pages, last_open, highlights, notes = conn:rowexec(string.format(sql_stmt, id_book))

    highlights = highlights and tonumber(highlights) or "?"
    notes = notes and tonumber(notes) or "?"

    sql_stmt = [[
        SELECT count(*)
        FROM   (
                    SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') AS dates
                    FROM   page_stat
                    WHERE  id_book = %d
                    GROUP  BY dates
               );
    ]]
    local total_days = conn:rowexec(string.format(sql_stmt, id_book))

    sql_stmt = [[
        SELECT sum(duration),
               count(DISTINCT page),
               min(start_time),
               (select max(ps2.page) from page_stat as ps2 where ps2.start_time = max(page_stat.start_time))
        FROM   page_stat
        WHERE  id_book = %d;
    ]]
    local total_time_book, total_read_pages, first_open, last_page = conn:rowexec(string.format(sql_stmt, id_book))
    conn:close()

    local book_read_pages, book_read_time = self:getPageTimeTotalStats(id_book)
    local now_ts = os.time()

    if total_time_book == nil then total_time_book = 0 end
    if total_read_pages == nil then total_read_pages = 0 end
    if first_open == nil then first_open = now_ts end
    total_time_book = tonumber(total_time_book)
    total_read_pages = tonumber(total_read_pages)
    last_page = tonumber(last_page) or 0
    pages = tonumber(pages) or 1

    -- ==========================================
    -- Physical Page Lock for Past Books
    -- ==========================================
    local physical_pages = nil
    local ratio = 1
    
    if self.id_curr_book and id_book == self.id_curr_book and self.ui and self.ui.doc_settings then
        physical_pages = self.ui.doc_settings:readSetting("yanllsama_physical_pages")
        ratio = self.ui.doc_settings:readSetting("yanllsama_screen_ratio") or 1
        if self.ui.doc_settings:readSetting("pagemap_chars_per_synthetic_page") then ratio = 1.0 end
    end

    if physical_pages then
        pages = physical_pages
        last_page = math.max(1, math.ceil(last_page / ratio))
        if last_page > pages then last_page = pages end
        
        if total_read_pages > pages then total_read_pages = pages end
    end
    -- ==========================================

    local first_open_days_ago = math.floor(tonumber(now_ts - first_open)/86400)
    local last_open_days_ago = math.floor(tonumber(now_ts - last_open)/86400)
    local avg_time_per_page = book_read_time / book_read_pages
    local user_duration_format = G_reader_settings:readSetting("duration_format")
    local more_arrow = BD.mirroredUILayout() and "◂" or "▸"
    return {
        { _("Title"), title},
        { _("Author(s)"), authors, separator = true },
        { _("Total time spent on this book"), datetime.secondsToClockDuration(user_duration_format, total_time_book, false) },
        { _("Time spent reading"), datetime.secondsToClockDuration(user_duration_format, book_read_time, false), separator = true },
        { _("Days reading this book") .. " " .. more_arrow, tonumber(total_days),
            callback = function()
                local kv = self.kv
                UIManager:close(self.kv)
                self.kv = KeyValuePage:new{
                    title = T(_("Days reading %1"), title),
                    value_overflow_align = "right",
                    kv_pairs = self:getDatesForBook(id_book),
                    callback_return = function()
                        UIManager:show(kv)
                        self.kv = kv
                    end,
                    close_callback = function() self.kv = nil end,
                }
                UIManager:show(self.kv)
            end,
        },
        { _("Average time per day"), datetime.secondsToClockDuration(user_duration_format, book_read_time/tonumber(total_days), false), separator = true },
        { _("Book start date"), T(N_("(1 day ago) %2", "(%1 days ago) %2", first_open_days_ago), first_open_days_ago, datetime.secondsToDate(tonumber(first_open), true)) },
        { _("Last read date"), T(N_("(1 day ago) %2", "(%1 days ago) %2", last_open_days_ago), last_open_days_ago, datetime.secondsToDate(tonumber(last_open), true)), separator = true },
        { _("Last read page/Total pages"), string.format("%d / %d (%d%%)", last_page, pages, Math.round(100*last_page/pages)) },
        { _("Pages read"), string.format("%d (%d%%)", total_read_pages, Math.round(100*total_read_pages/pages)) },
        { _("Average time per page"), datetime.secondsToClockDuration(user_duration_format, avg_time_per_page, false), separator = true },
        { _("Book highlights"), highlights },
        { _("Book notes"), notes },
    }
end

local function sqlDaily()
    return
    [[
            SELECT dates,
                   count(*)             AS pages,
                   sum(sum_duration)    AS durations,
                   start_time
            FROM   (
                        SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') AS dates,
                               sum(duration)                                                 AS sum_duration,
                               start_time
                        FROM   page_stat
                        WHERE  start_time >= %d
                        GROUP  BY id_book, page, dates
                   )
            GROUP  BY dates
            ORDER  BY dates DESC;
    ]]
end

local function sqlWeekly()
    return
    [[
            SELECT dates,
                   count(*)             AS pages,
                   sum(sum_duration)    AS durations,
                   start_time
            FROM   (
                        SELECT strftime('%%Y-%%W', start_time, 'unixepoch', 'localtime')     AS dates,
                               sum(duration)                                                 AS sum_duration,
                               start_time
                        FROM   page_stat
                        WHERE  start_time >= %d
                        GROUP  BY id_book, page, dates
                   )
            GROUP  BY dates
            ORDER  BY dates DESC;
    ]]
end

local function sqlMonthly()
    return
    [[
            SELECT dates,
                   count(*)             AS pages,
                   sum(sum_duration)    AS durations,
                   start_time
            FROM   (
                        SELECT strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime')     AS dates,
                               sum(duration)                                                 AS sum_duration,
                               start_time
                        FROM   page_stat
                        WHERE  start_time >= %d
                        GROUP  BY id_book, page, dates
                   )
            GROUP  BY dates
            ORDER  BY dates DESC;
    ]]
end

function ReaderStatistics:onPageUpdate(pageno)
    if not self:isEnabledAndNotFrozen() then
        return
    end

    if self._reading_paused_ts then
        self._reading_paused_curr_page = pageno
        return
    end

    if self.curr_page == pageno then
        return
    end

    local closing = false
    if pageno == false then
        closing = true
        pageno = self.curr_page
    end

    local is_pdf = false
    if self.document and self.document.file then
        is_pdf = string.match(string.lower(self.document.file), "%.pdf$") ~= nil
    end

    -- ==========================================
    -- Ninja Engine v4: Physical Page Synchronization
    --
    -- CORE PRINCIPLE:
    --   When pagemap mode (synthetic or real) is active:
    --     Read the physical page number directly shown by KOReader
    --     via getCurrentPageLabel(). This is much more accurate
    --     than binary search or global ratio estimates.
    --   When pagemap is absent: estimate via ratio (legacy behavior).
    --
    -- CACHE LOGIC:
    --   Read label on each call and cache as _yanllsama_phys_label_prev
    --   for the next invocation to serve as the previous physical page
    --   (phys_prev).
    -- ==========================================

    -- ---- Read Ninja Engine v4 settings ----
    local SCREENS_PER_PAGE = 1.0
    local sync_enabled = false
    local physical_pages_locked = nil
    local use_pagemap_mode = false
    if not is_pdf then
        local se = self.ui.doc_settings:readSetting("yanllsama_sync_enabled")
        if se == nil then se = true end
        sync_enabled = se
        if sync_enabled then
            SCREENS_PER_PAGE = self.ui.doc_settings:readSetting("yanllsama_screen_ratio") or 1.0
            if self.ui.doc_settings:readSetting("pagemap_chars_per_synthetic_page") then SCREENS_PER_PAGE = 1.0 end
            physical_pages_locked = self.ui.doc_settings:readSetting("yanllsama_physical_pages")
            -- If pagemap is active (synthetic or real), run in pagemap mode
            if self.ui.pagemap and self.ui.pagemap.has_pagemap and self.ui.pagemap.use_page_labels then
                use_pagemap_mode = true
            end
        end
    end

    -- ---- CRE to physical conversion helper for ratio mode (when pagemap absent) ----
    local function cre_to_phys_ratio(cre_pageno, max_phys)
        if SCREENS_PER_PAGE < 1.0 then
            return math.max(1, math.min(max_phys, math.floor((cre_pageno - 1) / SCREENS_PER_PAGE + 1.5)))
        else
            return math.max(1, math.min(max_phys, math.ceil(cre_pageno / SCREENS_PER_PAGE)))
        end
    end

    -- ---- Interim Screen Time Accumulation Helper ----
    -- NOTE: data_tuple[1] (start_time) is NEVER modified! It marks true page start.
    -- Intermediate screen reading times are accumulated in _yanllsama_phys_curr_acc_dur
    -- and recorded accurately in one pass when page completes or book closes.
    local function accumulate_screen_time(phys_page)
        local now_ts = os.time()
        local last_ts = self._yanllsama_screen_last_ts
        if not last_ts then
            local page_data = self.page_stat[phys_page]
            local data_tuple = page_data and page_data[#page_data]
            last_ts = data_tuple and data_tuple[1] or now_ts
        end
        local diff_time = now_ts - last_ts
        local valid_time = 0
        if diff_time > self.settings.max_sec then
            valid_time = self.settings.max_sec
        elseif diff_time > 0 then
            valid_time = diff_time
        end
        if valid_time > 0 then
            self._yanllsama_phys_curr_acc_dur = (self._yanllsama_phys_curr_acc_dur or 0) + valid_time
        end
        self._yanllsama_screen_last_ts = now_ts
    end

    -- ---- Ninja Engine v4: Pagemap mode ----
    -- getCurrentPageLabel() -> Page number SHOWN to user by KOReader.
    -- During onPageUpdate(pageno) getCurrentPageLabel() returns the NEW page.
    -- Use _yanllsama_phys_label_prev cache to retrieve previous physical page.
    if not is_pdf and not closing and sync_enabled and use_pagemap_mode then
        if type(self.curr_page) == "number" and self.curr_page > 0 then
            -- Read physical label of new page
            local lbl_now = nil
            local phys_now = nil
            if self.ui.pagemap then
                lbl_now = self.ui.pagemap:getCurrentPageLabel(true)
                phys_now = lbl_now and tonumber(lbl_now)
            end
            -- Previous page physical label (from cache)
            local phys_prev = self._yanllsama_phys_label_prev

            if phys_now and phys_prev then
                if phys_now == phys_prev then
                    -- Same physical page: only CRE screen changed. Accumulate time.
                    accumulate_screen_time(phys_prev)
                    self.curr_page = pageno
                    -- Update cache
                    self._yanllsama_phys_label_prev = phys_now
                    return
                end
                -- Physical page changed: mark for persistence
                self._phys_curr = phys_prev
                self._phys_next = phys_now
            elseif phys_now and not phys_prev then
                -- First transition: initialize cache timestamp
                -- (falls through to then_ts block)
                self._yanllsama_phys_label_prev = phys_now
            end
        end
    -- ---- Ninja Engine v4: Ratio mode (when pagemap absent) ----
    elseif not is_pdf and not closing and sync_enabled and not use_pagemap_mode then
        if type(self.curr_page) == "number" and self.curr_page > 0 then
            local max_phys_b = physical_pages_locked or self.data.pages or 9999
            if SCREENS_PER_PAGE >= 1.0 then
                -- Threshold mode: calculate physical page via global ratio
                local phys_prev = cre_to_phys_ratio(self.curr_page, max_phys_b)
                local phys_now  = cre_to_phys_ratio(pageno, max_phys_b)
                if phys_now == phys_prev then
                    -- Same physical page: accumulate screen time
                    accumulate_screen_time(phys_prev)
                    self.curr_page = pageno
                    return
                end
                self._phys_curr = phys_prev
                self._phys_next = phys_now
            else
                -- Multiplier mode (ratio < 1): multiple physical pages per screen
                local max_phys = max_phys_b
                local target_phys = cre_to_phys_ratio(pageno, max_phys)
                if not self._phys_curr_anchored then
                    self._phys_curr_anchored = cre_to_phys_ratio(self.curr_page, max_phys)
                end
                local curr_phys = self._phys_curr_anchored
                local next_phys = (target_phys > curr_phys) and target_phys or (curr_phys + 1)
                self._phys_curr_anchored = target_phys
                self._screen_pageno = pageno
                self._phys_curr     = curr_phys
                self._phys_next     = next_phys
            end
        end
    end

    self.pageturn_count = self.pageturn_count + 1
    local now_ts = os.time()

    -- ---- Determine page keys for recording ----
    -- Use physical page if sync_enabled and _phys_curr is set; else CRE screen.
    local stat_curr_page = self.curr_page
    local stat_next_page = pageno
    local max_phys_fb = physical_pages_locked or self.data.pages or 9999
    if sync_enabled then
        if self._phys_curr then
            stat_curr_page = self._phys_curr
            stat_next_page = self._phys_next
        else
            -- _phys_curr not set (first page, closing, or first pagemap transition)
            if use_pagemap_mode and self.ui.pagemap then
                -- In Pagemap mode: obtain physical page from label
                local lbl_fb = self.ui.pagemap:getCurrentPageLabel(true)
                local phys_fb = lbl_fb and tonumber(lbl_fb)
                if phys_fb then
                    stat_curr_page = phys_fb
                    stat_next_page = phys_fb
                end
            else
                stat_curr_page = cre_to_phys_ratio(self.curr_page, max_phys_fb)
                stat_next_page = cre_to_phys_ratio(pageno, max_phys_fb)
            end
        end
    end

    local page_data  = self.page_stat[stat_curr_page]
    local data_tuple = page_data and page_data[#page_data]
    local then_ts    = data_tuple and data_tuple[1]

    if not then_ts then
        logger.dbg("ReaderStatistics: No timestamp for previous page", stat_curr_page)
        -- Initial page opening: create timestamp for stat_next_page
        self.page_stat[stat_next_page] = { { now_ts, 0 } }
        self.curr_page = pageno
        self._yanllsama_screen_last_ts = now_ts
        self._yanllsama_phys_curr_acc_dur = 0
        -- Pagemap mode: initialize cache
        if use_pagemap_mode and self.ui.pagemap then
            local lbl_init = self.ui.pagemap:getCurrentPageLabel(true)
            self._yanllsama_phys_label_prev = lbl_init and tonumber(lbl_init)
        end
        self._phys_curr = nil
        self._phys_next = nil
        self._screen_pageno = nil
        self._baraj_page_ts = nil
        self._baraj_phys_page = nil
        self._phys_curr_anchored = nil
        self._phys_page_acc = nil
        return
    end

    -- Calculate elapsed time on the physical page's last screen
    local last_screen_ts = self._yanllsama_screen_last_ts or then_ts
    local last_screen_diff = now_ts - last_screen_ts
    local last_screen_valid = 0
    if last_screen_diff > self.settings.max_sec then
        last_screen_valid = self.settings.max_sec
    elseif last_screen_diff > 0 then
        last_screen_valid = last_screen_diff
    end

    -- Accumulated interim times + final screen time = Total physical page duration
    local total_page_time = (self._yanllsama_phys_curr_acc_dur or 0) + last_screen_valid
    local valid_time = 0
    if total_page_time >= self.settings.min_sec then
        valid_time = total_page_time
    end

    if valid_time > 0 then
        -- Distribute duration across physical page range
        local start_p, end_p
        if sync_enabled and self._phys_curr then
            start_p = self._phys_curr
            -- If jumping forward in any mode, allocate across skipped pages as well
            if self._phys_next and self._phys_next > self._phys_curr then
                end_p = self._phys_next - 1
            else
                end_p = self._phys_curr
            end
        else
            start_p = stat_curr_page
            end_p   = stat_curr_page
        end
        local pages_in_range = end_p - start_p + 1
        local time_per_page  = math.floor(valid_time / pages_in_range)
        local remainder      = valid_time - time_per_page * pages_in_range

        for p = start_p, end_p do
            local p_data = self.page_stat[p]
            if not p_data then
                p_data = { { then_ts, 0 } }
                self.page_stat[p] = p_data
            end
            local d_tuple = p_data[#p_data]
            local c_dur   = d_tuple[2]
            local allocated = time_per_page + (p == start_p and remainder or 0)
            if allocated > 0 then
                self.mem_read_time = self.mem_read_time + allocated
                if #p_data == 1 and c_dur == 0 then
                    self.mem_read_pages = self.mem_read_pages + 1
                end
                d_tuple[2] = c_dur + allocated
            end
        end
    end

    if closing then
        self._phys_curr = nil
        self._phys_next = nil
        self._screen_pageno = nil
        self._baraj_page_ts = nil
        self._baraj_phys_page = nil
        self._phys_curr_anchored = nil
        self._phys_page_acc = nil
        self._yanllsama_screen_last_ts = nil
        self._yanllsama_phys_curr_acc_dur = nil
        return
    end

    if self.pageturn_count >= MAX_PAGETURNS_BEFORE_FLUSH then
        self.pageturn_count = 0
        UIManager:tickAfterNext(function()
            self:insertDB()
        end)
    end

    if self.book_read_pages > 0 or self.mem_read_pages > 0 then
        self.avg_time = (self.book_read_time + self.mem_read_time) / (self.book_read_pages + self.mem_read_pages)
    end

    -- Update curr_page (always store CRE screen number)
    self.curr_page = pageno

    -- Pagemap mode: cache new page's physical label
    -- (used as phys_prev in subsequent onPageUpdate calls)
    if use_pagemap_mode and self.ui.pagemap then
        local lbl_next = self.ui.pagemap:getCurrentPageLabel(true)
        self._yanllsama_phys_label_prev = lbl_next and tonumber(lbl_next)
    end

    -- New entry timestamp for next page
    local new_page_data = self.page_stat[stat_next_page]
    if new_page_data then
        table.insert(new_page_data, { now_ts, 0 })
    else
        self.page_stat[stat_next_page] = { { now_ts, 0 } }
    end
    self._yanllsama_screen_last_ts = now_ts
    self._yanllsama_phys_curr_acc_dur = 0

    -- Clear temporary physical page variables
    self._phys_curr     = nil
    self._phys_next     = nil
    self._screen_pageno = nil
    self._baraj_page_ts = nil
end

function ReaderStatistics:onCloseDocument()
    self:onPageUpdate(false) -- update current page duration
    self:insertDB()
    -- Clear Ninja Engine v4 caches (reloaded on next book open)
    self._yanllsama_pagemap_list = nil
    self._yanllsama_phys_label_prev = nil
    self._yanllsama_screen_last_ts = nil
    self._yanllsama_phys_curr_acc_dur = nil
    _G.yanllsama_current_physical_pages = nil
end

function ReaderStatistics:onReadingResumed()
    if self:isEnabledAndNotFrozen() then
        if self._reading_paused_ts then
            -- Just add the pause duration to the current page start_time
            local pause_duration = os.time() - self._reading_paused_ts
            -- When sync_enabled, page_stat is keyed by physical page numbers
            local _pause_stat_key = self.curr_page
            if self.ui and self.ui.doc_settings then
                local se    = self.ui.doc_settings:readSetting("yanllsama_sync_enabled")
                if se == nil then se = true end
                if se and type(self.curr_page) == "number" then
                    -- 1. In Pagemap mode, obtain directly from label (most accurate key)
                    local use_pm = self.ui.pagemap and self.ui.pagemap.has_pagemap
                                   and self.ui.pagemap.use_page_labels
                    if use_pm then
                        local lbl = self.ui.pagemap:getCurrentPageLabel(true)
                        local phys = lbl and tonumber(lbl)
                        if phys then
                            _pause_stat_key = phys
                        end
                    elseif self._phys_curr then
                        _pause_stat_key = self._phys_curr
                    else
                        local max_phys = (self.ui.doc_settings:readSetting("yanllsama_physical_pages"))
                                         or (self.data and self.data.pages) or 9999
                        local ratio = self.ui.doc_settings:readSetting("yanllsama_screen_ratio") or 1.0
                        if ratio < 1.0 then
                            _pause_stat_key = math.max(1, math.min(max_phys, math.floor((self.curr_page - 1) / ratio + 1.5)))
                        else
                            _pause_stat_key = math.max(1, math.min(max_phys, math.ceil(self.curr_page / ratio)))
                        end
                    end
                end
            end
            local page_data = self.page_stat[_pause_stat_key]
            local data_tuple = page_data and page_data[#page_data]
            if data_tuple then
                data_tuple[1] = data_tuple[1] + pause_duration
            end
            -- Shift screen timer by sleep duration (prevents ghost blocks)
            if self._yanllsama_screen_last_ts then
                self._yanllsama_screen_last_ts = self._yanllsama_screen_last_ts + pause_duration
            end
            if self._reading_paused_curr_page and self._reading_paused_curr_page ~= self.curr_page then
                self._reading_paused_ts = nil
                self:onPageUpdate(self._reading_paused_curr_page)
                self._reading_paused_curr_page = nil
            end
        end
    end
    self._reading_paused_ts = nil
end

function ReaderStatistics:getCurrentBookReadPages()
    if not self:isEnabled() then return end
    self:insertDB()
    local sql_stmt = [[
        SELECT
          page,
          min(sum(duration), ?) AS durations,
          max(start_time) AS last_time
        FROM page_stat
        WHERE id_book = ?
        GROUP BY page
        ORDER BY page;
    ]]
    local conn = SQ3.open(db_location)
    local stmt = conn:prepare(sql_stmt)
    local res, nb = stmt:reset():bind(self.settings.max_sec, self.id_curr_book):resultset("i")
    stmt:close()
    conn:close()
    local read_pages = {}
    local max_duration = 0
    local now_ts = os.time()
    for i=1, nb do
        local page, duration, last_time = res[1][i], res[2][i], res[3][i]
        page = tonumber(page)
        duration = tonumber(duration)
        local delay = now_ts - (tonumber(last_time) or now_ts)
        read_pages[page] = {duration, delay}
        if duration > max_duration then
            max_duration = duration
        end
    end
    for page, info in pairs(read_pages) do
        -- Make the value a duration ratio (vs capped or max duration)
        read_pages[page][1] = info[1] / max_duration
    end



    return read_pages
end

-- Reconnect toggle statistics switch
function ReaderStatistics:onToggleStatistics(enable)
    if enable ~= nil and enable == self.settings.is_enabled then return end
    
    self.settings.is_enabled = enable == nil and not self.settings.is_enabled or enable
    G_reader_settings:saveSetting("statistics", self.settings)
    
    if self.settings.is_enabled then
        if self.document then
            self:initData()
        end
        UIManager:show(InfoMessage:new{
            text = _("Reading statistics enabled."),
            timeout = 2,
        })
    else
        UIManager:show(InfoMessage:new{
            text = _("Reading statistics disabled."),
            timeout = 2,
        })
    end
    
    if self.ui.menu then
        self.ui.menu:updateConfig("statistics")
    end
end


    -- ---- addToMainMenu Hook ----
    if not ReaderStatistics._yanllsama_orig_addToMainMenu then
        ReaderStatistics._yanllsama_orig_addToMainMenu = ReaderStatistics.addToMainMenu
        ReaderStatistics.addToMainMenu = function(self, menu_items)
            self:_yanllsama_orig_addToMainMenu(menu_items)
            if menu_items and menu_items.statistics and menu_items.statistics.sub_item_table then
                local sync_menu_item = {
                text = _("⚙️ Physical Page Sync"),
                sub_item_table = (self.document and self.ui and self.ui.doc_settings) and {
                    {
                        text = _("Active (On / Off)"),
                        checked_func = function()
                            local state = self.ui.doc_settings:readSetting("yanllsama_sync_enabled")
                            if state == nil then return true else return state end
                        end,
                        callback = function()
                            local Event = require("ui/event")
                            local InfoMessage = require("ui/widget/infomessage")
                            local UIManager = require("ui/uimanager")

                            local current = self.ui.doc_settings:readSetting("yanllsama_sync_enabled")
                            if current == nil then current = true end
                            local new_state = not current
                            
                            self.ui.doc_settings:saveSetting("yanllsama_sync_enabled", new_state)

                            if not new_state then
                                self.ui.doc_settings:saveSetting("yanllsama_font_locked", false)
                                self.ui.doc_settings:saveSetting("yanllsama_locked_font_size", nil)
                                self.ui.doc_settings:saveSetting("yanllsama_screen_ratio", 1)
                                local pagemap = (self.view and self.view.pagemap) or (self.ui and self.ui.pagemap)
                                if pagemap then
                                    pagemap.use_page_labels = false
                                    pagemap.show_page_labels = false
                                    pagemap.page_labels_cache = nil
                                    pagemap.chars_per_synthetic_page = nil
                                end
                                self.ui.doc_settings:saveSetting("pagemap_use_page_labels", false)
                                self.ui.doc_settings:saveSetting("show_page_overlap_marker", false)
                                self.ui.doc_settings:delSetting("pagemap_chars_per_synthetic_page")
                                self.ui.doc_settings:delSetting("pagemap_doc_pages")
                                
                                if self.document.buildSyntheticPageMap then
                                    self.document:buildSyntheticPageMap(1500)
                                end
                                
                                if self.data and self.document then
                                    self.data.pages = self.document:getPageCount()
                                end

                                if type(self.resetLayout) == "function" then self:resetLayout() end
                                if self.view and type(self.view.refresh) == "function" then self.view:refresh() end
                                UIManager:broadcastEvent(Event:new("UsePageLabelsUpdated"))
                                UIManager:show(InfoMessage:new{ 
                                    text = _("Module Disabled.\nReverted to original settings."), 
                                    timeout = 3 
                                })
                            else
                                UIManager:show(InfoMessage:new{ 
                                    text = _("Module Enabled.\nPlease sync below."), 
                                    timeout = 3 
                                })
                            end
                        end,
                        separator = false,
                    },
                    {
                        text = _("🔒 Lock Font Size"),
                        checked_func = function()
                            return isFontLocked(self.ui)
                        end,
                        callback = function()
                            local InfoMessage = require("ui/widget/infomessage")
                            local UIManager = require("ui/uimanager")
                            local current = isFontLocked(self.ui)
                            local new_state = not current
                            self.ui.doc_settings:saveSetting("yanllsama_font_locked", new_state)
                            if new_state then
                                local cur_size = (self.ui.font and self.ui.font.configurable and self.ui.font.configurable.font_size)
                                    or (self.document and self.document.configurable and self.document.configurable.font_size)
                                if cur_size then
                                    self.ui.doc_settings:saveSetting("yanllsama_locked_font_size", cur_size)
                                end
                                UIManager:show(InfoMessage:new{
                                    text = _("Font Size Locked!\nPhysical page layout protected against accidental changes."),
                                    timeout = 3,
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("Font Size Unlocked.\nYou can now freely change font size."),
                                    timeout = 3,
                                })
                            end
                        end,
                        separator = true,
                    },
                    {
                        text = _("1. Enter Page Count"),
                        callback = function()
                            self:promptEnterPhysicalPages()
                        end,
                    },
                    {
                        text = _("2. Sync for Font Size"),
                        callback = function()
                            local InfoMessage = require("ui/widget/infomessage")
                            local Event = require("ui/event")
                            local UIManager = require("ui/uimanager")
                            
                            if self.ui.doc_settings:readSetting("yanllsama_sync_enabled") == false then
                                UIManager:show(InfoMessage:new{ text = _("Please set the module to 'Active' first."), timeout = 3 })
                                return
                            end
                            
                            local physical_pages = self.ui.doc_settings:readSetting("yanllsama_physical_pages")
                            
                            if not physical_pages then
                                UIManager:show(InfoMessage:new{ text = _("Enter page count first."), timeout = 3 })
                                return
                            end
                            
                            local total_screens = self.document:getPageCount() or physical_pages
                            local new_ratio = (total_screens / physical_pages)
                            new_ratio = math.floor(new_ratio * 100 + 0.5) / 100
                            
                            self.ui.doc_settings:saveSetting("yanllsama_screen_ratio", new_ratio)
                            self.ui.doc_settings:saveSetting("yanllsama_font_locked", true)
                            local cur_size = (self.ui.font and self.ui.font.configurable and self.ui.font.configurable.font_size)
                                or (self.document and self.document.configurable and self.document.configurable.font_size)
                            if cur_size then
                                self.ui.doc_settings:saveSetting("yanllsama_locked_font_size", cur_size)
                            end
                            
                            if type(self.resetLayout) == "function" then self:resetLayout() end
                            if self.view and type(self.view.refresh) == "function" then self.view:refresh() end
                            
                            UIManager:broadcastEvent(Event:new("UsePageLabelsUpdated"))
                            UIManager:show(InfoMessage:new{ 
                                text = string.format(_("Adjusted for Font!\nRatio: %.2f taps per page.\nFont auto-locked."), new_ratio), 
                                timeout = 4 
                            })
                        end,
                    },
                    {
                        text = _("3. Enter Manual Ratio"),
                        callback = function()
                            local SpinWidget = require("ui/widget/spinwidget")
                            local InfoMessage = require("ui/widget/infomessage")
                            local UIManager = require("ui/uimanager")
                            local Event = require("ui/event")
                            
                            if self.ui.doc_settings:readSetting("yanllsama_sync_enabled") == false then
                                UIManager:show(InfoMessage:new{ text = _("Please set the module to 'Active' first."), timeout = 3 })
                                return
                            end
                            
                            local current_ratio = self.ui.doc_settings:readSetting("yanllsama_screen_ratio") or 1.0
                            UIManager:show(SpinWidget:new{
                                value = math.floor(current_ratio * 100), value_min = 1, value_max = 1000, value_step = 1,
                                ok_text = _("Save"),
                                title_text = _("Ratio x100 (e.g. 56 for 0.56)"),
                                callback = function(spin)
                                    local new_ratio = spin.value / 100.0
                                    self.ui.doc_settings:saveSetting("yanllsama_screen_ratio", new_ratio)
                                    
                                    if type(self.resetLayout) == "function" then self:resetLayout() end
                                    if self.view and type(self.view.refresh) == "function" then self.view:refresh() end
                                    UIManager:broadcastEvent(Event:new("UsePageLabelsUpdated"))
                                    
                                    UIManager:show(InfoMessage:new{ text = string.format(_("Custom Ratio Saved!\nNew Ratio: %.2f"), new_ratio), timeout = 4 })
                                end,
                            })
                        end,
                    },
                    {
                        text = _("4. Reset All Settings"),
                        callback = function()
                            local ConfirmBox = require("ui/widget/confirmbox")
                            local InfoMessage = require("ui/widget/infomessage")
                            local UIManager = require("ui/uimanager")
                            local Event = require("ui/event")
                            
                            UIManager:show(ConfirmBox:new{
                                text = _("All physical page settings for this book will be cleared and KOReader defaults restored.\n\nAre you sure?"),
                                ok_text = _("Yes, Reset"),
                                cancel_text = _("Cancel"),
                                ok_callback = function()
                                    self.ui.doc_settings:saveSetting("yanllsama_physical_pages", nil)
                                    self.ui.doc_settings:saveSetting("yanllsama_sync_prompt_dismissed", nil)
                                    self.ui.doc_settings:saveSetting("yanllsama_font_locked", nil)
                                    self.ui.doc_settings:saveSetting("yanllsama_locked_font_size", nil)
                                    self.ui.doc_settings:saveSetting("yanllsama_screen_ratio", 1)
                                    
                                    self.ui.doc_settings:saveSetting("pagemap_use_page_labels", false)
                                    self.ui.doc_settings:saveSetting("show_page_overlap_marker", false)
                                    self.ui.doc_settings:saveSetting("pagemap_chars_per_synthetic_page", nil)
                                    self.ui.doc_settings:saveSetting("pagemap_doc_pages", nil)
                                    
                                    local pagemap = (self.view and self.view.pagemap) or (self.ui and self.ui.pagemap)
                                    if pagemap then
                                        pagemap.use_page_labels = false
                                        pagemap.show_page_labels = false
                                        pagemap.page_labels_cache = nil
                                        pagemap.chars_per_synthetic_page = nil
                                    end
                                    
                                    if self.document.buildSyntheticPageMap then
                                        self.document:buildSyntheticPageMap(1500)
                                    end
                                    
                                    if self.data and self.document then
                                        self.data.pages = self.document:getPageCount()
                                        -- ==========================================
                                        -- Database Update (Restore original pages in DB)
                                        -- ==========================================
                                        if self.id_curr_book and db_location then
                                            local conn = SQ3.open(db_location)
                                            if conn then
                                                conn:exec(string.format("UPDATE book SET pages = %d WHERE id = %d;", self.data.pages, self.id_curr_book))
                                                conn:close()
                                            end
                                        end
                                        -- ==========================================
                                    end
                                    
                                    if type(self.resetLayout) == "function" then self:resetLayout() end
                                    if self.view and type(self.view.refresh) == "function" then self.view:refresh() end
                                    UIManager:broadcastEvent(Event:new("UsePageLabelsUpdated"))
                                    
                                    UIManager:show(InfoMessage:new{ text = _("Everything reset!"), timeout = 3 })
                                end
                            })
                        end,
                    },
                } or {
                    {
                        text = _("⚠️ Only available while reading a book."),
                        callback = function() end
                    }
                },
                separator = true,
            }

                local already_has_sync = false
                for _, it in ipairs(menu_items.statistics.sub_item_table) do
                    if it._is_yanllsama_sync then
                        already_has_sync = true
                        break
                    end
                end
                if not already_has_sync then
                    sync_menu_item._is_yanllsama_sync = true
                    table.insert(menu_items.statistics.sub_item_table, 1, sync_menu_item)
                end
            end
        end
    end
end



-- =============================================================================
-- 4. Activation & Lifecycle Hooks
-- =============================================================================
local function initPatch()
    installFontProtection()

    -- 1. Check package.loaded
    local loaded_stats = package.loaded["plugins/statistics.koplugin/main"]
        or package.loaded["statistics.koplugin/main"]
        or package.loaded["plugins/statistics.koplugin"]
    if loaded_stats and type(loaded_stats) == "table" then
        patchReaderStatistics(loaded_stats)
    end

    -- 2. Official userpatch hook (register if available)
    local ok_up, userpatch = pcall(require, "userpatch")
    if ok_up and userpatch and userpatch.registerPatchPluginFunc then
        userpatch.registerPatchPluginFunc("statistics", function(plugin)
            patchReaderStatistics(plugin)
        end)
    end

    -- 3. PluginLoader hook
    local ok_pl, PluginLoader = pcall(require, "pluginloader")
    if ok_pl and PluginLoader then
        if PluginLoader.enabled_plugins then
            for _, p in ipairs(PluginLoader.enabled_plugins) do
                if p.name == "statistics" then
                    patchReaderStatistics(p)
                end
            end
        end

        if not PluginLoader._yanllsama_orig_loadPlugins then
            PluginLoader._yanllsama_orig_loadPlugins = PluginLoader.loadPlugins
            PluginLoader.loadPlugins = function(self_pl, ...)
                local enabled, disabled = self_pl:_yanllsama_orig_loadPlugins(...)
                if enabled then
                    for _, p in ipairs(enabled) do
                        if p.name == "statistics" then
                            patchReaderStatistics(p)
                        end
                    end
                end
                return enabled, disabled
            end
        end

        if not PluginLoader._yanllsama_orig_createPluginInstance then
            PluginLoader._yanllsama_orig_createPluginInstance = PluginLoader.createPluginInstance
            PluginLoader.createPluginInstance = function(self_pl, plugin, attr)
                local ok, inst = self_pl:_yanllsama_orig_createPluginInstance(plugin, attr)
                if ok and plugin and plugin.name == "statistics" and inst then
                    patchReaderStatistics(plugin)
                    patchReaderStatistics(getmetatable(inst) or inst)
                    patchReaderStatistics(inst)
                end
                return ok, inst
            end
        end
    end

    -- 4. ReaderUI hook
    local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_rui and ReaderUI and not ReaderUI._yanllsama_orig_registerModule then
        ReaderUI._yanllsama_orig_registerModule = ReaderUI.registerModule
        ReaderUI.registerModule = function(self_rui, name, mod)
            if name == "statistics" and mod then
                patchReaderStatistics(getmetatable(mod) or mod)
            end
            return self_rui:_yanllsama_orig_registerModule(name, mod)
        end
    end

    -- 5. Global require hook (deterministic capture)
    local orig_require = require
    _G.require = function(modname)
        local loaded = orig_require(modname)
        if (modname == "plugins/statistics.koplugin/main" or modname == "statistics.koplugin/main") and type(loaded) == "table" then
            patchReaderStatistics(loaded)
        end
        return loaded
    end

    logger.info("PhysicalPageSync: Patch loaded successfully!")
end

initPatch()
