local Config = require("annas.config")
local Api = require("annas.api")
local logger = require("logger")
local DataStorage = require("datastorage")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local socketutil_ok, socketutil = pcall(require, "socketutil")
if not socketutil_ok then socketutil = nil end

local Scraper = {}

-- Cache configuration
local CACHE_DIR = DataStorage:getDataDir() .. "/cache/annas"
local CACHE_FILE = CACHE_DIR .. "/domains_cache.txt"
local CACHE_DURATION = 12 * 60 * 60  -- 12 hours in seconds

-- Ensure cache directory exists
local function ensure_cache_dir()
    if not lfs.attributes(CACHE_DIR, "mode") then
        util.makePath(CACHE_DIR)
    end
end

-- Shell-safe quoting for arguments passed to io.popen/os.execute
local function shell_quote(s)
    -- Use single-quoting; escape embedded single-quotes
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Reads domains from cache
local function read_cache()
    local f = io.open(CACHE_FILE, "r")
    if not f then
        return nil, nil
    end

    local timestamp_str = f:read("*l")
    if not timestamp_str then
        f:close()
        return nil, nil
    end

    local timestamp = tonumber(timestamp_str)
    if not timestamp then
        f:close()
        return nil, nil
    end

    -- Check whether cache is still valid
    if os.time() - timestamp > CACHE_DURATION then
        f:close()
        logger.dbg("Scraper: Domain cache expired")
        return nil, nil
    end

    local domains = {}
    for line in f:lines() do
        if line and line ~= "" then
            table.insert(domains, line)
        end
    end
    f:close()

    if #domains > 0 then
        logger.dbg("Scraper: Loaded", #domains, "domains from cache")
        return domains, timestamp
    end

    return nil, nil
end

-- Writes domains to cache
local function write_cache(domains)
    ensure_cache_dir()
    local f = io.open(CACHE_FILE, "w")
    if not f then
        logger.warn("Scraper: Could not write cache file")
        return false
    end

    f:write(os.time() .. "\n")
    for _, domain in ipairs(domains) do
        f:write(domain .. "\n")
    end
    f:close()

    logger.dbg("Scraper: Cached", #domains, "domains")
    return true
end

-- Extracts domains from Wikipedia HTML
local function extract_domains_from_wikipedia(html)
    local domains = {}

    -- Search for all annas-archive URLs
    for url in html:gmatch('href="(https://annas%-archive%.[^/"]+)/?"') do
        -- Extract only the domain part
        local domain = url:match("https://(.+)")
        if domain and not domains[domain] then
            domains[domain] = true
            table.insert(domains, domain)
            logger.dbg("Scraper: Found domain:", domain)
        end
    end

    return domains
end

-- Check if an external command is available
local function command_exists(cmd)
    -- Use shell_quote to prevent injection
    local handle = io.popen("command -v " .. shell_quote(cmd) .. " 2>/dev/null")
    if handle then
        local result = handle:read("*a")
        handle:close()
        return result and result ~= ""
    end
    return false
end

-- Fetches domains from Wikipedia
local function fetch_domains_from_wikipedia()
    logger.dbg("Scraper: Fetching domains from Wikipedia...")

    local wikipedia_url = "https://en.wikipedia.org/wiki/Anna%27s_Archive"

    -- Try using different methods
    local status, data = Scraper.check_url(wikipedia_url)

    if status ~= "success" or not data then
        logger.warn("Scraper: Failed to fetch Wikipedia page")
        return nil
    end

    local domains = extract_domains_from_wikipedia(data)
    if #domains > 0 then
        write_cache(domains)
    end
    return domains
end

-- Gets Anna's Archive domains (from cache or Wikipedia)
local function get_annas_archive_domains()
    -- Try to load from cache first
    local domains, _ = read_cache()
    if domains then
        return domains
    end

    -- Fetch fresh from Wikipedia
    domains = fetch_domains_from_wikipedia()
    if domains and #domains > 0 then
        return domains
    end

    -- Fallback to known domains
    logger.dbg("Scraper: Using fallback domains")
    return {
        "annas-archive.org",
        "annas-archive.se",
        "annas-archive.is",
    }
end

-- Try using LuaSocket (pure Lua HTTP)
local function fetch_with_lua_socket(url)
    logger.dbg("Scraper: Trying LuaSocket for:", url)

    local http_ok, http = pcall(require, "socket.http")
    if not http_ok then
        return "no_socket", nil
    end

    local ltn12_ok, ltn12 = pcall(require, "ltn12")
    if not ltn12_ok then
        return "no_socket", nil
    end

    local response_body = {}
    local res, code, response_headers, status = http.request{
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
            ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        },
        sink = ltn12.sink.table(response_body),
        redirect = true,
    }

    if res and code == 200 then
        local body = table.concat(response_body)
        logger.dbg("Scraper: LuaSocket succeeded, got", #body, "bytes")
        return "success", body
    else
        logger.dbg("Scraper: LuaSocket failed, code:", code, "status:", status)
        return "socket_error", nil
    end
end

-- Try external commands (curl/wget) for HTTP requests
-- Uses shell_quote() to prevent injection from user-controlled or mirror URLs
local function fetch_with_external_command(url)
    logger.dbg("Scraper: Trying external command for URL:", url)

    -- Try curl first (most reliable)
    if command_exists("curl") then
        logger.dbg("Scraper: Using curl")
        local cmd = string.format("curl -L -s --max-time 20 %s 2>&1", shell_quote(url))
        local handle = io.popen(cmd)
        if handle then
            local result = handle:read("*a")
            local success = handle:close()
            if success and result and #result > 0 then
                logger.dbg("Scraper: curl succeeded, got", #result, "bytes")
                return "success", result
            end
        end
    end

    -- Try wget as fallback
    if command_exists("wget") then
        logger.dbg("Scraper: Using wget")
        local temp_file = os.tmpname()
        local cmd = string.format("wget -q -O %s --timeout=20 %s 2>&1",
            shell_quote(temp_file), shell_quote(url))
        local handle = io.popen(cmd)
        if handle then
            handle:close()
            local f = io.open(temp_file, "r")
            if f then
                local result = f:read("*a")
                f:close()
                os.remove(temp_file)
                if result and #result > 0 then
                    logger.dbg("Scraper: wget succeeded, got", #result, "bytes")
                    return "success", result
                end
            end
        end
    end

    return "no_external_command", nil
end

-- Try KOReader's API with multiple header configurations
local function fetch_with_api(url, custom_sink)
    logger.dbg("Scraper: Trying Api.makeHttpRequest for:", url)

    local user_session = Config.getUserSession()
    local hostname = url:match("://([^/]+)")

    -- Try different header configurations for compatibility
    local header_configs = {
        -- Minimal headers
        {
            ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
        },
        -- Standard headers
        {
            ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
            ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Accept-Language"] = "en-US,en;q=0.5",
        },
        -- Full headers with session
        {
            ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
            ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Accept-Language"] = "en-US,en;q=0.5",
            ["Host"] = hostname,
        }
    }

    for i, headers in ipairs(header_configs) do
        logger.dbg("Scraper: API attempt", i, "with", #headers, "headers")

        -- Add session cookie if available
        if user_session and user_session.user_id and user_session.user_key then
            headers["Cookie"] = string.format("remix_userid=%s; remix_userkey=%s",
                                             user_session.user_id, user_session.user_key)
        end

        local success, http_result = pcall(function()
            return Api.makeHttpRequest{
                url = url,
                method = "GET",
                headers = headers,
                timeout = 20,
                sink = custom_sink,
            }
        end)

        if not success then
            logger.dbg("Scraper: API call threw error:", http_result)
            goto next_attempt
        end

        if not http_result then
            logger.dbg("Scraper: API returned nil")
            goto next_attempt
        end

        if http_result.error then
            logger.dbg("Scraper: API returned error:", http_result.error)
            goto next_attempt
        end

        local status_code = tonumber(http_result.status_code)
        if status_code == 200 and (custom_sink or (http_result.body and #http_result.body > 0)) then
            logger.dbg("Scraper: API succeeded with attempt", i)
            return "success", http_result.body
        else
            logger.dbg("Scraper: API attempt", i, "failed - status:", status_code)
        end

        ::next_attempt::
    end

    return "api_failed", nil
end

-- Main HTTP request function with three-tier fallback system
function Scraper.check_url(url)
    logger.dbg("Scraper: check_url called with:", url)

    -- Method 1: Try external commands (curl/wget) - most reliable
    local ext_status, ext_data = fetch_with_external_command(url)
    if ext_status == "success" then
        return "success", ext_data
    end

    logger.dbg("Scraper: External command not available, trying alternative methods")

    -- Method 2: Try LuaSocket (pure Lua, no external dependencies)
    local socket_status, socket_data = fetch_with_lua_socket(url)
    if socket_status == "success" then
        return "success", socket_data
    end

    logger.dbg("Scraper: LuaSocket not available or failed, trying Api.makeHttpRequest")

    -- Method 3: Try KOReader's API with multiple configurations
    local api_status, api_data = fetch_with_api(url)
    if api_status == "success" then
        return "success", api_data
    end

    -- All methods failed
    logger.warn("Scraper: All HTTP methods failed for:", url)
    return "network_error", nil
end

-- Extract MD5 hash from HTML entry
local function extract_md5_and_link(line)
    -- Extract MD5 hash from href="/md5/<hash>" pattern
    local md5 = line:match('href="/md5/([a-fA-F0-9]+)"')
    if md5 and #md5 == 32 then
        return md5
    end
    return nil
end

-- Extract title from HTML entry
local function extract_title(line)
    -- Extract title from data-content attribute and clean it
    local content = line:match('<div class="font%-bold text%-violet%-900 line%-clamp%-%[5%]" data%-content="([^"]+)"')
    if content then
        content = content:match("^%s*(.-)%s*$")  -- trim whitespace
        content = content:gsub('"', '\\"')     -- escape quotes
        content = content:gsub("•", "\\u2022") -- escape bullet points
        logger.dbg("Scraper: Title:", content)
        return content
    end
    return "Could not retrieve title."
end

-- Extract author from HTML entry
local function extract_author(line)
    -- Extract author from specific div class combination
    if line:match('<div[^>]*class="[^"]*font%-bold[^"]*text%-amber%-900[^"]*line%-clamp%-%[2%][^"]*"') then
        local block = line:match('<div[^>]*class="[^"]*font%-bold[^"]*text%-amber%-900[^"]*line%-clamp%-%[2%][^"]*" data%-content="[^"]+"')
        if block then
            local author = block:match('data%-content="([^"]+)"')
            if author then
                logger.dbg("Scraper: Author:", author)
                return author
            end
        end
    end
    return "Could not retrieve author."
end

-- Extract format from HTML entry
local function extract_format(line)
    -- Extract file format (PDF, EPUB, etc.) from text content
    local div_text = line:match('<div class="text%-gray%-800[^>]*>[^<]+')
    if div_text then
        local content = div_text:match('>([^<]+)')
        if content then
            local format = content:match("([A-Z][A-Z]+)")  -- match uppercase format like PDF, EPUB
            if format then
                logger.dbg("Scraper: format:", format)
                return format
            end
        end
    end
    return "Could not retrieve format."
end

-- Extract description from HTML entry
local function extract_description(line)
    -- Extract and clean description text from HTML
    local div_block = line:match('<div[^>]*class="[^"]*line%-clamp%-%[2%][^"]*"[^>]*>(.-)</div>')
    if div_block then
        local description = div_block
        description = description:gsub('<script[^>]*>.-</script>', '')  -- remove scripts
        description = description:gsub('<a[^>]*>.-</a>', '')           -- remove links
        description = description:gsub('<[^>]->', '')                -- remove HTML tags
        description = description:gsub('&[#a-zA-Z0-9]+;', '')          -- remove HTML entities
        description = description:gsub('^%s+', ''):gsub('%s+$', '')  -- trim whitespace
        logger.dbg("Scraper: Description:", description)
        return description
    end
    return "Could not retrieve description."
end

-- Force refresh of domain cache
function Scraper.force_refresh_domains()
    logger.dbg("Scraper: Force refreshing domain cache...")
    -- Remove cache file if it exists
    if util.fileExists(CACHE_FILE) then
        os.remove(CACHE_FILE)
    end
    return get_annas_archive_domains()
end

function Scraper.scraper(query, page_num)
    -- Check for custom mirror URL first, then fall back to auto-detected domains
    local custom_mirror = Config.getSetting(Config.SETTINGS_CUSTOM_MIRROR_KEY)
    local aa_domains
    if custom_mirror and custom_mirror ~= "" then
        -- Extract just the domain part from the custom URL
        local custom_domain = custom_mirror:match("^https?://(.+)$") or custom_mirror
        custom_domain = custom_domain:gsub("/+$", "")  -- strip trailing slashes
        aa_domains = { custom_domain }
        logger.dbg("Scraper: Using custom mirror:", custom_domain)
    else
        aa_domains = get_annas_archive_domains()
    end

    logger.dbg("Scraper: Using", #aa_domains, "Anna's Archive domains")

    local domain_counter = 0
    local protocols = {"https://"}
    local protocol_counter = 1
    local page = tostring(page_num or 1)

    if not query then
        query = ""
    end

    logger.dbg("Scraper: got query:", query, "page:", page)

    local encoded_query = string.gsub(query, " ", "+")
    local languages = Config.getSearchLanguages()
    local ext = Config.getSearchExtensions()
    local order = Config.getSearchOrder()
    local src = "lgli"
    local filters = ""

    if languages then
        for _, lang in pairs(languages) do
            filters = filters .. "&lang=" .. lang
        end
    end

    if ext then
        for _, e in pairs(ext) do
            filters = filters .. "&ext=" .. string.lower(e)
        end
    end

    if order[1] then
        filters = filters .. "&sort=" .. order[1]
    end

    if src then
        filters = filters .. "&src=" .. src
    end

    logger.dbg("Scraper: applying filters:", filters)

    ::retry::
    domain_counter = domain_counter + 1
    if domain_counter > #aa_domains then
        domain_counter = 1
        protocol_counter = protocol_counter + 1
        if protocol_counter > #protocols then
            return "All domains and protocols failed. Anna's Archive may be blocked or no working HTTP method available."
        end
    end

    local annas_url = protocols[protocol_counter] .. aa_domains[domain_counter] .. "/"
    local url = string.format("%ssearch?page=%s&q=%s%s", annas_url, page, encoded_query, filters)

    logger.dbg("Scraper: Attempting URL:", url)
    logger.dbg("Scraper: Protocol:", protocols[protocol_counter], "Domain:", aa_domains[domain_counter])

    local status, data = Scraper.check_url(url)

    if status == "network_error" or status == "dns_error" then
        logger.dbg("Scraper: Network/DNS error on", annas_url, "- checking different mirror...")
        goto retry
    elseif status == "success" then
        logger.dbg("Scraper: HTTP request succeeded")

        if not data or data == "" then
            logger.warn("Scraper: No data received from server, retrying with different mirror...")
            goto retry
        end

        logger.dbg("Scraper: Received data, length:", #data)

        local ddos_guard_needle = "der-gray-100<!doctype html><html><head><title>DDoS-Guard</titl"

        if data:find(ddos_guard_needle, 1, true) then
            logger.dbg("Scraper: DDoS guard triggered, trying different mirror...")
            goto retry
        end

        -- Split HTML into book entries using consistent pattern
        local split_pattern = "pt-3 pb-3 border-b last:border-b-0 border-gray-100"

        local result_html = split_pattern .. data

        local segments = {}

        local start_pos = 1

        while true do
            local s, e = result_html:find(split_pattern, start_pos, true)
            if not s then break end

            -- Find next occurrence to extract individual segments
            local next_s = result_html:find(split_pattern, e + 1, true)

            local segment
            if next_s then
                segment = result_html:sub(s, next_s - 1)
                start_pos = next_s
            else
                segment = result_html:sub(s)
                start_pos = #result_html + 1
            end

            table.insert(segments, segment)
        end

        local book_lst = {}
        local book_count = 0

        for i, entry in ipairs(segments) do
            logger.dbg("Scraper: Processing entry #" .. i)

            local md5 = extract_md5_and_link(entry)
            local link = nil

            if md5 then
                link = annas_url .. "md5/" .. md5
                logger.dbg("Scraper: found link", link)
            else
                logger.dbg("Scraper: Could not fetch MD5 sum of entry, skipping.")
                goto continue
            end

            local book = {}
            book.title = extract_title(entry)
            book.author = extract_author(entry)
            book.format = extract_format(entry)
            book.description = extract_description(entry)
            book.md5 = md5
            book.link = link

            if string.find(entry, "lgli", 1, true) then
                book.download = "lgli"

                if string.find(entry, "zlib", 1, true) then
                    book.download = book.download .. " | zlib"
                end
            else
                if string.find(entry, "zlib", 1, true) then
                    book.download = "zlib"
                end
            end

            local number_str = entry:match(" (%d+%.?%d*)MB · ")

            if number_str then
                book.size = number_str .. "MB"
            else
                book.size = "NA"
            end

            table.insert(book_lst, book)
            book_count = book_count + 1

            ::continue::
        end

        logger.dbg("Scraper: found " .. book_count .. " entries")

        return book_lst
    else
        logger.dbg("Scraper: Unknown error on", annas_url, ":", status, "- checking different mirror...")
        goto retry
    end
    return "Unknown error occurred"
end

function Scraper.sanitize_name(name)
    local sanitized = name
    sanitized = sanitized:gsub("[^%w._-]", "_")
    sanitized = sanitized:gsub(" ", "_")
    return sanitized
end

-- Save binary data to file
function Scraper.save_file_bytes(path, bytes)
    local f, err = io.open(path, "wb")  -- open in binary mode
    if not f then
        return nil, "open failed: "..tostring(err)
    end

    local ok, werr = f:write(bytes)
    f:close()
    if not ok then
        return nil, "write failed: "..tostring(werr)
    end

    return true, "saved file to: " .. path
end

-- Download book from Library Genesis mirrors
function Scraper.download_book(book, path, progress_callback, is_cancelled_func)
    -- Try different Library Genesis mirrors
    local lgli_exts = {
        ".la/",
        ".gl/",
        ".li/",
        ".is/",
        ".rs/",
        ".st/",
        ".bz/",
    }

    if not book.download then
        logger.warn("Scraper: no source available for download")
        return "Failed, no download source available [lgli, zlib]."
    end

    local fmt = (book.format or "unknown"):lower()
    local filename = path .. "/" .. Scraper.sanitize_name(book.title) .. "_" .. Scraper.sanitize_name(book.author) .. "." .. fmt

    for _, lgli_ext in ipairs(lgli_exts) do
        local lgli_url = "https://libgen" .. lgli_ext
        logger.dbg("Scraper: Trying mirror:", lgli_url)

        -- Only try libgen if this source is available
        if not string.find(book.download, "lgli", 1, true) then
            logger.dbg("Scraper: book not available on libgen, skipping")
            break
        end

        local download_page_url = lgli_url .. "ads.php?md5=" .. book.md5
        logger.dbg("Scraper: download page:", download_page_url)
        local status, page_data = Scraper.check_url(download_page_url)

        if status ~= "success" or not page_data then
            logger.dbg("Scraper: ads page failed on", lgli_url, ", trying next mirror")
            goto continue_mirror
        end

        -- Check ads page isn't a DDoS/captcha wall
        local page_lower = page_data:lower()
        if page_lower:match("ddos%-guard") or page_lower:match("access denied") or page_lower:match("cloudflare") then
            logger.dbg("Scraper: DDoS/block detected on", lgli_url, ", trying next mirror")
            goto continue_mirror
        end

        do
            -- Extract the actual download link from the ads page
            local download_link = page_data:match('href="([^"]*get%.php[^"]*)"')

            if not download_link then
                logger.dbg("Scraper: No get.php link found on", lgli_url, ", trying next mirror")
                goto continue_mirror
            end

            -- Fix potential double-slash: strip trailing / from base, ensure link starts with /
            local base = lgli_url:gsub("/$", "")
            if not download_link:match("^/") then
                download_link = "/" .. download_link
            end
            local download_url = base .. download_link
            logger.dbg("Scraper: Final download URL:", download_url)

            local temp_filename = filename .. ".tmp"
            local dl_data = nil
            local download_ok = false

            -- Method A: KOReader-native socketutil sink with progress (pure Lua, works on Kobo)
            if socketutil and socketutil.file_sink then
            do
                local f = io.open(temp_filename, "wb")
                if f then
                    local file_sink = socketutil.file_sink(f)
                    local sink_to_use = file_sink

                    -- Chain progress callback if available (KOReader 2025.08+)
                    if progress_callback and type(socketutil.chainSinkWithProgressCallback) == "function" then
                        sink_to_use = socketutil.chainSinkWithProgressCallback(file_sink, progress_callback)
                    elseif progress_callback then
                        logger.dbg("Scraper: chainSinkWithProgressCallback not available, progress bar disabled")
                    end

                    logger.dbg("Scraper: Trying KOReader-native download with progress...")
                    local http_result = Api.makeHttpRequest{
                        url = download_url,
                        method = "GET",
                        headers = {
                            ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                        },
                        sink = sink_to_use,
                        timeout = {30, 300},
                        redirect = true,
                    }

                    if http_result and http_result.status_code == 200 then
                        logger.dbg("Scraper: KOReader-native download succeeded")
                        download_ok = true
                    else
                        logger.dbg("Scraper: KOReader-native download failed:",
                            tostring(http_result and http_result.error or "unknown"))
                        pcall(os.remove, temp_filename)
                    end
                end
            end
            end -- if socketutil

            -- Method B: Fallback to check_url (curl/wget/luasocket, no progress but reliable)
            if not download_ok then
                logger.dbg("Scraper: Falling back to check_url for download (no progress bar)...")
                local dl_status
                dl_status, dl_data = Scraper.check_url(download_url)

                if dl_status ~= "success" or not dl_data then
                    logger.dbg("Scraper: File download failed on", lgli_url, ", trying next mirror")
                    goto continue_mirror
                end

                -- Write to temp file
                local ok, msg = Scraper.save_file_bytes(temp_filename, dl_data)
                if not ok then
                    logger.dbg("Scraper: Failed to write temp file:", tostring(msg))
                    goto continue_mirror
                end
                download_ok = true
                dl_data = nil -- free memory
            end

            -- Validate the downloaded temp file
            local tf = io.open(temp_filename, "rb")
            if not tf then
                logger.dbg("Scraper: Could not open temp file for validation")
                goto continue_mirror
            end

            local header = tf:read(16) or ""
            local file_size = tf:seek("end") or 0
            tf:close()

            -- Reject HTML error pages
            local header_lower = header:lower()
            local is_html = header_lower:match("^<!doctyp") or header_lower:match("^<html") or header_lower:match("^<?xml")
            local too_small = (file_size < 10240)  -- under 10 kB is an error page

            if is_html or too_small then
                logger.warn(string.format("Scraper: Rejected bad file from %s: %d bytes, is_html=%s",
                    lgli_url, file_size, tostring(is_html)))
                os.remove(temp_filename)
                goto continue_mirror
            end

            -- Validate magic bytes for known formats
            local file_header = header:sub(1, 8)
            local valid = true
            if fmt == "epub" or fmt == "zip" or fmt == "cbz" or fmt == "azw3" then
                valid = (file_header:sub(1,2) == "PK")
                if not valid then
                    logger.dbg("Scraper: Expected ZIP/EPUB magic (PK) but got garbage — trying next mirror")
                end
            elseif fmt == "pdf" then
                valid = (file_header:sub(1,4) == "%PDF")
                if not valid then
                    logger.dbg("Scraper: Expected PDF magic but got garbage — trying next mirror")
                end
            end

            if not valid then
                os.remove(temp_filename)
                goto continue_mirror
            end

            -- All checks passed — rename temp file to actual file
            os.rename(temp_filename, filename)
            logger.dbg(string.format("Scraper: Download success: %s (%d bytes)", filename, file_size))
            return filename
        end

        ::continue_mirror::
    end

    return "Failed, all Library Genesis mirrors returned invalid content or an error page. Try changing DNS to 1.1.1.1."
end

-- Backward-compatible global wrappers for existing callers
function check_url(...)
    return Scraper.check_url(...)
end

function scraper(...)
    return Scraper.scraper(...)
end

function download_book(...)
    return Scraper.download_book(...)
end

function sanitize_name(...)
    return Scraper.sanitize_name(...)
end

function save_file_bytes(...)
    return Scraper.save_file_bytes(...)
end

function force_refresh_domains(...)
    return Scraper.force_refresh_domains(...)
end

return Scraper