--[[--
This is a stoka plugin

@module koplugin.libby
--]]
--
local ConfirmBox = require("ui/widget/confirmbox")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local JSON = require("json")
local http = require("socket.http")
local NetworkMgr = require("ui/network/manager")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local Stoka = WidgetContainer:extend {
    name = "Stoka",
    is_doc_only = false,
}

function Stoka:logout()
    self.stoka_token = ""
    G_reader_settings:saveSetting("stoka_token", "")
end

function Stoka:login(username, password)
    local uri = self.stoka_endpoint .. "/na/user"
    local data = JSON.encode({ username = username, password = password, identifier = "password" })
    local sink = {}
    local code, headers, status = socket.skip(1, http.request {
        url     = uri,
        method  = "POST",
        headers = {
            ["Content-Type"]   = "application/json",
            ["Content-Length"] = string.len(data),
        },
        source  = ltn12.source.string(data),
        sink    = ltn12.sink.table(sink),

    })
    socketutil:reset_timeout()
    local result_response = table.concat(sink)
    logger.dbg("Hlleow from login", username, password, data, uri, headers, result_response, code)
    if code == 200 then
        logger.dbg()
        local ret, result = pcall(JSON.decode, result_response)
        logger.dbg('current tokten', self.stoka_token)
        self.stoka_token = result.token;
        G_reader_settings:saveSetting("stoka_token", self.stoka_token)
        logger.dbg("Stokav: Response headers:", headers)
    end
    return code
end

function Stoka:downloadBook(id)
    logger.dbg(id)
    local uri = self.stoka_endpoint .. "/api/book/" .. id
    local sink = {}
    local code, headers, status = socket.skip(1, http.request {
        url     = uri,
        method  = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. self.stoka_token,
        },
        sink    = ltn12.sink.table(sink),
    })
    local result_response = table.concat(sink)
    if code == 200 then
        local _, result = pcall(JSON.decode, result_response)
        local fp = self.stoka_path .. "/" .. result.data.title .. "." .. result.data.file_type.name;
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        
        local code, _, _ = socket.skip(1, http.request {
            url     = uri .. '/dl',
            method  = "GET",
            headers = {
                ["Authorization"] = "Bearer " .. self.stoka_token,
            },
            sink    = ltn12.sink.file(io.open(fp, "wb+")),
        })
        logger.dbg(code, fp)
        socketutil:reset_timeout()
    end
end

function Stoka:download(all)
    logger.dbg(self.stoka_hashes)

    local sink = {}

    local uri = self.stoka_endpoint .. "/api/books"
    local code, _, _ = socket.skip(1, http.request {
        url     = uri,
        method  = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. self.stoka_token
        },
        sink    = ltn12.sink.table(sink),
    })
    logger.dbg(code, uri, self.stoka_token)
    socketutil:reset_timeout()
    local result_response = table.concat(sink)
    if code == 200 then
        local _, result = pcall(JSON.decode, result_response)
        for _, book in ipairs(result.data) do
            if all or not self.stoka_hashes[book.hash] == true then
                self:downloadBook(book.id);
                self.stoka_hashes[book.hash] = true
            else
                logger.dbg('Skipping book with hash ', book.hash)
            end
        end
        G_reader_settings:saveSetting("stoka_hashes", JSON.encode(self.stoka_hashes)) -- stoka_hashes is a table of hashes that have already been seen
        logger.dbg(self.stoka_hashes)
    end
end

function Stoka:init()
    local ret, hashes = pcall(JSON.decode, G_reader_settings:readSetting("stoka_hashes")) 
    self.stoka_hashes = ret and hashes or {}
    self.stoka_token = G_reader_settings:readSetting("stoka_token") or ""
    self.stoka_path = G_reader_settings:readSetting("stoka_path") or "../Stoka"
    lfs.mkdir(self.stoka_path)
    self.stoka_endpoint = G_reader_settings:readSetting("stoka_endpoint") or "https://stoka.notmarek.com"
    self.ui.menu:registerToMainMenu(self)
end

function Stoka:addToMainMenu(menu_items)
    menu_items.stoka = {
        text = _("Stoka"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text_func = function() return _(self.stoka_token == "" and "Sign in" or "Logout") end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    if self.stoka_token == "" then
                        self:show_login_dialog(touchmenu_instance)
                    else
                        UIManager:show(ConfirmBox:new {
                            text = _("Cancel"),
                            ok_text = _("Logout"),
                            ok_callback = function()
                                self:logout()
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end,
                        })
                    end
                end,
                checked_func = function() return not (self.stoka_token == "") end
            },
            {
                text = _("Download New"),
                keep_menu_open = false,
                callback = function() NetworkMgr:runWhenOnline(function() self:download(false) end) end,
                enabled_func = function() return not (self.stoka_token == "") end,

            },
            {
                text = _("Redownload All"),
                keep_menu_open = false,
                callback = function() NetworkMgr:runWhenOnline(function()  self:download(true) end) end,
                enabled_func = function() return not (self.stoka_token == "") end,
            },
        }
    }
end

function Stoka:show_login_dialog(touchmenu_instance)
    local text_endpoint, text_username, text_password, text_path
    text_endpoint = self.stoka_endpoint
    text_path = self.stoka_path
    self.login_dialog = MultiInputDialog:new {
        title = _("Login to stoka"),
        fields = {
            {
                text = text_endpoint,
                hint = _("Stoka endpoint"),
            },
            {
                text = text_username,
                hint = _("Username"),
            },
            {
                text = text_password,
                hint = _("Password"),
            },
            {
                text = text_path,
                hint = _("Stoka folder (/ for root)"),
            }
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.login_dialog)
                    end,
                },
                {
                    text = _("Login"),
                    is_enter_default = true,
                    callback = function()
                        local fields = self.login_dialog:getFields()
                        text_endpoint = fields[1]
                        text_username = fields[2]
                        text_password = fields[3]
                        text_path = fields[4]
                        logger.dbg("popup", fields, text_username, text_password)
                        self.stoka_path = text_path
                        G_reader_settings:saveSetting("stoka_path", self.stoka_path)
                        self.stoka_endpoint = text_endpoint
                        G_reader_settings:saveSetting("stoka_endpoint", self.stoka_endpoint)
                        self:login(text_username, text_password)
                        UIManager:close(self.login_dialog)

                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                },
            },
        },
    }
    UIManager:show(self.login_dialog)
    self.login_dialog:onShowKeyboard()
end

return Stoka
