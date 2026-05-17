local Config = require("annas.config")
local Api = require('annas.api')
local socketutil = require("socketutil")

-- Cache configuration
local CACHE_FILE = "annas_domains_cache.txt"
local CACHE_DURATION = 12 * 60 * 60  -- 12 hours in seconds

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
        print("=== Cache expired")
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
        print("=== Loaded", #domains, "domains from cache")
        return domains, timestamp
    end
    
    return nil, nil
end

-- Writes domains to cache
local function write_cache(domains)
    local f = io.open(CACHE_FILE, "w")
    if not f then
        print("=== Warning: Could not write cache file")
        return false
    end
    
    f:write(os.time() .. "\n")
    for _, domain in ipairs(domains) do
        f:write(domain .. "\n")
    end
    f:close()
    
    print("=== Cached", #domains, "domains")
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
            print("=== Found domain:", domain)
        end
    end
    
    return domains
end

-- Fetches domains from Wikipedia
local function fetch_domains_from_wikipedia()
    print("=== Fetching domains from Wikipedia...")
    
    local wikipedia_url = "https://en.wikipedia.org/wiki/Anna%27s_Archive"
    
    -- Try using different methods
    local status, data = check_url(wikipedia_url)
    
    if status ~= "success" or not data then
        print("=== Failed to fetch Wikipedia page")
        return nil
    end
    
    print("=== Successfully fetched Wikipedia page")
    
    local domains = extract_domains_from_wikipedia(data)
    
    if #domains == 0 then
        print("=== Warning: No domains found in Wikipedia page")
        return nil
    end
    
    print("=== Extracted", #domains, "domains from Wikipedia")
    
    -- Save to cache
    write_cache(domains)
    
    return domains
end

-- Main function to retrieve domains
local function get_annas_archive_domains()
    -- Try loading from cache first
    local cached_domains, cache_time = read_cache()
    if cached_domains then
        local age_hours = math.floor((os.time() - cache_time) / 3600)
        print("=== Using cached domains (age:", age_hours, "hours)")
        return cached_domains
    end
    
    -- If cache is unavailable, fetch from Wikipedia
    local domains = fetch_domains_from_wikipedia()
    
    if domains and #domains > 0 then
        return domains
    end
    
    -- Fallback: default domains if Wikipedia fails
    print("=== Warning: Using fallback domains")
    return {
        "annas-archive.li",
        "annas-archive.gl",
        "annas-archive.org",
        "annas-archive.se",
        "annas-archive.gs",
        "annas-archive.pm",
        "annas-archive.in",
    }
end

function force_refresh_domains()
    print("=== Force refreshing domains from Wikipedia ===")
    os.remove(CACHE_FILE)
    local domains = fetch_domains_from_wikipedia()
    if not domains or #domains == 0 then
        return false, "Failed to fetch active mirrors from Wikipedia. Check your internet connection."
    end
    return true, "Successfully refreshed mirrors! Found " .. #domains .. " active domains:\n" .. table.concat(domains, "\n")
end


local function extract_md5_and_link(line)
    -- Extract MD5 hash from href="/md5/<hash>" pattern
    local md5 = line:match('href="/md5/([a-fA-F0-9]+)"')
    if md5 and #md5 == 32 then
        return md5
    end
    return nil
end

local function extract_title(line)
    -- Extract title from data-content attribute and clean it
    local content = line:match('<div class="font%-bold text%-violet%-900 line%-clamp%-%[5%]" data%-content="([^"]+)"')
    if content then
        content = content:match("^%s*(.-)%s*$")  -- trim whitespace
        content = content:gsub('"', '\\"')     -- escape quotes
        content = content:gsub("•", "\\u2022") -- escape bullet points
        print('Title: ', content)
        return content
    end
    return 'Could not retrieve title.'
end

local function extract_author(line)
    -- Extract author from specific div class combination
    if line:match('<div[^>]*class="[^"]*font%-bold[^"]*text%-amber%-900[^"]*line%-clamp%-%[2%][^"]*"') then
        local block = line:match('<div[^>]*class="[^"]*font%-bold[^"]*text%-amber%-900[^"]*line%-clamp%-%[2%][^"]*" data%-content="[^"]+"')
        if block then
            local author = block:match('data%-content="([^"]+)"')
            if author then
                print("Author:", author)
                return author
            end
        end
    end
    return 'Could not retrieve author.'
end

local function extract_format(line)
    -- Extract file format (PDF, EPUB, etc.) from text content
    local div_text = line:match('<div class="text%-gray%-800[^>]*>[^<]+')
    if div_text then
        local content = div_text:match('>([^<]+)')
        if content then
            local format = content:match("([A-Z][A-Z]+)")  -- match uppercase format like PDF, EPUB
            if format then
                print('format: ', format)
                return format
            end
        end
    end
    return 'Could not retrieve format.'
end

local function extract_description(line)
    -- Extract and clean description text from HTML
    local div_block = line:match('<div[^>]*class="[^"]*line%-clamp%-%[2%][^"]*"[^>]*>(.-)</div>')
    print('desc: ', div_block)
    if div_block then
        local description = div_block
        description = description:gsub('<script[^>]*>.-</script>', '')  -- remove scripts
        description = description:gsub('<a[^>]*>.-</a>', '')           -- remove links
        description = description:gsub('<[^>]->', '')                -- remove HTML tags
        description = description:gsub('&[#a-zA-Z0-9]+;', '')          -- remove HTML entities
        description = description:gsub('^%s+', ''):gsub('%s+$', '')  -- trim whitespace
        print("Description:", description)
        return description
    end
    print("Description: Could not retrieve")
    return 'Could not retrieve description.'
end

-- Check if external command (curl/wget) is available
local function command_exists(cmd)
    local handle = io.popen("which " .. cmd .. " 2>/dev/null")
    if not handle then return false end
    local result = handle:read("*a")
    handle:close()
    return result and result ~= ""
end

-- Pure Lua HTTP implementation using LuaSocket (fallback method)
local function fetch_with_lua_socket(url)
    print('=== Trying pure Lua socket for URL:', url)
    
    local socket_ok, socket = pcall(require, "socket")
    local http_ok, http = pcall(require, "socket.http")
    local ltn12_ok, ltn12 = pcall(require, "ltn12")
    
    if not (socket_ok and http_ok and ltn12_ok) then
        print('=== LuaSocket not available')
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
        print('=== LuaSocket succeeded, got', #body, 'bytes')
        return "success", body
    else
        print('=== LuaSocket failed, code:', code, 'status:', status)
        return "socket_error", nil
    end
end

-- Try external commands (curl/wget) for HTTP requests
local function fetch_with_external_command(url)
    print('=== Trying external command for URL:', url)
    
    -- Try curl first (most reliable)
    if command_exists("curl") then
        print('=== Using curl')
        local handle = io.popen('curl -L -s --max-time 20 "' .. url .. '" 2>&1')
        if handle then
            local result = handle:read("*a")
            local success = handle:close()
            if success and result and #result > 0 then
                print('=== curl succeeded, got', #result, 'bytes')
                return "success", result
            end
        end
    end
    
    -- Try wget as fallback
    if command_exists("wget") then
        print('=== Using wget')
        local temp_file = os.tmpname()
        local cmd = string.format('wget -q -O "%s" --timeout=20 "%s" 2>&1', temp_file, url)
        local handle = io.popen(cmd)
        if handle then
            handle:close()
            local f = io.open(temp_file, "r")
            if f then
                local result = f:read("*a")
                f:close()
                os.remove(temp_file)
                if result and #result > 0 then
                    print('=== wget succeeded, got', #result, 'bytes')
                    return "success", result
                end
            end
        end
    end
    
    return "no_external_command", nil
end

-- Try KOReader's API with multiple header configurations
local function fetch_with_api(url, custom_sink)
    print('=== Trying Api.makeHttpRequest for:', url)
    
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
        print('=== API attempt', i, 'with', #headers, 'headers')
        
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
            print('=== API call threw error:', http_result)
            goto next_attempt
        end
        
        if not http_result then
            print('=== API returned nil')
            goto next_attempt
        end
        
        if http_result.error then
            print('=== API returned error:', http_result.error)
            goto next_attempt
        end
        
        local status_code = tonumber(http_result.status_code)
        if status_code == 200 and (custom_sink or (http_result.body and #http_result.body > 0)) then
            print('=== API succeeded with attempt', i)
            return "success", http_result.body
        else
            print('=== API attempt', i, 'failed - status:', status_code)
        end
        
        ::next_attempt::
    end
    
    return "api_failed", nil
end

-- Main HTTP request function with three-tier fallback system
function check_url(url)
    print('=== DEBUG: check_url called with:', url)
    
    -- Method 1: Try external commands (curl/wget) - most reliable
    local ext_status, ext_data = fetch_with_external_command(url)
    if ext_status == "success" then
        return "success", ext_data
    end
    
    print('=== External command not available, trying alternative methods')
    
    -- Method 2: Try LuaSocket (pure Lua, no external dependencies)
    local socket_status, socket_data = fetch_with_lua_socket(url)
    if socket_status == "success" then
        return "success", socket_data
    end
    
    print('=== LuaSocket not available or failed, trying Api.makeHttpRequest')
    
    -- Method 3: Try KOReader's API with multiple configurations
    local api_status, api_data = fetch_with_api(url)
    if api_status == "success" then
        return "success", api_data
    end
    
    -- All methods failed
    print('=== ERROR: All HTTP methods failed')
    print('=== Tried: external commands (curl/wget), LuaSocket, Api.makeHttpRequest')
    
    return "network_error", nil
end

function scraper(query, page_num)
    -- Get current Anna's Archive domains from Wikipedia (with caching)
    local aa_domains = get_annas_archive_domains()
    
    print("=== Using", #aa_domains, "Anna's Archive domains")

    local domain_counter = 0
    local protocols = {"https://"}
    local protocol_counter = 1
    local page = tostring(page_num or 1)

    if not query then
        query = ''
    end

    print('got query: ', query, 'page:', page)

    local encoded_query = string.gsub(query, " ", "+")
    local languages = Config.getSearchLanguages()
    local ext = Config.getSearchExtensions()
    local order = Config.getSearchOrder()
    local src = 'lgli'
    local filters = ''

    if languages then
        for k, lang in pairs(languages) do
            filters = filters .. "&lang=" .. lang
        end
    end

    if ext then
        for k, e in pairs(ext) do
            filters = filters .. "&ext=" .. string.lower(e)
        end
    end

    if order[1] then
        filters = filters .. "&sort=" .. order[1]
    end

    if src then
        filters = filters .. "&src=" .. src
    end

    print('applying filters: ', filters)

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
    
    print('Attempting URL:', url)
    print('Protocol:', protocols[protocol_counter], 'Domain:', aa_domains[domain_counter])
    
    local status, data = check_url(url)

    if status == "network_error" or status == "dns_error" then
        print('Network/DNS error on ', annas_url)
        print('Checking different mirror ...')
        goto retry
    elseif status == "success" then
        print("=== HTTP request succeeded")

        if not data or data == "" then
            print('=== ERROR: No data received from server')
            print('=== Retrying with different mirror...')
            goto retry
        end

        print('=== SUCCESS: Received data, length:', #data)
        print('=== First 100 chars:', string.sub(data, 1, 100))

        local ddos_guard_needle = 'der-gray-100<!doctype html><html><head><title>DDoS-Guard</titl'

        if data:find(ddos_guard_needle, 1, true) then
            print("=== DDoS guard triggered, trying different mirror ...")
            goto retry
        end

        -- Split HTML into book entries using consistent pattern
        local split_pattern = 'pt-3 pb-3 border-b last:border-b-0 border-gray-100'
        
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
            print("\n---- Entry #" .. i .. " ----\n")
            print(string.sub(entry, 1, 100))

            local md5 = extract_md5_and_link(entry)
            local link = nil
            
            if md5 then
                link = annas_url .. 'md5/' .. md5
                print('found link', link )
            else
                print('Couldnt fetch MD5 sum of entry, probs not a valid html segment.')
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
                book.download = 'lgli'

                if string.find(entry, "zlib", 1, true) then
                    book.download = book.download .. ' | zlib'
                end
            else
                if string.find(entry, "zlib", 1, true) then
                    book.download = 'zlib'
                end
            end

            local number_str = entry:match(" (%d+%.?%d*)MB · ")

            if number_str then
                book.size = number_str .. "MB"
            else
                number_str = 'NA'
            end

            print(book.download)

            table.insert(book_lst, book)
            book_count = book_count + 1
            
            ::continue::
        end

        print("found " .. book_count .. " entries")

        return book_lst
    else
        print('Unknown error on ', annas_url, ': ', status)
        print('Checking different mirror ...')
        goto retry
    end
    return "Unknown error occurred"
end

function sanitize_name(name)
    local sanitized = name
    sanitized = sanitized:gsub("[^%w._-]", "_")
    sanitized = sanitized:gsub(" ", "_")
    return sanitized
end

-- Save binary data to file
function save_file_bytes(path, bytes)
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
function download_book(book, path, progress_callback, is_cancelled_func)
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
        print('no source available')
        return "Failed, no download source available [lgli, zlib]."
    end

    local fmt = (book.format or "unknown"):lower()
    local filename = path .. "/" .. sanitize_name(book.title) .. "_" .. sanitize_name(book.author) .. "." .. fmt

    for _, lgli_ext in ipairs(lgli_exts) do
        local lgli_url = "https://libgen" .. lgli_ext
        print("=== Trying mirror: " .. lgli_url)

        -- Only try libgen if this source is available
        if not string.find(book.download, 'lgli', 1, true) then
            print('book not available on libgen, skipping')
            break
        end

        local download_page_url = lgli_url .. "ads.php?md5=" .. book.md5
        print('download page: ', download_page_url)
        local status, page_data = check_url(download_page_url)

        if status ~= "success" or not page_data then
            print("=== ads page failed on " .. lgli_url .. ", trying next mirror")
            goto continue_mirror
        end

        -- Check ads page isn't a DDoS/captcha wall
        local page_lower = page_data:lower()
        if page_lower:match("ddos%-guard") or page_lower:match("access denied") or page_lower:match("cloudflare") then
            print("=== DDoS/block detected on " .. lgli_url .. ", trying next mirror")
            goto continue_mirror
        end

        do
            -- Extract the actual download link from the ads page
            local download_link = page_data:match('href="([^"]*get%.php[^"]*)"')

            if not download_link then
                print("=== No get.php link found on " .. lgli_url .. ", trying next mirror")
                goto continue_mirror
            end

            -- Fix potential double-slash: strip trailing / from base, ensure link starts with /
            local base = lgli_url:gsub("/$", "")
            if not download_link:match("^/") then
                download_link = "/" .. download_link
            end
            local download_url = base .. download_link
            print("=== Final download URL: " .. download_url)

            local temp_filename = filename .. ".tmp"
            local dl_data = nil
            local download_ok = false

            -- Method A: KOReader-native socketutil sink with progress (pure Lua, works on Kobo)
            do
                local f = io.open(temp_filename, "wb")
                if f then
                    local file_sink = socketutil.file_sink(f)
                    local sink_to_use = file_sink

                    -- Chain progress callback if available (KOReader 2025.08+)
                    if progress_callback and type(socketutil.chainSinkWithProgressCallback) == "function" then
                        sink_to_use = socketutil.chainSinkWithProgressCallback(file_sink, progress_callback)
                    end

                    print("=== Trying KOReader-native download with progress...")
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
                        print("=== KOReader-native download succeeded")
                        download_ok = true
                    else
                        print("=== KOReader-native download failed: " .. tostring(http_result and http_result.error or "unknown"))
                        pcall(os.remove, temp_filename)
                    end
                end
            end

            -- Method B: Fallback to check_url (curl/wget/luasocket, no progress but reliable)
            if not download_ok then
                print("=== Falling back to check_url for download (no progress bar)...")
                local dl_status
                dl_status, dl_data = check_url(download_url)

                if dl_status ~= "success" or not dl_data then
                    print("=== File download failed on " .. lgli_url .. ", trying next mirror")
                    goto continue_mirror
                end

                -- Write to temp file
                local ok, msg = save_file_bytes(temp_filename, dl_data)
                if not ok then
                    print("=== Failed to write temp file: " .. tostring(msg))
                    goto continue_mirror
                end
                download_ok = true
                dl_data = nil -- free memory
            end

            -- Validate the downloaded temp file
            local tf = io.open(temp_filename, "rb")
            if not tf then
                print("=== Could not open temp file for validation")
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
                print(string.format("=== Rejected bad file from %s: %d bytes, is_html=%s",
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
                    print("=== Expected ZIP/EPUB magic (PK) but got garbage — trying next mirror")
                end
            elseif fmt == "pdf" then
                valid = (file_header:sub(1,4) == "%PDF")
                if not valid then
                    print("=== Expected PDF magic but got garbage — trying next mirror")
                end
            end

            if not valid then
                os.remove(temp_filename)
                goto continue_mirror
            end

            -- All checks passed — rename temp file to actual file
            os.rename(temp_filename, filename)
            print(string.format("=== Download success: %s (%d bytes)", filename, file_size))
            return filename
        end

        ::continue_mirror::
    end

    return "Failed, all Library Genesis mirrors returned invalid content or an error page. Try changing DNS to 1.1.1.1."
end

-- Main execution block (runs when script is executed directly)
if ... == nil then
    print("Running as main script")
    local book_lst = scraper('Marx')
end
