'use strict';
'require view';
'require fs';
'require ui';

// ==================== 工具函数 ====================

function parseUci(text) {
    var result = {};
    var current = null;
    var lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        if (!line || line.charAt(0) === '#') continue;
        var m;
        if ((m = line.match(/^config\s+(\w+)\s+['"]?([\w\-]+)['"]?/))) {
            current = { kind: m[1], name: m[2], options: {}, lists: {} };
            result[m[2]] = current;
        } else if (current && (m = line.match(/^option\s+(\w+)\s+(.+)$/))) {
            var val = m[2].trim();
            if ((val.charAt(0) === '"' && val.charAt(val.length - 1) === '"') ||
                (val.charAt(0) === "'" && val.charAt(val.length - 1) === "'")) {
                val = val.substring(1, val.length - 1);
            }
            current.options[m[1]] = val;
        } else if (current && (m = line.match(/^list\s+(\w+)\s+(.+)$/))) {
            var v = m[2].trim();
            if ((v.charAt(0) === '"' && v.charAt(v.length - 1) === '"') ||
                (v.charAt(0) === "'" && v.charAt(v.length - 1) === "'")) {
                v = v.substring(1, v.length - 1);
            }
            if (!current.lists[m[1]]) current.lists[m[1]] = [];
            current.lists[m[1]].push(v);
        }
    }
    return result;
}

function findPort(listenList) {
    if (!listenList) return null;
    for (var i = 0; i < listenList.length; i++) {
        var m = listenList[i].match(/^(\d+)/);
        if (m) return parseInt(m[1], 10);
    }
    return null;
}

// ★ 修复：只从 location / { ... } 块里提取 root，跳过 player.html/mpegts.min.js 里的 /www
function extractRoot(content) {
    if (!content) return '/mnt';
    var lines = content.split('\n');
    var inRootLocation = false;
    var depth = 0;
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        // 匹配 `location / {` 或 `location /{`（不含 location = / 和 location /api/dir/）
        if (!inRootLocation && /^\s*location\s+\/\s*\{/.test(line)) {
            inRootLocation = true;
            depth = 1;
            continue;
        }
        if (inRootLocation) {
            var m = line.match(/^\s*root\s+([^;]+);/);
            if (m) return m[1].trim();
            depth += (line.match(/\{/g) || []).length;
            depth -= (line.match(/\}/g) || []).length;
            if (depth <= 0) break;
        }
    }
    // 兜底 1：从 alias 提取（形如 alias /mnt/sda1/media/;）
    var aliasM = content.match(/alias\s+([^;]+);/);
    if (aliasM) {
        var ap = aliasM[1].trim().replace(/\/$/, '');
        if (ap !== '/www' && ap !== '/') return ap;
    }
    // 兜底 2：找第一个非 /www 的 root
    for (var j = 0; j < lines.length; j++) {
        var m2 = lines[j].match(/^\s*root\s+([^;]+);/);
        if (m2) {
            var r = m2[1].trim();
            if (r !== '/www') return r;
        }
    }
    return '/mnt';
}

// ==================== uci / 对话框 ====================

function uciExec(args) {
    return fs.exec('/sbin/uci', args).then(function(res) {
        if (res.code !== 0) throw new Error((res.stderr || '').trim() || 'uci 失败');
        return res;
    }).catch(function(e) {
        return fs.exec('/usr/sbin/uci', args).then(function(res) {
            if (res.code !== 0) throw new Error((res.stderr || '').trim() || 'uci 失败');
            return res;
        });
    });
}

function changePortDirect(mediaName, newPort) {
    return uciExec(['-q', 'delete', 'nginx.' + mediaName + '.listen'])
        .catch(function() {})
        .then(function() {
            return uciExec(['add_list', 'nginx.' + mediaName + '.listen=' + newPort + ' default_server']);
        })
        .then(function() {
            return uciExec(['add_list', 'nginx.' + mediaName + '.listen=[::]:' + newPort + ' default_server']);
        })
        .then(function() {
            return uciExec(['commit', 'nginx']);
        })
        .then(function() {
            return fs.exec('/etc/init.d/nginx', ['reload']).then(function(res) {
                if (res.code !== 0) throw new Error((res.stderr || '').trim() || 'nginx reload 失败');
            });
        });
}

function showCommandDialog(title, cmd) {
    var input = E('textarea', {
        'readonly': 'readonly',
        'rows': '4',
        'style': 'width:100%; font-family:monospace; font-size:12px; padding:8px; border:1px solid #ccc; border-radius:3px; background:#fafafa;'
    });
    input.value = cmd;

    var statusEl = E('span', { 'style': 'color:#4a9eff; margin-left:10px; font-size:12px;' }, '');

    function doCopy() {
        input.select();
        input.setSelectionRange(0, 99999);
        var ok = false;
        try {
            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(cmd);
                ok = true;
            }
        } catch (e) {}
        if (!ok) {
            try { ok = document.execCommand('copy'); } catch (e) {}
        }
        statusEl.textContent = ok ? '✔ 已复制到剪贴板' : '✖ 复制失败，请手动选中复制';
        setTimeout(function() { statusEl.textContent = ''; }, 2500);
    }

    ui.showModal(title, [
        E('p', { 'style': 'margin-bottom:8px; color:#666; font-size:13px;' },
            '请复制下面的命令，在路由器 SSH 中粘贴执行：'),
        input,
        E('div', { 'style': 'margin-top:8px;' }, [
            E('button', { 'class': 'cbi-button cbi-button-action', 'click': doCopy }, '📋 复制命令'),
            statusEl
        ]),
        E('div', { 'class': 'right', 'style': 'margin-top:15px;' }, [
            E('button', { 'class': 'cbi-button cbi-button-neutral',
                'click': function() { ui.hideModal(); } }, '关闭')
        ])
    ]);

    setTimeout(function() { input.focus(); input.select(); }, 100);
}

// ==================== 主视图 ====================

return view.extend({

    load: function() {
        return Promise.all([
            fs.read('/etc/config/nginx').catch(function() { return ''; }),
            fs.read('/etc/nginx/media.locations').catch(function() { return ''; })
        ]).then(function(data) {
            return {
                uciText: data[0] || '',
                mediaLocText: data[1] || ''
            };
        });
    },

    handleReloadNginx: function() {
        return fs.exec('/etc/init.d/nginx', ['reload']).then(function(res) {
            if (res.code !== 0) throw new Error((res.stderr || '').trim() || '未知错误');
            ui.addNotification(null, E('p', _('Nginx 已重载')), 'info');
        }).catch(function(e) {
            ui.addNotification(null, E('p', _('重载失败：%s').format(e.message)), 'error');
        });
    },

    handleReloadPage: function() { window.location.reload(); },

    handleJumpTtyd: function() {
        window.open('/cgi-bin/luci/admin/system/ttyd', '_blank');
    },

    handleOpenMediaSite: function() {
        var portInput = document.getElementById('media-port');
        var port = (portInput && portInput.value) || '880';
        var host = window.location.hostname;
        window.open('http://' + host + ':' + port + '/', '_blank');
    },

    saveMediaPort: function(mediaName, currentPort) {
        var newPort = parseInt(document.getElementById('media-port').value, 10);
        if (!newPort || newPort < 1 || newPort > 65535) {
            ui.addNotification(null, E('p', _('端口必须为 1-65535 之间的数字')), 'error');
            return;
        }
        if (newPort === currentPort) {
            ui.addNotification(null, E('p', _('端口未改变')), 'info');
            return;
        }
        if (!mediaName) {
            ui.addNotification(null, E('p', _('未找到媒体服务块')), 'error');
            return;
        }

        return changePortDirect(mediaName, newPort)
            .then(function() {
                ui.addNotification(null, E('p', _('媒体端口已改为 %d').format(newPort)), 'info');
                window.setTimeout(function() { window.location.reload(); }, 1200);
            })
            .catch(function(e) {
                ui.addNotification(null, E('p', _('直接修改失败，已改为生成命令：%s').format(e.message)), 'warning');
                var cmd =
                    'uci -q delete nginx.' + mediaName + '.listen && ' +
                    'uci add_list nginx.' + mediaName + '.listen="' + newPort + ' default_server" && ' +
                    'uci add_list nginx.' + mediaName + '.listen="[::]:' + newPort + ' default_server" && ' +
                    'uci commit nginx && ' +
                    '/etc/init.d/nginx reload';
                showCommandDialog('修改媒体服务端口为 ' + newPort, cmd);
            });
    },

    showRootCommand: function(newRoot) {
        if (!newRoot || newRoot.charAt(0) !== '/') {
            ui.addNotification(null, E('p', _('路径必须以 / 开头')), 'error');
            return;
        }
        // ★ 只替换 location / 和视频正则块里的 root（不碰 player.html/mpegts.min.js）
        var cmd =
            "sed -i 's|root /www;|__KEEP__/www;|g; " +
            "s|^\\s*root\\s\\+[^;]\\+;|root " + newRoot + ";|g; " +
            "s|__KEEP__/www;|root /www;|g' /etc/nginx/media.locations && " +
            '/etc/init.d/nginx reload';
        showCommandDialog('修改网站根目录为 ' + newRoot, cmd);
    },

    showBrowseDialog: function(callback) {
        var currentPath = '/mnt';
        var pathEl = E('code', { 'style': 'color:#4a9eff; font-size:13px; word-break:break-all;' }, currentPath);
        var listEl = E('div', {
            'style': 'max-height:380px; min-height:220px; overflow-y:auto; border:1px solid #ddd; border-radius:4px; background:#fff;'
        }, []);

        var pickBtn = E('button', {
            'class': 'cbi-button cbi-button-action',
            'click': function() {
                ui.hideModal();
                callback(currentPath);
            }
        }, '选择此目录');

        function renderDir(path) {
            currentPath = path;
            pathEl.textContent = path;
            listEl.innerHTML = '';
            listEl.appendChild(E('div', { 'style': 'padding:14px; color:#888;' }, '加载中...'));

            return fs.list(path).then(function(entries) {
                listEl.innerHTML = '';

                if (path !== '/mnt') {
                    var parent = path.replace(/\/+$/, '').replace(/\/[^\/]+$/, '') || '/mnt';
                    if (parent.length < 4) parent = '/mnt';
                    var up = E('div', {
                        'style': 'padding:8px 12px; cursor:pointer; color:#ff9800; border-bottom:1px solid #eee; user-select:none;',
                        'click': function() { renderDir(parent); }
                    }, '📁 ..  (上级目录)');
                    up.addEventListener('mouseover', function() { up.style.background = '#fff8e1'; });
                    up.addEventListener('mouseout', function() { up.style.background = ''; });
                    listEl.appendChild(up);
                }

                var dirs = (entries || []).filter(function(e) {
                    return e.type === 'directory';
                }).sort(function(a, b) {
                    return a.name.localeCompare(b.name);
                });

                if (dirs.length === 0) {
                    listEl.appendChild(E('div', { 'style': 'padding:14px; color:#888;' }, '(此目录下无子目录)'));
                } else {
                    dirs.forEach(function(d) {
                        var full = path.replace(/\/+$/, '') + '/' + d.name;
                        var item = E('div', {
                            'style': 'padding:8px 12px; cursor:pointer; border-bottom:1px solid #eee; user-select:none;',
                            'click': function() { renderDir(full); }
                        }, [
                            E('span', { 'style': 'margin-right:8px;' }, '📁'),
                            E('span', { 'style': 'color:#333;' }, d.name)
                        ]);
                        item.addEventListener('mouseover', function() { item.style.background = '#f0f7ff'; });
                        item.addEventListener('mouseout', function() { item.style.background = ''; });
                        listEl.appendChild(item);
                    });
                }
            }).catch(function(e) {
                listEl.innerHTML = '';
                listEl.appendChild(E('div', { 'style': 'padding:14px; color:#d32f2f;' },
                    '读取失败：' + (e.message || e)));
            });
        }

        renderDir('/mnt');

        ui.showModal('浏览 /mnt 目录', [
            E('div', { 'style': 'margin-bottom:10px; padding:8px; background:#f0f7ff; border-radius:4px;' }, [
                E('span', { 'style': 'color:#666; margin-right:6px;' }, '当前位置：'),
                pathEl
            ]),
            E('div', { 'style': 'margin-bottom:8px; font-size:12px; color:#888;' },
                '点击目录进入下一层，"选择此目录"会把当前路径填入输入框'),
            listEl,
            E('div', { 'class': 'right', 'style': 'margin-top:15px;' }, [
                E('button', { 'class': 'cbi-button cbi-button-neutral',
                    'click': function() { ui.hideModal(); } }, '取消'),
                ' ',
                pickBtn
            ])
        ]);
    },

    render: function(data) {
        var self = this;
        var uciMap = parseUci(data.uciText);
        var mediaLocText = data.mediaLocText;

        var httpServer = null, httpsServer = null, mediaServer = null;
        Object.keys(uciMap).forEach(function(name) {
            var s = uciMap[name];
            var ports = (s.lists.listen || []).map(function(l) { return findPort([l]); });
            if (ports.indexOf(443) >= 0) httpsServer = s;
            else if (ports.indexOf(80) >= 0) httpServer = s;
            else if (!mediaServer && ports.length > 0) mediaServer = s;
        });
        var mediaName = mediaServer ? mediaServer.name : null;
        var mediaPort = mediaServer ? findPort(mediaServer.lists.listen || []) : 880;
        var mediaRoot = extractRoot(mediaLocText);

        var toolbar = E('div', { 'style': 'margin-bottom:15px; display:flex; gap:8px; flex-wrap:wrap;' }, [
            E('button', { 'class': 'cbi-button cbi-button-action',
                'click': ui.createHandlerFn(this, 'handleReloadNginx') }, _('重载 Nginx')),
            E('button', { 'class': 'cbi-button cbi-button-neutral',
                'click': ui.createHandlerFn(this, 'handleReloadPage') }, _('刷新页面')),
            E('button', { 'class': 'cbi-button cbi-button-apply',
                'click': ui.createHandlerFn(this, 'handleJumpTtyd') }, _('💻 打开终端'))
        ]);

        var mainSection = E('div', { 'class': 'cbi-section' }, [
            E('h3', _('主服务（只读）')),
            E('div', { 'class': 'cbi-map-descr' }, _('来自 /etc/config/nginx，由 nginx init 脚本生成，仅供查看。'))
        ]);
        if (httpServer) {
            mainSection.appendChild(E('div', {
                'style': 'border:1px solid #ddd; border-radius:4px; padding:10px; margin-bottom:10px; background:#fafafa;'
            }, [
                E('strong', {}, ' HTTP 80 — UCI: ' + httpServer.name),
                E('pre', { 'style': 'background:#fff; padding:8px; margin:6px 0 0 0; font-size:12px; white-space:pre-wrap;' },
                    'listen: ' + (httpServer.lists.listen || []).join(', ') + '\n' +
                    'server_name: ' + (httpServer.options.server_name || '-') + '\n' +
                    'include: ' + (httpServer.lists.include || []).join(', '))
            ]));
        }
        if (httpsServer) {
            mainSection.appendChild(E('div', {
                'style': 'border:1px solid #ddd; border-radius:4px; padding:10px; margin-bottom:10px; background:#fafafa;'
            }, [
                E('strong', {}, ' HTTPS 443 — UCI: ' + httpsServer.name),
                E('pre', { 'style': 'background:#fff; padding:8px; margin:6px 0 0 0; font-size:12px; white-space:pre-wrap;' },
                    'listen: ' + (httpsServer.lists.listen || []).join(', ') + '\n' +
                    'server_name: ' + (httpsServer.options.server_name || '-') + '\n' +
                    'ssl_certificate: ' + (httpsServer.options.ssl_certificate || '-') + '\n' +
                    'ssl_certificate_key: ' + (httpsServer.options.ssl_certificate_key || '-'))
            ]));
        }

        var rootInput = E('input', {
            'type': 'text',
            'id': 'media-root-input',
            'class': 'cbi-input-text',
            'value': mediaRoot,
            'style': 'width:320px;'
        });

        var mediaSection = E('div', { 'class': 'cbi-section' }, [
            E('h3', _('媒体服务（可修改）')),
            E('div', { 'class': 'cbi-map-descr' },
                _('UCI 名称：%s ／ 扩展配置来自 /etc/nginx/media.locations').format(mediaName || '(未找到)')),
            E('div', {
                'style': 'margin-bottom:10px; padding:8px 12px; background:#e8f5e9; border-left:3px solid #4caf50; border-radius:3px; font-size:12px; color:#555; line-height:1.6;'
            }, [
                '💡 端口可直接保存；根目录因 rpcd 限制无法直接写，改用"生成命令"方式'
            ]),

            E('div', { 'class': 'cbi-value' }, [
                E('label', { 'class': 'cbi-value-title' }, _('HTTP 端口')),
                E('div', { 'class': 'cbi-value-field', 'style': 'display:flex; gap:8px; align-items:center; flex-wrap:wrap;' }, [
                    E('input', { 'type': 'number', 'id': 'media-port', 'class': 'cbi-input-text',
                        'value': mediaPort, 'min': '1', 'max': '65535', 'style': 'width:120px;' }),
                    E('button', { 'class': 'cbi-button cbi-button-action',
                        'click': function() { self.saveMediaPort(mediaName, mediaPort); } }, _('保存端口')),
                    E('button', { 'class': 'cbi-button cbi-button-apply',
                        'click': function() { self.handleOpenMediaSite(); } }, _('🌐 进入服务器站点'))
                ])
            ]),

            E('div', { 'class': 'cbi-value' }, [
                E('label', { 'class': 'cbi-value-title' }, _('网站根目录')),
                E('div', { 'class': 'cbi-value-field' }, [
                    E('div', { 'style': 'display:flex; gap:8px; align-items:center; flex-wrap:wrap;' }, [
                        rootInput,
                        E('button', {
                            'class': 'cbi-button cbi-button-neutral',
                            'click': function() {
                                self.showBrowseDialog(function(picked) {
                                    rootInput.value = picked;
                                });
                            }
                        }, _('📂 浏览选择')),
                        E('button', {
                            'class': 'cbi-button cbi-button-action',
                            'click': function() {
                                self.showRootCommand(rootInput.value.trim());
                            }
                        }, _('生成修改命令'))
                    ]),
                    E('div', {
                        'style': 'margin-top:6px; padding:8px 10px; background:#f0f7ff; border-left:3px solid #4a9eff; border-radius:3px; font-size:12px; color:#555; line-height:1.6;'
                    }, [
                        '点击"📂 浏览选择"打开目录树，选中后自动填入，再点"生成修改命令"复制到 SSH 执行'
                    ])
                ])
            ])
        ]);

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', _('Nginx 配置管理')),
            toolbar,
            mainSection,
            mediaSection
        ]);
    }
});
