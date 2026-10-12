'use strict';
'require view';
'require fs';
'require ui';

// 写文件（通过 base64 + sh，绕开 ubus 权限）
function writeFile(path, content) {
var b64 = btoa(unescape(encodeURIComponent(content)));
var cmd = 'printf %s "' + b64 + '" | base64 -d > ' + path;
return fs.exec('/bin/sh', ['-c', cmd]).then(function(res) {
if (res && res.code !== 0) {
throw new Error('写入失败：' + ((res.stderr || '').trim() || '未知错误'));
}
});
}

function reloadNginx() {
return fs.exec('/etc/init.d/nginx', ['reload']).then(function(res) {
if (res.code !== 0) {
throw new Error('Nginx 重载失败：' + ((res.stderr || '').trim() || ''));
}
});
}

// 解析 UCI 文本里的 server 块
function parseUciServers(content) {
if (!content) return [];
var lines = content.split('\n');
var blocks = [];
var current = null;
for (var i = 0; i < lines.length; i++) {
var m = lines[i].match(/^config\s+server\s+'([^']+)'/);
if (m) {
if (current) blocks.push(current);
current = { name: m[1], lines: [lines[i]] };
} else if (/^config\s+/.test(lines[i])) {
if (current) { blocks.push(current); current = null; }
} else if (current) {
current.lines.push(lines[i]);
}
}
if (current) blocks.push(current);
return blocks.map(function(b) {
return { name: b.name, text: b.lines.join('\n') };
});
}

// 判断 UCI server 块里监听的端口
function getListenPorts(blockText) {
var ports = [];
var re = /list\s+listen\s+'
:
:
:::(\d+)[^']'/g;
var m;
while ((m = re.exec(blockText)) !== null) ports.push(parseInt(m[1], 10));
// 如果没有 [::] 形式，找纯数字
if (ports.length === 0) {
var re2 = /list\s+listen\s+'(\d+)[^']'/g;
while ((m = re2.exec(blockText)) !== null) ports.push(parseInt(m[1], 10));
}
return ports;
}

// 从 UCI 里获取 root
function getUciRoot(blockText) {
var m = blockText.match(/option\s+root\s+'([^']+)'/);
return m ? m[1] : '';
}

// 修改 UCI 块的 listen 端口
function replaceUciListen(blockText, oldPort, newPort) {
var re1 = new RegExp("list\s+listen\s+'" + oldPort + "\s+default_server'", 'g');
var re2 = new RegExp("list\s+listen\s+'\[::\]:" + oldPort + "\s+default_server'", 'g');
var re3 = new RegExp("list\s+listen\s+'" + oldPort + "'", 'g');
var re4 = new RegExp("list\s+listen\s+'\[::\]:" + oldPort + "'", 'g');
blockText = blockText.replace(re1, "list listen '" + newPort + " default_server'");
blockText = blockText.replace(re2, "list listen '[::]:" + newPort + " default_server'");
blockText = blockText.replace(re3, "list listen '" + newPort + "'");
blockText = blockText.replace(re4, "list listen '[::]:" + newPort + "'");
return blockText;
}

// 修改 UCI 块的 root
function replaceUciRoot(blockText, newRoot) {
if (/option\s+root\s+'[^']'/.test(blockText)) {
return blockText.replace(/option\s+root\s+'[^']'/, "option root '" + newRoot + "'");
}
// 没有 root 字段，插到最后一行前
var lines = blockText.split('\n');
lines.push("\toption root '" + newRoot + "'");
return lines.join('\n');
}

// 替换 UCI 里某个 server 块
function replaceUciBlock(fullContent, blockName, newBlockText) {
var lines = fullContent.split('\n');
var result = [];
var i = 0;
var replaced = false;
while (i < lines.length) {
var m = lines[i].match(/^config\s+server\s+'([^']+)'/);
if (m && m[1] === blockName) {
// 找到目标块，用新内容替换
result.push(newBlockText);
// 跳过旧块的所有行
i++;
while (i < lines.length && !/^config\s+/.test(lines[i])) {
i++;
}
replaced = true;
} else {
result.push(lines[i]);
i++;
}
}
if (!replaced) {
result.push(newBlockText);
}
return result.join('\n');
}

// 从 extra.conf 里解析所有 server 块
function parseNginxServers(content) {
var blocks = [];
if (!content) return blocks;
var lines = content.split('\n');
var i = 0;
while (i < lines.length) {
if (/^\sserver\s{/.test(lines[i])) {
var start = i, depth = 0, j = i;
for (; j < lines.length; j++) {
for (var k = 0; k < lines[j].length; k++) {
var c = lines[j][k];
if (c === '{') depth++;
else if (c === '}') depth--;
}
if (depth === 0) break;
}
blocks.push({ index: blocks.length, text: lines.slice(start, j + 1).join('\n') });
i = j + 1;
} else { i++; }
}
return blocks;
}

return view.extend({
load: function() {
return Promise.all([
fs.read('/etc/config/nginx').catch(function() { return ''; }),
fs.read('/etc/nginx/conf.d/extra.conf').catch(function() { return ''; })
]).then(function(arr) {
return { uci: arr[0], extra: arr[1] };
});
},

handleReloadNginx: function(ev) {
return reloadNginx().then(function() {
ui.addNotification(null, E('p', _('Nginx 已重载')), 'info');
}).catch(function(e) {
ui.addNotification(null, E('p', _('重载失败：%s').format(e.message)), 'error');
});
},

handleReloadPage: function(ev) { window.location.reload(); },

handleOpenPlayer: function(ev) {
window.open('http://' + window.location.hostname + ':880/', '_blank');
},

// ---------- 媒体服务：改端口 ----------
handleSaveMediaPort: function(ev, blockName, oldPort) {
var newPort = parseInt(document.getElementById('media-port-' + blockName).value, 10);
if (!newPort || newPort < 1 || newPort > 65535) {
ui.addNotification(null, E('p', _('端口必须为 1-65535')), 'error');
return;
}
if (newPort === oldPort) {
ui.addNotification(null, E('p', _('端口未改变')), 'info');
return;
}
var self = this;
return fs.read('/etc/config/nginx').catch(function() { return ''; })
.then(function(content) {
var blocks = parseUciServers(content);
var block = blocks.find(function(b) { return b.name === blockName; });
if (!block) throw new Error('未找到 UCI 块：' + blockName);
var newBlockText = replaceUciListen(block.text, oldPort, newPort);
var newContent = replaceUciBlock(content, blockName, newBlockText);
return writeFile('/etc/config/nginx', newContent).then(function() {
return reloadNginx();
});
}).then(function() {
ui.addNotification(null, E('p', _('端口已改为 %d').format(newPort)), 'info');
setTimeout(function() { window.location.reload(); }, 1200);
}).catch(function(e) {
ui.addNotification(null, E('p', _('保存失败：%s').format(e.message)), 'error');
});
},

// ---------- 媒体服务：改 root ----------
handleSaveMediaRoot: function(ev, blockName) {
var newRoot = document.getElementById('media-root-' + blockName).value.trim();
if (!newRoot || newRoot.charAt(0) !== '/') {
ui.addNotification(null, E('p', _('路径必须以 / 开头')), 'error');
return;
}
return fs.read('/etc/config/nginx').catch(function() { return ''; })
.then(function(content) {
var blocks = parseUciServers(content);
var block = blocks.find(function(b) { return b.name === blockName; });
if (!block) throw new Error('未找到 UCI 块：' + blockName);
var newBlockText = replaceUciRoot(block.text, newRoot);
var newContent = replaceUciBlock(content, blockName, newBlockText);
return writeFile('/etc/config/nginx', newContent).then(function() {
return reloadNginx();
});
}).then(function() {
ui.addNotification(null, E('p', _('根目录已改为 %s').format(newRoot)), 'info');
setTimeout(function() { window.location.reload(); }, 1200);
}).catch(function(e) {
ui.addNotification(null, E('p', _('保存失败：%s').format(e.message)), 'error');
});
},

// ---------- 额外服务：添加 ----------
handleAddExtra: function(ev) {
var port = document.querySelector('#extra-port').value.trim();
var server_name = document.querySelector('#extra-server-name').value.trim();
var root = document.querySelector('#extra-root').value.trim();
if (!port || isNaN(port)) {
ui.addNotification(null, E('p', _('端口必须为数字')), 'error');
return;
}
if (!server_name) server_name = 'localhost';
if (!root) root = '/mnt';
var block = '\nserver {\n' +
' listen ' + port + ' default_server;\n' +
' listen [::]:' + port + ' default_server;\n' +
' server_name ' + server_name + ';\n' +
' root ' + root + ';\n' +
' location / {\n' +
' autoindex on;\n' +
' }\n' +
'}\n';
return fs.read('/etc/nginx/conf.d/extra.conf').catch(function() { return ''; })
.then(function(content) {
return writeFile('/etc/nginx/conf.d/extra.conf', content + block);
}).then(function() {
return reloadNginx();
}).then(function() {
ui.addNotification(null, E('p', _('额外服务已添加')), 'info');
setTimeout(function() { window.location.reload(); }, 1200);
}).catch(function(e) {
ui.addNotification(null, E('p', _('添加失败：%s').format(e.message)), 'error');
});
},

// ---------- 额外服务：删除 ----------
handleDeleteExtra: function(ev, index) {
return fs.read('/etc/nginx/conf.d/extra.conf').catch(function() { return ''; })
.then(function(content) {
var blocks = parseNginxServers(content);
if (index < 0 || index >= blocks.length) throw new Error('无效的块索引');
var blockText = blocks[index].text;
var newContent = content.replace(blockText, '');
newContent = newContent.replace(/\n\s\n\s\n+/g, '\n\n').replace(/^\s*\n+/, '');
return writeFile('/etc/nginx/conf.d/extra.conf', newContent);
}).then(function() {
return reloadNginx();
}).then(function() {
ui.addNotification(null, E('p', _('已删除该额外服务')), 'info');
setTimeout(function() { window.location.reload(); }, 1200);
}).catch(function(e) {
ui.addNotification(null, E('p', _('删除失败：%s').format(e.message)), 'error');
});
},

switchTab: function(tab) {
document.querySelectorAll('.tab-btn').forEach(function(el) {
var isActive = el.getAttribute('data-tab') === tab;
el.style.background = isActive ? '#4a9eff' : '#f0f0f0';
el.style.color = isActive ? '#fff' : '#444';
el.style.borderColor = isActive ? '#4a9eff' : '#ccc';
});
document.querySelectorAll('.tab-panel').forEach(function(el) {
el.style.display = el.getAttribute('data-tab') === tab ? 'block' : 'none';
});
},

toggleSection: function(id) {
var body = document.querySelector('#' + id);
var arrow = document.querySelector('#arrow-' + id);
if (!body) return;
var isHidden = body.style.display === 'none';
body.style.display = isHidden ? 'block' : 'none';
if (arrow) arrow.textContent = isHidden ? '▼' : '▶';
},

render: function(data) {
var self = this;
var uciContent = data.uci || '';
var extraContent = data.extra || '';

// 解析 UCI server 块
var uciBlocks = parseUciServers(uciContent);
var mainUciBlocks = []; // 80/443
var mediaUciBlocks = []; // 其他端口
uciBlocks.forEach(function(b) {
var ports = getListenPorts(b.text);
var isMain = ports.some(function(p) { return p === 80 || p === 443; });
if (isMain) mainUciBlocks.push(b);
else mediaUciBlocks.push(b);
});

// 解析 extra.conf
var extraBlocks = parseNginxServers(extraContent);

// ---------- 顶部工具栏 ----------
var toolbar = E('div', { 'style': 'margin-bottom:15px; display:flex; gap:8px; flex-wrap:wrap;' }, [
E('button', { 'class': 'cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, 'handleReloadNginx') }, _('重载 Nginx')),
E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': ui.createHandlerFn(this, 'handleReloadPage') }, _('重新读取')),
E('button', { 'class': 'cbi-button cbi-button-apply', 'click': ui.createHandlerFn(this, 'handleOpenPlayer') }, _('打开播放器'))
]);

// ---------- tab 栏 ----------
var tabBtnBase = 'background:#f0f0f0; color:#444; border:1px solid #ccc; padding:6px 14px; border-radius:4px; cursor:pointer; font-size:13px;';
var tabBtnActive = 'background:#4a9eff; color:#fff; border-color:#4a9eff;';
var tabBar = E('div', { 'style': 'display:flex; gap:6px; margin-bottom:15px;' }, [
E('button', { 'class': 'tab-btn', 'data-tab': 'main', 'style': tabBtnBase + tabBtnActive,
'click': function() { self.switchTab('main'); } }, _('主服务') + ' (' + mainUciBlocks.length + ')'),
E('button', { 'class': 'tab-btn', 'data-tab': 'media', 'style': tabBtnBase,
'click': function() { self.switchTab('media'); } }, _('媒体服务') + ' (' + mediaUciBlocks.length + ')'),
E('button', { 'class': 'tab-btn', 'data-tab': 'extra', 'style': tabBtnBase,
'click': function() { self.switchTab('extra'); } }, _('额外服务') + ' (' + extraBlocks.length + ')')
]);

// ---------- 主服务面板 ----------
var mainPanel = E('div', { 'class': 'tab-panel', 'data-tab': 'main', 'style': 'display:block;' }, [
E('div', { 'class': 'cbi-map-descr', 'style': 'margin-bottom:10px;' }, _('80/443 端口，由 LuCI 系统使用，只读')),
E('pre', { 'style': 'background:#f4f4f4; padding:10px; border-radius:4px; overflow-x:auto; white-space:pre-wrap; font-size:12px;' },
mainUciBlocks.map(function(b) { return b.text; }).join('\n\n') || _('(无)'))
]);

// ---------- 媒体服务面板 ----------
var mediaPanel = E('div', { 'class': 'tab-panel', 'data-tab': 'media', 'style': 'display:none;' }, [
E('div', { 'class': 'cbi-map-descr', 'style': 'margin-bottom:10px;' }, _('880 端口，可改端口和网站根目录，不可删除')),
E('div', {}, mediaUciBlocks.length === 0
? [E('div', { 'style': 'color:#888; padding:10px;' }, _('(无媒体服务)'))]
: mediaUciBlocks.map(function(b) {
var ports = getListenPorts(b.text);
var port = ports[0] || '';
var root = getUciRoot(b.text);
return E('div', { 'style': 'border:1px solid #b8d4ff; border-radius:4px; padding:12px; margin-bottom:10px; background:#f0f7ff;' }, [
E('div', { 'style': 'font-weight:600; margin-bottom:10px; color:#4a9eff;' }, _('UCI 块：') + b.name),
E('div', { 'class': 'cbi-value' }, [
E('label', { 'class': 'cbi-value-title' }, _('HTTP 端口')),
E('div', { 'class': 'cbi-value-field', 'style': 'display:flex; gap:8px;' }, [
E('input', { 'type': 'number', 'id': 'media-port-' + b.name, 'class': 'cbi-input-text',
'value': port, 'min': '1', 'max': '65535', 'style': 'width:120px;' }),
E('button', { 'class': 'cbi-button cbi-button-action',
'click': function(ev) { self.handleSaveMediaPort(ev, b.name, port); } }, _('保存端口'))
])
]),
E('div', { 'class': 'cbi-value' }, [
E('label', { 'class': 'cbi-value-title' }, _('网站根目录')),
E('div', { 'class': 'cbi-value-field', 'style': 'display:flex; gap:8px;' }, [
E('input', { 'type': 'text', 'id': 'media-root-' + b.name, 'class': 'cbi-input-text',
'value': root, 'placeholder': '(继承 locations 里的 root)', 'style': 'width:300px;' }),
E('button', { 'class': 'cbi-button cbi-button-action',
'click': function(ev) { self.handleSaveMediaRoot(ev, b.name); } }, _('保存路径'))
])
]),
E('pre', { 'style': 'background:#fff; padding:8px; border-radius:3px; overflow-x:auto; white-space:pre-wrap; margin:10px 0 0 0; font-size:12px;' }, b.text)
]);
}))
]);

// ---------- 额外服务面板 ----------
var addExtraBody = E('div', { 'id': 'extra-add-body', 'style': 'display:none; padding:10px;' }, [
E('div', { 'class': 'cbi-value' }, [
E('label', { 'class': 'cbi-value-title', 'for': 'extra-port' }, _('监听端口')),
E('div', { 'class': 'cbi-value-field' }, [E('input', { 'type': 'text', 'id': 'extra-port', 'class': 'cbi-input-text', 'value': '8082' })])
]),
E('div', { 'class': 'cbi-value' }, [
E('label', { 'class': 'cbi-value-title', 'for': 'extra-server-name' }, _('服务器名称')),
E('div', { 'class': 'cbi-value-field' }, [E('input', { 'type': 'text', 'id': 'extra-server-name', 'class': 'cbi-input-text', 'value': 'localhost' })])
]),
E('div', { 'class': 'cbi-value' }, [
E('label', { 'class': 'cbi-value-title', 'for': 'extra-root' }, _('网站根目录')),
E('div', { 'class': 'cbi-value-field' }, [E('input', { 'type': 'text', 'id': 'extra-root', 'class': 'cbi-input-text', 'value': '/mnt' })])
]),
E('div', { 'class': 'cbi-page-actions' }, [
E('button', { 'class': 'cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, 'handleAddExtra') }, _('添加'))
])
]);

var extraList = E('div', {}, extraBlocks.length === 0
? [E('div', { 'style': 'color:#888; padding:10px;' }, _('(无额外服务)'))]
: extraBlocks.map(function(b, idx) {
return E('div', { 'style': 'border:1px solid #a5d6a7; border-radius:4px; padding:10px; margin-bottom:10px; background:#e8f5e9;' }, [
E('div', { 'style': 'display:flex; justify-content:space-between; align-items:center; margin-bottom:8px;' }, [
E('strong', { 'style': 'color:#2e7d32;' }, _('额外服务 #%d').format(idx + 1)),
E('button', { 'class': 'cbi-button cbi-button-remove', 'style': 'padding:2px 10px; font-size:12px;',
'click': function(ev) { self.handleDeleteExtra(ev, idx); } }, _('删除'))
]),
E('pre', { 'style': 'background:#fff; padding:8px; border-radius:3px; overflow-x:auto; white-space:pre-wrap; margin:0; font-size:12px;' }, b.text)
]);
}));

var extraPanel = E('div', { 'class': 'tab-panel', 'data-tab': 'extra', 'style': 'display:none;' }, [
E('div', { 'class': 'cbi-map-descr', 'style': 'margin-bottom:10px;' }, _('存储在 /etc/nginx/conf.d/extra.conf，可随意增删')),
extraList,
E('div', { 'class': 'cbi-section', 'style': 'margin-top:15px; border:1px solid #a5d6a7; border-radius:4px;' }, [
E('div', { 'style': 'display:flex; gap:8px; align-items:center; cursor:pointer; user-select:none; padding:8px 12px; background:#e8f5e9;',
'click': function() { self.toggleSection('extra-add-body'); } }, [
E('span', { 'id': 'arrow-extra-add-body', 'style': 'font-size:10px; color:#4a9eff; width:12px; text-align:center;' }, '▶'),
E('strong', { 'style': 'font-size:13px; color:#2e7d32;' }, _('+ 添加额外服务')),
E('span', { 'style': 'color:#888; font-size:12px; margin-left:6px;' }, _('（点击展开）'))
]),
addExtraBody
])
]);

return E('div', { 'class': 'cbi-map' }, [
E('h2', _('Nginx 配置管理')),
E('div', { 'class': 'cbi-map-descr' }, _('主服务/媒体服务：UCI 配置；额外服务：独立文件')),
toolbar,
tabBar,
mainPanel,
mediaPanel,
extraPanel
]);
}
});
