  const publishConfig = window.__Y2S_PUBLISH__ || {};
  let jobId = publishConfig.jobId || '';
  const sourceUrl = publishConfig.sourceUrl || '';
  const tgUserIdFromQuery = publishConfig.tgUserIdFromQuery || null;
  const trustedFromQuery = !!publishConfig.trustedFromQuery;
  const host = publishConfig.host || '';
    const gateWrapEl = document.getElementById('gateWrap');
    const gateTextEl = document.getElementById('gateText');
    const denyWrapEl = document.getElementById('denyWrap');
    const publishContentEl = document.getElementById('publishContent');
    const statusEl = document.getElementById('status');
    const previewEl = document.getElementById('preview');
    const noteEl = document.getElementById('note');
    const progressWrap = document.getElementById('progressWrap');
    const progressBar = document.getElementById('progressBar');
    const progressText = document.getElementById('progressText');
    let gateFailsafeTimer = null;
    let progressPct = 0;
    let startedAt = null;
    let startedAtSynced = false;
    function getStartedAtKey(jobId) {
      return 'y2s_startedAt_' + (jobId || '');
    }
    function loadStartedAt(jobId) {
      const key = getStartedAtKey(jobId);
      const val = localStorage.getItem(key);
      if (val && !isNaN(Number(val))) return Number(val);
      return null;
    }
    function saveStartedAt(jobId, value) {
      const key = getStartedAtKey(jobId);
      if (value && !isNaN(Number(value))) {
        localStorage.setItem(key, String(value));
      }
    }
    function clearStartedAt(jobId) {
      const key = getStartedAtKey(jobId);
      localStorage.removeItem(key);
    }
    // Инициализация startedAt из localStorage, если есть jobId
    if (jobId) {
      startedAt = loadStartedAt(jobId) || Date.now();
    } else {
      startedAt = Date.now();
    }
    let lastPartsSignature = null;

    try {
      if (window.Telegram && window.Telegram.WebApp && typeof window.Telegram.WebApp.ready === 'function') {
        window.Telegram.WebApp.ready();
        if (typeof window.Telegram.WebApp.expand === 'function') {
          window.Telegram.WebApp.expand();
        }
      }
    } catch (e) {}

    function armGateFailsafe(){
      if (gateFailsafeTimer) clearTimeout(gateFailsafeTimer);
      gateFailsafeTimer = setTimeout(() => {
        try {
          const gateVisible = gateWrapEl && window.getComputedStyle(gateWrapEl).display !== 'none';
          const denyVisible = denyWrapEl && window.getComputedStyle(denyWrapEl).display !== 'none';
          const contentVisible = publishContentEl && window.getComputedStyle(publishContentEl).display !== 'none';
          if (gateVisible && !denyVisible && !contentVisible) {
            showDenied('Не удалось инициализировать экран. Попробуйте открыть заново.');
          }
        } catch (e) {}
      }, 20000);
    }

    function clearGateFailsafe(){
      if (gateFailsafeTimer) {
        clearTimeout(gateFailsafeTimer);
        gateFailsafeTimer = null;
      }
    }

    function showGate(text){
      gateWrapEl.style.display = 'flex';
      gateTextEl.innerText = text || 'Загрузка';
      denyWrapEl.style.display = 'none';
      publishContentEl.style.display = 'none';
    }

    function showContent(){
      clearGateFailsafe();
      gateWrapEl.style.display = 'none';
      denyWrapEl.style.display = 'none';
      publishContentEl.style.display = 'block';
    }

    function showDenied(text){
      clearGateFailsafe();
      gateWrapEl.style.display = 'none';
      publishContentEl.style.display = 'none';
      denyWrapEl.style.display = 'flex';
      denyWrapEl.innerText = text || 'Публикация историй недоступна.';
    }

    function parseTelegramProfile(){
      try {
        if (!(window.Telegram && window.Telegram.WebApp && window.Telegram.WebApp.initDataUnsafe && window.Telegram.WebApp.initDataUnsafe.user)) {
          return {};
        }
        const user = window.Telegram.WebApp.initDataUnsafe.user || {};
        return {
          tg_user_id: user.id || null,
          username: user.username || null,
          first_name: user.first_name || null,
          last_name: user.last_name || null,
          language_code: user.language_code || null
        };
      } catch (e) {
        return {};
      }
    }

    function normalizeTgUserId(value){
      if (value === null || value === undefined) return null;
      const asString = String(value).trim();
      if (!asString) return null;
      const asNumber = Number(asString);
      if (!Number.isFinite(asNumber) || asNumber <= 0) return null;
      return String(Math.trunc(asNumber));
    }

    function startProcessing(tgProfile){
      // Новый jobId — сбросить startedAt
      if (jobId) clearStartedAt(jobId);
      try {
        if (!sourceUrl) {
          showDenied('Не найдена ссылка на YouTube.');
          return;
        }

        showGate('Запускаем обработку...');
        const payload = {
          url: sourceUrl,
          can_share: true,
          tg_user_id: normalizeTgUserId((tgProfile && tgProfile.tg_user_id) || tgUserIdFromQuery)
        };
        if (tgProfile && tgProfile.username) payload.username = tgProfile.username;
        if (tgProfile && tgProfile.first_name) payload.first_name = tgProfile.first_name;
        if (tgProfile && tgProfile.last_name) payload.last_name = tgProfile.last_name;
        if (tgProfile && tgProfile.language_code) payload.language_code = tgProfile.language_code;

        const fetchOptions = {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(payload)
        };

        let processTimeout = null;
        let processRequest = null;

        if (typeof AbortController === 'function') {
          const abortController = new AbortController();
          processTimeout = setTimeout(() => abortController.abort(), 15000);
          fetchOptions.signal = abortController.signal;
          processRequest = fetch('/process', fetchOptions);
        } else {
          processRequest = Promise.race([
            fetch('/process', fetchOptions),
            new Promise((_, reject) => {
              processTimeout = setTimeout(() => reject(new Error('timeout')), 15000);
            })
          ]);
        }

        processRequest
          .then(r=>r.json().then(data => ({ ok: r.ok, data })))
          .then(({ ok, data }) => {
            if (processTimeout) clearTimeout(processTimeout);
            if (!ok || !data || data.error) {
              showDenied('Не удалось запустить обработку.');
              return;
            }

            const nextJobId = data.job_id || data.id;
            if (!nextJobId) {
              showDenied('Сервер вернул неполный ответ.');
              return;
            }

            jobId = String(nextJobId);
            startedAt = Date.now();
            saveStartedAt(jobId, startedAt);
            showContent();
            check();
          })
          .catch((e) => {
            if (processTimeout) clearTimeout(processTimeout);
            console.error(e);
            showDenied('Ошибка сети при запуске обработки.');
          });
      } catch (e) {
        console.error(e);
        showDenied('Ошибка запуска обработки.');
      }
    }

    function waitForTelegramWebApp(timeoutMs){
      return new Promise((resolve) => {
        const start = Date.now();
        function tick(){
          try {
            if (window.Telegram && window.Telegram.WebApp) {
              resolve(true);
              return;
            }
            if (Date.now() - start >= timeoutMs) {
              resolve(false);
              return;
            }
          } catch (e) {
            // Ignore errors, continue polling
          }
          setTimeout(tick, 120);
        }
        tick();
      });
    }

    async function runPublishFlow(){
      const hasWebApp = await waitForTelegramWebApp(4500);
      if (!hasWebApp) {
        showDenied('Откройте эту страницу внутри Telegram.');
        return;
      }

      let canShare = !!(window.Telegram && window.Telegram.WebApp && typeof window.Telegram.WebApp.shareToStory === 'function');
      if (!canShare) {
        showGate('Загрузка');
        await new Promise(resolve => setTimeout(resolve, 2000));
        canShare = !!(window.Telegram && window.Telegram.WebApp && typeof window.Telegram.WebApp.shareToStory === 'function');
      }

      if (!canShare) {
        showDenied('Публикация историй недоступна для этого аккаунта.');
        return;
      }


      if (jobId) {
        showContent();
        // Тест: обновить статус через 2 секунды
        check();
        return;
      }

      const tgProfile = parseTelegramProfile();
      startProcessing(tgProfile);
    }

    function showProgress(){
      progressWrap.style.display = 'block';
    }

    function topStageLabel(stage, done){
      if (done) return 'Готово';
      switch(stage){
        case 'queued':
          return 'В очереди';
        case 'starting':
        case 'downloading':
        case 'downloaded':
          return 'Подготовка (скачивание видео)';
        case 'segmenting':
          return 'Подготовка (нарезка на ролики)';
        case 'transcoding':
          return 'Обработка роликов';
        case 'finalizing':
          return 'Финализация';
        case 'failed':
          return 'Ошибка обработки';
        default:
          return 'Обработка';
      }
    }

    function updateProgress(done, pct, stage){
      if(done){
        progressPct = 100;
      } else if (typeof pct === 'number' && !isNaN(pct)) {
        progressPct = Math.max(progressPct, Math.min(Math.floor(pct), 99));
      } else {
        progressPct = Math.min(progressPct + 7, 90);
      }
      progressBar.style.width = progressPct + '%';
      // startedAt всегда должен быть определён
      if (!startedAt) startedAt = Date.now();
      const elapsed = Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
      const stageText = topStageLabel(stage, done);
      progressText.innerText = stageText + ' · ' + progressPct + '% (' + elapsed + 's)';
    }

    function setPreviewFromVideoId(videoId){
      if (!videoId) return;
      if (previewEl.dataset.previewSet === '1' && previewEl.children.length > 0) return;
      const posterSrc = 'https://img.youtube.com/vi/' + videoId + '/maxresdefault.jpg';
      const posterFallback = 'https://img.youtube.com/vi/' + videoId + '/hqdefault.jpg';
      const img = document.createElement('img');
      img.src = posterSrc;
      img.alt = 'preview';
      img.style.width = '100%';
      img.style.borderRadius = '18px';
      img.style.background = '#0c0c0c';
      img.onerror = () => {
        img.onerror = null;
        img.src = posterFallback;
      };
      previewEl.innerHTML = '';
      previewEl.appendChild(img);
      previewEl.dataset.previewSet = '1';
    }

    function shareStory(url){
      try {
        if (window.Telegram && window.Telegram.WebApp && window.Telegram.WebApp.shareToStory) {
          window.Telegram.WebApp.shareToStory(url);
          statusEl.innerText = 'Открыт редактор историй.';
        } else {
          alert('Publishing via Telegram WebApp is available only inside Telegram.');
        }
      } catch(e){ console.error(e); alert('Ошибка публикации: ' + e.message) }
    }

    function normalizeParts(parts, fallbackOutput){
      if (Array.isArray(parts) && parts.length > 0) {
        return parts
          .map((part, idx) => {
            const normalizedIndex = Number(part && part.index);
            return Object.assign({}, part || {}, {
              index: Number.isFinite(normalizedIndex) ? normalizedIndex : (idx + 1)
            });
          })
          .sort((a, b) => {
            const indexA = Number(a.index) || 0;
            const indexB = Number(b.index) || 0;
            if (indexA !== indexB) return indexA - indexB;
            const startA = Number(a.start_sec);
            const startB = Number(b.start_sec);
            if (Number.isFinite(startA) && Number.isFinite(startB)) return startA - startB;
            return 0;
          });
      }
      if (fallbackOutput) return [{ index: 1, status: 'done', output: fallbackOutput }];
      return [];
    }

    function formatClock(totalSeconds){
      const sec = Math.max(0, Math.floor(Number(totalSeconds) || 0));
      const h = Math.floor(sec / 3600);
      const m = Math.floor((sec % 3600) / 60);
      const s = sec % 60;
      if (h > 0) {
        return String(h).padStart(2, '0') + ':' + String(m).padStart(2, '0') + ':' + String(s).padStart(2, '0');
      }
      return String(m).padStart(2, '0') + ':' + String(s).padStart(2, '0');
    }

    function partRangeLabel(part){
      const start = Number(part.start_sec);
      const duration = Number(part.duration_sec);
      if (!Number.isFinite(start) || !Number.isFinite(duration) || duration <= 0) return '';
      const from = formatClock(start);
      const to = formatClock(start + duration);
      return from + '–' + to;
    }

    function renderParts(parts, videoId, fallbackOutput){
      const normalized = normalizeParts(parts, fallbackOutput);
      if (normalized.length === 0) {
        noteEl.innerText = '';
        setPreviewFromVideoId(videoId);
        return;
      }

      const signature = JSON.stringify(normalized.map(part => [part.index, part.status, part.output, part.progress]));
      if (signature === lastPartsSignature) return;
      lastPartsSignature = signature;

      const thumb = videoId ? ('https://img.youtube.com/vi/' + videoId + '/maxresdefault.jpg') : '';
      const thumbFallback = videoId ? ('https://img.youtube.com/vi/' + videoId + '/hqdefault.jpg') : '';
      previewEl.innerHTML = '<div class="part-list">' + normalized.map((part, idx) => {
        const partIndex = part.index || (idx + 1);
        const hasOutput = !!part.output;
        const status = part.status || (hasOutput ? 'done' : 'processing');
        const progress = Math.max(0, Math.min(100, Number(part.progress || (hasOutput ? 100 : 0))));
        const statusText = status === 'done'
          ? 'готово'
          : (status === 'failed' ? 'ошибка' : (status === 'queued' ? 'в очереди' : ('обработка ' + progress + '%')));
        const timeRange = partRangeLabel(part);
        const media = thumb ? '<img class="part-video" src="' + thumb + '" data-fallback="' + thumbFallback + '" alt="preview">' : '<div class="part-video"></div>';
        const action = hasOutput
          ? '<button class="btn primary publish-part" data-url="' + host + '/' + part.output + '">Опубликовать</button>'
          : '<button class="btn ghost" disabled>Готовится</button>';
        return '<div class="part-card">'
          + '<div class="part-head"><div class="part-title">Ролик #' + partIndex + (timeRange ? ' · ' + timeRange : '') + '</div><div class="part-status">' + statusText + '</div></div>'
          + '<div class="part-progress-track"><div class="part-progress-bar" style="width:' + progress + '%"></div></div>'
          + media
          + '<div class="part-actions">' + action + '</div>'
          + '</div>';
      }).join('') + '</div>';

      previewEl.querySelectorAll('.part-video[data-fallback]').forEach(img => {
        img.addEventListener('error', () => {
          const fallbackSrc = img.dataset.fallback || '';
          if (!fallbackSrc || img.src === fallbackSrc) return;
          img.src = fallbackSrc;
        }, { once: true });
      });

      previewEl.querySelectorAll('.publish-part').forEach(btn => {
        btn.addEventListener('click', () => shareStory(btn.dataset.url));
      });

      const readyCount = normalized.filter(part => part.status === 'done' && !!part.output).length;
      noteEl.innerText = 'Частей: ' + normalized.length + ' · готово: ' + readyCount;
    }

    async function attachBotMessageIfNeeded() {
      const chatId = publishConfig.chatIdFromQuery;
      const messageId = publishConfig.messageIdFromQuery;
      if (jobId && chatId && messageId) {
        try {
          const resp = await fetch('/admin/attach_bot_message', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ job_id: jobId, chat_id: chatId, message_id: messageId })
          });
          // Можно добавить логирование или обработку ответа при необходимости
        } catch (e) {
          console.error('attach_bot_message failed', e);
        }
      }
    }

    function check() {
      attachBotMessageIfNeeded();
      fetch('/job_status?job_id=' + encodeURIComponent(jobId)).then(r=>r.json()).then(j=>{
        // Всегда синхронизируем startedAt, если сервер вернул started_at
        if (j.started_at) {
          const parsedStartedAt = Date.parse(j.started_at);
          if (!Number.isNaN(parsedStartedAt)) {
            startedAt = parsedStartedAt;
            startedAtSynced = true;
            if (jobId) saveStartedAt(jobId, startedAt);
          }
        }
        renderParts(j.parts, j.video_id, j.output);
        if (j.status === 'done') {
          statusEl.innerText = 'Готово';
          updateProgress(true, 100, 'done');
          renderParts(j.parts, j.video_id, j.output);
        } else if (j.status === 'failed') {
          statusEl.innerText = 'Ошибка обработки';
          showProgress();
          updateProgress(false, j.progress, 'failed');
          if (j.error) {
            noteEl.innerText = 'Ошибка: ' + j.error;
          }
        } else {
          const queueStage = j.stage === 'queued';
          const preparingStage = queueStage || j.stage === 'starting' || j.stage === 'downloading' || j.stage === 'downloaded' || j.stage === 'segmenting';
          statusEl.innerText = queueStage ? 'В очереди...' : (preparingStage ? 'Подготовка...' : 'Обработка...');
          showProgress();
          updateProgress(false, j.progress, j.stage);
          if (queueStage && !noteEl.innerText) {
            noteEl.innerText = 'Видео в очереди. Подготовка может занять несколько минут.';
          }
          setTimeout(check, 2000);
        }
      }).catch(e=>{statusEl.innerText='Ошибка'; console.error(e)});
    }

    showGate('Проверяем Telegram...');
    armGateFailsafe();
    runPublishFlow().catch((e) => {
      console.error(e);
      showDenied('Ошибка инициализации Telegram.');
    });
  