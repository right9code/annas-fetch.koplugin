--[[--
@module koplugin.Annas
--]]--

local Dispatcher = require("dispatcher")  -- luacheck:ignore
local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local util = require("util")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("annas.gettext")
local Config = require("annas.config")
local Api = require("annas.api")
local Ui = require("annas.ui")
local ReaderUI = require("apps/reader/readerui")
local AsyncHelper = require("annas.async_helper")
local logger = require("logger")
local Ota = require("annas.ota")
local Device = require("device")
local DialogManager = require("annas.dialog_manager")

require('src.scraper')

local Annas = WidgetContainer:extend{
    name = T("Anna's Archive"),
    is_doc_only = false,
    plugin_path = nil,
    dialog_manager = nil,
}

function Annas:onDispatcherRegisterActions()
    Dispatcher:registerAction("annas_search", { category="none", event="AnnasSearch", title=T("Anna's Archive search"), general=true,})
end

function Annas:init()
    local full_source_path = debug.getinfo(1, "S").source
    if full_source_path:sub(1,1) == "@" then
        full_source_path = full_source_path:sub(2)
    end
    self.plugin_path, _ = util.splitFilePathName(full_source_path):gsub("/+", "/")
    
    Config.loadCredentialsFromFile(self.plugin_path)
    
    local current_version = Ota.getCurrentPluginVersion(self.plugin_path)
    
    self.dialog_manager = DialogManager:new()
    Ui.setPluginInstance(self)
    
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    else
        logger.warn("self.ui or self.ui.menu not initialized in Annas:init")
    end

    logger.info(string.format("Annas: Init successful, version is: %s", current_version))

end

function Annas:onAnnasSearch()
    local def_search_input
    if self.ui and self.ui.doc_settings and self.ui.doc_settings.data.doc_props then
      local doc_props = self.ui.doc_settings.data.doc_props
      def_search_input = doc_props.authors or doc_props.title
    end
    Ui.showSearchDialog(self, def_search_input)
    return true
end

function Annas:addToMainMenu(menu_items)

    if not self.ui.view then
        menu_items.annas_archive_main = {
            sorting_hint = "search",
            text = T("Anna's Archive"),
            callback = function()
                Ui.showSearchDialog(self)
            end,
        }
    end
end



function Annas:performSearch(query)
    if not NetworkMgr:isOnline() then
        Ui.showErrorMessage(T("No internet connection detected."))
        return
    end

    local loading_msg = Ui.showLoadingMessage(T("Searching for \"") .. query .. "\"...")

    local task = function()
        return scraper(query)
    end

    local on_success = function(res)
        Ui.closeMessage(loading_msg)

        -- scraper() can return an error string on total failure
        if type(res) == "string" then
            Ui.showErrorMessage(res)
            return
        end

        if type(res) ~= "table" or #res == 0 then
            Ui.showInfoMessage(T("No results found for \"") .. query .. "\".")
            return
        end

        logger.info(string.format("Annas:performSearch - Fetch successful. Results: %d", #res))
        self.current_search_query = query
        self.current_search_api_page_loaded = 1
        self.has_more_api_results = true
        self.all_search_results_data = res

        UIManager:nextTick(function()
            self:displaySearchResults(self.all_search_results_data, self.current_search_query)
        end)
    end

    local on_error = function(err_msg)
        Ui.closeMessage(loading_msg)
        Ui.showRetryErrorDialog(tostring(err_msg), T("Search"), function()
            self:performSearch(query)
        end, function() end, loading_msg)
    end

    AsyncHelper.run(task, on_success, on_error, loading_msg)
end

function Annas:displaySearchResults(initial_book_data_list, query_string)
    if not initial_book_data_list or #initial_book_data_list == 0 then
        logger.info("Annas:displaySearchResults - No initial results to display.")
        return
    end

    local menu_items = {}
    logger.info(string.format("Annas:displaySearchResults - Preparing menu items from %d initial results.", #initial_book_data_list))

    for i = 1, #initial_book_data_list do
        local book_menu_item_data = initial_book_data_list[i]
        menu_items[i] = Ui.createBookMenuItem(book_menu_item_data, self)
    end

    if self.active_results_menu then
        UIManager:close(self.active_results_menu)
        self.active_results_menu = nil
    end

    local function on_goto_page_handler(menu_instance, new_page_number)
        menu_instance.prev_focused_path = nil
        menu_instance.page = new_page_number

        local is_last_page_of_current_items = (new_page_number == menu_instance.page_num)

        if is_last_page_of_current_items and self.has_more_api_results then
            local next_api_page_to_fetch = self.current_search_api_page_loaded + 1
            logger.info(string.format("Annas: Reached UI page %d. Fetching Anna's Archive page %d.", new_page_number, next_api_page_to_fetch))

            local loading_msg_more = Ui.showLoadingMessage(string.format(T("Fetching more results (Page %s)..."), next_api_page_to_fetch))

            local task_load_more = function()
                return scraper(self.current_search_query, next_api_page_to_fetch)
            end

            local on_success_load_more = function(scraper_result)
                Ui.closeMessage(loading_msg_more)
                
                if type(scraper_result) == "string" then
                    -- Error returned from scraper
                    Ui.showErrorMessage(Ui.colonConcat(T("Failed to fetch more results"), scraper_result))
                    return
                end

                if type(scraper_result) == "table" and #scraper_result > 0 then
                    logger.info(string.format("Annas: Adding %d new books.", #scraper_result))
                    self.current_search_api_page_loaded = next_api_page_to_fetch

                    local new_menu_items_to_add = {}
                    for _, book_data in ipairs(scraper_result) do
                        table.insert(self.all_search_results_data, book_data)
                        table.insert(new_menu_items_to_add, Ui.createBookMenuItem(book_data, self))
                    end
                    Ui.appendSearchResultsToMenu(menu_instance, new_menu_items_to_add)
                else
                    logger.info("Annas: No more results returned by scraper.")
                    self.has_more_api_results = false
                    Ui.showInfoMessage(T("End of search results reached."))
                    menu_instance:updateItems(1, true)
                end
            end

            local on_error_load_more = function(err_msg)
                Ui.closeMessage(loading_msg_more)
                Ui.showErrorMessage(Ui.colonConcat(T("Failed to load more results"), tostring(err_msg)))
            end

            AsyncHelper.run(task_load_more, on_success_load_more, on_error_load_more, loading_msg_more)
        else
            if is_last_page_of_current_items and not self.has_more_api_results then
                logger.info("Annas: Reached last page, and no more results to load.")
            end
            menu_instance:updateItems(1, true)
        end
        return true
    end

    self.active_results_menu = Ui.createSearchResultsMenu(self.ui, query_string, menu_items, on_goto_page_handler)
end

function Annas:downloadBook(book)
    if not NetworkMgr:isOnline() then
        Ui.showErrorMessage(T("No internet connection detected."))
        return
    end

    if not book.download then
        Ui.showErrorMessage(T("No download link available for this book."))
        return
    end

    --[[     local download_url = Config.getDownloadUrl(book.download)
    logger.info(string.format("Annas:downloadBook - Download URL: %s", download_url))

    local safe_title = util.trim(book.title or "Unknown Title"):gsub("[/\\?%*:|\"<>%c]", "_")
    local safe_author = util.trim(book.author or "Unknown Author"):gsub("[/\\?%*:|\"<>%c]", "_")
    local filename = string.format("%s - %s.%s", safe_title, safe_author, book.format or "unknown")
    logger.info(string.format("Annas:downloadBook - Proposed filename: %s", filename)) ]]

    local target_dir = Config.getDownloadDir()

    if not target_dir then
        target_dir = Config.DEFAULT_DOWNLOAD_DIR_FALLBACK
        logger.warn(string.format("Annas:downloadBook - Download directory setting not found, using fallback: %s", target_dir))
    else
        logger.info(string.format("Annas:downloadBook - Using configured download directory: %s", target_dir))
    end

    if lfs.attributes(target_dir, "mode") ~= "directory" then
        local ok, err_mkdir = lfs.mkdir(target_dir)
        if not ok then
            Ui.showErrorMessage(string.format(T("Cannot create downloads directory: %s"), err_mkdir or "Unknown error"))
            return
        end
        logger.info(string.format("Annas:downloadBook - Created downloads directory: %s", target_dir))
    end

    --local target_filepath = target_dir .. "/" .. filename
    --logger.info(string.format("Annas:downloadBook - Target filepath: %s", target_filepath))

    local function attemptDownload(retry_on_auth_error)
        retry_on_auth_error = retry_on_auth_error == nil and true or retry_on_auth_error
        
        local user_session = Config.getUserSession()
        local referer_url = book.href and Config.getBookUrl(book.href) or nil

        local is_cancelled = false
        local on_cancel = function()
            is_cancelled = true
        end

        local loading_msg, pb_callback = Ui.showBookDownloadProgress(book, nil, on_cancel)

        local function task_download()
            local last_update_time = 0
            
            local progress_callback = function(written_bytes)
                if pb_callback then
                    -- Call directly to avoid flooding the event loop with nextTick
                    pb_callback(written_bytes)
                else
                    -- Fallback to InfoMessage text updating
                    local current_time = os.time()
                    if current_time - last_update_time >= 1 then
                        local mb = string.format("%.1f", written_bytes / (1024 * 1024))
                        local text = string.format("%s\n%s MB", T("Downloading, please wait …"), mb)
                        UIManager:nextTick(function()
                            if loading_msg then
                                loading_msg:setText(text)
                                UIManager:setDirty(nil, "ui")
                            end
                        end)
                        last_update_time = current_time
                    end
                end
            end
            
            local is_cancelled_func = function() return is_cancelled end
            
            return download_book(book, target_dir, progress_callback, is_cancelled_func)
        end

        local function on_success_download(api_result)
            -- i think this is just for login issue catching but we dont need a login
--[[             if api_result and api_result.error and retry_on_auth_error and Api.isAuthenticationError(api_result.error) then
                Ui.closeMessage(loading_msg)
                self:login(function(login_ok)
                    if login_ok then
                        attemptDownload(false)
                    end
                end)
                return
            end ]]

            Ui.closeMessage(loading_msg)
            if not string.find(api_result, 'Failed,', 1, true)  then
                local has_wifi_toggle = Device:hasWifiToggle()
                local default_turn_off_wifi = Config.getTurnOffWifiAfterDownload()

                Ui.confirmOpenBook(api_result, has_wifi_toggle, default_turn_off_wifi, function(should_turn_off_wifi)
                    if should_turn_off_wifi then
                        NetworkMgr:disableWifi(function()
                            logger.info("Annas:downloadBook - Wi-Fi disabled after download as requested by user")
                        end)
                    end

                    if ReaderUI then
                        logger.info("Annas:downloadBook - Cleaning up dialogs before opening reader")
                        self.dialog_manager:closeAllDialogs()
                        ReaderUI:showReader(api_result)
                    else
                        Ui.showErrorMessage(T("Could not open reader UI."))
                        logger.warn("Annas:downloadBook - ReaderUI not available.")
                    end
                end,
                function(should_turn_off_wifi)
                    if should_turn_off_wifi then
                        NetworkMgr:disableWifi(function()
                            logger.info("Annas:downloadBook - Wi-Fi disabled after download as requested by user")
                        end)
                        logger.info("Annas:downloadBook - Cleaning up dialogs cause wifi is turned off")
                        self.dialog_manager:closeAllDialogs()
                    end
                end
            )
            else
                local fail_msg = api_result
                Ui.showErrorMessage(fail_msg)
            end
        end

        local function on_error_download(err_msg)
            -- again authen stuff
--[[             if retry_on_auth_error and Api.isAuthenticationError(err_msg) then
                Ui.closeMessage(loading_msg)
                self:login(function(login_ok)
                    if login_ok then
                        attemptDownload(false)
                    end
                end)
                return
            end ]]
            
            local error_string = tostring(err_msg)
            if string.find(error_string, "Download limit reached or file is an HTML page", 1, true) then
                Ui.closeMessage(loading_msg)
                Ui.showErrorMessage(T("Download limit reached. Please try again later or check your account."))
                return
            end
            
            -- Use retry dialog for timeout and network errors
            Ui.showRetryErrorDialog(err_msg, T("Download"), function()
                -- Retry callback
                local new_loading_msg = Ui.showLoadingMessage(T("Retrying download..."))
                loading_msg = new_loading_msg
                AsyncHelper.run(task_download, on_success_download, on_error_download, loading_msg)
            end, function(final_err_msg)
                -- Cancel callback
            end, loading_msg)
        end

        AsyncHelper.run(task_download, on_success_download, on_error_download, loading_msg)
    end

    Ui.confirmDownload(book.title, function()
        attemptDownload()
    end)
end

function Annas:downloadAndShowCover(book)
    local cover_url = book.cover
    local book_id = book.id
    local book_hash = book.hash
    local book_title = book.title

    if not (cover_url and book_id and book_hash) then
        logger.warn("Annas:downloadAndShowCover - parameter error")
        return
    end

    local function getImgExtension(url)
       local clean_url = url:match("^([^%?]+)") or url
       return clean_url:match("[%.]([^%.]+)$") or "jpg"
    end

    local cover_ext = getImgExtension(cover_url)
    local cache_path = Cache:makePath(book_id, book_hash)
    local cover_cache_path = string.format("%s.%s", cache_path, cover_ext)

    if not util.fileExists(cover_cache_path) then
        local download_result = Api.downloadBookCover(cover_url, cover_cache_path)
        if download_result.error or not download_result.success then
            if util.fileExists(cover_cache_path) then
                    pcall(os.remove, cover_cache_path)
            end
            Ui.showErrorMessage(tostring(download_result.error))
            return
        end
    end

    Ui.showCoverDialog(book_title, cover_cache_path)
end

function Annas:onExit()
    if self.dialog_manager and self.dialog_manager:getDialogCount() > 0 then
        logger.info("Annas:onExit - Cleaning up " .. self.dialog_manager:getDialogCount() .. " remaining dialogs")
        self.dialog_manager:closeAllDialogs()
    end
end

function Annas:onCloseWidget()
    if self.dialog_manager and self.dialog_manager:getDialogCount() > 0 then
        logger.info("Annas:onCloseWidget - Cleaning up " .. self.dialog_manager:getDialogCount() .. " remaining dialogs")
        self.dialog_manager:closeAllDialogs()
    end
end

return Annas