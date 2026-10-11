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

    // ---------- 重载 / 刷新 / 部署 ----------
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

    // ---------- 打开 Web 页面 ----------
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

    // ---------- 添加额外监听端口 ----------
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

    // ---------- 删除块 ----------
    handleDelete: function(index, ev) {
        return fs.read('/etc/nginx/conf.d/nginx.conf').catch(function() { return ''; })
            .then(function(content) {
                var originalContent = content;
                var blocks = parseBlocks(content);
                if (index < 0 || index >= blocks.length) throw new Error(_('无效的块索引'));
                var blockText = blocks[index].text;

                if (/listen\s+\d+\s+default_server/.test(blockText)) {
                    ui.addNotification(null, E('p', _('主服务块不允许删除，仅可修改端口')), 'error');
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

    // ---------- 查看日志 ----------
    handleViewLog: function(ev) {
        var panel = document.querySelector('#log-panel');
        if (!panel) return;
        if (panel.style.display === 'block') {
            panel.style.display = 'none';
            return;
        }
        panel.style.display = 'block';
        return this.loadLog();
    },

    loadLog: function() {
        var pre = document.querySelector('#log-content');
        if (pre) {
            pre.textContent = '加载中...';
            pre.scrollTop = 0;
        }
        return fs.exec('/sbin/logread', ['-e', 'nginx']).then(function(res) {
            var out = (res.stdout || '') + (res.stderr || '');
            var lines = out.split('\n').filter(function(l) { return l.trim() !== ''; });
            if (lines.length > 200) lines = lines.slice(-200);
            var text = lines.join('\n') || '(无 nginx 日志)';
            var el = document.querySelector('#log-content');
            if (el) {
                el.textContent = text;
                el.scrollTop = el.scrollHeight;
            }
        }).catch(function(e) {
            var el = document.querySelector('#log-content');
            if (el) el.textContent = '读取日志失败：' + (e.message || e);
        });
    },

    // ---------- 切换 tab ----------
    switchTab: function(tab) {
        document.querySelectorAll('.tab-btn').forEach(function(el) {
            var isActive = el.getAttribute('data-tab') === tab;
            el.style.background = isActive ? '#4a9eff' : '#f0f0f0';
            el.style.color = isActive ? '#fff' : '#444';
            el.style.borderColor = isActive ? '#4a9eff' : '#ccc';
            if (isActive) el.classList.add('active'); else el.classList.remove('active');
        });
        document.querySelectorAll('.block-card').forEach(function(el) {
            el.style.display = el.getAttribute('data-tab') === tab ? 'block' : 'none';
        });
    },

    render: function(currentContent) {
        var self = this;
        var content = currentContent || '';
        var blocks = parseBlocks(content);
        var mediaPort = extractMediaPort(content);

        // 分类块
        var mainBlocks = [];
        var extraBlocks = [];
        blocks.forEach(function(b, idx) {
            if (/listen\s+\d+\s+default_server/.test(b.text)) {
                mainBlocks.push({ idx: idx, block: b });
            } else {
                extraBlocks.push({ idx: idx, block: b });
            }
        });

        // ---------- 顶部工具栏 ----------
        var toolbar = E('div', { 'style': 'margin-bottom:15px; display:flex; gap:8px; flex-wrap:wrap;' }, [
            E('button', {
                'class': 'cbi-button cbi-button-action',
                'click': ui.createHandlerFn(this, 'handleReloadNginx')
            }, _('重载 Nginx')),
            E('button', {
                'class': 'cbi-button cbi-button-neutral',
                'click': ui.createHandlerFn(this, 'handleReloadPage')
            }, _('重新读取文件')),
            E('button', {
                'class': 'cbi-button cbi-button-neutral',
                'click': ui.createHandlerFn(this, 'handleDeployPlayer')
            }, _('重新部署播放器')),
            E('button', {
                'class': 'cbi-button cbi-button-neutral',
                'click': ui.createHandlerFn(this, 'handleViewLog')
            }, _('查看日志'))
        ]);

        // ---------- 多媒体 HTTP 服务面板 ----------
        var mediaSection = E('div', { 'class': 'cbi-section' }, [
            E('h3', _('多媒体 HTTP 服务')),
            E('div', { 'class': 'cbi-map-descr' }, _('控制播放器所在 nginx 服务块的监听端口')),

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
                    }, _('打开 Web 页面'))
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

        // ---------- 日志面板 ----------
        var logPanel = E('div', {
            'id': 'log-panel',
            'class': 'cbi-section',
            'style': 'display:none; border:1px solid #4a9eff; background:#f0f7ff;'
        }, [
            E('div', { 'style': 'display:flex; justify-content:space-between; align-items:center; margin-bottom:10px;' }, [
                E('h3', { 'style': 'margin:0;' }, _('Nginx 日志（最近 200 行）')),
                E('div', { 'style': 'display:flex; gap:6px;' }, [
                    E('button', {
                        'class': 'cbi-button cbi-button-neutral',
                        'click': function(ev) { self.loadLog(); }
                    }, _('刷新')),
                    E('button', {
                        'class': 'cbi-button cbi-button-neutral',
                        'click': function(ev) {
                            var p = document.querySelector('#log-panel');
                            if (p) p.style.display = 'none';
                        }
                    }, _('关闭'))
                ])
            ]),
            E('pre', {
                'id': 'log-content',
                'style': 'background:#1e1e1e; color:#d4d4d4; padding:12px; border-radius:4px; max-height:400px; overflow:auto; font-size:12px; margin:0; white-space:pre-wrap; word-break:break-all;'
            }, _('（点上方"查看日志"加载）'))
        ]);

        // ---------- 监听端口 tab 切换 ----------
        var tabBtnBase = 'background:#f0f0f0; color:#444; border:1px solid #ccc; padding:6px 14px; border-radius:4px; cursor:pointer; font-size:13px;';
        var tabBtnActive = 'background:#4a9eff; color:#fff; border-color:#4a9eff;';

        var tabBar = E('div', { 'style': 'display:flex; gap:6px; margin-bottom:12px;' }, [
            E('button', {
                'class': 'tab-btn active',
                'data-tab': 'main',
                'style': tabBtnBase + tabBtnActive,
                'click': function(ev) { self.switchTab('main'); }
            }, _('主服务') + ' (' + mainBlocks.length + ')'),
            E('button', {
                'class': 'tab-btn',
                'data-tab': 'extra',
                'style': tabBtnBase,
                'click': function(ev) { self.switchTab('extra'); }
            }, _('额外服务') + ' (' + extraBlocks.length + ')')
        ]);

        function makeCard(item, isMain) {
            var b = item.block;
            var idx = item.idx;

            var header = E('div', {
                'style': 'display:flex; justify-content:space-between; align-items:center; padding:8px 12px; background:' + (isMain ? '#e6f0ff' : '#f5f5f5') + '; border-radius:4px; cursor:pointer; user-select:none;',
                'click': function(ev) {
                    if (ev.target.tagName === 'BUTTON') return;
                    var body = ev.currentTarget.nextElementSibling;
                    var arrow = ev.currentTarget.querySelector('.toggle-arrow');
                    if (body) {
                        var isHidden = body.style.display === 'none';
                        body.style.display = isHidden ? 'block' : 'none';
                        if (arrow) arrow.textContent = isHidden ? '▼' : '▶';
                    }
                }
            }, [
                E('div', { 'style': 'display:flex; gap:8px; align-items:center;' }, [
                    E('span', { 'class': 'toggle-arrow', 'style': 'font-size:10px; color:#888; width:12px; text-align:center;' }, '▼'),
                    E('strong', { 'style': 'font-size:13px;' },
                        _('监听配置 #%d').format(idx + 1) + (isMain ? '  (' + _('主服务') + ')' : ''))
                ]),
                isMain
                    ? E('span', { 'style': 'color:#4a9eff; font-size:12px;' }, _('端口由上方面板管理'))
                    : E('button', {
                        'class': 'cbi-button cbi-button-remove',
                        'style': 'padding:2px 10px; font-size:12px;',
                        'click': function(ev) {
                            ev.stopPropagation();
                            self.handleDelete(idx, ev);
                        }
                    }, _('删除'))
            ]);

            var body = E('div', {
                'style': 'border:1px solid ' + (isMain ? '#b8d4ff' : '#ddd') + '; border-top:none; border-radius:0 0 4px 4px; padding:10px; background:#fff;'
            }, [
                E('pre', {
                    'style': 'background:#fafafa; padding:8px; border-radius:3px; overflow-x:auto; white-space:pre-wrap; margin:0; font-size:12px;'
                }, b.text)
            ]);

            return E('div', {
                'class': 'block-card',
                'data-tab': isMain ? 'main' : 'extra',
                'data-index': idx,
                'style': 'margin-bottom:10px;'
            }, [header, body]);
        }

        var blockListContainer = E('div', {}, []);
        mainBlocks.forEach(function(m) { blockListContainer.appendChild(makeCard(m, true)); });
        extraBlocks.forEach(function(m) { blockListContainer.appendChild(makeCard(m, false)); });

        var blockList = E('div', { 'class': 'cbi-section' }, [
            E('h3', _('已配置的监听端口')),
            tabBar,
            blockListContainer
        ]);

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

        // ---------- 文件预览 ----------
        var rawView = E('div', { 'class': 'cbi-section' }, [
            E('h3', _('当前文件内容')),
            E('pre', {
                'style': 'background:#f4f4f4; padding:10px; border-radius:4px; overflow-x:auto; white-space:pre-wrap; max-height:400px;'
            }, content || _('(文件为空)'))
        ]);

        var wrapper = E('div', { 'class': 'cbi-map' }, [
            E('h2', _('Nginx 配置管理')),
            E('div', { 'class': 'cbi-map-descr' }, _('直接管理 /etc/nginx/conf.d/nginx.conf 文件')),
            toolbar,
            mediaSection,
            logPanel,
            blockList,
            addForm,
            rawView
        ]);

        // render 后把非当前 tab 的卡片隐藏
        setTimeout(function() { self.switchTab('main'); }, 0);

        return wrapper;
    }
});
