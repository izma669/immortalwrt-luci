/* ============================================================================
   音乐中心 · Music Center
   轮询 /cgi-bin/luci/music/status，渲染三套音乐服务并发送控制指令。
   无外部依赖；所有服务端文本都用 textContent 写入，避免 XSS。
   ========================================================================== */
(function () {
    'use strict';

    var API = '/cgi-bin/luci/music';
    var $ = function (id) { return document.getElementById(id); };
    var $$ = function (sel, root) {
        return Array.prototype.slice.call((root || document).querySelectorAll(sel));
    };

    var el = {
        connDot: $('conn-dot'),
        connText: $('conn-text'),
        hostname: $('hostname'),
        clock: $('clock'),
        refreshBtn: $('refresh-btn'),
        themeToggle: $('theme-toggle'),
        themeIcon: document.querySelector('#theme-icon use'),
        fullscreenBtn: $('fullscreen-btn'),
        errorBanner: $('error-banner'),
        errorText: $('error-text'),
        retryBtn: $('retry-btn'),

        masterSlider: $('master-slider'),
        masterValue: $('master-value'),
        masterDevice: $('master-device'),
        masterMute: $('master-mute'),
        masterMuteIcon: $('master-mute-icon'),

        owntoneCard: $('owntone-card'),
        owntoneName: $('owntone-name'),
        owntoneBg: $('owntone-bg'),
        owntoneState: $('owntone-state'),
        owntoneService: $('owntone-service'),
        owntoneStart: $('owntone-start'),
        owntoneWeb: $('owntone-web'),
        owntoneCover: $('owntone-cover'),
        owntoneVinyl: $('owntone-vinyl'),
        owntoneLed: $('owntone-led'),
        owntoneLedFrame: $('owntone-led-frame'),
        owntoneLedPath: $('owntone-led-path'),
        owntoneLedNotch: $('owntone-led-notch'),
        owntoneTimeFlow: $('owntone-time-flow'),
        owntonePlayIndicator: $('owntone-play-indicator'),
        owntoneTitleMarquee: $('owntone-title-marquee'),
        owntoneMetaMarquee: $('owntone-meta-marquee'),
        owntonePos: $('owntone-pos'),
        owntoneDur: $('owntone-dur'),
        owntoneAudioInfo: $('owntone-audio-info'),
        owntoneLower: $('owntone-lower'),
        owntoneFormat: $('owntone-format'),
        owntoneBitrate: $('owntone-bitrate'),
        owntoneSamplerate: $('owntone-samplerate'),
        owntoneProgress: $('owntone-progress'),
        owntonePrev: $('owntone-prev'),
        owntonePlay: $('owntone-play'),
        owntonePlayIcon: document.querySelector('#owntone-play-icon use'),
        owntoneNext: $('owntone-next'),
        owntoneShuffle: $('owntone-shuffle'),
        owntoneRepeat: $('owntone-repeat'),
        owntoneVolume: $('owntone-volume'),
        owntoneKnob: $('owntone-knob'),
        owntoneMute: $('owntone-mute'),
        owntoneVolValue: $('owntone-vol-value'),
        owntoneHint: $('owntone-hint'),

        gmrCard: $('gmr-card'),
        gmrState: $('gmr-state'),
        gmrCover: $('gmr-cover'),
        gmrVinyl: $('gmr-vinyl'),
        gmrTitle: $('gmr-title'),
        gmrArtist: $('gmr-artist'),
        gmrAlbum: $('gmr-album'),
        gmrSoundcard: $('gmr-soundcard'),
        gmrBroadcast: $('gmr-broadcast'),
        gmrUrl: $('gmr-url'),
        gmrCopyUrl: $('gmr-copy-url'),
        gmrOpenUrl: $('gmr-open-url'),
        gmrDownload: $('gmr-download'),
        gmrDownloadStatus: $('gmr-download-status'),
        gmrPos: $('gmr-pos'),
        gmrDur: $('gmr-dur'),
        gmrProgress: $('gmr-progress'),
        gmrPrev: $('gmr-prev'),
        gmrPlay: $('gmr-play'),
        gmrPlayIcon: document.querySelector('#gmr-play-icon use'),
        gmrNext: $('gmr-next'),
        gmrStop: $('gmr-stop'),
        gmrVolume: $('gmr-volume'),
        gmrVolValue: $('gmr-vol-value'),
        gmrStart: $('gmr-start'),

        airCard: $('air-card'),
        airState: $('air-state'),
        airCover: $('air-cover'),
        airVinyl: $('air-vinyl'),
        airTitle: $('air-title'),
        airArtist: $('air-artist'),
        airAlbum: $('air-album'),
        airSoundcard: $('air-soundcard'),
        airFormat: $('air-format'),
        airBroadcast: $('air-broadcast'),
        airVolFill: $('air-vol-fill'),
        airLyric: $('air-lyric'),
        airClient: $('air-client'),
        airVolValue: $('air-vol-value'),
        airStart: $('air-start'),
        airStart: $('air-start'),

        servicesCount: $('services-count'),
        svcOwntoneState: $('svc-owntone-state'),
        svcGmrState: $('svc-gmr-state'),
        svcAirState: $('svc-air-state'),
        restartAll: $('restart-all'),
        footerServices: $('footer-services'),

        toast: $('toast'),
        toastText: $('toast-text')
    };

    var ledResizeObserver = null;

    var state = {
        data: null,
        timer: null,
        inFlight: false,
        failures: 0,
        overrides: {},
        localMute: false,
        localMuteVolume: 0,
        seeking: {},
        progress: {},
        lyric: { key: '', lines: [] },
        led: {
            title: { text: '', empty: false },
            meta: { text: '', empty: false }
        },
        serviceBusy: {},
        bgUrl: '',
        failedCovers: {},
        downloadTimer: null,
        downloading: false,
        downloadName: '',
        lastAutoDownload: '',
        toastTimer: null,
        owntoneApi: { url: '', busy: false, failures: 0, pausedUntil: 0 },
        directOwntone: false,
        modes: { shuffle: false, repeat: 'off' }
    };

    var PROGRESS = {
        owntone: { input: 'owntone-progress', pos: 'owntone-pos', dur: 'owntone-dur' },
        gmr: { input: 'gmr-progress', pos: 'gmr-pos', dur: 'gmr-dur' }
    };

    var SERVICE_LABEL = {
        owntone: 'OwnTone',
        gmediarender: 'GMediaRender',
        shairport: 'AirPlay 2 Receiver',
        all: '全部服务'
    };

    var AIR_LYRIC_SPANS = $$('#air-lyric span');

    /* -----------------------------------------------------------------------
       基础工具
       -------------------------------------------------------------------- */
    function pad(n) { return n < 10 ? '0' + n : String(n); }

    function clamp(n, min, max) {
        n = Number(n);
        if (!isFinite(n)) n = min;
        return Math.min(max, Math.max(min, n));
    }

    function fmtTime(sec) {
        sec = Number(sec);
        if (!isFinite(sec) || sec < 0) sec = 0;
        sec = Math.floor(sec);
        var h = Math.floor(sec / 3600);
        var m = Math.floor((sec % 3600) / 60);
        var s = sec % 60;
        return h > 0 ? h + ':' + pad(m) + ':' + pad(s) : m + ':' + pad(s);
    }

    function setText(node, text) {
        if (!node) return;
        text = (text === null || text === undefined) ? '' : String(text);
        if (node.textContent !== text) node.textContent = text;
    }

    function setRangeFill(input, value, max) {
        if (!input) return;
        var pct = max > 0 ? clamp(value / max * 100, 0, 100) : 0;
        input.style.setProperty('--val', pct.toFixed(2) + '%');
        var bar = input.parentElement;
        if (bar && bar.classList.contains('led-bar')) {
            bar.style.setProperty('--val', pct.toFixed(2) + '%');
        }
    }

    function setIcon(use, id) {
        if (!use || !id) return;
        if (use.getAttribute('href') === '#' + id) return;
        use.setAttribute('href', '#' + id);
        try {
            use.setAttributeNS('http://www.w3.org/1999/xlink', 'xlink:href', '#' + id);
        } catch (e) { /* 老浏览器忽略 */ }
    }

    function safeImageUrl(url) {
        if (!url) return '';
        url = String(url);
        if (url.charAt(0) === '/') return url;
        if (url.indexOf('data:image/') === 0) return url;
        try {
            var u = new URL(url, window.location.href);
            if (u.protocol === 'http:' || u.protocol === 'https:') return u.href;
        } catch (e) { /* ignore */ }
        return '';
    }

    function isFresh(target) {
        var o = state.overrides[target];
        return !!(o && (performance.now() - o.at) < 2600);
    }

    function toast(msg, isError) {
        setText(el.toastText, msg);
        el.toast.classList.toggle('is-error', !!isError);
        el.toast.classList.add('is-show');
        clearTimeout(state.toastTimer);
        state.toastTimer = setTimeout(function () {
            el.toast.classList.remove('is-show');
        }, 3200);
    }

    /* -----------------------------------------------------------------------
       网络
       -------------------------------------------------------------------- */
    function request(path, options) {
        var opts = Object.assign({ cache: 'no-store', credentials: 'same-origin' }, options || {});
        return fetch(path, opts).then(function (res) {
            return res.text().then(function (text) {
                var data = null;
                try { data = text ? JSON.parse(text) : null; } catch (e) { data = null; }
                if (!res.ok) {
                    var msg = data && data.error ? data.error : ('HTTP ' + res.status);
                    throw new Error(msg);
                }
                if (!data) {
                    throw new Error('后端返回了非 JSON 数据（可能被登录页拦截）');
                }
                if (data.ok === false) {
                    throw new Error(data.error || '操作失败');
                }
                return data;
            });
        });
    }

    function post(path, params) {
        return request(API + path, {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' },
            body: new URLSearchParams(params).toString()
        });
    }

    function poll(manual) {
        if (state.inFlight) return;
        state.inFlight = true;
        if (manual) el.refreshBtn.classList.add('is-busy');

        request(API + '/status?_=' + Date.now())
            .then(function (data) {
                state.failures = 0;
                state.data = data;
                el.errorBanner.hidden = true;
                setConnection(true);
                try {
                    render(data);
                } catch (e) {
                    if (window.console && console.error) console.error('音乐中心渲染失败', e);
                }
            })
            .catch(function (err) {
                state.failures++;
                setConnection(false);
                if (state.failures >= 2) {
                    setText(el.errorText,
                        '无法连接音乐中心服务：' + (err && err.message ? err.message : '网络错误')
                        + '。页面会自动重试。');
                    el.errorBanner.hidden = false;
                }
            })
            .then(function () {
                state.inFlight = false;
                el.refreshBtn.classList.remove('is-busy');
                schedule();
            });
    }

    function schedule() {
        clearTimeout(state.timer);
        if (document.hidden) return;
        var d = state.data;
        var playing = !!(d && (
            (d.owntone && d.owntone.playing) ||
            (d.gmediarender && d.gmediarender.playing) ||
            (d.shairport && d.shairport.playing)
        ));
        state.timer = setTimeout(function () { poll(false); }, playing ? 2200 : 4500);
    }

    function pollLater(delays) {
        (delays || [600]).forEach(function (ms) {
            setTimeout(function () {
                if (!document.hidden) poll(false);
            }, ms);
        });
    }

    function setConnection(ok) {
        el.connDot.classList.toggle('is-on', ok);
        el.connDot.classList.toggle('is-off', !ok);
        setText(el.connText, ok ? '已连接' : '连接中断');
    }

    /* -----------------------------------------------------------------------
       封面 / 黑胶 / 跑马灯
       -------------------------------------------------------------------- */
    function setCover(img, vinyl, url) {
        if (!img || !vinyl) return;
        var safe = safeImageUrl(url);

        if (!safe) {
            img.onload = null;
            img.onerror = null;
            img.dataset.url = '';
            img.removeAttribute('src');
            vinyl.classList.remove('has-art');
            return;
        }

        // 同一个坏地址 30 秒内不要每 2 秒重试一次
        var failedAt = state.failedCovers[safe];
        if (failedAt && (Date.now() - failedAt) < 30000) {
            if (img.dataset.url !== '') {
                img.onload = null;
                img.onerror = null;
                img.dataset.url = '';
                img.removeAttribute('src');
                vinyl.classList.remove('has-art');
            }
            return;
        }

        if (img.dataset.url === safe) {
            if (img.complete && img.naturalWidth > 0) vinyl.classList.add('has-art');
            return;
        }

        img.dataset.url = safe;
        // 不要先移除 has-art：新封面加载期间继续显示旧图，避免每轮询闪一下底图
        img.onload = function () {
            if (img.dataset.url === safe && img.naturalWidth > 0) {
                delete state.failedCovers[safe];
                vinyl.classList.add('has-art');
            }
        };
        img.onerror = function () {
            if (img.dataset.url !== safe) return;
            state.failedCovers[safe] = Date.now();
            img.dataset.url = '';
            img.removeAttribute('src');
            vinyl.classList.remove('has-art');
        };
        img.src = safe;
    }

    function setVinylPlaying(vinyl, playing) {
        if (!vinyl) return;
        vinyl.classList.toggle('is-playing', !!playing);
    }

    function setPlayerBg(url) {
        var safe = safeImageUrl(url);
        if (safe === state.bgUrl) return;
        state.bgUrl = safe;
        if (safe) {
            el.owntoneBg.style.backgroundImage = 'url(' + JSON.stringify(safe) + ')';
            el.owntoneBg.classList.remove('is-empty');
        } else {
            el.owntoneBg.style.backgroundImage = '';
            el.owntoneBg.classList.add('is-empty');
        }
    }

    /* -----------------------------------------------------------------------
       LED 电子屏跑马灯：歌名向左，演唱者 / 专辑向右，两行各自独立
       -------------------------------------------------------------------- */
    var LED_LINES = {
        title: { viewport: 'owntoneTitleMarquee', speed: 46 },
        meta: { viewport: 'owntoneMetaMarquee', speed: 52 }
    };

    function renderLedLine(key) {
        var line = LED_LINES[key];
        var viewport = line && el[line.viewport];
        if (!viewport) return;

        var slot = state.led[key];
        var spans = $$('.led-text', viewport);
        var track = viewport.querySelector('.led-track');
        spans.forEach(function (s) { s.textContent = slot.text; });
        viewport.classList.toggle('is-empty', slot.empty);
        viewport.classList.remove('is-scrolling');
        if (!track) return;

        requestAnimationFrame(function () {
            var w = spans[0] ? spans[0].getBoundingClientRect().width : 0;
            if (slot.empty || !slot.text || w <= 0) return;

            // 文字比屏幕窄时，把间距撑到整屏宽再复制，
            // 这样同一时刻屏幕上只出现一份文字，不会并排重复。
            var vw = viewport.clientWidth;
            var gap = Math.max(72, vw - w + 20);
            var distance = w + gap;

            viewport.style.setProperty('--gap', Math.ceil(gap) + 'px');
            viewport.style.setProperty('--distance', '-' + Math.ceil(distance) + 'px');
            viewport.style.setProperty('--duration',
                (distance / line.speed).toFixed(1) + 's');
            viewport.classList.add('is-scrolling');
        });
    }

    function setLedLine(key, text, empty) {
        var slot = state.led[key];
        if (!slot) return;
        text = text || '';
        empty = !!empty;
        if (slot.text === text && slot.empty === empty) return;
        slot.text = text;
        slot.empty = empty;
        renderLedLine(key);
    }

    function refreshMarquee() {
        Object.keys(state.led).forEach(function (key) {
            if (state.led[key].text) renderLedLine(key);
        });
    }

    /* -----------------------------------------------------------------------
       状态标签
       -------------------------------------------------------------------- */
    function setChip(node, base, text, stateClass) {
        if (!node) return;
        node.className = 'chip ' + base + (stateClass ? ' ' + stateClass : '');
        var span = node.querySelector('span');
        if (span) span.textContent = text;
    }

    /* -----------------------------------------------------------------------
       物理声卡
       -------------------------------------------------------------------- */
    function renderPhysical(p) {
        p = p || {};
        var available = !!p.available;
        var vol = available ? clamp(Math.round(Number(p.volume) || 0), 0, 100) : 0;

        if (available) {
            var name = p.name || '声卡';
            setText(el.masterDevice, name + ' · hw:' + (p.card || '0') + ' · ' + (p.control || 'Master'));
        } else {
            setText(el.masterDevice, '未找到可用的声卡混音控制');
        }

        if (!isFresh('physical') && document.activeElement !== el.masterSlider) {
            el.masterSlider.value = vol;
            setText(el.masterValue, available ? vol + '%' : '--%');
            setRangeFill(el.masterSlider, vol, 100);
        }

        el.masterSlider.disabled = !available;
        el.masterMute.disabled = !available;

        var muted = !!p.muted;
        el.masterMute.classList.toggle('is-muted', muted);
        setIcon(el.masterMuteIcon, muted ? 'i-mute' : 'i-volume');
        el.masterMute.title = muted ? '取消静音' : '静音';
    }

    /* -----------------------------------------------------------------------
       OwnTone
       -------------------------------------------------------------------- */
    function owntoneWebUrl(port) {
        var host = window.location.hostname || '127.0.0.1';
        if (host.indexOf(':') !== -1 && host.charAt(0) !== '[') host = '[' + host + ']';
        return 'http://' + host + ':' + (Number(port) || 3689) + '/';
    }

    function renderOwntone(o) {
        o = o || {};
        setText(el.owntoneName, o.name || '');
        var installed = !!o.installed;
        var running = !!o.running;
        var playing = !!o.playing;
        var paused = o.state === 'pause';

        el.owntoneCard.classList.toggle('is-offline', !running);
        el.owntoneStart.hidden = !(installed && !running);
        el.owntoneWeb.hidden = !installed;
        if (installed) el.owntoneWeb.href = owntoneWebUrl(o.port);

        // OwnTone 自带的 API 允许跨域，直接用它取精确进度；
        // 这样即使 LuCI 的 status 接口慢或旧 Lua 返回 0，时间也不会漂。
        var apiUrl = (installed && running)
            ? owntoneWebUrl(o.port).replace(/\/+$/, '') + '/api/player'
            : '';
        if (apiUrl !== state.owntoneApi.url) {
            state.owntoneApi.url = apiUrl;
            state.owntoneApi.failures = 0;
            state.owntoneApi.pausedUntil = 0;
        }
        if (!apiUrl) state.directOwntone = false;

        var chipText, chipState;
        if (!installed) { chipText = '未安装'; chipState = 'is-off'; }
        else if (!running) { chipText = '未运行'; chipState = 'is-off'; }
        else if (playing) { chipText = '播放中'; chipState = ''; }
        else if (paused) { chipText = '暂停中'; chipState = 'is-paused'; }
        else if (o.state === 'stop') { chipText = '已停止'; chipState = 'is-off'; }
        else { chipText = '缓冲中'; chipState = 'is-idle'; }
        setChip(el.owntoneState, 'chip--owntone', chipText, chipState);
        setText(el.owntoneService, !installed
            ? '未安装'
            : (running ? '服务运行中' : '服务未运行'));
        el.owntoneService.classList.toggle('is-off', !running);

        var title = o.title || '';
        var artist = o.artist || '';
        var album = o.album || '';
        var stateLabel;
        if (!installed) stateLabel = '未安装';
        else if (!running) stateLabel = '未运行';
        else if (playing) stateLabel = '播放中';
        else if (paused) stateLabel = '暂停中';
        else if (o.state === 'stop') stateLabel = '已停止';
        else stateLabel = '正在缓冲';
        var indicatorState = (!installed || !running) ? 'off' : (playing ? 'playing' : (paused ? 'paused' : 'idle'));
        el.owntonePlayIndicator.className = 'led-play is-' + indicatorState;
        el.owntonePlayIndicator.title = stateLabel;
        el.owntonePlayIndicator.setAttribute('aria-label', stateLabel);
        el.owntoneLed.classList.toggle('is-playing', playing);

        var empty = !title;
        // 第一行“歌名”向左滚；第二行“演唱者 + 专辑”向右滚，两行互不影响
        var titleLine = title
            ? ('歌名：' + title)
            : ('歌名：' + (!installed ? '未安装 OwnTone' : (!running ? 'OwnTone 未运行' : '暂无播放')));
        var metaLine = title
            ? ('演唱者：' + (artist || '未知艺术家') + '　专辑：' + (album || '未知专辑'))
            : '演唱者：等待音乐　专辑：OwnTone 音乐库';
        setLedLine('title', titleLine, empty);
        setLedLine('meta', metaLine, empty);

        var fmt = String(o.format || '').toUpperCase();
        var br = Number(o.bitrate) || 0;
        var sr = Number(o.samplerate) || 0;
        var hasAudioInfo = !!(fmt || br || sr);
        if (el.owntoneAudioInfo) el.owntoneAudioInfo.hidden = !hasAudioInfo;
        setText(el.owntoneFormat, fmt || '未知');
        setText(el.owntoneBitrate, br ? br + 'K/s' : '--');
        setText(el.owntoneSamplerate, sr ? (Math.round(sr / 100) / 10) + 'kHz' : '--');

        setCover(el.owntoneCover, el.owntoneVinyl, o.art);
        setVinylPlaying(el.owntoneVinyl, playing);
        setPlayerBg(o.art);

        if (!state.directOwntone) updateProgressSource('owntone', o, running);
        setIcon(el.owntonePlayIcon, playing ? 'i-pause' : 'i-play');
        el.owntonePlay.classList.toggle('is-playing', playing);
        el.owntonePlay.classList.toggle('is-paused', !playing);

        el.owntonePrev.disabled = !running;
        el.owntonePlay.disabled = !running;
        el.owntoneNext.disabled = !running;
        el.owntoneShuffle.disabled = !running;
        el.owntoneRepeat.disabled = !running;
        if (!state.directOwntone
            && (typeof o.shuffle === 'boolean' || typeof o.repeat === 'string')) {
            renderModes(o.shuffle, o.repeat);
        }
        el.owntoneProgress.disabled = !running || !(Number(o.duration) > 0);
        setVolumeUI(el.owntoneVolume, el.owntoneVolValue, 'owntone', o.volume, running);

        var vol = Number(o.volume) || 0;
        if (state.localMute && vol > 0) {
            state.localMute = false;
            try {
                localStorage.removeItem('music-center-owntone-mute');
                localStorage.removeItem('music-center-owntone-mute-volume');
            } catch (e) {}
        }
        var muted = !!(o.muted || state.localMute);
        if (el.owntoneMute) {
            el.owntoneMute.disabled = !running;
            setMuteUI(muted);
        }

        if (!installed) {
            setText(el.owntoneHint, '未安装 OwnTone 插件，无法播放本地音乐库。');
        } else if (!running) {
            setText(el.owntoneHint, '服务未运行，点右上角「启动 OwnTone」。');
        } else if (o.error) {
            setText(el.owntoneHint, 'OwnTone API 暂时无响应，稍后会自动重试。');
        } else {
            setText(el.owntoneHint, '也支持 iPhone Remote、MPD 客户端直接控制。');
        }
        if (typeof updateLedFrame === 'function') setTimeout(updateLedFrame, 0);
    }

    function renderModes(shuffle, repeat) {
        var sh = !!shuffle;
        var rep = String(repeat || 'off').toLowerCase();
        var repOn = rep === 'all' || rep === 'single';
        state.modes.shuffle = sh;
        state.modes.repeat = rep;

        el.owntoneShuffle.classList.toggle('is-on', sh);
        el.owntoneShuffle.setAttribute('aria-pressed', sh ? 'true' : 'false');
        el.owntoneShuffle.title = '随机播放：' + (sh ? '开' : '关');

        el.owntoneRepeat.classList.toggle('is-on', repOn);
        el.owntoneRepeat.classList.toggle('is-single', rep === 'single');
        el.owntoneRepeat.setAttribute('aria-pressed', repOn ? 'true' : 'false');
        el.owntoneRepeat.title = '循环播放：'
            + (rep === 'single' ? '单曲' : (repOn ? '全部' : '关'));
    }

    function ownToneApiBase() {
        return String(state.owntoneApi.url || '').replace(/\/api\/player\/?$/, '');
    }

    function putOwnToneMode(kind, query) {
        var base = ownToneApiBase();
        if (!base) return Promise.reject(new Error('OwnTone API 不可用'));
        return fetch(base + '/api/player/' + kind + '?' + query, {
            method: 'PUT',
            cache: 'no-store',
            credentials: 'omit'
        }).then(function (res) {
            if (!res.ok) throw new Error('HTTP ' + res.status);
            return true;
        });
    }

    function toggleShuffle() {
        var prev = state.modes.shuffle;
        var next = !prev;
        renderModes(next, state.modes.repeat);
        putOwnToneMode('shuffle', 'state=' + next).catch(function () {
            return control('owntone', 'shuffle', next ? 'true' : 'false').then(function (ok) {
                if (!ok) throw new Error('control failed');
            });
        }).catch(function () {
            renderModes(prev, state.modes.repeat);
        });
    }

    function toggleRepeat() {
        var prev = state.modes.repeat;
        var on = prev === 'all' || prev === 'single';
        var next = on ? 'off' : 'all';
        renderModes(state.modes.shuffle, next);
        putOwnToneMode('repeat', 'state=' + next).catch(function () {
            return control('owntone', 'repeat', next).then(function (ok) {
                if (!ok) throw new Error('control failed');
            });
        }).catch(function () {
            renderModes(state.modes.shuffle, prev);
        });
    }

    /* -----------------------------------------------------------------------
       GMediaRender
       -------------------------------------------------------------------- */
    function renderGmr(g) {
        g = g || {};
        var installed = !!g.installed;
        var running = !!g.running;
        var playing = !!g.playing;
        var st = String(g.state || '').toUpperCase();

        el.gmrCard.classList.toggle('is-offline', !running);
        el.gmrStart.hidden = !(installed && !running);

        var chipText, chipState;
        if (!installed) { chipText = '未安装'; chipState = 'is-off'; }
        else if (!running) { chipText = '未运行'; chipState = 'is-off'; }
        else if (g.error) { chipText = '无响应'; chipState = 'is-off'; }
        else if (st === 'PLAYING') { chipText = '投播被控中'; chipState = ''; }
        else if (st === 'PAUSED_PLAYBACK' || st === 'PAUSED') { chipText = '已暂停'; chipState = 'is-idle'; }
        else if (st === 'TRANSITIONING') { chipText = '缓冲中'; chipState = 'is-idle'; }
        else if (st === 'NO_MEDIA_PRESENT' || st === 'STOPPED') { chipText = '等待推送'; chipState = 'is-idle'; }
        else { chipText = '等待推送'; chipState = 'is-idle'; }
        setChip(el.gmrState, 'chip--dlna', chipText, chipState);

        var title = g.title || '';
        var artist = g.artist || '';
        var album = g.album || '';
        var hasTitle = !!title;

        setText(el.gmrTitle, hasTitle ? title : 'GmediaRender');
        setText(el.gmrArtist, hasTitle
            ? (artist || '未知艺术家')
            : (running ? '等待手机 / 电脑推送' : (installed ? '服务未运行' : '未安装插件')));
        setText(el.gmrAlbum, hasTitle ? (album || '') : (running ? '在 DLNA 客户端中选择这个设备' : ''));
        setText(el.gmrSoundcard, '输出声卡：' + (g.soundcard || '-'));
        setText(el.gmrBroadcast, g.broadcast || 'GMediaRender');

        var stream = (g.streamurl || '').trim();
        setText(el.gmrUrl, stream || '-');
        el.gmrUrl.title = stream || '';
        el.gmrCopyUrl.disabled = !stream;
        if (stream && /^https?:\/\//i.test(stream)) {
            el.gmrOpenUrl.href = stream;
            el.gmrOpenUrl.classList.remove('is-disabled');
        } else {
            el.gmrOpenUrl.href = '#';
            el.gmrOpenUrl.classList.add('is-disabled');
        }
        el.gmrDownload.disabled = !running || !stream || state.downloading;
        if (!state.downloading) setText(el.gmrDownload, '下载到设备');

        // 后端在“播放时自动下载”触发时只会在这一次状态里返回 true
        if (g.auto_download_triggered) {
            var autoKey = (g.auto_download_file || '') + '|' + (g.streamurl || '');
            if (state.lastAutoDownload !== autoKey) {
                state.lastAutoDownload = autoKey;
                state.downloadName = g.auto_download_file || g.title || '歌曲';
                state.downloading = true;
                setText(el.gmrDownload, '下载中...');
                el.gmrDownload.disabled = true;
                setDownloadStatus('检测到新歌曲，已开始自动下载'
                    + (g.auto_download_file ? '：' + g.auto_download_file : ''), 'info');
                toast('检测到新歌曲，已开始自动下载');
                pollDownloadLog();
            }
        }

        setCover(el.gmrCover, el.gmrVinyl, g.art);
        setVinylPlaying(el.gmrVinyl, playing);
        updateProgressSource('gmr', g, running);
        setIcon(el.gmrPlayIcon, playing ? 'i-pause' : 'i-play');

        el.gmrPrev.disabled = !running;
        el.gmrPlay.disabled = !running;
        el.gmrNext.disabled = !running;
        el.gmrStop.disabled = !running;
        el.gmrPrev.title = '上一曲';
        el.gmrNext.title = '下一曲';
        el.gmrProgress.disabled = !running || !(Number(g.duration) > 0);
        setVolumeUI(el.gmrVolume, el.gmrVolValue, 'gmediarender', g.volume, running);
    }

    /* -----------------------------------------------------------------------
       AirPlay
       -------------------------------------------------------------------- */
    function updateLyric(a) {
        a = a || {};
        var key = (a.title || '') + '|' + (a.artist || '');
        if (key !== state.lyric.key) {
            state.lyric.key = key;
            state.lyric.lines = [];
        }

        var raw = a.lyric ? String(a.lyric).trim() : '';
        if (raw) {
            raw.split(/\r?\n/).forEach(function (line) {
                line = line.trim();
                if (!line) return;
                if (state.lyric.lines[state.lyric.lines.length - 1] === line) return;
                state.lyric.lines.push(line);
                if (state.lyric.lines.length > 3) state.lyric.lines.shift();
            });
        }

        var lines = state.lyric.lines.slice(-3);
        var pad = 3 - lines.length;
        for (var i = 0; i < AIR_LYRIC_SPANS.length; i++) {
            var text = i < pad ? '' : lines[i - pad];
            var span = AIR_LYRIC_SPANS[i];
            span.textContent = text || '';
            span.classList.toggle('is-active', i === 2 && !!text);
        }
        if (!lines.length && AIR_LYRIC_SPANS.length) {
            var last = AIR_LYRIC_SPANS[AIR_LYRIC_SPANS.length - 1];
            last.textContent = a.playing ? '正在播放…' : '歌词会在这里滚动显示';
            last.classList.remove('is-active');
        }
    }

    function renderAir(a) {
        a = a || {};
        var installed = !!a.installed;
        var running = !!a.running;
        var playing = !!a.playing;

        el.airCard.classList.toggle('is-offline', !running);
        el.airStart.hidden = !(installed && !running);

        var chipText, chipState;
        if (!installed) { chipText = '未安装'; chipState = 'is-off'; }
        else if (!running) { chipText = '未运行'; chipState = 'is-off'; }
        else if (playing) { chipText = '数据接收中'; chipState = ''; }
        else { chipText = '等待推送'; chipState = 'is-idle'; }
        setChip(el.airState, 'chip--air', chipText, chipState);

        var title = a.title || '';
        var artist = a.artist || '';
        var album = a.album || '';
        var hasTitle = !!title;

        setText(el.airTitle, hasTitle ? title : 'Apple AirPlay 2');
        setText(el.airArtist, hasTitle
            ? (artist || '未知艺术家')
            : (running ? '等待 iPhone / iPad 推送' : (installed ? '服务未运行' : '未安装插件')));
        setText(el.airAlbum, hasTitle ? (album || '') : (running ? '从控制中心选择这个设备' : ''));
        setText(el.airSoundcard, '输出声卡：' + (a.soundcard || '-'));
        setText(el.airFormat, '音频格式：ALAC 44.1kHz/16bit/立体声');
        setText(el.airBroadcast, a.broadcast || 'AirPlay 2');
        if (el.airVolFill) {
            el.airVolFill.style.width = clamp(Math.round(Number(a.volume) || 0), 0, 100) + '%';
        }
        setCover(el.airCover, el.airVinyl, a.cover);
        setVinylPlaying(el.airVinyl, playing);
        updateLyric(a);

        var clientIp = String(a.client_ip || '');
        if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(clientIp)) clientIp = '';
        var clientLabel = a.client || clientIp;
        if (!clientLabel) {
            clientLabel = playing ? '已连接' : (running ? '等待连接' : '未连接');
        }
        setText(el.airClient, clientLabel);
        setText(el.airVolValue, running ? (clamp(Math.round(Number(a.volume) || 0), 0, 100) + '%') : '--%');
    }

    /* -----------------------------------------------------------------------
       进度
       -------------------------------------------------------------------- */
    function updateProgressSource(key, data, running) {
        var now = performance.now();
        var dur = Math.max(0, Number(data && data.duration) || 0);
        var serverPos = Math.max(0, Number(data && data.position) || 0);
        if (dur > 0) serverPos = Math.min(serverPos, dur);

        var playing = !!(data && data.playing && running);
        var trackKey = String((data && data.title) || '') + '|' + String((data && data.artist) || '');
        var prev = state.progress[key];
        var sameTrack = !!(prev && prev.trackKey === trackKey
            && Math.abs((prev.duration || 0) - (running ? dur : 0)) < 0.75);
        var localPos = prev ? prev.base + (prev.playing ? (now - prev.at) / 1000 : 0) : 0;

        var base = running ? serverPos : 0;
        // 有些 OwnTone 版本 / 老 Lua 返回的进度一直是 0，轮询会把时间反复拉回 0:00。
        // 只要还是同一首歌且本地时钟已经走远，就继续用本地时间，避免 0→1→2 循环。
        if (sameTrack && running && serverPos + 1.5 < localPos) {
            base = localPos;
        }
        if (dur > 0) base = Math.min(base, dur);

        state.progress[key] = {
            base: base,
            at: now,
            duration: running ? dur : 0,
            playing: playing,
            trackKey: trackKey
        };
        renderProgress(key);
    }

    // 直接向 OwnTone 的 /api/player 要精确进度（局域网跨端口，OwnTone 已允许 CORS）
    function pollDirectProgress() {
        var api = state.owntoneApi;
        if (!api.url || api.busy || document.hidden) return;
        if (performance.now() < api.pausedUntil) return;

        api.busy = true;
        fetch(api.url, { cache: 'no-store', credentials: 'omit' }).then(function (res) {
            if (!res.ok) throw new Error('HTTP ' + res.status);
            return res.json();
        }).then(function (d) {
            api.busy = false;
            api.failures = 0;
            if (typeof d.shuffle === 'boolean') renderModes(d.shuffle, d.repeat);
            var dur = Math.max(0, Number(d && d.item_length_ms) || 0) / 1000;
            var pos = Math.max(0, Number(d && d.item_progress_ms) || 0) / 1000;
            if (!(dur > 0)) return;
            if (pos > dur) pos = dur;
            if (state.seeking.owntone) return;

            var prev = state.progress.owntone;
            state.progress.owntone = {
                base: pos,
                at: performance.now(),
                duration: dur,
                playing: (d.state === 'play'),
                trackKey: (prev && Math.abs((prev.duration || 0) - dur) < 0.75)
                    ? prev.trackKey : ('direct:' + dur)
            };
            state.directOwntone = true;
            renderProgress('owntone');
        }).catch(function () {
            api.busy = false;
            api.failures++;
            // 直连被防火墙/CORS/密码挡住时，退回 status 接口的进度，不再反复请求
            if (api.failures >= 3) {
                state.directOwntone = false;
                api.pausedUntil = performance.now() + 30000;
            }
        });
    }

    function renderProgress(key) {
        var cfg = PROGRESS[key];
        var p = state.progress[key];
        var input = $(cfg.input);
        var posEl = $(cfg.pos);
        var durEl = $(cfg.dur);
        if (!p) {
            setText(posEl, '0:00');
            setText(durEl, '0:00');
            if (input) { input.value = 0; setRangeFill(input, 0, 1000); }
            return;
        }

        var pos = p.base;
        if (p.playing) pos += (performance.now() - p.at) / 1000;
        if (p.duration > 0) pos = Math.min(pos, p.duration);

        setText(durEl, fmtTime(p.duration));
        if (state.seeking[key]) return;

        setText(posEl, fmtTime(pos));
        var val = p.duration > 0 ? Math.round(pos / p.duration * 1000) : 0;
        if (input) {
            input.value = val;
            setRangeFill(input, val, 1000);
        }
    }

    function tickProgress() {
        if (document.hidden) return;
        renderProgress('owntone');
        renderProgress('gmr');
    }

    /* -----------------------------------------------------------------------
       音量 UI
       -------------------------------------------------------------------- */
    function setKnobVisual(value, disabled) {
        var knob = el.owntoneKnob;
        if (!knob) return;
        var v = clamp(Math.round(Number(value) || 0), 0, 100);
        knob.style.setProperty('--knob-angle', (-135 + v * 2.7) + 'deg');
        knob.style.setProperty('--knob-fill', (v * 2.7) + 'deg');
        knob.setAttribute('aria-valuenow', v);
        knob.classList.toggle('is-disabled', !!disabled);
    }

    function setMuteUI(muted) {
        if (!el.owntoneMute) return;
        el.owntoneMute.classList.toggle('is-muted', !!muted);
        el.owntoneMute.setAttribute('aria-pressed', muted ? 'true' : 'false');
        el.owntoneMute.title = muted ? '取消静音' : '静音';
        var wrap = el.owntoneMute.closest('.mute-wrap');
        if (wrap) wrap.classList.toggle('is-muted', !!muted);
    }

    function initMuteState() {
        try {
            state.localMute = localStorage.getItem('music-center-owntone-mute') === '1';
            state.localMuteVolume = Number(localStorage.getItem('music-center-owntone-mute-volume')) || 0;
        } catch (e) {
            state.localMute = false;
            state.localMuteVolume = 0;
        }
    }

    function setVolumeUI(input, output, target, value, enabled) {
        if (!input) return;
        if (!isFresh(target) && document.activeElement !== input) {
            state.overrides[target] = null;
            var v = clamp(Math.round(Number(value) || 0), 0, 100);
            input.value = v;
            setText(output, v + '%');
            setRangeFill(input, v, 100);
        }
        input.disabled = !enabled;
        if (input === el.owntoneVolume) setKnobVisual(input.value, !enabled);
    }

    function bindVolume(input, output, target) {
        if (!input) return;
        var timer = null;
        input.addEventListener('input', function () {
            var value = clamp(Math.round(Number(input.value) || 0), 0, 100);
            setText(output, value + '%');
            setRangeFill(input, value, 100);
            if (input === el.owntoneVolume) setKnobVisual(value, input.disabled);
            state.overrides[target] = { value: value, at: performance.now() };
            clearTimeout(timer);
            timer = setTimeout(function () {
                sendVolume(target, value);
            }, 300);
        });
    }

    function bindKnob(input, knob) {
        if (!input || !knob) return;
        var dragging = false;

        function valueFromEvent(ev) {
            var r = knob.getBoundingClientRect();
            var cx = r.left + r.width / 2;
            var cy = r.top + r.height / 2;
            var deg = Math.atan2(ev.clientX - cx, cy - ev.clientY) * 180 / Math.PI;
            if (deg < -135) deg = -135;
            if (deg > 135) deg = 135;
            return Math.round((deg + 135) / 270 * 100);
        }

        function apply(v) {
            v = clamp(Math.round(Number(v) || 0), 0, 100);
            if (String(input.value) !== String(v)) {
                input.value = v;
                input.dispatchEvent(new Event('input', { bubbles: true }));
            }
        }

        function down(ev) {
            if (input.disabled) return;
            dragging = true;
            try { knob.setPointerCapture(ev.pointerId); } catch (e) {}
            apply(valueFromEvent(ev));
            ev.preventDefault();
        }
        function move(ev) {
            if (!dragging) return;
            apply(valueFromEvent(ev));
            ev.preventDefault();
        }
        function up(ev) {
            dragging = false;
            try { knob.releasePointerCapture(ev.pointerId); } catch (e) {}
        }

        knob.addEventListener('pointerdown', down);
        knob.addEventListener('pointermove', move);
        knob.addEventListener('pointerup', up);
        knob.addEventListener('pointercancel', up);
        knob.addEventListener('wheel', function (ev) {
            if (input.disabled) return;
            ev.preventDefault();
            apply((Number(input.value) || 0) + (ev.deltaY < 0 ? 2 : -2));
        }, { passive: false });
        knob.addEventListener('keydown', function (ev) {
            if (input.disabled) return;
            var v = Number(input.value) || 0;
            var step = ev.shiftKey ? 10 : 2;
            var handled = true;
            if (ev.key === 'ArrowUp' || ev.key === 'ArrowRight') v += step;
            else if (ev.key === 'ArrowDown' || ev.key === 'ArrowLeft') v -= step;
            else if (ev.key === 'PageUp') v += 10;
            else if (ev.key === 'PageDown') v -= 10;
            else if (ev.key === 'Home') v = 0;
            else if (ev.key === 'End') v = 100;
            else handled = false;
            if (handled) {
                ev.preventDefault();
                apply(v);
            }
        });
    }

    function sendVolume(target, value) {
        return post('/volume', { target: target, value: value })
            .then(function () {
                state.overrides[target] = { value: value, at: performance.now() };
            })
            .catch(function (err) {
                state.overrides[target] = null;
                toast('音量设置失败：' + err.message, true);
                pollLater([300]);
            });
    }

    /* -----------------------------------------------------------------------
       GMediaRender 音频源 / 下载（照搬原 nowplaying.htm 的功能）
       -------------------------------------------------------------------- */
    function copyText(text, label) {
        text = String(text || '');
        if (!text || text === '-') {
            toast('没有可复制的内容', true);
            return;
        }
        function done() { toast('已复制' + (label || '')); }
        function fallback() {
            var ta = document.createElement('textarea');
            ta.value = text;
            ta.setAttribute('readonly', '');
            ta.style.position = 'fixed';
            ta.style.left = '-9999px';
            ta.style.top = '0';
            document.body.appendChild(ta);
            ta.focus();
            ta.select();
            var ok = false;
            try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
            document.body.removeChild(ta);
            if (ok) done();
            else toast('复制失败，请手动选择地址', true);
        }
        if (navigator.clipboard && window.isSecureContext) {
            navigator.clipboard.writeText(text).then(done).catch(fallback);
        } else {
            fallback();
        }
    }

    function setDownloadStatus(text, kind) {
        if (!el.gmrDownloadStatus) return;
        if (!text) {
            el.gmrDownloadStatus.hidden = true;
            return;
        }
        el.gmrDownloadStatus.hidden = false;
        el.gmrDownloadStatus.className = 'source-status is-' + (kind || 'info');
        el.gmrDownloadStatus.textContent = text;
    }

    function finishDownload() {
        state.downloading = false;
        clearTimeout(state.downloadTimer);
        state.downloadTimer = null;
        setText(el.gmrDownload, '下载到设备');
        if (el.gmrDownload) el.gmrDownload.disabled = false;
        pollLater([1000]);
    }

    function pollDownloadLog() {
        clearTimeout(state.downloadTimer);
        var attempts = 0;

        function tick() {
            attempts++;
            request(API + '/download_log?_=' + Date.now())
                .then(function (res) {
                    var log = (res.log || '').trim();
                    var lines = log.split(/\r?\n/).filter(Boolean);
                    var tail = lines.slice(-3).join('\n');
                    var done = /100%|saved|已保存|complete/i.test(log);
                    var failed = /failed|失败|错误|ERROR|No space|No such file|磁盘空间已满/i.test(log);

                    if (done) {
                        setDownloadStatus('下载完成' + (tail ? '\n' + tail : ''), 'ok');
                        toast((state.downloadName || '歌曲') + ' 下载完成');
                        finishDownload();
                    } else if (failed) {
                        setDownloadStatus('下载失败' + (tail ? '\n' + tail : ''), 'error');
                        toast((state.downloadName || '歌曲') + ' 下载失败', true);
                        finishDownload();
                    } else {
                        setDownloadStatus('正在下载...' + (tail ? '\n' + tail : ''), 'info');
                        if (attempts < 200) {
                            state.downloadTimer = setTimeout(tick, 1500);
                        } else {
                            finishDownload();
                        }
                    }
                })
                .catch(function () {
                    setDownloadStatus('读取下载日志失败，稍后重试…', 'error');
                    if (attempts < 200) {
                        state.downloadTimer = setTimeout(tick, 2000);
                    } else {
                        finishDownload();
                    }
                });
        }

        tick();
    }

    function downloadGmr() {
        var g = state.data && state.data.gmediarender;
        if (!g || !g.streamurl) {
            toast('当前没有可下载的音频源', true);
            return;
        }
        if (state.downloading) return;

        state.downloading = true;
        state.downloadName = g.title || '歌曲';
        el.gmrDownload.disabled = true;
        setText(el.gmrDownload, '请求中...');
        setDownloadStatus('正在发送下载请求...', 'info');

        post('/download', {
            url: g.streamurl,
            title: g.title || '',
            artist: g.artist || ''
        }).then(function (res) {
            setDownloadStatus('已开始下载：' + (res.file || ''), 'ok');
            setText(el.gmrDownload, '下载中...');
            pollDownloadLog();
        }).catch(function (err) {
            state.downloading = false;
            setText(el.gmrDownload, '下载到设备');
            el.gmrDownload.disabled = false;
            setDownloadStatus('下载失败：' + err.message, 'error');
        });
    }

    /* -----------------------------------------------------------------------
       服务列表
       -------------------------------------------------------------------- */
    function renderServices(data) {
        var rows = [
            { key: 'owntone', obj: data.owntone, state: el.svcOwntoneState },
            { key: 'gmediarender', obj: data.gmediarender, state: el.svcGmrState },
            { key: 'shairport', obj: data.shairport, state: el.svcAirState }
        ];
        var running = 0;
        var installed = 0;

        rows.forEach(function (r) {
            var o = r.obj || {};
            var row = document.querySelector('.service-row[data-service="' + r.key + '"]');
            if (row) {
                row.classList.toggle('is-on', !!o.running);
                row.classList.toggle('is-off', !o.running && !!o.installed);
                var cb = row.querySelector('input[data-auto]');
                if (cb) {
                    cb.checked = !!o.enabled;
                    cb.disabled = !o.installed;
                }
                $$('button[data-svc]', row).forEach(function (btn) {
                    var act = btn.dataset.act;
                    btn.disabled = !o.installed
                        || (act === 'start' && o.running)
                        || (act === 'stop' && !o.running);
                });
            }

            if (r.state) {
                var text, cls;
                if (!o.installed) { text = '未安装'; cls = ''; }
                else if (o.running) { text = '运行中'; cls = 'is-on'; }
                else { text = '已停止'; cls = 'is-off'; }
                setText(r.state, text);
                r.state.className = 'service-state' + (cls ? ' ' + cls : '');
            }

            if (o.running) running++;
            if (o.installed) installed++;
        });

        var total = Number(data.services && data.services.total) || 3;
        setText(el.servicesCount, running + ' / ' + total + ' 运行中');
        setText(el.footerServices, installed
            ? (running + ' 个服务运行中 · ' + installed + ' 个已安装')
            : '未检测到音乐插件');
    }

    /* -----------------------------------------------------------------------
       总渲染
       -------------------------------------------------------------------- */
    function updateDocumentTitle(now) {
        now = now || {};
        var playing = false;
        if (state.data) {
            playing = !!((state.data.owntone && state.data.owntone.playing) ||
                (state.data.gmediarender && state.data.gmediarender.playing) ||
                (state.data.shairport && state.data.shairport.playing));
        }
        var title = now.title || '';
        var artist = now.artist || '';
        var next = title
            ? ((playing ? '▶ ' : '') + title + (artist ? ' — ' + artist : '') + ' · 音乐中心')
            : '音乐中心';
        if (document.title !== next) document.title = next;
    }

    function render(data) {
        setText(el.hostname, data.hostname || '路由器');
        renderPhysical(data.physical || {});
        renderOwntone(data.owntone || {});
        renderGmr(data.gmediarender || {});
        renderAir(data.shairport || {});
        renderServices(data);
        updateDocumentTitle(data.now || {});
    }

    /* -----------------------------------------------------------------------
       控制动作
       -------------------------------------------------------------------- */
    function serviceAction(name, action, label) {
        if (state.serviceBusy[name]) return;
        state.serviceBusy[name] = true;
        setTimeout(function () { state.serviceBusy[name] = false; }, 1800);

        var verb = { start: '启动', stop: '停止', restart: '重启', enable: '开启自启', disable: '关闭自启' };
        post('/service', { name: name, action: action })
            .then(function () {
                toast('已发送' + (verb[action] || action) + '指令：' + (label || SERVICE_LABEL[name] || name));
                pollLater([900, 2600, 6000]);
            })
            .catch(function (err) {
                toast('操作失败：' + err.message, true);
            });
    }

    function control(service, action, value) {
        return post('/control', {
            service: service,
            action: action,
            value: value === undefined ? '' : String(value)
        }).then(function () {
            pollLater([350]);
            return true;
        }).catch(function (err) {
            toast('操作失败：' + err.message, true);
            return false;
        });
    }

    function bindSeek(input, service, stateKey, timeEl) {
        if (!input) return;
        input.addEventListener('input', function () {
            state.seeking[stateKey] = true;
            var p = state.progress[stateKey];
            if (p && p.duration > 0) {
                setText(timeEl, fmtTime(p.duration * (Number(input.value) || 0) / 1000));
                setRangeFill(input, Number(input.value) || 0, 1000);
            }
        });
        input.addEventListener('change', function () {
            var p = state.progress[stateKey];
            if (!p || !(p.duration > 0)) {
                state.seeking[stateKey] = false;
                return;
            }
            var sec = p.duration * (Number(input.value) || 0) / 1000;
            state.seeking[stateKey] = false;
            control(service, 'seek', sec.toFixed(1)).then(function (ok) {
                if (ok) {
                    p.base = sec;
                    p.at = performance.now();
                    renderProgress(stateKey);
                }
            });
        });
    }

    /* -----------------------------------------------------------------------
       主题 / 时钟 / 全屏
       -------------------------------------------------------------------- */
    function applyTheme(theme, persist) {
        document.documentElement.dataset.theme = theme;
        setIcon(el.themeIcon, theme === 'dark' ? 'i-sun' : 'i-moon');
        var meta = document.querySelector('meta[name="theme-color"]');
        if (meta) meta.setAttribute('content', theme === 'dark' ? '#070a10' : '#eef2f8');
        if (persist) {
            try { localStorage.setItem('music-center-theme', theme); } catch (e) { /* ignore */ }
        }
    }

    function initTheme() {
        var forced = null;
        try {
            forced = new URLSearchParams(window.location.search).get('theme');
        } catch (e) { /* ignore */ }

        var saved = null;
        try { saved = localStorage.getItem('music-center-theme'); } catch (e) { /* ignore */ }

        var systemLight = !!(window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches);
        var theme = (forced === 'light' || forced === 'dark') ? forced : (saved || (systemLight ? 'light' : 'dark'));
        applyTheme(theme, !forced);
    }

    function tickClock() {
        var d = new Date();
        setText(el.clock, pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds()));
    }

    /* -----------------------------------------------------------------------
       事件绑定
       -------------------------------------------------------------------- */
    function bindEvents() {
        el.refreshBtn.addEventListener('click', function () { poll(true); });
        el.retryBtn.addEventListener('click', function () { poll(true); });

        el.themeToggle.addEventListener('click', function () {
            var next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
            applyTheme(next, true);
        });

        if (!document.documentElement.requestFullscreen) {
            el.fullscreenBtn.hidden = true;
        } else {
            el.fullscreenBtn.addEventListener('click', function () {
                if (!document.fullscreenElement) {
                    document.documentElement.requestFullscreen().catch(function () { /* ignore */ });
                } else if (document.exitFullscreen) {
                    document.exitFullscreen();
                }
            });
        }

        el.masterMute.addEventListener('click', function () {
            var muted = !!(state.data && state.data.physical && state.data.physical.muted);
            post('/volume', { target: 'physical', action: muted ? 'unmute' : 'mute', value: 0 })
                .then(function () {
                    state.overrides.physical = null;
                    toast(muted ? '已取消静音' : '已静音');
                    pollLater([300]);
                })
                .catch(function (err) {
                    toast('静音设置失败：' + err.message, true);
                });
        });

        bindVolume(el.masterSlider, el.masterValue, 'physical');
        bindVolume(el.owntoneVolume, el.owntoneVolValue, 'owntone');
        bindKnob(el.owntoneVolume, el.owntoneKnob);
        if (el.owntoneVolume) setKnobVisual(el.owntoneVolume.value, true);
        if (el.owntoneMute) {
            el.owntoneMute.addEventListener('click', function () {
                var muted = el.owntoneMute.classList.contains('is-muted');
                el.owntoneMute.disabled = true;
                if (!muted) {
                    var current = Number(el.owntoneVolume ? el.owntoneVolume.value : 0) || 0;
                    var save = current > 0 ? current : 70;
                    state.localMute = true;
                    state.localMuteVolume = save;
                    try {
                        localStorage.setItem('music-center-owntone-mute', '1');
                        localStorage.setItem('music-center-owntone-mute-volume', String(save));
                    } catch (e) {}
                    setMuteUI(true);
                    post('/volume', { target: 'owntone', value: 0 })
                        .then(function () {
                            toast('已静音');
                            pollLater([300]);
                        })
                        .catch(function (err) {
                            toast('静音设置失败：' + err.message, true);
                        })
                        .then(function () { el.owntoneMute.disabled = false; });
                } else {
                    var restore = Number(state.localMuteVolume)
                        || Number(localStorage.getItem('music-center-owntone-mute-volume'))
                        || 70;
                    state.localMute = false;
                    try {
                        localStorage.removeItem('music-center-owntone-mute');
                        localStorage.removeItem('music-center-owntone-mute-volume');
                    } catch (e) {}
                    setMuteUI(false);
                    post('/volume', { target: 'owntone', value: restore })
                        .then(function () {
                            toast('已取消静音');
                            pollLater([300]);
                        })
                        .catch(function (err) {
                            toast('取消静音失败：' + err.message, true);
                        })
                        .then(function () { el.owntoneMute.disabled = false; });
                }
            });
        }
        bindVolume(el.gmrVolume, el.gmrVolValue, 'gmediarender');
        bindSeek(el.owntoneProgress, 'owntone', 'owntone', el.owntonePos);
        bindSeek(el.gmrProgress, 'gmediarender', 'gmr', el.gmrPos);

        el.owntoneStart.addEventListener('click', function () {
            serviceAction('owntone', 'start');
        });
        el.gmrStart.addEventListener('click', function () {
            serviceAction('gmediarender', 'start');
        });
        el.airStart.addEventListener('click', function () {
            serviceAction('shairport', 'start');
        });

        el.owntonePlay.addEventListener('click', function () {
            var playing = !!(state.data && state.data.owntone && state.data.owntone.playing);
            control('owntone', playing ? 'pause' : 'play');
        });
        el.owntonePrev.addEventListener('click', function () { control('owntone', 'previous'); });
        el.owntoneNext.addEventListener('click', function () { control('owntone', 'next'); });
        el.owntoneShuffle.addEventListener('click', toggleShuffle);
        el.owntoneRepeat.addEventListener('click', toggleRepeat);

        el.gmrPlay.addEventListener('click', function () {
            var playing = !!(state.data && state.data.gmediarender && state.data.gmediarender.playing);
            control('gmediarender', playing ? 'pause' : 'play');
        });
        el.gmrPrev.addEventListener('click', function () { control('gmediarender', 'previous'); });
        el.gmrNext.addEventListener('click', function () { control('gmediarender', 'next'); });
        el.gmrStop.addEventListener('click', function () { control('gmediarender', 'stop'); });

        el.gmrCopyUrl.addEventListener('click', function () {
            copyText(state.data && state.data.gmediarender && state.data.gmediarender.streamurl,
                '音频源地址');
        });
        el.gmrOpenUrl.addEventListener('click', function (e) {
            var g = state.data && state.data.gmediarender;
            if (!g || !g.streamurl) {
                e.preventDefault();
                toast('当前没有可打开的音频源', true);
            }
        });
        el.gmrDownload.addEventListener('click', downloadGmr);

        $$('.service-buttons button[data-svc]').forEach(function (btn) {
            btn.addEventListener('click', function () {
                serviceAction(btn.dataset.svc, btn.dataset.act);
            });
        });

        $$('input[data-auto]').forEach(function (cb) {
            cb.addEventListener('change', function () {
                var name = cb.dataset.auto;
                var action = cb.checked ? 'enable' : 'disable';
                cb.disabled = true;
                post('/service', { name: name, action: action })
                    .then(function () {
                        toast((cb.checked ? '已开启开机自启：' : '已关闭开机自启：')
                            + (SERVICE_LABEL[name] || name));
                        pollLater([600]);
                    })
                    .catch(function (err) {
                        cb.checked = !cb.checked;
                        toast('设置失败：' + err.message, true);
                    })
                    .then(function () { cb.disabled = false; });
            });
        });

        el.restartAll.addEventListener('click', function () {
            serviceAction('all', 'restart', '全部服务');
        });

        document.addEventListener('visibilitychange', function () {
            if (!document.hidden) poll(false);
        });

        var resizeTimer = null;
        window.addEventListener('resize', function () {
            clearTimeout(resizeTimer);
            resizeTimer = setTimeout(refreshMarquee, 160);
        });
    }

    // LED 外框用像素坐标重画：圆角在任何宽高比下都是正圆；
    // 切角左边/上边直接跟着时间框，避免和播放时间之间留大空隙。
    function updateLedFrame() {
        var screen = el.owntoneLed;
        var time = el.owntoneTimeFlow;
        var lower = el.owntoneLower || time;
        var svg = el.owntoneLedFrame;
        var path = el.owntoneLedPath;
        var notch = el.owntoneLedNotch;
        if (!screen || !time || !lower || !svg || !path || !notch) return;

        var sr = screen.getBoundingClientRect();
        var lr = lower.getBoundingClientRect();
        var vr = svg.getBoundingClientRect();
        var w = Math.round(vr.width * 100) / 100;
        var h = Math.round(vr.height * 100) / 100;
        if (w < 120 || h < 60) return;

        var gap = 8;
        var nx = Math.max(60, Math.min(w - 80, lr.right - vr.left + gap));
        var ny = Math.max(50, Math.min(h - 50, lr.top - vr.top - 1));
        var r = 18, trr = 22, nr = 14, br = 8;
        var d = 'M' + r + ' 0 H' + (w - r) + ' Q' + w + ' 0 ' + w + ' ' + r
            + ' V' + (ny - trr) + ' Q' + w + ' ' + ny + ' ' + (w - trr) + ' ' + ny
            + ' H' + (nx + nr) + ' Q' + nx + ' ' + ny + ' ' + nx + ' ' + (ny + nr)
            + ' V' + (h - br) + ' Q' + nx + ' ' + h + ' ' + (nx - br) + ' ' + h
            + ' H' + r + ' Q0 ' + h + ' 0 ' + (h - r) + ' V' + r + ' Q0 0 ' + r + ' 0 Z';
        svg.setAttribute('viewBox', '0 0 ' + w + ' ' + h);
        path.setAttribute('d', d);

        notch.style.left = (lr.right - sr.left + gap) + 'px';
        notch.style.top = (lr.top - sr.top - 1) + 'px';
        notch.style.width = 'auto';
        notch.style.height = 'auto';

        // 把音量旋钮所在的整块面板向上塞进 LED 屏右下角的切角空位
        var volumeRow = el.owntoneVolume ? el.owntoneVolume.closest('.volume-row') : null;
        if (volumeRow) {
            if (window.innerWidth <= 760) {
                volumeRow.style.marginTop = '0px';
            } else {
                var deck = volumeRow.closest('.control-deck');
                var deckGap = deck ? (parseFloat(window.getComputedStyle(deck).marginTop) || 0) : 0;
                var tuck = Math.max(0, Math.round(deckGap + (h - ny) - 3));
                volumeRow.style.marginTop = (-tuck) + 'px';
            }
        }
    }

    /* -----------------------------------------------------------------------
       启动
       -------------------------------------------------------------------- */
    function init() {
        initTheme();
        initMuteState();
        if (state.localMute) setMuteUI(true);
        tickClock();
        setInterval(tickClock, 1000);
        setInterval(tickProgress, 500);
        setInterval(pollDirectProgress, 1000);
        bindEvents();
        updateLedFrame();
        setTimeout(updateLedFrame, 80);
        window.addEventListener('resize', updateLedFrame);
        if (window.ResizeObserver) {
            ledResizeObserver = new ResizeObserver(updateLedFrame);
            if (el.owntoneLed) ledResizeObserver.observe(el.owntoneLed);
            if (el.owntoneTimeFlow) ledResizeObserver.observe(el.owntoneTimeFlow);
        }
        poll(false);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
