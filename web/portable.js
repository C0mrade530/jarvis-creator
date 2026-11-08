'use strict';

(() => {
  if (location.protocol !== 'http:' || location.hostname !== '127.0.0.1') return;
  const fragmentToken = new URLSearchParams(location.hash.slice(1)).get('jarvis');
  let token = fragmentToken;
  try {
    const storageKey = 'jarvis-portable-session';
    if (fragmentToken) sessionStorage.setItem(storageKey, fragmentToken);
    else token = sessionStorage.getItem(storageKey);
  } catch {
    // The startup URL still works if storage is disabled.
  }
  if (!token) return;
  if (fragmentToken) window.history.replaceState(null, '', location.pathname + location.search);

  const byId = id => document.getElementById(id);
  const AudioContext = window.AudioContext || window.webkitAudioContext;
  const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;
  const command = navigator.platform.startsWith('Win') ? '.\\jarvis.cmd' : './jarvis';
  const unsupportedVoice = 'Голосовой ввод здесь недоступен. Напиши вопрос или попробуй Chrome.';
  const serverUnavailable = 'Нет связи с Jarvis. Проверь, что окно запуска ещё открыто, или запусти Jarvis заново.';
  let phase = 'idle';
  let filming = false;
  let preparing = false;
  let reportStarted = 0;
  let reportEpoch = 0;
  let reportText = '';
  let reportTimer = 0;
  let session = 0;
  let conversationActive = false;
  let assistantBusy = false;
  let recognition = null;
  let nextListen = 0;
  let microphone = null;
  let openingMic = false;
  let micLevel = 0;
  let micStatus = 'Микрофон выключен';
  let sensitivity = 1;
  let playback = null;

  window.jarvisPortable = {postMessage, command, canListen: Boolean(Recognition)};

  const settings = byId('settingsForm').elements;
  settings.namedItem('provider').querySelector('[value="system"]').textContent = 'Системный голос';
  settings.namedItem('provider').querySelector('[value="voicestudio"]').remove();
  settings.namedItem('conversation_mode').closest('label').hidden = true;
  const voiceStep = settings.namedItem('provider').closest('fieldset');
  voiceStep.querySelector('legend + p').textContent = 'Выбери системный голос браузера или подключи ElevenLabs.';
  settings.namedItem('assistant_provider').closest('label').nextElementSibling.textContent = 'Войди в выбранном CLI. В режиме «Автоматически» Jarvis использует Codex, если он установлен, иначе Claude Code.';
  document.querySelectorAll('.platform-option code').forEach(code => {
    code.textContent = code.textContent.replace('./jarvis', command);
  });
  byId('turnInfo').textContent = Recognition
    ? 'Браузер распознаёт речь. Jarvis передаёт текст выбранному помощнику, озвучивает ответ и в разговоре снова начинает слушать.'
    : unsupportedVoice;
  if (!Recognition) {
    byId('listenButton').hidden = true;
    byId('liveConversation').hidden = true;
  }

  const reportButton = document.createElement('button');
  reportButton.type = 'button';
  reportButton.hidden = true;
  reportButton.textContent = 'Текст отчёта';
  reportButton.addEventListener('click', showReport);
  document.querySelector('.control-buttons').append(reportButton);
  const prepareButton = document.querySelector('[data-action="prepare"]');
  prepareButton.textContent = 'Подготовить отчёт';
  prepareButton.title = 'Собрать текст утреннего отчёта';

  async function request(action, value) {
    let response;
    try {
      response = await fetch('/api/action', {
        method: 'POST', headers: {'Content-Type': 'application/json', 'X-Jarvis-Token': token},
        body: JSON.stringify({action, value}), cache: 'no-store', credentials: 'omit', redirect: 'error',
      });
    } catch {
      throw new Error(serverUnavailable);
    }
    const result = await response.json().catch(() => null);
    if (!response.ok || !result) throw new Error(result?.error || serverUnavailable);
    return result;
  }

  function apply(result) {
    if (result.profile) window.jarvisProfile(result.profile);
    if (result.stats) window.jarvisStats(result.stats);
  }

  function update() {
    const elapsed = reportStarted ? (performance.now() - reportStarted) / 1000 : 0;
    window.jarvisNative({phase, filming, preparing, elapsed,
      sideElapsed: phase === 'report' || phase === 'done' ? elapsed : -1,
      level: playback?.playing ? 0.16 + 0.1 * Math.sin(performance.now() / 125) : 0,
      armed: Boolean(microphone), micStatus, micLevel, canSwapDisplays: false,
    });
  }

  function assistant(state, fields = {}) {
    window.jarvisAssistant({state, conversationActive, ...fields});
  }

  function occupied() {
    return preparing || phase === 'boot' || phase === 'report' || assistantBusy || recognition || conversationActive;
  }

  function syncClaps() {
    if (!microphone) return;
    const active = !occupied();
    if (!active) micLevel = 0;
    microphone.node.port.postMessage({active, sensitivity});
  }

  async function arm() {
    if (openingMic) return;
    if (microphone) {
      closeMic();
      micStatus = 'Микрофон выключен';
      update();
      return;
    }
    if (!AudioContext || !window.AudioWorkletNode || !navigator.mediaDevices?.getUserMedia) {
      micStatus = 'Хлопки здесь недоступны. Запусти отчёт кнопкой или пробелом.';
      update();
      return;
    }
    openingMic = true;
    micStatus = 'Разреши доступ к микрофону';
    update();
    let stream;
    let context;
    try {
      context = new AudioContext();
      const resume = context.resume();
      // Start the permission request and audio context from the same user gesture.
      [stream] = await Promise.all([navigator.mediaDevices.getUserMedia({audio: {
        echoCancellation: false, noiseSuppression: false, autoGainControl: false,
      }}), resume.catch(() => {})]);
      await context.audioWorklet.addModule('/clap-processor.js');
      const source = context.createMediaStreamSource(stream);
      const node = new AudioWorkletNode(context, 'jarvis-clap');
      node.port.onmessage = ({data}) => {
        if (microphone?.node !== node || occupied()) return;
        if (typeof data.level === 'number') micLevel = data.level;
        if (data.clap) void runReport('start');
        else update();
      };
      source.connect(node).connect(context.destination);
      microphone = {stream, context, source, node};
      for (const track of stream.getAudioTracks()) track.addEventListener('ended', () => {
        if (microphone?.stream !== stream) return;
        closeMic();
        micStatus = 'Микрофон отключён. Включи хлопки снова, чтобы выбрать устройство.';
        update();
      });
      micStatus = 'Ожидаю два хлопка';
      syncClaps();
    } catch {
      stream?.getTracks().forEach(track => track.stop());
      void context?.close().catch(() => {});
      micStatus = 'Микрофон недоступен. Проверь разрешение браузера или запусти отчёт кнопкой.';
    } finally {
      openingMic = false;
      update();
    }
  }

  function closeMic() {
    if (!microphone) return;
    const {stream, context, node, source} = microphone;
    microphone = null;
    micLevel = 0;
    node.port.onmessage = null;
    node.disconnect();
    source.disconnect();
    stream.getTracks().forEach(track => track.stop());
    void context.close().catch(() => {});
  }

  function stopPlayback() {
    playback?.cancel();
  }

  function play(setup) {
    return new Promise((resolve, reject) => {
      let cancelOutput = () => {};
      let finished = false;
      const output = {playing: false, cancel: () => finish()};
      const timer = setTimeout(() => finish(new Error('Озвучка не завершилась.')), 180000);
      function finish(error) {
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        if (playback === output) playback = null;
        cancelOutput();
        if (error) reject(error);
        else resolve();
      }
      playback = output;
      try {
        cancelOutput = setup(finish, () => { output.playing = true; });
      } catch (error) {
        finish(error);
      }
    });
  }

  function playAudio(url) {
    return play((finish, started) => {
      const audio = new Audio(url);
      audio.onplaying = started;
      audio.onended = () => finish();
      audio.onerror = () => finish(new Error('Браузер не воспроизвёл голос ElevenLabs.'));
      void audio.play().catch(() => finish(new Error('Браузер не запустил озвучку.')));
      return () => { audio.pause(); audio.removeAttribute('src'); audio.load(); };
    });
  }

  function playSystem(text) {
    const engine = window.speechSynthesis;
    if (!engine || !window.SpeechSynthesisUtterance) throw new Error('В браузере нет системной озвучки.');
    const voices = engine.getVoices().filter(voice => /^ru(?:[-_]|$)/i.test(voice.lang));
    const voice = voices.find(item => item.localService) || voices[0];
    const phrases = text.match(/.{1,180}(?:\s+|$)|.{1,180}/gu) || [text];
    return play((finish, started) => {
      let index = 0;
      let cancelled = false;
      const next = () => {
        if (cancelled) return;
        if (index === phrases.length) { finish(); return; }
        const utterance = new SpeechSynthesisUtterance(phrases[index++].trim());
        utterance.lang = 'ru-RU';
        if (voice) utterance.voice = voice;
        utterance.onstart = started;
        utterance.onend = next;
        utterance.onerror = () => finish(new Error('Системный голос недоступен. Проверь настройки синтеза речи.'));
        engine.speak(utterance);
      };
      next();
      return () => { cancelled = true; engine.cancel(); };
    });
  }

  async function speak(text, current, beforePlaying) {
    const {voice} = await request('speak', {text});
    if (!current()) return;
    if (voice?.provider === 'elevenlabs' && voice.audioUrl?.startsWith('data:audio/mpeg;base64,')) {
      beforePlaying(voice);
      try { await playAudio(voice.audioUrl); return; }
      catch { if (!current()) return; }
    }
    beforePlaying(voice?.provider === 'elevenlabs' ? {provider: 'system', message: 'Не удалось воспроизвести ElevenLabs. Включаю системный голос.'} : voice);
    await playSystem(text);
  }

  function showReport() {
    if (!reportText || document.querySelector('dialog[open]')) return;
    const dialog = document.createElement('dialog');
    dialog.setAttribute('aria-label', 'Утренний отчёт');
    const heading = document.createElement('h2');
    heading.textContent = 'Утренний отчёт';
    const paragraph = document.createElement('p');
    paragraph.textContent = reportText;
    const close = document.createElement('button');
    close.textContent = 'Закрыть';
    close.addEventListener('click', () => dialog.close());
    dialog.append(heading, paragraph, close);
    dialog.addEventListener('close', () => dialog.remove(), {once: true});
    document.body.append(dialog);
    dialog.showModal();
  }

  async function runReport(action) {
    if (occupied() || document.querySelector('dialog[open]')) return;
    const epoch = ++reportEpoch;
    const current = () => epoch === reportEpoch;
    preparing = true;
    syncClaps();
    update();
    window.jarvisPrepared({state: 'preparing'});
    try {
      const result = await request(action);
      if (!current()) return;
      apply(result);
      reportText = result.report?.text || '';
      if (!reportText) throw new Error('Jarvis не получил текст отчёта.');
      reportButton.hidden = false;
      if (action === 'prepare') {
        window.jarvisPrepared({state: 'ready', fallbackReason: 'Текст утреннего отчёта готов.'});
        showReport();
        return;
      }
      phase = 'boot';
      filming = true;
      reportStarted = performance.now();
      reportTimer = window.setInterval(update, 80);
      update();
      await speak(reportText, current, voice => {
        phase = 'report';
        window.jarvisPrepared({state: 'ready', provider: voice?.provider, fallbackReason: voice?.fallbackReason || voice?.message});
        update();
      });
    } catch (error) {
      if (!current()) return;
      window.jarvisPrepared({state: 'error', error: error.message});
      if (reportText && phase !== 'idle') showReport();
    } finally {
      if (current()) {
        clearInterval(reportTimer);
        if (phase === 'boot' || phase === 'report') phase = 'done';
        preparing = false;
        syncClaps();
        update();
      }
    }
  }

  function resetReport() {
    if (phase === 'boot' || phase === 'report') stopPlayback();
    ++reportEpoch;
    clearInterval(reportTimer);
    phase = 'idle';
    filming = false;
    preparing = false;
    reportStarted = 0;
    window.jarvisPrepared({state: 'idle'});
    syncClaps();
    update();
  }

  async function ask(value) {
    if (assistantBusy || recognition || preparing || phase === 'boot' || phase === 'report') return;
    const question = typeof value?.question === 'string' ? value.question.trim().slice(0, 3000) : '';
    if (!question) return;
    const epoch = ++session;
    const current = () => epoch === session;
    assistantBusy = true;
    syncClaps();
    assistant('thinking', {transcript: question});
    let response;
    try {
      const {assistant: result} = await request('ask', {question, history: value.history});
      if (!current()) return;
      if (!result || result.error || !result.reply) throw new Error(result?.error || 'Ассистент вернул пустой ответ.');
      response = {reply: result.reply, recommendation: result.recommendation};
      assistant('voicing', response);
      await speak(result.reply, current, voice => assistant('speaking', {...response, voiceProvider: voice?.provider,
        voiceFallbackReason: voice?.fallbackReason, error: voice?.message}));
      if (!current()) return;
      assistant('ready');
    } catch (error) {
      if (!current()) return;
      conversationActive = false;
      assistant('error', {...response, error: error.message});
    } finally {
      if (current()) {
        assistantBusy = false;
        syncClaps();
        update();
        if (conversationActive) nextListen = setTimeout(() => startListening(true), 350);
      }
    }
  }

  function startListening(continuous) {
    if (assistantBusy || recognition || preparing || phase === 'boot' || phase === 'report') return;
    if (!Recognition) { assistant('error', {error: unsupportedVoice}); return; }
    conversationActive = continuous;
    const input = new Recognition();
    recognition = input;
    input.lang = 'ru-RU';
    input.interimResults = true;
    input.continuous = false;
    let transcript = '';
    let listenTimer;
    function finish(error) {
      if (recognition !== input) return;
      clearTimeout(listenTimer);
      recognition = null;
      if (error || !transcript.trim()) {
        conversationActive = false;
        try { input.abort(); } catch { /* recognition already ended */ }
        assistant('error', {error: error || 'Не расслышал фразу. Попробуй ещё раз или напиши вопрос.'});
        syncClaps();
        update();
        return;
      }
      void ask({question: transcript, history: window.jarvisPortable.getHistory?.()});
    }
    input.onresult = event => {
      if (recognition !== input) return;
      transcript = Array.from(event.results, result => result[0].transcript).join(' ').trim();
      if (transcript) assistant('listening', {transcript});
    };
    input.onerror = event => {
      const errors = {'not-allowed': 'Разреши микрофон в браузере.', 'service-not-allowed': 'Браузер запретил распознавание речи.',
        'audio-capture': 'Браузер не нашёл микрофон.', network: 'Распознавание речи недоступно. Проверь интернет или напиши вопрос.'};
      finish(errors[event.error] || 'Не удалось распознать речь. Попробуй ещё раз или напиши вопрос.');
    };
    input.onend = () => finish();
    recognition.cancel = () => { clearTimeout(listenTimer); try { input.abort(); } catch { /* already ended */ } };
    assistant('listening');
    syncClaps();
    try {
      input.start();
      listenTimer = setTimeout(() => finish('Не удалось получить речь от браузера. Попробуй ещё раз или напиши вопрос.'), 25000);
    } catch {
      finish('Браузер не запустил голосовой ввод. Проверь микрофон или напиши вопрос.');
    }
  }

  function stopConversation() {
    ++session;
    clearTimeout(nextListen);
    const input = recognition;
    recognition = null;
    input?.cancel();
    if (assistantBusy) stopPlayback();
    assistantBusy = false;
    conversationActive = false;
    assistant('ready');
    syncClaps();
    update();
  }

  async function postMessage({action, value}) {
    if (action === 'arm') return arm();
    if (action === 'sensitivity') { sensitivity = value; syncClaps(); return; }
    if (action === 'film') { filming = !filming; update(); return; }
    if (action === 'reset') return resetReport();
    if (action === 'start' || action === 'prepare') return runReport(action);
    if (action === 'listen-start' || action === 'conversation-start') return startListening(action === 'conversation-start');
    if (action === 'listen-stop') { try { recognition?.stop(); } catch { stopConversation(); } return; }
    if (action === 'conversation-stop') return stopConversation();
    if (action === 'ask') return ask(value);
    if (action === 'stats-refresh') {
      byId('refreshStats').disabled = true;
      byId('refreshStatus').textContent = 'Читаю подключённые аккаунты…';
    }
    try {
      apply(await request(action, value));
      if (action === 'profile-get') update();
    } catch (error) {
      if (action === 'stats-refresh') {
        byId('refreshStats').disabled = false;
        byId('refreshStatus').textContent = error.message;
      } else if (action === 'profile-save') {
        window.jarvisPortable.profileError?.(error.message);
      } else {
        byId('appStatus').textContent = error.message;
      }
    }
  }

  window.addEventListener('pagehide', () => {
    closeMic();
    stopPlayback();
    recognition?.cancel();
  });
})();
