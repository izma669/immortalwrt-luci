'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';

// 声明调用 ubus 的 service list 方法
var callServiceList = rpc.declare({
    object: 'service',
    method: 'list',
    params: ['name'],
    expect: { '': {} }
});

return view.extend({
    // 加载时需要的数据
    load: function() {
        return Promise.all([
            uci.load('nginx'),
            callServiceList('nginx')
        ]);
    },

    render: function(data) {
        var serviceData = data[1];
        var m, s, o;

        // 创建表单 Map，绑定到 'nginx' 配置文件
        m = new form.Map('nginx', _('Nginx 配置管理'),
            _('通过 UCI 管理 Nginx 的服务器配置。'));

        // --- 全局设置 (config main global) ---
        s = m.section(form.NamedSection, 'global', 'main', _('全局设置'));
        s.anonymous = true;

        o = s.option(form.Flag, 'uci_enable', _('启用 UCI 配置'),
            _('启用后，Nginx 将从 UCI 生成配置文件。'));
        o.default = 'true';
        o.rmempty = false;

        // --- HTTP 服务器 (_lan_http) ---
        s = m.section(form.NamedSection, '_lan_http', 'server', _('HTTP 服务器 (端口 80)'));
        s.anonymous = false; // 显示 section 名称
        s.addremove = false; // 不允许删除默认 server

        o = s.option(form.DynamicList, 'listen', _('监听地址'),
            _('例如：80 或 [::]:80'));
        o.datatype = 'string';

        o = s.option(form.Value, 'server_name', _('服务器名称'),
            _('例如：_lan 或 example.com'));
        o.datatype = 'hostname';

        o = s.option(form.DynamicList, 'include', _('包含文件'),
            _('例如：conf.d/*.locations'));
        o.datatype = 'string';

        // --- HTTPS 服务器 (_lan) ---
        s = m.section(form.NamedSection, '_lan', 'server', _('HTTPS 服务器 (端口 443)'));
        s.anonymous = false;
        s.addremove = false;

        o = s.option(form.DynamicList, 'listen', _('监听地址'),
            _('例如：443 ssl default_server'));
        o.datatype = 'string';

        o = s.option(form.Value, 'server_name', _('服务器名称'));
        o.datatype = 'hostname';

        o = s.option(form.DynamicList, 'include', _('包含文件'));
        o.datatype = 'string';

        o = s.option(form.Flag, 'uci_manage_ssl', _('UCI 管理 SSL'));
        o.default = 'self-signed';
        o.rmempty = false;

        o = s.option(form.Value, 'ssl_certificate', _('SSL 证书路径'));
        o.datatype = 'file';

        o = s.option(form.Value, 'ssl_certificate_key', _('SSL 私钥路径'));
        o.datatype = 'file';

        o = s.option(form.Value, 'ssl_session_cache', _('SSL 会话缓存'));
        o.datatype = 'string';

        o = s.option(form.Value, 'ssl_session_timeout', _('SSL 会话超时'));
        o.datatype = 'string';

        o = s.option(form.Value, 'access_log', _('访问日志'));
        o.datatype = 'string';

        // 在表单下方添加服务控制按钮
        var serviceStatus = serviceData['nginx'] ? serviceData['nginx'].instances : null;
        var isRunning = serviceStatus && serviceStatus.instance1 && serviceStatus.instance1.running;

        m.description = _('当前 Nginx 状态：%s').format(
            isRunning ? _('运行中') : _('已停止')
        ) + '<br />' +
        '<button class="btn cbi-button cbi-button-apply" onclick="location.href=\'/cgi-bin/luci/admin/system/startup\'">' +
        _('管理服务') + '</button>';

        return m.render();
    }
});
