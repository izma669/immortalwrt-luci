<%+header%>

<style>
    .vhusbd-card { padding: 15px; border: 1px solid #ddd; border-radius: 4px; margin-bottom: 15px; background: #fff; }
    .status-badge { padding: 4px 8px; border-radius: 4px; color: #fff; font-weight: bold; }
    .status-running { background-color: #5cb85c; }
    .status-stopped { background-color: #d9534f; }
    .fw-status { font-weight: bold; margin-right: 20px; }
    .fw-on { color: #5cb85c; }
    .fw-off { color: #d9534f; }
    #log-area { width: 100%; height: 200px; font-family: monospace; background: #f5f5f5; border: 1px solid #ccc; padding: 10px; overflow-y: scroll; display: none; margin-top: 10px; }
</style>

<div class="cbi-map">
    <h2>VirtualHere USB Server</h2>
    
    <!-- 新增：简单介绍和下载地址 -->
    <div class="vhusbd-card">
        <h3>简介与客户端下载</h3>
        <p>VirtualHere USB Server 用途：可实现通过网络挂载USB设备。</p>
        <p>从 <a href="http://www.virtualhere.com/usb_client_software" target="_blank">官网</a> 下载对应平台的客户端程序运行并联机。</p>
    </div>

    <!-- 服务控制 -->
    <div class="vhusbd-card">
        <h3>服务控制</h3>
        <p>当前状态：<span id="service-status" class="status-badge">获取中...</span></p>
        <button class="cbi-button cbi-button-apply" onclick="doAction('start')">启动服务</button>
        <button class="cbi-button cbi-button-reset" onclick="doAction('stop')">停止服务</button>
        <button class="cbi-button cbi-button-action" onclick="doAction('restart')">重启服务</button>
    </div>

    <!-- 网络访问控制 -->
    <div class="vhusbd-card">
        <h3>网络访问控制</h3>
        <p>
            <span class="fw-status">外网访问状态：<span id="wan-status" class="fw-off">获取中</span></span>
            <span class="fw-status">IPv6 访问状态：<span id="ipv6-status" class="fw-off">获取中</span></span>
        </p>
        <button class="cbi-button cbi-button-action" onclick="toggleFw('wan')">切换外网开关</button>
        <button class="cbi-button cbi-button-action" onclick="toggleFw('ipv6')">切换 IPv6 开关</button>
        <p style="color:#666; font-size:12px;">* 默认开放端口 7575，依赖 iptables/ip6tables 规则生效</p>
    </div>

    <!-- 一键注册 -->
    <div class="vhusbd-card">
        <h3>一键注册</h3>
        <p>点击下方按钮，自动读取 MAC 并替换 <code>/usr/bin/config.ini</code> 中的序列号。</p>
        <button class="cbi-button cbi-button-apply" onclick="doRegister()">一键注册</button>
    </div>

    <!-- 日志查看 -->
    <div class="vhusbd-card">
        <h3>系统日志</h3>
        <button class="cbi-button cbi-button-action" onclick="showLogs()">查看日志</button>
        <pre id="log-area"></pre>
    </div>

    <div id="action-msg" style="margin-top: 10px; font-weight: bold;"></div>
</div>

<script type="text/javascript">
    // 轮询状态
    function pollStatus(expectedState, maxRetries) {
        if (maxRetries <= 0) return;
        XHR.get('<%=url("admin/services/vhusbd/action")%>?action=status', null, function(x) {
            var badge = document.getElementById('service-status');
            var res = x.responseText;
            
            if (res === 'RUNNING') {
                badge.innerHTML = '运行中';
                badge.className = 'status-badge status-running';
            } else {
                badge.innerHTML = '已停止';
                badge.className = 'status-badge status-stopped';
            }

            if (res !== expectedState && maxRetries > 0) {
                setTimeout(function() { pollStatus(expectedState, maxRetries - 1); }, 1000);
            }
        });
    }

    function updateFwStatus() {
        XHR.get('<%=url("admin/services/vhusbd/action")%>?action=get_fw', null, function(x) {
            var res = x.responseText;
            if (res.indexOf('FW:') === 0) {
                var parts = res.replace('FW:', '').split(',');
                var wanOn = parts[0] === '1';
                var ipv6On = parts[1] === '1';
                
                var wanEl = document.getElementById('wan-status');
                var ipv6El = document.getElementById('ipv6-status');
                
                wanEl.innerHTML = wanOn ? '已开启' : '已关闭';
                wanEl.className = wanOn ? 'fw-on' : 'fw-off';
                
                ipv6El.innerHTML = ipv6On ? '已开启' : '已关闭';
                ipv6El.className = ipv6On ? 'fw-on' : 'fw-off';
            }
        });
    }

    function toggleFw(type) {
        var msgDiv = document.getElementById('action-msg');
        var currentOn = (type === 'wan') ? 
            (document.getElementById('wan-status').innerHTML === '已开启') : 
            (document.getElementById('ipv6-status').innerHTML === '已开启');
        
        var newVal = currentOn ? '0' : '1';
        msgDiv.innerHTML = '正在处理...';
        msgDiv.style.color = 'blue';

        XHR.get('<%=url("admin/services/vhusbd/action")%>?action=set_fw&type=' + type + '&val=' + newVal, null, function(x) {
            var res = x.responseText;
            if (res.indexOf('SUCCESS') === 0) {
                msgDiv.innerHTML = res.replace('SUCCESS:', '');
                msgDiv.style.color = 'green';
                updateFwStatus();
            } else {
                msgDiv.innerHTML = res.replace('ERROR:', '');
                msgDiv.style.color = 'red';
            }
        });
    }

    function doAction(act) {
        var msgDiv = document.getElementById('action-msg');
        msgDiv.innerHTML = '正在执行...';
        msgDiv.style.color = 'blue';

        var expect = (act === 'stop') ? 'STOPPED' : 'RUNNING';

        XHR.get('<%=url("admin/services/vhusbd/action")%>?action=' + act, null, function(x) {
            var res = x.responseText;
            if (res.indexOf('SUCCESS') === 0) {
                msgDiv.innerHTML = res.replace('SUCCESS:', '');
                msgDiv.style.color = 'green';
                pollStatus(expect, 5);
            } else {
                msgDiv.innerHTML = res.replace('ERROR:', '');
                msgDiv.style.color = 'red';
            }
        });
    }

    function doRegister() {
        var msgDiv = document.getElementById('action-msg');
        msgDiv.innerHTML = '正在注册，请稍候...';
        msgDiv.style.color = 'blue';
        XHR.get('<%=url("admin/services/vhusbd/action")%>?action=register', null, function(x) {
            var res = x.responseText;
            if (res.indexOf('SUCCESS') === 0) {
                msgDiv.innerHTML = '✅ ' + res.replace('SUCCESS:', '');
                msgDiv.style.color = 'green';
            } else {
                msgDiv.innerHTML = '❌ ' + res.replace('ERROR:', '');
                msgDiv.style.color = 'red';
            }
        });
    }

    function showLogs() {
        var logArea = document.getElementById('log-area');
        if (logArea.style.display === 'block') {
            logArea.style.display = 'none';
            return;
        }
        logArea.style.display = 'block';
        logArea.innerHTML = '加载中...';
        XHR.get('<%=url("admin/services/vhusbd/action")%>?action=logs', null, function(x) {
            logArea.innerHTML = x.responseText;
        });
    }

    window.onload = function() {
        pollStatus('RUNNING', 1);
        updateFwStatus();
    };
</script>

<%+footer%>
