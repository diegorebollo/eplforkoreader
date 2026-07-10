local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local SQ3 = require("lua-ljsqlite3/init")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
local logger = require("logger")


local EpubLibre = WidgetContainer:extend {
    name = "epublibre",
    is_doc_only = false,
}

local DB_BASE = "https://raw.githubusercontent.com/diegorebollo/eplforkoreader/main"

function EpubLibre:init()
    self.ui.menu:registerToMainMenu(self)
    local db_path = self.path .. "/db.db"
    logger.dbg(db_path)
    local f = io.open(db_path)
    if f then
        f:close()
        self.db = SQ3.open(db_path)
        if not self.db then
            logger.warn("ePubLibre: could not open db at", db_path)
        end
    end
    local ok, cfg = pcall(dofile, self.path .. "/config.lua")
    self.config = ok and cfg or {}
    self.config.books_dir = self.config.books_dir or "/mnt/base-us/documents/books"
    self.config.torrent_timeout = self.config.torrent_timeout or 300
    self.config.trackers = self.config.trackers or {}
end

function EpubLibre:searchInDB(query)
    if not self.db then return {} end
    local like_pattern = "%" .. query .. "%"
    local sql = "SELECT * FROM books WHERE title LIKE ? OR author LIKE ? LIMIT 200"
    local author_prefix = query:lower():match("^author:%s*(.*)")
    if author_prefix and #author_prefix > 0 then
        like_pattern = "%" .. author_prefix .. "%"
        sql = "SELECT * FROM books WHERE author LIKE ? LIMIT 200"
    end
    local stmt = self.db:prepare(sql)
    if not stmt then
        return {}
    end
    local results = {}
    stmt:bind(like_pattern, like_pattern)
    for row in stmt:rows() do
        table.insert(results, row)
    end
    stmt:close()
    return results
end

function EpubLibre:showSearchResults(query)
    local results = self:searchInDB(query)

    if #results == 0 then
        UIManager:show(InfoMessage:new {
            text = "No se encontraron resultados para:\n" .. query,
            timeout = 3,
        })
        return
    end

    local item_table = {}
    for _, row in ipairs(results) do
        local title = row["title"] or row[1] or "Sin título"
        local author = row["author"] or row[2] or ""
        local year = row["year"] or row[3]
        local magnet = row["magnet"] or row[4]
        if year then
            year = tonumber(year)
        end
        local mandatory = author
        if year then
            mandatory = mandatory .. " (" .. year .. ")"
        end
        if #mandatory > 30 then
            mandatory = mandatory:sub(1, 27) .. "..."
        end

        table.insert(item_table, {
            text = title,
            mandatory = mandatory,
            callback = function()
                local lines = { title }
                if author then table.insert(lines, "Autor: " .. author) end
                if year then table.insert(lines, "Año: " .. tostring(year)) end

                self.detail_dialog = ButtonDialogTitle:new {
                    title = table.concat(lines, "\n"),
                    buttons = {
                        {
                            {
                                text = "Descargar",
                                callback = function()
                                    UIManager:close(self.detail_dialog)
                                    if not magnet then
                                        UIManager:show(InfoMessage:new {
                                            text = "No hay enlace de descarga",
                                            timeout = 2,
                                        })
                                        return
                                    end
                                    local TRACKERS = ""
                                    for _, t in ipairs(self.config.trackers) do
                                        TRACKERS = TRACKERS .. "&tr=" .. t
                                    end
                                    local safe_title = title:gsub("[ &%%#=+]", {
                                        [" "] = "%%20", ["%%"] = "%%25", ["&"] = "%%26",
                                        ["#"] = "%%23", ["="] = "%%3D", ["+"] = "%%2B",
                                    })
                                    local magnet_with_tr = magnet .. "&dn=" .. safe_title .. TRACKERS
                                    local rain = "/mnt/us/koreader/plugins/epublibre.koplugin/bin/rain"
                                    local rf = io.open(rain)
                                    if not rf then
                                        UIManager:show(InfoMessage:new {
                                            text = "Binario rain no encontrado",
                                            timeout = 3,
                                        })
                                        return
                                    end
                                    rf:close()
                                    local outdir = self.config.books_dir
                                    os.execute("mkdir -p '" .. outdir .. "'")
                                    local tmpfile = "/tmp/rain_" .. os.time() .. ".txt"
                                    local resume_path = "/tmp/rain_" .. os.time() .. ".resume"
                                    local cmd = string.format("cd '%s' && %s download -t '%s' -r '%s' > '%s' 2>&1", outdir, rain, magnet_with_tr, resume_path, tmpfile)
                                    os.execute(cmd .. " &")

                                    self.dl_start = os.time()
                                    self.dl_active = true

                                    local function update_dialog(text)
                                        if self.dl_dialog then
                                            UIManager:close(self.dl_dialog)
                                        end
                                        self.dl_dialog = ButtonDialogTitle:new {
                                            title = text,
                                            buttons = {{
                                                {
                                                    text = "Cancelar",
                                                    callback = function()
                                                        self.dl_active = false
                                                        os.execute("killall rain 2>/dev/null")
                                                        os.execute("rm -f '" .. tmpfile .. "' '" .. resume_path .. "' 2>/dev/null")
                                                        UIManager:close(self.dl_dialog)
                                                    end,
                                                },
                                            }},
                                        }
                                        UIManager:show(self.dl_dialog)
                                    end

                                    update_dialog("Conectando con peers...")

                                    local function poll()
                                        if not self.dl_active then return end

                                        logger.dbg("DLL poll: active, elapsed=", os.time() - self.dl_start)

                                        if os.time() - self.dl_start > self.config.torrent_timeout then
                                            self.dl_active = false
                                            os.execute("killall rain 2>/dev/null")
                                            os.execute("rm -f '" .. tmpfile .. "' '" .. resume_path .. "' 2>/dev/null")
                                            UIManager:close(self.dl_dialog)
                                            UIManager:show(InfoMessage:new { text = "Cancelada (timeout " .. math.floor(self.config.torrent_timeout / 60) .. " min)" })
                                            return
                                        end

                                        local pct = 0
                                        local done = false
                                        local last
                                        local f = io.open(tmpfile)
                                        if f then
                                            local content = f:read("*a")
                                            f:close()
                                            done = content:find("download completed") ~= nil
                                            for line in content:gmatch("[^\n]+") do last = line end
                                            pct = tonumber(last and last:match("Progress: (%d+)%%") or "0") or 0
                                            logger.dbg("DLL poll: last=", tostring(last))
                                        end

                                        if done then
                                            self.dl_active = false
                                            os.execute("rm -f '" .. tmpfile .. "' '" .. resume_path .. "' 2>/dev/null")
                                            UIManager:close(self.dl_dialog)
                                            UIManager:show(InfoMessage:new { text = "Descarga completada" })
                                            self.ui.file_chooser:refreshPath()
                                            return
                                        end

                                        if pct > 0 then
                                            update_dialog("Descargando... " .. pct .. "%")
                                        end

                                        logger.dbg("DLL scheduling next poll")
                                        UIManager:scheduleIn(2, poll)
                                    end

                                    logger.dbg("DLL starting first poll")
                                    UIManager:scheduleIn(2, poll)
                                end,
                            },
                            {
                                text = "Cerrar",
                                callback = function()
                                    UIManager:close(self.detail_dialog)
                                    if self.results_menu then
                                        UIManager:show(self.results_menu)
                                    end
                                end,
                            },
                        },
                    },
                }
                UIManager:show(self.detail_dialog)
            end,
        })
    end

    self.results_menu = Menu:new {
        title = "Buscar: " .. query,
        item_table = item_table,
        is_popout = false,
        is_borderless = true,
    }
    UIManager:show(self.results_menu)
end

function EpubLibre:addToMainMenu(menu_items)
    menu_items.epublibre = {
        text = "ePubLibre",
        sorting_hint = "search",
        sub_item_table = {
            {
                text = "Buscar",
                callback = function()
                    if not self.db then
                        local dl_msg = InfoMessage:new {
                            text = "Descargando base de datos...",
                        }
                        UIManager:show(dl_msg)
                        UIManager:scheduleIn(0.5, function()
                            local db_path = self.path .. "/db.db"
                            self:downloadDB(db_path)
                            self.db = SQ3.open(db_path)
                            UIManager:close(dl_msg)
                            self:searchDialog()
                        end)
                        return
                    end
                    self:searchDialog()
                end,
            },
            {
                text = "Ajustes",
                sub_item_table = {
                    {
                        text = "Carpeta de descargas",
                        callback = function()
                            self:configInput("books_dir", "Carpeta de descargas")
                        end,
                    },
                    {
                        text = "Timeout de descarga",
                        callback = function()
                            self:configInput("torrent_timeout", "Timeout de descarga (segundos)")
                        end,
                    },
                    {
                        text = "Trackers",
                        callback = function()
                            self:configInput("trackers", "Trackers (uno por línea)")
                        end,
                    },
                },
            },
            {
                text = "Actualizar base de datos",
                callback = function()
                    self:checkDBUpdate()
                end,
            },
            {
                text = "Acerca de",
                callback = function()
                    UIManager:show(InfoMessage:new {
                        text = "Plugin EpubLibre v1.0.0",
                    })
                end,
            },
        },
    }
end

function EpubLibre:searchDialog()
    local dialog
    dialog = InputDialog:new {
        title = "Search on ePubLibre",
        input_hint = "escribe o author: J.K Rowling",
        buttons = {
            {
                {
                    text = "Cancel",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = "Search",
                    is_enter_default = true,
                    callback = function()
                        local query = dialog:getInputText()
                        UIManager:close(dialog)
                        if #query < 2 then
                            UIManager:show(InfoMessage:new {
                                text = "Escribe al menos 2 caracteres para buscar",
                                timeout = 2,
                            })
                            return
                        end
                        self:showSearchResults(query)
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end


function EpubLibre:saveConfig()
    local f = io.open(self.path .. "/config.lua", "w")
    if f then
        f:write("return {\n")
        f:write(string.format("    books_dir = %q,\n", self.config.books_dir))
        f:write(string.format("    torrent_timeout = %d,\n", self.config.torrent_timeout))
        f:write("    trackers = {\n")
        for _, t in ipairs(self.config.trackers) do
            f:write(string.format("        %q,\n", t))
        end
        f:write("    },\n")
        f:write("}\n")
        f:close()
    end
end

function EpubLibre:configInput(key, title)
    local val = self.config[key]
    if type(val) == "table" then
        val = table.concat(val, "\n")
    end
    val = tostring(val or "")
    local dialog
    dialog = InputDialog:new {
        title = title,
        input = val,
        buttons = {
            {
                {
                    text = "Cancel",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = "Guardar",
                    is_enter_default = true,
                    callback = function()
                        local new_val = dialog:getInputText()
                        UIManager:close(dialog)
                        if key == "torrent_timeout" then
                            self.config[key] = tonumber(new_val) or self.config[key]
                        elseif key == "trackers" then
                            local trackers = {}
                            for raw in new_val:gmatch("[^\n]+") do
                                local line = raw:match("^%s*(.-)%s*$")
                                if #line > 0 then
                                    table.insert(trackers, line)
                                end
                            end
                            if #trackers > 0 then
                                self.config[key] = trackers
                            end
                        else
                            self.config[key] = new_val
                        end
                        self:saveConfig()
                        UIManager:show(InfoMessage:new {
                            text = title .. " actualizado",
                            timeout = 2,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function EpubLibre:downloadDB(path)
    local gz_path = path .. ".gz"
    local ok = os.execute("curl -sL -o '" .. gz_path .. "' '" .. DB_BASE .. "/datos.db.gz' 2>/dev/null")
    if ok == 0 or ok == true then
        os.execute("gzip -df '" .. gz_path .. "' 2>/dev/null")
        os.execute("rm -f '" .. gz_path .. "'")
        os.execute("curl -sL -o '" .. self.path .. "/db_version.txt' '" .. DB_BASE .. "/db_version.txt' 2>/dev/null")
    end
end

function EpubLibre:readLocalDBVersion()
    local f = io.open(self.path .. "/db_version.txt")
    if f then
        local v = f:read("*l")
        f:close()
        return v and v:match("^%s*(.-)%s*$") or "desconocida"
    end
    return "desconocida"
end

function EpubLibre:checkDBUpdate()
    local local_ver = self:readLocalDBVersion()
    local tmp = "/tmp/db_remote_ver.txt"
    os.execute("curl -sL -o '" .. tmp .. "' '" .. DB_BASE .. "/db_version.txt' 2>/dev/null")
    local f = io.open(tmp)
    if not f then
        UIManager:show(InfoMessage:new { text = "Sin conexión", timeout = 2 })
        return
    end
    local remote_ver = f:read("*l")
    f:close()
    os.execute("rm -f '" .. tmp .. "'")
    if not remote_ver then
        UIManager:show(InfoMessage:new { text = "Error al leer versión remota", timeout = 2 })
        return
    end
    remote_ver = remote_ver:match("^%s*(.-)%s*$")

    if remote_ver == local_ver then
        UIManager:show(InfoMessage:new { text = "DB actualizada (" .. local_ver .. ")" })
    else
        self:confirmDBUpdate(local_ver, remote_ver)
    end
end

function EpubLibre:confirmDBUpdate(local_ver, remote_ver)
    local dialog
    dialog = ButtonDialogTitle:new {
        title = "¿Actualizar DB?",
        text = "Local: " .. local_ver .. "\nNueva: " .. remote_ver,
        buttons = {
            {
                {
                    text = "Cancelar",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = "Actualizar",
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new {
                            text = "Descargando DB...",
                            timeout = 1,
                        })
                        if self.db then
                            self.db:close()
                        end
                        local db_path = self.path .. "/db.db"
                        self:downloadDB(db_path)
                        self.db = SQ3.open(db_path)
                        UIManager:show(InfoMessage:new {
                            text = "DB actualizada: " .. remote_ver,
                            timeout = 2,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function EpubLibre:onCloseWidget()
    if self.dl_dialog then
        self.dl_active = false
        os.execute("killall rain 2>/dev/null")
        UIManager:close(self.dl_dialog)
    end
    if self.results_menu then
        UIManager:close(self.results_menu)
        self.results_menu = nil
    end
    if self.db then
        self.db:close()
    end
end

return EpubLibre
