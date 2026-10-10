'use strict';
'require view';
'require fs';
'require ui';

function parseBlocks(content) {
    var blocks = [];
    if (!content) return blocks;
    var lines = content.split('\n');
    var i = 0;
    while (i < lines.length) {
        if (/^\s*server\s*\{/.test(lines[i])) {
            var start = i;
            var depth = 0;
            var j = i;
            for (; j < lines.length; j++) {
                for (var k = 0; k < lines[j].length; k++) {
                    var c = lines[j][k];
                    if (c === '{') depth++;
                    else if (c === '}') depth--;
                }
                if (depth === 0) break;
            }
            blocks.push({
                index: blocks.length,
                text: lines.slice(start, j + 1).join('\n')
            });
            i = j + 1;
        } else {
            i++;
        }
    }
    return blocks;
}

// 调用 init.d 重载；非 0 视为失败
function reloadNginx() {
    return fs.exec('/etc/init.d/nginx', ['reload']).then(function(res) {
        if (res.code !== 0) {
            var msg = (res.stderr || '').trim() || (res.stdout || '').trim() || _('未知错误');
            throw new Error(_('Nginx 重载失败：\n') + msg);
        }
    });
}

return view.extend({
    load: function() {
        return fs.read('/etc/nginx/conf.d/nginx.conf').catch(function() {
            return '';
        });
    },

    // ---------- 重载 Nginx ----------
    handleReloadNginx: function(ev) {
        return reloadNginx().then(function() {
            ui.addNotification(null, E('p', _('Nginx 已重载')), 'info');
        }).catch(function(e) {
            ui.addNotification(null, E('p', _('重载失败：%s').format(e.message)), 'error');
        });
    },

    // ---------- 重新读取文件 ----------
    handleReloadPage: function(ev) {
        window.location.reload();
    },

    // ---------- 添加 ----------
    handleSaveApply: function(ev) {
        var port = document.querySelector('#port').value.trim();
        var server_name = document.querySelector('#server_name').value.trim();
        var root = document.querySelector('#root').value.trim();
        var autoindex = document.querySelector('#autoindex').checked ? 'on' : 'off';
        var charset = document.querySelector('#charset').value.trim();

        if (!port || isNaN(port)) {
            ui.addNotification(null, E('p', _('端口必须为数字')), 'error');
            return;
        }
        if (!server_name) server_name = 'localhost';
        if (!root) root = '/mnt';
        if (!charset) charset = 'utf-8';

        var block = '\nserver {\n' +
                    '\tlisten ' + port + ' default_server;\n' +
                    '\tlisten [::]:' + port + ' default_server;\n' +
                    '\tserver_name ' + server_name + ';\n' +
                    '\tlocation / {\n' +
                    '\t\tautoindex ' + autoindex + ';\n' +
                    '\t\tcharset ' + charset + ';\n' +
                    '\t\troot ' + root + ';\n' +
                    '\t}\n' +
                    '}\n';

        var originalContent;

        return fs.read('/etc/nginx/conf.d/nginx.conf').catch(function() {
            return '';
        }).then(function(content) {
            originalContent = content;
            return fs.write('/etc/nginx/conf.d/nginx.conf', content + block);
        }).then(function() {
            return reloadNginx().catch(function(e) {
                // 重载失败 → 回滚文件
                return fs.write('/etc/nginx/conf.d/nginx.conf', originalContent).then(function() {
                    throw e;
                });
            });
        }).then(function() {
            ui.addNotification(null, E('p', _('配置已成功保存并重载 Nginx')), 'info');
            window.setTimeout(function() { window.location.reload(); }, 1200);
        }).catch(function(e) {
            ui.addNotification(null, E('p', _('保存失败：%s').format(e.message)), 'error');
        });
    },

    // ---------- 删除 ----------
    handleDelete: function(index, ev) {
        return fs.read('/etc/nginx/conf.d/nginx.conf').catch(function() {
            return '';
        }).then(function(content) {
            var originalContent = content;
            var blocks = parseBlocks(content);
            if (index < 0 || index >= blocks.length) {
                throw new Error(_('无效的块索引'));
            }
            var blockText = blocks[index].text;

            var newContent = content.replace(blockText, '');
            newContent = newContent.replace(/\n\s*\n\s*\n+/g, '\n\n');
            newContent = newContent.replace(/^\s*\n+/, '');

            return fs.write('/etc/nginx/conf.d/nginx.conf', newContent).then(function() {
                return reloadNginx().catch(function(e) {
                    return fs.write('/etc/nginx/conf.d/nginx.conf', originalContent).then(function() {
                        throw e;
                    });
                });
            }).then(function() {
                ui.addNotification(null, E('p', _('已删除该监听配置')), 'info');
                window.setTimeout(function() { window.location.reload(); }, 1200);
            }).catch(function(e) {
                ui.addNotification(null, E('p', _('删除失败：%s').format(e.message)), 'error');
            });
        });
    },

    // ---------- 渲染 ----------
    render: function(currentContent) {
        var self = this;
        var blocks = parseBlocks(currentContent || '');

        var toolbar = E('div', {
            'style': 'margin-bottom:15px; display:flex; gap:8px;'
        }, [
            E('button', {
                'class': 'cbi-button cbi-button-action',
                'click': ui.createHandlerFn(this, 'handleReloadNginx')
            }, _('重载 Nginx')),
            E('button', {
                'class': 'cbi-button cbi-button-neutral',
                'click': ui.createHandlerFn(this, 'handleReloadPage')
            }, _('重新读取文件'))
        ]);

        var blockList = E('div', { 'class': 'cbi-section' }, [
            E('h3', _('已配置的监听端口'))
        ]);

        if (blocks.length === 0) {
            blockList.appendChild(E('div', {
                'style': 'color:#888; padding:8px 0;'
            }, _('(暂无配置)')));
        } else {
            blocks.forEach(function(b, idx) {
                var card = E('div', {
                    'style': 'border:1px solid #ddd; border-radius:4px; padding:10px; margin-bottom:10px; background:#fafafa;'
                }, [
                    E('div', {
                        'style': 'display:flex; justify-content:space-between; align-items:center; margin-bottom:8px;'
                    }, [
                        E('strong', {}, _('监听配置 #%d').format(idx + 1)),
                        E('button', {
                            'class': 'cbi-button cbi-button-remove',
                            'click': function(ev) { self.handleDelete(idx, ev); }
                        }, _('删除'))
                    ]),
                    E('pre', {
                        'style': 'background:#fff; padding:8px; border-radius:3px; overflow-x:auto; white-space:pre-wrap; margin:0; font-size:12px;'
                    }, b.text)
                ]);
                blockList.appendChild(card);
            });
        }

        var addForm = E('div', { 'class': 'cbi-section' }, [
            E('h3', _('添加新监听端口')),

            E('div', { 'class': 'cbi-value' }, [
                E('label', { 'class': 'cbi-value-title', 'for': 'port' }, _('监听端口')),
                E('div', { 'class': 'cbi-value-field' }, [
                    E('input', { 'type': 'text', 'id': 'port', 'class': 'cbi-input-text', 'value': '880' })
                ])
            ]),

            E('div', { 'class': 'cbi-value' }, [
                E('label', { 'class': 'cbi-value-title', 'for': 'server_name' }, _('服务器名称')),
                E('div', { 'class': 'cbi-value-field' }, [
                    E('input', { 'type': 'text', 'id': 'server_name', 'class': 'cbi-input-text', 'value': 'localhost' })
                ])
            ]),

            E('div', { 'class': 'cbi-value' }, [
                E('label', { 'class': 'cbi-value-title', 'for': 'root' }, _('网站根目录')),
                E('div', { 'class': 'cbi-value-field' }, [
                    E('input', { 'type': 'text', 'id': 'root', 'class': 'cbi-input-text', 'value': '/mnt' })
                ])
            ]),

            E('div', { 'class': 'cbi-value' }, [
                E('label', { 'class': 'cbi-value-title', 'for': 'autoindex' }, _('开启目录浏览')),
                E('div', { 'class': 'cbi-value-field' }, [
                    E('input', { 'type': 'checkbox', 'id': 'autoindex', 'checked': true })
                ])
            ]),

            E('div', { 'class': 'cbi-value' }, [
                E('label', { 'class': 'cbi-value-title', 'for': 'charset' }, _('字符编码')),
                E('div', { 'class': 'cbi-value-field' }, [
                    E('input', { 'type': 'text', 'id': 'charset', 'class': 'cbi-input-text', 'value': 'utf-8' })
                ])
            ]),

            E('div', { 'class': 'cbi-page-actions' }, [
                E('button', {
                    'class': 'cbi-button cbi-button-apply',
                    'click': ui.createHandlerFn(this, 'handleSaveApply')
                }, _('保存并应用'))
            ])
        ]);

        var rawView = E('div', { 'class': 'cbi-section' }, [
            E('h3', _('当前文件内容')),
            E('pre', {
                'style': 'background: #f4f4f4; padding: 10px; border-radius: 4px; overflow-x: auto; white-space: pre-wrap;'
            }, currentContent || _('(文件为空)'))
        ]);

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', _('Nginx 配置管理')),
            E('div', { 'class': 'cbi-map-descr' }, _('直接管理 /etc/nginx/conf.d/nginx.conf 文件')),

            toolbar,
            blockList,
            addForm,
            rawView
        ]);
    }
});
