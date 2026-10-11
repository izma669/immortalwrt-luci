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

function reloadNginx() {
    return fs.exec('/etc/init.d/nginx', ['reload']).then(function(res) {
        if (res.code !== 0) {
            var msg = (res.stderr || '').trim() || (res.stdout || '').trim() || _('未知错误');
            throw new Error(_('Nginx 重载失败：\n') + msg);
        }
    });
}

function extractMediaPort(content) {
    if (!content) return null;
    var m = content.match(/listen\s+(\d+)\s+default_server/);
    return m ? parseInt(m[1], 10) : null;
}

function replaceMediaPort(content, oldPort, newPort) {
    var re1 = new RegExp('listen\\s+' + oldPort + '\\s+default_server', 'g');
    var re2 = new RegExp('listen\\s+\\[::\\]:' + oldPort + '\\s+default_server', 'g');
    content = content.replace(re1, 'listen ' + newPort + ' default_server');
    content = content.replace(re2, 'listen [::]:' + newPort + ' default_server');
    return content;
}

return view.extend({
    load: function() {
        return fs.read('/etc/nginx/conf.d/nginx.conf').catch(function() {
            return '';
        });
    },

    handleReloadNginx: function(ev) {
        return reloadNginx().then(function() {
            ui.addNotification(null, E('p', _('Nginx 已重载')), 'info');
        }).catch(function(e) {
            ui.addNotification(null, E('p', _('重载失败：%s').format(e.message)), 'error');
        });
    },

    handleReloadPage: function(ev) {
        window.location.reload();
    },

    // ---------- 部署播放器到 /mnt ----------
    handleDeployPlayer: function(ev) {
        return fs.exec('/bin/cp', ['-f', '/www/player.html', '/mnt/player.html'])
            .then(function(res) {
                if (res.code !== 0) {
                    throw new Error((res.stderr || '').trim() || _('复制失败'));
                }
                ui.addNotification(null, E('p', _('播放器已部署到 /mnt/player.html')), 'info');
            })
            .catch(function(e) {
                ui.addNotification(null, E('p', _('部署失败：%s').format(e.message)), 'error');
            });
    },

    // ---------- 打开多媒体 HTTP 管理 ----------
    handleOpenPlayer: function(ev) {
        var port = document.getElementById('media-port').value;
        var url = 'http://' + window.location.hostname + ':' + port + '/';
        window.open(url, '_blank');
    },

    // ---------- 保存媒体端口 ----------
    handleSaveMediaPort: function(ev) {
        var newPort = parseInt(document.getElementById('media-port').value, 10);
        if (!newPort || newPort < 1 || newPort > 65535) {
            ui.addNotification(null, E('p', _('端口必须为 1-65535 之间的数字')), 'error');
            return;
        }

        return fs.read('/etc/nginx/conf.d/nginx.conf').catch(function() { return ''; })
            .then(function(content) {
                var oldPort = extractMediaPort(content);
                if (!oldPort) throw new Error(_('未找到 listen <port> default_server 配置'));
                if (oldPort === newPort) {
                    ui.addNotification(null, E('p', _('端口未改变')), 'info');
                    return;
                }
                var originalContent = content;
                var newContent = replaceMediaPort(content, oldPort, newPort);
                return fs.write('/etc/nginx/conf.d/nginx.conf', newContent)
                    .then(function() {
                        return reloadNginx().catch(function(e) {
                            return fs.write('/etc/nginx/conf.d/nginx.conf', originalContent)
                                .then(function() { throw e; });
                        });
                    })
                    .then(function() {
                        ui.addNotification(null, E('p', _('媒体端口已改为 %d，Nginx 已重载').format(newPort)), 'info');
                        window.setTimeout(function() { window.location.reload(); }, 1200);
                    });
            })
            .catch(function(e) {
                ui.addNotification(null, E('p', _('保存失败：%s').format(e.message)), 'error');
            });
    },

    // ---------- 添加监听端口（其它用途） ----------
    handleAddServer: function(ev) {
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
        return fs.read('/etc/nginx/conf.d/nginx.conf').catch(function() { return ''; })
            .then(function(content) {
                originalContent = content;
                return fs.write('/etc/nginx/conf.d/nginx.conf', content + block);
            })
            .then(function() {
                return reloadNginx().catch(function(e) {
                    return fs.write('/etc/nginx/conf.d/nginx.conf', originalContent)
                        .then(function() { throw e; });
                });
            })
            .then(function() {
                ui.addNotification(null, E('p', _('配置已成功保存并重载 Nginx')), 'info');
                window.setTimeout(function() { window.location.reload(); }, 1200);
            })
            .catch(function(e) {
                ui.addNotification(null, E('p', _('保存失败：%s').format(e.message)), 'error');
            });
    },

    handleDelete: function(index, ev) {
        return fs.read('/etc/nginx/conf.d/nginx.conf').catch(function() { return ''; })
            .then(function(content) {
                var originalContent = content;
                var blocks = parseBlocks(content);
                if (index < 0 || index >= blocks.length) throw new Error(_('无效的块索引'));
                var blockText = blocks[index].text;

                // 主服务块（含 listen XXX default_server）不允许删除
                if (/listen\s+\d+\s+default_server/.test(blockText)) {
                    ui.addNotification(null, E('p', _('媒体服务器块不允许删除，仅可修改端口')), 'error');
                    return;
                }

                var newContent = content.replace(blockText, '');
                newContent = newContent.replace(/\n\s*\n\s*\n+/g, '\n\n');
                newContent = newContent.replace(/^\s*\n+/, '');

                return fs.write('/etc/nginx/conf.d/nginx.conf', newContent)
                    .then(function() {
                        return reloadNginx().catch(function(e) {
                            return fs.write('/etc/nginx/conf.d/nginx.conf', originalContent)
                                .then(function() { throw e; });
                        });
                    })
                    .then(function() {
                        ui.addNotification(null, E('p', _('已删除该监听配置')), 'info');
                        window.setTimeout(function() { window.location.reload(); }, 1200);
                    });
            })
            .catch(function(e) {
                ui.addNotification(null, E('p', _('删除失败：%s').format(e.message)), 'error');
            });
    },

    render: function(currentContent) {
        var self = this;
        var content = currentContent || '';
        var blocks = parseBlocks(content);
        var mediaPort = extractMediaPort(content);

        // ---------- 顶部工具栏 ----------
        var toolbar = E('div', { 'style': 'margin-bottom:15px; display:flex; gap:8px; flex-wrap:wrap;' }, [
            E('button', {
                'class': 'cbi-button cbi-button-action',
                'click': ui.createHandlerFn(this, 'handleOpenPlayer')
            }, _('▶ 启动多媒体 HTTP 管理')),
            E('button', {
                'class': 'cbi-button cbi-button-neutral',
                'click': ui.createHandlerFn(this, 'handleReloadNginx')
            }, _('重载 Nginx')),
            E('button', {
                'class': 'cbi-button cbi-button-neutral',
                'click': ui.createHandlerFn(this, 'handleReloadPage')
            }, _('重新读取文件')),
            E('button', {
                'class': 'cbi-button cbi-button-neutral',
                'click': ui.createHandlerFn(this, 'handleDeployPlayer')
            }, _('重新部署播放器'))
        ]);

        // ---------- 媒体服务端口面板 ----------
        var mediaSection = E('div', { 'class': 'cbi-section' }, [
            E('h3', _('多媒体 HTTP 服务')),
            E('div', { 'class': 'cbi-map-descr' },
                _('控制播放器所在 nginx 服务块的监听端口。改完自动保存并重载。')),

            E('div', { 'class': 'cbi-value' }, [
                E('label', { 'class': 'cbi-value-title', 'for': 'media-port' }, _('HTTP 端口')),
                E('div', { 'class': 'cbi-value-field', 'style': 'display:flex; gap:8px; align-items:center; flex-wrap:wrap;' }, [
                    E('input', {
                        'type': 'number',
                        'id': 'media-port',
                        'class': 'cbi-input-text',
                        'value': mediaPort || 880,
                        'min': '1',
                        'max': '65535',
                        'style': 'width:120px;'
                    }),
                    E('button', {
                        'class': 'cbi-button cbi-button-action',
                        'click': ui.createHandlerFn(this, 'handleSaveMediaPort')
                    }, _('保存端口')),
                    E('button', {
                        'class': 'cbi-button cbi-button-apply',
                        'click': ui.createHandlerFn(this, 'handleOpenPlayer')
                    }, _('启动多媒体 HTTP 管理'))
                ])
            ]),

            E('div', { 'class': 'cbi-value' }, [
                E('label', { 'class': 'cbi-value-title' }, _('访问地址')),
                E('div', { 'class': 'cbi-value-field' }, [
                    E('code', { 'style': 'color:#4a9eff;' },
                        'http://' + window.location.hostname + ':' + (mediaPort || 880) + '/')
                ])
            ])
        ]);

        // ---------- 已配置块列表 ----------
        var blockList = E('div', { 'class': 'cbi-section' }, [
            E('h3', _('已配置的监听端口'))
        ]);

        if (blocks.length === 0) {
            blockList.appendChild(E('div', {
                'style': 'color:#888; padding:8px 0;'
            }, _('(暂无配置)')));
        } else {
            blocks.forEach(function(b, idx) {
                var isMedia = /listen\s+\d+\s+default_server/.test(b.text);
                var card = E('div', {
                    'style': 'border:1px solid ' + (isMedia ? '#4a9eff' : '#ddd') + '; border-radius:4px; padding:10px; margin-bottom:10px; background:' + (isMedia ? '#f0f7ff' : '#fafafa') + ';'
                }, [
                    E('div', {
                        'style': 'display:flex; justify-content:space-between; align-items:center; margin-bottom:8px;'
                    }, [
                        E('strong', {}, _('监听配置 #%d').format(idx + 1) + (isMedia ? '  (' + _('主服务') + ')' : '')),
                        isMedia
                            ? E('span', { 'style': 'color:#4a9eff; font-size:12px;' }, _('端口由上方面板管理'))
                            : E('button', {
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

        // ---------- 添加新监听端口 ----------
        var addForm = E('div', { 'class': 'cbi-section' }, [
            E('h3', _('添加额外监听端口')),
            E('div', { 'class': 'cbi-map-descr' }, _('额外端口不会影响多媒体 HTTP 服务')),

            E('div', { 'class': 'cbi-value' }, [
                E('label', { 'class': 'cbi-value-title', 'for': 'port' }, _('监听端口')),
                E('div', { 'class': 'cbi-value-field' }, [
                    E('input', { 'type': 'text', 'id': 'port', 'class': 'cbi-input-text', 'value': '8081' })
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
                    'class': 'cbi-button cbi-button-action',
                    'click': ui.createHandlerFn(this, 'handleAddServer')
                }, _('添加此监听配置'))
            ])
        ]);

        // ---------- 文件内容预览 ----------
        var rawView = E('div', { 'class': 'cbi-section' }, [
            E('h3', _('当前文件内容')),
            E('pre', {
                'style': 'background:#f4f4f4; padding:10px; border-radius:4px; overflow-x:auto; white-space:pre-wrap; max-height:400px;'
            }, content || _('(文件为空)'))
        ]);

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', _('Nginx 配置管理')),
            E('div', { 'class': 'cbi-map-descr' }, _('直接管理 /etc/nginx/conf.d/nginx.conf 文件')),

            toolbar,
            mediaSection,
            blockList,
            addForm,
            rawView
        ]);
    }
});
