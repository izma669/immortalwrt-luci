'use strict';
'require view';
'require fs';
'require ui';

return view.extend({
    load: function() {
        return fs.read('/etc/nginx/conf.d/nginx.conf').catch(function() {
            return '';
        });
    },

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
            var newContent = content + block;
            return fs.write('/etc/nginx/conf.d/nginx.conf', newContent);
        }).then(function() {
            // 用 nginx -t 检查配置
            return fs.exec('/usr/sbin/nginx', ['-t']).then(function(res) {
                if (res.code !== 0) {
                    // 测试失败 → 回滚
                    return fs.write('/etc/nginx/conf.d/nginx.conf', originalContent).then(function() {
                        throw new Error(_('Nginx 配置测试失败：\n') + (res.stderr || res.stdout));
                    });
                }
                // 直接发 reload 信号，绕过 init.d 的 rc.common 框架
                return fs.exec('/usr/sbin/nginx', ['-s', 'reload']);
            });
        }).then(function() {
            ui.addNotification(null, E('p', _('配置已成功保存并重载 Nginx')), 'info');
            window.setTimeout(function() { window.location.reload(); }, 1500);
        }).catch(function(e) {
            ui.addNotification(null, E('p', _('保存失败：%s').format(e.message)), 'error');
        });
    },

    render: function(currentContent) {
        var container = E('div', { 'class': 'cbi-map' }, [
            E('h2', _('Nginx 配置管理')),
            E('div', { 'class': 'cbi-map-descr' }, _('直接管理 /etc/nginx/conf.d/nginx.conf 文件')),

            E('div', { 'class': 'cbi-section' }, [
                E('h3', _('当前文件内容')),
                E('pre', {
                    'style': 'background: #f4f4f4; padding: 10px; border-radius: 4px; overflow-x: auto; white-space: pre-wrap;'
                }, currentContent || _('(文件为空)'))
            ]),

            E('div', { 'class': 'cbi-section' }, [
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
            ])
        ]);
        return container;
    }
});
