local urlparse = require("socket.url")
local https = require("ssl.https")
local cjson = require("cjson")
local utf8 = require("utf8")
local html_entities = require("htmlEntities")
local openssl_digest = require("openssl.digest")
local basexx = require("basexx")

local item_dir = os.getenv("item_dir")
local warc_file_base = os.getenv("warc_file_base")
local item_type = nil
local item_name = nil
local item_value = nil

local url_count = 0
local tries = 0
local downloaded = {}
local addedtolist = {}
local abortgrab = false
local killgrab = false
local logged_response = false
local status_code = 0
local content_type = ""

local discovered_outlinks = {}
local discovered_items = {}
local bad_items = {}
local ids = {}

local retry_url = false
local context = {}
local warc_digests = {}

local item_patterns = {
  ["^https?://zapytaj%.onet%.pl/Category/[0-9]+,[0-9]+/2,([0-9]+),[^/]+%.html"] = "question",
  ["^https?://zapytaj%.onet%.pl/Profile/user_([0-9]+)%.html"] = "user",
  ["^https?://zapytaj%.onet%.pl/Profile/page,[a-z]+,([0-9]+),[0-9]+%.html"] = "user",
  ["^https?://zapytaj%.onet%.pl/Profile/5,best,([0-9]+),[0-9]+%.html"] = "user",
  ["^https?://zapytaj%.onet%.pl/Profile/([0-9]+)/Comments/"] = "user",
  ["^https?://zapytaj%.onet%.pl/profil/([0-9]+)/"] = "user",
  ["^https?://zapytaj%.onet%.pl/klub/([^/%?]+)"] = "club",
  ["^https?://zapytaj%.onet%.pl/([^/%?]+)%?comment_page=[0-9]+"] = "club",
  ["^https?://zapytaj%.onet%.pl/([^/%?]+)/pytania/lista%.html"] = "club",
  ["^https?://zapytaj%.onet%.pl/rss/club/([^/]+)%.xml"] = "club",
  ["^https?://(zapytaj%.onet%.pl/css/[^#]+)"] = "media",
  ["^https?://(zapytaj%.onet%.pl/js/[^#]+)"] = "media",
  ["^https?://(zapytaj%.onet%.pl/font/[^#]+)"] = "media",
  ["^https?://(zapytaj%.onet%.pl/images/[^#]+)"] = "media",
  ["^https?://(zapytaj%.onet%.pl/images%-v3/[^#]+)"] = "media",
  ["^https?://(zapytaj%.onet%.pl/image/generate%.html%?[^#]+)"] = "media",
  ["^https?://(ocdn%.eu/zapytaj/[^#]+)"] = "media",
  ["^https?://(ocdn%.eu/zapytaj%-transforms/[^#]+)"] = "media",
  ["^https?://(ocdn%.eu/images/zapytaj/[^#]+)"] = "media",
  ["^https?://(ocdn%.eu/_m[^#]+)"] = "media",
  ["^https?://(avatars%.zapytaj%.com%.pl/[^#]+)"] = "media",
  ["^https?://(images%.zapytaj%.com%.pl/[^#]+)"] = "media",
}

abort_item = function(item)
  abortgrab = true
  if not item then
    item = item_name
  end
  if not bad_items[item] then
    io.stdout:write("Aborting item " .. item .. ".\n")
    io.stdout:flush()
    bad_items[item] = true
  end
end

kill_grab = function(item)
  io.stdout:write("Aborting crawling.\n")
  io.stdout:flush()
  killgrab = true
end

read_file = function(file)
  if file then
    local f = assert(io.open(file, "rb"))
    local body = f:read("*all")
    f:close()
    return body
  else
    return ""
  end
end

processed = function(url)
  if downloaded[url] or addedtolist[url] then
    return true
  end
  return false
end

discover_item = function(target, item)
  if item ~= item_name and not target[item] then
    target[item] = true
    return true
  end
  return false
end

percent_encode_url = function(newurl)
  return string.gsub(newurl, "(.)", function(c)
    local b = string.byte(c)
    if b < 32 or b > 126 then
      return string.format("%%%02X", b)
    end
    return c
  end)
end

find_item = function(url)
  for pattern, type_ in pairs(item_patterns) do
    local value = string.match(url, pattern)
    if value then
      if type_ ~= "media" then
        value = percent_encode_url(urlparse.unescape(value))
      end
      return {
        ["value"]=value,
        ["type"]=type_
      }
    end
  end
end

finish_item = function()
  if item_name then
    for _, checked in pairs(context["digests"]) do
      if checked ~= true and not warc_digests[checked] then
        error("WARC digest does not match downloaded data.")
      end
    end
  end
end

set_item = function(url)
  if ids[string.lower(url)] then
    return nil
  end
  local found = find_item(url)
  if found then
    local new_item_type = found["type"]
    local new_item_value = found["value"]
    local new_item_name = new_item_type .. ":" .. new_item_value
    if new_item_name ~= item_name then
      finish_item()
      ids = {}
      context = {
        ["entry_url"]=url,
        ["digests"]={}
      }
      item_value = new_item_value
      item_type = new_item_type
      ids[string.lower(url)] = true
      ids[string.lower(urlparse.unescape(item_value))] = true
      abortgrab = false
      tries = 0
      retry_url = false
      item_name = new_item_name
      print("Archiving item " .. item_name)
    end
  end
end

allowed = function(url, parent)
  local lower = string.lower(url)
  if ids[lower] then
    return true
  end

  for _, pattern in pairs({
    "^https?://zapytaj%.onet%.pl/report%-notice/",
    "^https?://zapytaj%.onet%.pl/klub/[^/%?]+/[^/%?]+/create%.html",
    "^https?://zapytaj%.onet%.pl/klub/[^/%?]+/zapytaj%.html",
    "^https?://events%.ocdn%.eu/",
    "^https?://kropka%.onet%.pl/",
    "^https?://lib%.onet%.pl/",
    "^https?://[^/]*googletagmanager%.com/",
    "^https?://[^/]*googleadservices%.com/",
    "^https?://[^/]*gstatic%.com/prose/",
    "^https?://[^/]*facebook%.com/sharer/",
    "^https?://[^/]*facebook%.com/2008/fbml",
    "^https?://[^/]*w3%.org/2000/svg",
    "^https?://schema%.org/"
  }) do
    if string.match(lower, pattern) then
      return false
    end
  end

  local found = find_item(url)
  if found then
    local new_item = found["type"] .. ":" .. found["value"]
    if new_item ~= item_name then
      discover_item(discovered_items, percent_encode_url(new_item))
      return false
    end
    return true
  end

  if not (
    string.match(lower, "^https?://zapytaj%.onet%.pl/")
    or string.match(lower, "^https?://r%.adres%.pl/")
    or string.match(lower, "^https?://ocdn%.eu/")
    or string.match(lower, "^https?://[^/]*%.zapytaj%.com%.pl/")
  ) then
    discover_item(discovered_outlinks, string.match(percent_encode_url(url), "^([^%s]+)"))
    return false
  end

  if item_type == "question"
    and string.match(lower .. "?", "^https?://zapytaj%.onet%.pl/comment/answer/previous%.html%?") then
    return true
  end

  if item_type == "user"
    and string.match(lower, "^https?://r%.adres%.pl/[0-9]+%.html") then
    for _, pattern in pairs({
      "([0-9]+)",
      "([^/%?&;=]+)"
    }) do
      for identifier in string.gmatch(string.match(url, "^([^%?]+)"), pattern) do
        identifier = urlparse.unescape(identifier)
        if ids[string.lower(identifier)] then
          return true
        end
      end
    end
  end

  return false
end

wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  return false
end

decode_codepoint = function(newurl)
  newurl = string.gsub(
    newurl, "\\[uU]([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])",
    function(s)
      return utf8.char(tonumber(s, 16))
    end
  )
  return newurl
end

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local html = nil

  downloaded[url] = true

  if abortgrab then
    return {}
  end

  local function fix_case(newurl)
    if not string.match(newurl, "^https?://[^/]") then
      return newurl
    end
    if string.match(newurl, "^https?://[^/]+$") then
      newurl = newurl .. "/"
    end
    local a, b = string.match(newurl, "^(https?://[^/]+/)(.*)$")
    return string.lower(a) .. b
  end

  local function check(newurl, body_data)
    if not newurl then
      newurl = ""
    end
    newurl = html_entities.decode(decode_codepoint(newurl))
    newurl = string.gsub(newurl, "\\/", "/")
    newurl = string.match(newurl, "^%s*(.-)%s*$")
    newurl = fix_case(newurl)
    if not string.match(newurl, "^https?://") or string.match(newurl, "[%s\\\"<>]") then
      return nil
    end
    local url = string.match(newurl, "^([^#]+)")
    local url_ = url
    while string.match(url_, "&amp;") do
      url_ = string.gsub(url_, "&amp;", "&")
    end
    if not body_data
      and string.match(url_, "^https?://zapytaj%.onet%.pl/Comment/Answer/previous%.html") then
      return nil
    end
    local key = (body_data and "POST" or "GET") .. "\0" .. url_ .. "\0" .. (body_data or "")
    if not processed(key)
      and (body_data or not processed(url_))
      and allowed(url_) then
      local url_data = {
        url=url_,
        headers={}
      }
      if body_data then
        url_data["body_data"] = body_data
        url_data["method"] = "POST"
        url_data["headers"]["Content-Type"]="application/x-www-form-urlencoded; charset=UTF-8"
      end
      table.insert(urls, url_data)
      addedtolist[key] = true
      if not body_data then
        addedtolist[url_] = true
        addedtolist[url] = true
      end
      return true
    end
  end

  local function checknewurl(newurl)
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "['\"><]") then
      return nil
    end
    if string.match(newurl, "^https?:////") then
      check((string.gsub(newurl, ":////", "://")))
    elseif string.match(newurl, "^https?://") then
      check(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check((string.gsub(newurl, "\\", "")))
    elseif string.match(newurl, "^\\/\\/") then
      checknewurl((string.gsub(newurl, "\\", "")))
    elseif string.match(newurl, "^//") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^\\/") then
      checknewurl((string.gsub(newurl, "\\", "")))
    elseif string.match(newurl, "^/") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(urlparse.absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "['\"><]") then
      return nil
    end
    newurl = string.gsub(newurl, " ", "%%20")
    if string.match(newurl, "^%?") then
      check(urlparse.absolute(url, newurl))
    elseif not (
      string.match(newurl, "^https?:\\?/\\?//?/?")
      or string.match(newurl, "^[/\\]")
      or string.match(newurl, "^%./")
      or string.match(newurl, "^[jJ]ava[sS]cript:")
      or string.match(newurl, "^[mM]ail[tT]o:")
      or string.match(newurl, "^vine:")
      or string.match(newurl, "^android%-app:")
      or string.match(newurl, "^ios%-app:")
      or string.match(newurl, "^data:")
      or string.match(newurl, "^irc:")
      or string.match(newurl, "^%${")
    ) then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function check_comments(answer, page)
    local body_data = "answer=" .. answer .. "&question=" .. item_value .. "&page=" .. tostring(page)
    check("https://zapytaj.onet.pl/Comment/Answer/previous.html", body_data)
    check("https://zapytaj.onet.pl/Comment/Answer/previous.html?" .. body_data, body_data)
  end

  if allowed(url) and status_code < 300 then
    if item_type == "media" then
      if url == context["entry_url"]
        and string.match(url, "^https?://ocdn%.eu/zapytaj/") then
        check("https://zapytaj.onet.pl/image/generate.html?url=" .. url .. "&image=large")
      end
      local data = string.match(url, "^https?://ocdn%.eu/zapytaj%-transforms/1/...([0-9a-zA-Z_%-]+)")
      if data then
        local image_url = string.match(basexx.from_url64(data), "(MDA_/[0-9a-zA-Z_%.%-]+)")
        if image_url then
          check("https://ocdn.eu/zapytaj/" .. image_url)
        end
      end
      if string.match(content_type, "text/css") or string.match(content_type, "javascript") then
        html = read_file(file)
      end
    else
      html = read_file(file)
      if string.match(url, "^https?://zapytaj%.onet%.pl/Comment/Answer/previous%.html%?") then
        if string.match(html, "id=[\"']commentdiv[0-9]+") then
          check_comments(string.match(url, "[%?&]answer=([0-9]+)"), tonumber(string.match(url, "[%?&]page=([0-9]+)")) + 1)
        end
      elseif item_type == "question" then
        for tag in string.gmatch(html, "<a%s+([^>]+)>") do
          if string.match(tag, "id=[\"']prev_comment[\"']") then
            check_comments(string.match(tag, "answer=[\"']([0-9]+)"), tonumber(string.match(tag, "page=[\"']([0-9]+)")))
          end
        end
      elseif item_type == "user"
        and string.match(url, "^https?://zapytaj%.onet%.pl/Profile/user_[0-9]+%.html$") then
        check("https://zapytaj.onet.pl/Profile/" .. item_value .. "/Comments/By/User/0.html")
        check("https://zapytaj.onet.pl/profil/" .. item_value .. "/prezenty.html")
      end
    end

    if html then
      for quote, quoted in pairs({
        ["\""]=string.gsub(html, "&[qQ][uU][oO][tT];", "\""),
        ["'"]=string.gsub(html, "&#039;", "'")
      }) do
        for newurl in string.gmatch(quoted, "([^" .. quote .. "]+)") do
          checknewurl(newurl)
        end
        for _, attribute in pairs({"href", "src", "data-src"}) do
          for newurl in string.gmatch(html, "[^%-]" .. string.gsub(attribute, "%-", "%%-") .. "=" .. quote .. "([^" .. quote .. "]+)" .. quote) do
            checknewshorturl(newurl)
          end
        end
      end
      for newurl in string.gmatch(html, "url%(%s*(.-)%s*%)") do
        newurl = string.gsub(html_entities.decode(newurl), "^[\"'](.-)[\"']$", "%1")
        checknewurl(newurl)
        checknewshorturl(newurl)
      end
      for newurl in string.gmatch(html, "<link>(.-)</link>") do
        check(string.match(newurl, "^%s*<!%[CDATA%[(.-)%]%]>%s*$") or newurl)
      end
      html = string.gsub(html, "&gt;", ">")
      html = string.gsub(html, "&lt;", "<")
      for newurl in string.gmatch(html, ">%s*([^<%s]+)") do
        checknewurl(newurl)
      end
    end
  end

  return urls
end

wget.callbacks.dedup_response = function(url, digest)
  if context["digests"][url] then
    if digest ~= context["digests"][url] then
      error("WARC digest does not match downloaded data.")
    end
    context["digests"][url] = true
    warc_digests[digest] = true
  end
end

wget.callbacks.write_to_warc = function(url, http_stat)
  local headers = http_stat["response_headers"]["headers"]
  status_code = http_stat["statcode"]
  content_type = headers["content-type"] and string.lower(headers["content-type"][1]) or ""
  set_item(url["url"])

  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
  io.stdout:flush()

  logged_response = true
  if not item_name then
    error("No item name found.")
  end

  if abortgrab then
    print("Not writing to WARC.")
    return false
  end

  if http_stat["res"] < 0 then
    return false
  end

  if not (
    status_code == 200
    or status_code == 301
    or status_code == 302
    or (
      status_code == 404
      and (url["url"] == context["entry_url"] or item_type == "media")
    )
  ) then
    retry_url = true
    return false
  end

  if status_code == 200 then
    if (http_stat["contlen"] >= 0 and http_stat["len"] ~= http_stat["contlen"])
      or (
        http_stat["len"] == 0
        and not string.match(url["url"], "^https?://zapytaj%.onet%.pl/Comment/Answer/previous%.html")
      ) then
      retry_url = true
      return false
    end
    if string.match(url["url"], "^https?://zapytaj%.onet%.pl/Comment/Answer/previous%.html") then
      local html = read_file(http_stat["local_file"])
      if string.match(html, "^%s*{") then
        if cjson.decode(html)["error"] then
          retry_url = true
          return false
        end
      end
      if string.match(html, "%S") and not string.match(html, "id=[\"']commentdiv[0-9]+") then
        retry_url = true
        return false
      end
    end

    if http_stat["len"] > 0 then
      local expected = nil
      if string.match(url["url"], "^https?://ocdn%.eu/zapytaj") and headers["etag"] then
        expected = string.match(headers["etag"][1], "^\"([0-9a-fA-F]+)\"$")
      end
      local sha1 = openssl_digest.new("sha1")
      local md5 = nil
      if expected and string.len(expected) == 32 then
        md5 = openssl_digest.new("md5")
      end
      local file = assert(io.open(http_stat["local_file"], "rb"))
      while true do
        local data = file:read(16 * 1024 * 1024)
        if not data then
          break
        end
        sha1:update(data)
        if md5 then
          md5:update(data)
        end
      end
      file:close()
      if md5 and basexx.to_hex(md5:final()) ~= string.upper(expected) then
        error("File does not match etag.")
      end
      context["digests"][url["url"]] = "sha1:" .. basexx.to_base32(sha1:final())
    end
  end

  if status_code >= 300 and status_code <= 399 then
    if not http_stat["newloc"] then
      retry_url = true
      return false
    end
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    if string.match(newloc, "[%s\\\"]") or not string.match(newloc, "^https?://") then
      retry_url = true
      return false
    end
  end

  retry_url = false
  tries = 0
  return true
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]
  set_item(url["url"])

  if not logged_response then
    url_count = url_count + 1
    io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
    io.stdout:flush()
    retry_url = true
  end
  logged_response = false

  if killgrab then
    return wget.actions.ABORT
  end

  if not item_name then
    error("No item name found.")
  end

  if abortgrab then
    abort_item()
    return wget.actions.EXIT
  end

  local newloc = nil
  if status_code >= 300 and status_code <= 399 then
    if http_stat["newloc"] then
      newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    end
  end

  if status_code == 0 or http_stat["res"] < 0 or retry_url then
    io.stdout:write("Server returned bad response. ")
    io.stdout:flush()
    tries = tries + 1
    local maxtries = 5
    if string.match(url["url"], "/image/generate%.html%?") then
      maxtries = 0
    end
    if tries > maxtries then
      io.stdout:write(" Skipping.\n")
      io.stdout:flush()
      tries = 0
      abort_item()
      return wget.actions.EXIT
    end
    local sleep_time = math.random(
      math.floor(math.pow(2, tries-0.5)),
      math.floor(math.pow(2, tries))
    )
    io.stdout:write("Sleeping " .. sleep_time .. " seconds.\n")
    io.stdout:flush()
    os.execute("sleep " .. sleep_time)
    return wget.actions.CONTINUE
  else
    downloaded[url["url"]] = true
  end

  if newloc then
    if string.match(url["url"], "^https?://zapytaj%.onet%.pl/image/generate%.html%?") then
      local image_url = string.match(url["url"], "[%?&]url=([^&]+)")
      if image_url then
        if not string.match(image_url, "^https?://") then
          image_url = urlparse.unescape(image_url)
        end
        allowed(image_url, url["url"])
      end
    end
    if processed(newloc) or not allowed(newloc, url["url"]) then
      tries = 0
      return wget.actions.EXIT
    end
  end

  tries = 0

  return wget.actions.NOTHING
end

wget.callbacks.finish = function(start_time, end_time, wall_time, numurls, total_downloaded_bytes, total_download_time)
  finish_item()
  local function submit_backfeed(items, key)
    local tries = 0
    local maxtries = 5
    while tries < maxtries do
      if killgrab then
        return false
      end
      local body, code, headers, status = https.request(
        "https://legacy-api.arpa.li/backfeed/legacy/" .. key,
        items .. "\0"
      )
      if code == 200 and body ~= nil and cjson.decode(body)["status_code"] == 200 then
        io.stdout:write(string.match(body, "^(.-)%s*$") .. "\n")
        io.stdout:flush()
        return nil
      end
      io.stdout:write("Failed to submit discovered URLs." .. tostring(code) .. tostring(body) .. "\n")
      io.stdout:flush()
      os.execute("sleep " .. math.floor(math.pow(2, tries)))
      tries = tries + 1
    end
    kill_grab()
    error()
  end

  local file = io.open(item_dir .. "/" .. warc_file_base .. "_bad-items.txt", "w")
  for url, _ in pairs(bad_items) do
    file:write(url .. "\n")
  end
  file:close()
  for key, data in pairs({
    ["zapytajonet-56ea22d1033e0d4a"] = discovered_items,
    ["urls-2737e6525ab2fe5c"] = discovered_outlinks
  }) do
    print("queuing for", string.match(key, "^(.+)%-"))
    local items = nil
    local count = 0
    for item, _ in pairs(data) do
      print("found item", item)
      if items == nil then
        items = item
      else
        items = items .. "\0" .. item
      end
      count = count + 1
      if count == 1000 then
        submit_backfeed(items, key)
        items = nil
        count = 0
      end
    end
    if items ~= nil then
      submit_backfeed(items, key)
    end
  end
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if killgrab then
    return wget.exits.IO_FAIL
  end
  if abortgrab then
    abort_item()
  end
  return exit_status
end
