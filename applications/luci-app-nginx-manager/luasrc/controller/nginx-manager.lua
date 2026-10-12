<%
local http = require "luci.http"
local sys = require "luci.sys"

-- ========== POST 处理 ==========
if http.getenv("REQUEST_METHOD") == "POST" then
    local action = http.formvalue("action") or ""
    if action == "change_port" then
        local new_port = http.formvalue("new_port")
        if new_port and new_port:match("^%d+$") then
            local mn = http.formvalue("media_name") or "_media"
            sys.exec("uci -q delete nginx." .. mn .. ".listen")
            sys.exec("uci add_list nginx." .. mn .. '.listen="' .. new_port .. ' default_server"')
            sys.exec("uci add_list nginx." .. mn .. '.listen="[::]:' .. new_port .. ' default_server"')
            sys.exec("uci commit nginx")
        end
    elseif action == "change_root" then
        local new_root = http.formvalue("new_root")
        if new_root and new_root:match("^/") then
            local fh = io.open("/etc/nginx/media.locations", "r")
            if fh then
                local content = fh:read("*a")
                fh:close()
                content = content:gsub("root%s+/www;", "__KEEP__/www;")
                content = content:gsub("root%s+[^;]+;", "root " .. new_root .. ";")
                content = content:gsub("__KEEP__/www;", "root /www;")
                fh = io.open("/etc/nginx/media.locations", "w")
                if fh then fh:write(content); fh:close() end
            end
        end
    end
    sys.exec("/etc/init.d/nginx reload")
    http.redirect(http.getenv("REQUEST_URI") or "/cgi-bin/luci/admin/services/nginx-manager")
    return
end

-- ========== AJAX：目录浏览 ==========
if http.formvalue("ajax") == "browse" then
    local path = http.formvalue("path") or "/mnt"
    if not path:match("^/mnt") then path = "/mnt" end
    local safe = path:gsub("'", "'\\''")
    local out = sys.exec("ls -1p '" .. safe .. "' 2>/dev/null | grep '/$' | sed 's|/$||'")
    local dirs = {}
    for name in out:gmatch("[^\n]+") do
        table.insert(dirs, name)
    end
    local json = "["
    local first = true
    for _, name in ipairs(dirs) do
        if not first then json = json .. "," end
        json = json .. '"' .. name:gsub('"', '\\"') .. '"'
        first = false
    end
    json = json .. "]"
    http.prepare_content("application/json")
    http.write(json)
    return
end

-- ========== 读取 UCI ==========
local uci_text = ""
local fh = io.open("/etc/config/nginx", "r")
if fh then
    uci_text = fh:read("*a")
    fh:close()
end

local servers = {}
local current = nil
for line in uci_text:gmatch("[^\n]+") do
    local cn = line:match("^config%s+server%s+['\"]?([%w_%-]+)['\"]?")
    if cn then
        current = { name = cn, listens = {}, options = {} }
        table.insert(servers, current)
    elseif current then
        local listen = line:match("^%s*list%s+listen%s+['\"]?(.-)['\"]?%s*$")
        if listen then
            table.insert(current.listens, listen)
        else
            local opt, val = line:match("^%s*option%s+([%w_%-]+)%s+['\"]?(.-)['\"]?%s*$")
            if opt then current.options[opt] = val end
        end
    end
end

local http_server, https_server, media_server
for _, s in ipairs(servers) do
    local has_443 = false
    local has_80 = false
    for _, l in ipairs(s.listens) do
        if l:match("^443") or l:match("^%[::%]:443") then has_443 = true end
        if l:match("^80") or l:match("^%[::%]:80") then has_80 = true end
    end
    if has_443 then
        https_server = s
    elseif has_80 then
        http_server = s
    elseif not media_server then
        media_server = s
    end
end

local media_port = "880"
if media_server then
    for _, l in ipairs(media_server.listens) do
        local p = l:match("^(%d+)")
        if p then
            media_port = p
            break
        end
    end
end

local media_root = "/mnt"
fh = io.open("/etc/nginx/media.locations", "r")
if fh then
    local content = fh:read("*a")
    fh:close()
    local in_root = false
    for line in content:gmatch("[^\n]+") do
        if line:match("^%s*location%s+/%s*{") then
            in_root = true
        elseif in_root then
            local r = line:match("^%s*root%s+([^;]+);")
            if r then
                media_root = r
                break
            end
            if line:match("^%s*}") then
                in_root = false
            end
        end
    end
end

local uci_enable = "1"
if uci_text:match("option%s+uci_enable%s+['\"]true['\"]") then
    uci_enable = "1"
elseif uci_text:match("option%s+uci_enable%s+['\"]false['\"]") then
    uci_enable = "0"
end
%>
<%+header%>

<style type="text/css">
.mgr-wrap { max-width: 960px; margin: 0; }
.mgr-title { font-size: 22px; color: #1f2d3d; margin: 0 0 8px 0; }
.mgr-descr { color: #666; font-size: 13px; margin-bottom: 20px; line-height: 1.6; }

.mgr-card { background: #fff; border: 1px solid #e4e7eb; border-radius: 10px; margin-bottom: 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.04); overflow: hidden; }
.mgr-card-head { background: linear-gradient(135deg, #f8f9fb, #eef2f7); border-bottom: 1px solid #e4e7eb; padding: 14px 22px; font-size: 15px; font-weight: 600; color: #1f2d3d; }
.mgr-card-body { padding: 0; }
.mgr-row { padding: 12px 22px; border-bottom: 1px solid #f4f6f8; display: flex; align-items: center; min-height: 46px; transition: background 0.15s; }
.mgr-row:hover { background: #fafbfc; }
.mgr-row:last-child { border-bottom: none; }
.mgr-label { width: 150px; flex-shrink: 0; font-size: 13px; color: #4a5568; font-weight: 500; }
.mgr-field { flex: 1; display: flex; align-items: center; flex-wrap: wrap; gap: 10px; min-width: 0; }
.mgr-field input[type="text"], .mgr-field input[type="number"] { padding: 7px 12px; border: 1px solid #d5dbe1; border-radius: 6px; font-size: 13px; transition: all 0.2s; background: #fff; color: #2d3748; box-sizing: border-box; }
.mgr-field input[type="text"]:focus, .mgr-field input[type="number"]:focus { outline: none; border-color: #4a9eff; box-shadow: 0 0 0 3px rgba(74,158,255,0.15); }
.mgr-field input[type="checkbox"] { width: 16px; height: 16px; cursor: pointer; accent-color: #4a9eff; }
.mgr-ro { background: #f5f7fa; padding: 7px 12px; border-radius: 6px; color: #2d3748; font-family: 'SF Mono', Consolas, Monaco, monospace; font-size: 12.5px; display: inline-block; min-width: 240px; word-break: break-all; }

.mgr-btn { display: inline-flex; align-items: center; gap: 5px; background: linear-gradient(135deg, #4a9eff, #3a7fd5); border: none; color: #fff; padding: 8px 16px; border-radius: 6px; font-size: 12.5px; font-weight: 500; cursor: pointer; transition: all 0.2s; box-shadow: 0 1px 3px rgba(74,158,255,0.25); white-space: nowrap; font-family: inherit; text-decoration: none; }
.mgr-btn:hover { background: linear-gradient(135deg, #3a8eef, #2a6fc5); box-shadow: 0 3px 8px rgba(74,158,255,0.35); transform: translateY(-1px); }
.mgr-btn:active { transform: translateY(0); }
.mgr-btn.btn-success { background: linear-gradient(135deg, #2ecc71, #27ae60); box-shadow: 0 1px 3px rgba(46,204,113,0.25); }
.mgr-btn.btn-success:hover { background: linear-gradient(135deg, #27ae60, #229954); }
.mgr-btn.btn-secondary { background: linear-gradient(135deg, #7c8798, #6c7585); box-shadow: 0 1px 3px rgba(108,117,125,0.25); }
.mgr-btn.btn-secondary:hover { background: linear-gradient(135deg, #6c7585, #5a6272); }

#browse-modal { display: none; position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: rgba(20,25,35,0.55); z-index: 9999; align-items: center; justify-content: center; }
#browse-modal .modal-box { background: #fff; border-radius: 12px; min-width: 560px; max-width: 85vw; box-shadow: 0 20px 60px rgba(0,0,0,0.35); overflow: hidden; }
#browse-modal .modal-header { padding: 16px 22px; background: linear-gradient(135deg, #4a9eff, #3a7fd5); color: #fff; font-size: 16px; font-weight: 600; }
#browse-modal .modal-path { padding: 12px 22px; background: #f0f7ff; border-bottom: 1px solid #d8e8f8; font-size: 12.5px; color: #5a6272; }
#browse-modal .modal-path code { color: #2a6fc5; font-family: 'SF Mono', Consolas, Monaco, monospace; font-size: 13px; font-weight: 600; }
#browse-modal .modal-list { max-height: 420px; min-height: 260px; overflow-y: auto; padding: 8px; }
#browse-modal .modal-item { padding: 10px 16px; cursor: pointer; border-radius: 6px; font-size: 13.5px; display: flex; align-items: center; gap: 10px; transition: all 0.15s; user-select: none; color: #2d3748; }
#browse-modal .modal-item:hover { background: #e8f2ff; color: #2a6fc5; }
#browse-modal .modal-item.up { color: #e67e22; font-weight: 500; }
#browse-modal .modal-item.up:hover { background: #fff5e6; }
#browse-modal .modal-footer { padding: 14px 22px; background: #f8f9fa; border-top: 1px solid #e4e7eb; display: flex; justify-content: flex-end; gap: 10px; }
#browse-modal .loading, #browse-modal .empty { padding: 40px; text-align: center; color: #95a5b8; font-size: 13px; }
</style>

<div class="mgr-wrap">
    <h2 class="mgr-title">Nginx 配置管理</h2>
    <div class="mgr-descr">直接管理 /etc/config/nginx 和 /etc/nginx/media.locations，保存后立即生效。</div>

    <div style="margin-bottom:20px;">
        <form method="post" style="display:inline;">
            <input type="hidden" name="action" value="reload">
            <button type="submit" class="mgr-btn">🔄 重载 Nginx</button>
        </form>
        <button type="button" class="mgr-btn btn-secondary" onclick="location.reload()" style="margin-left:10px;">🔃 刷新页面</button>
        <a href="/cgi-bin/luci/admin/system/ttyd" target="_blank" class="mgr-btn btn-success" style="margin-left:10px;">💻 打开终端</a>
    </div>

    <div class="mgr-card">
        <div class="mgr-card-head">⚙️ 全局设置</div>
        <div class="mgr-card-body">
            <div class="mgr-row">
                <div class="mgr-label">启用 UCI 配置</div>
                <div class="mgr-field">
                    <input type="checkbox" <% if uci_enable == "1" then %>checked<% end %> disabled>
                    <span style="color:#8898aa;font-size:12.5px;">启用后 nginx 会根据 UCI 自动生成配置文件</span>
                </div>
            </div>
        </div>
    </div>

    <% if http_server then %>
    <div class="mgr-card">
        <div class="mgr-card-head">🌐 HTTP 服务（只读）</div>
        <div class="mgr-card-body">
            <div class="mgr-row">
                <div class="mgr-label">监听地址</div>
                <div class="mgr-field"><span class="mgr-ro"><%= table.concat(http_server.listens, "　") %></span></div>
            </div>
            <div class="mgr-row">
                <div class="mgr-label">服务器名称</div>
                <div class="mgr-field"><span class="mgr-ro"><%= http_server.options.server_name or "-" %></span></div>
            </div>
        </div>
    </div>
    <% end %>

    <% if https_server then %>
    <div class="mgr-card">
        <div class="mgr-card-head">🔒 HTTPS 服务（只读）</div>
        <div class="mgr-card-body">
            <div class="mgr-row">
                <div class="mgr-label">监听地址</div>
                <div class="mgr-field"><span class="mgr-ro"><%= table.concat(https_server.listens, "　") %></span></div>
            </div>
            <div class="mgr-row">
                <div class="mgr-label">服务器名称</div>
                <div class="mgr-field"><span class="mgr-ro"><%= https_server.options.server_name or "-" %></span></div>
            </div>
            <div class="mgr-row">
                <div class="mgr-label">SSL 证书</div>
                <div class="mgr-field"><span class="mgr-ro"><%= https_server.options.ssl_certificate or "-" %></span></div>
            </div>
            <div class="mgr-row">
                <div class="mgr-label">SSL 私钥</div>
                <div class="mgr-field"><span class="mgr-ro"><%= https_server.options.ssl_certificate_key or "-" %></span></div>
            </div>
        </div>
    </div>
    <% end %>

    <div class="mgr-card">
        <div class="mgr-card-head">🎬 媒体服务（可修改）</div>
        <div class="mgr-card-body">
            <form method="post">
                <input type="hidden" name="action" value="change_port">
                <input type="hidden" name="media_name" value="<%= media_server and media_server.name or "_media" %>">
                <div class="mgr-row">
                    <div class="mgr-label">HTTP 端口</div>
                    <div class="mgr-field">
                        <input type="number" name="new_port" value="<%= media_port %>" min="1" max="65535" style="width:120px;">
                        <button type="submit" class="mgr-btn">💾 保存端口</button>
                        <button type="button" class="mgr-btn btn-success" onclick="openSite()">🌐 打开网站</button>
                    </div>
                </div>
            </form>

            <form method="post">
                <input type="hidden" name="action" value="change_root">
                <div class="mgr-row">
                    <div class="mgr-label">网站根目录</div>
                    <div class="mgr-field">
                        <input type="text" name="new_root" id="root-input" value="<%= media_root %>" style="width:280px;" placeholder="/mnt">
                        <button type="button" class="mgr-btn" onclick="openBrowser()">📂 选择目录</button>
                        <button type="submit" class="mgr-btn">💾 保存根目录</button>
                    </div>
                </div>
            </form>

            <div class="mgr-row" style="background:#fbfcfe;color:#95a5b8;font-size:12.5px;font-style:italic;">
                💡 默认 /mnt，保存后写入 /etc/nginx/media.locations
            </div>
        </div>
    </div>
</div>

<div id="browse-modal">
    <div class="modal-box">
        <div class="modal-header">📂 选择目录</div>
        <div class="modal-path">当前位置：<code id="browse-path">/mnt</code></div>
        <div class="modal-list" id="browse-list"></div>
        <div class="modal-footer">
            <button type="button" class="mgr-btn btn-secondary" onclick="closeBrowser()">取消</button>
            <button type="button" class="mgr-btn btn-success" onclick="pickBrowser()">✓ 选择此目录</button>
        </div>
    </div>
</div>

<script type="text/javascript">
(function() {
    'use strict';
    var browseCurrent = '/mnt';
    var currentPort = '<%= media_port %>';

    window.openBrowser = function() {
        document.getElementById('browse-modal').style.display = 'flex';
        browseLoad('/mnt');
    };
    window.closeBrowser = function() {
        document.getElementById('browse-modal').style.display = 'none';
    };
    window.pickBrowser = function() {
        document.getElementById('root-input').value = browseCurrent;
        closeBrowser();
    };
    window.openSite = function() {
        window.open('http://' + window.location.hostname + ':' + currentPort + '/', '_blank');
    };

    function browseLoad(path) {
        browseCurrent = path;
        document.getElementById('browse-path').textContent = path;
        var list = document.getElementById('browse-list');
        list.innerHTML = '<div class="loading">加载中...</div>';

        var xhr = new XMLHttpRequest();
        xhr.open('GET', location.pathname + '?ajax=browse&path=' + encodeURIComponent(path), true);
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4) {
                if (xhr.status === 200) {
                    try { renderBrowseList(JSON.parse(xhr.responseText)); }
                    catch(e) { list.innerHTML = '<div class="loading" style="color:#e74c3c;">解析失败：' + e.message + '</div>'; }
                } else {
                    list.innerHTML = '<div class="loading" style="color:#e74c3c;">HTTP ' + xhr.status + '</div>';
                }
            }
        };
        xhr.send();
    }

    function renderBrowseList(entries) {
        var list = document.getElementById('browse-list');
        list.innerHTML = '';

        if (browseCurrent !== '/mnt') {
            var parent = browseCurrent.replace(/\/+$/, '').replace(/\/[^\/]+$/, '') || '/mnt';
            if (parent.length < 4) parent = '/mnt';
            var up = document.createElement('div');
            up.className = 'modal-item up';
            up.innerHTML = '📁 .. (上级目录)';
            up.onclick = function() { browseLoad(parent); };
            list.appendChild(up);
        }

        if (!entries || entries.length === 0) {
            var empty = document.createElement('div');
            empty.className = 'empty';
            empty.textContent = '(此目录下无子目录)';
            list.appendChild(empty);
            return;
        }

        for (var i = 0; i < entries.length; i++) {
            (function(name) {
                var item = document.createElement('div');
                item.className = 'modal-item';
                item.innerHTML = '📁 ' + name;
                item.onclick = function() { browseLoad(browseCurrent.replace(/\/+$/, '') + '/' + name); };
                list.appendChild(item);
            })(entries[i]);
        }
    }
})();
</script>

<%+footer%>
