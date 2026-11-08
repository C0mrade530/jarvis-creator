'use strict';

const $ = id => document.getElementById(id);
const params = new URLSearchParams(location.search);
const roles = {core: 'VOICE INTERFACE', left: 'SOCIAL ANALYTICS', right: 'CREATOR WORKSPACE', combined: 'CREATOR OVERVIEW'};
const role = Object.hasOwn(roles, params.get('role')) ? params.get('role') : 'core';
const native = Boolean(window.webkit?.messageHandlers?.jarvis);
const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
const clamp = (value, min = 0, max = 1) => Math.max(min, Math.min(max, value));
const ease = value => 1 - (1 - clamp(value)) ** 3;
const number = new Intl.NumberFormat('ru-RU');
const platformNames = {instagram: 'Instagram', youtube: 'YouTube', telegram: 'Telegram'};
const voiceNames = {system: 'SYSTEM', elevenlabs: 'ELEVENLABS', voicestudio: 'VOICESTUDIO', 'gpt-live-1': 'GPT-LIVE 1'};
const voiceFallbackMessages = {
  elevenlabs_unavailable: 'ElevenLabs сейчас недоступен. Отвечаю системным голосом.',
  elevenlabs_not_configured: 'Для ElevenLabs нужны API-ключ и Voice ID. Отвечаю системным голосом.',
  voicestudio_unavailable: 'VoiceStudio сейчас недоступен. Отвечаю системным голосом.',
  voicestudio_not_ready: 'Запусти модель в VoiceStudio. Пока отвечаю системным голосом.',
  voicestudio_invalid_voice: 'Проверь выбранный голос VoiceStudio. Пока отвечаю системным голосом.',
};
const assistantNames = {auto: 'CODEX / CLAUDE', codex: 'CODEX', claude: 'CLAUDE CODE'};
const formatDescriptions = {
  'talking-head': 'Запиши разговорный ролик. Jarvis поможет собрать сценарий, выбрать удачные дубли и смонтировать вертикальную версию.',
  animated: 'Начни с идеи, которую проще показать в движении: схема, сравнение или процесс. Jarvis поможет собрать сцену и отрендерить ролик.',
  mixed: 'Снимай личные истории и мнения на камеру, а схемы, сравнения и процессы показывай анимацией. Jarvis поможет с обоими форматами.',
};
const activityLabels = {
  idle: 'ОЖИДАЮ КОМАНДУ', boot: 'ПРОБУЖДЕНИЕ СИСТЕМЫ', report: 'УТРЕННИЙ ОТЧЁТ',
  done: 'ОТЧЁТ ЗАВЕРШЁН', listening: 'СЛУШАЮ', thinking: 'ГОТОВЛЮ ОТВЕТ', speaking: 'ОТВЕЧАЮ',
  streaming: 'ГОТОВЛЮ ОТВЕТ',
  connecting: 'ПОДКЛЮЧАЮСЬ', closing: 'ЗАВЕРШАЮ РАЗГОВОР',
};
let state = {phase: 'idle', elapsed: 0, level: 0, armed: false, filming: false, screenCount: 1};
let profile = {name: '', voice: {}, platforms: {}, format: 'mixed'};
let snapshot = {stats: []};
let controlsVisible = true;
let smoothLevel = 0;
let firstProfile = true;
let setupStep = 0;
let settingsShortcut = false;
let pendingSave = null;
let assistantState = 'ready';
let conversationActive = false;
let liveTurns = [];
let liveRecommendation = false;
let history = [];
let currentQuestion = '';
let currentReply = '';
let currentRecommendation = '';
const mhsLabsURL = 'https://mhslabs.ru/';

document.body.dataset.role = role;
document.body.classList.toggle('side', role !== 'core');
$(role).classList.add('active');
$('screenLabel').textContent = roles[role];
const bars = $('voiceBars').children;
if (role === 'core') {
  for (let i = 0; i < 55; i += 1) $('voiceBars').appendChild(document.createElement('i'));
}

function write(element, value) {
  if (element.textContent !== value) element.textContent = value;
}

function element(tag, value, className) {
  const node = document.createElement(tag);
  if (value) node.textContent = value;
  if (className) node.className = className;
  return node;
}

function mhsLabsLink() {
  const link = element('a', 'Открыть MHS Labs', 'resource-link');
  link.href = mhsLabsURL;
  return link;
}

function send(action, value) {
  if (native) {
    const message = {action};
    if (value !== undefined) message.value = value;
    window.webkit.messageHandlers.jarvis.postMessage(message);
  } else {
    write($('appStatus'), 'Для запуска откройте локальное приложение Jarvis Creator.');
  }
}

function setControls(show) {
  controlsVisible = show;
  $('controls').classList.toggle('hidden', !show);
}
window.jarvisToggleControls = () => setControls(!controlsVisible);

window.jarvisNative = data => {
  const previous = state;
  state = {...state, ...data};
  const busy = ['connecting', 'closing', 'listening', 'transcribing', 'thinking', 'streaming', 'voicing', 'speaking'].includes(assistantState);
  if (state.phase !== previous.phase) {
    document.body.classList.remove(previous.phase);
    document.body.classList.add(state.phase);
    if (role !== 'core') resize();
  }
  if (state.filming !== previous.filming) {
    document.body.classList.toggle('filming', state.filming);
    setControls(!state.filming);
  }
  if (role !== 'core') return;
  const showDock = state.screenCount === 1 && state.filming && state.sideElapsed >= 0;
  $('singleDock').hidden = !showDock;
  document.body.classList.toggle('dock-live', showDock);
  const assistantPhase = assistantState === 'transcribing' ? 'thinking' : assistantState;
  const status = (busy && activityLabels[assistantPhase]) || activityLabels[state.phase] || activityLabels.idle;
  write($('coreState'), state.phase === 'idle' && state.armed && !busy ? 'ОЖИДАЮ ДВА ХЛОПКА' : status);
  write($('voiceTag'), state.phase === 'report' || assistantState === 'speaking' ? 'JARVIS SPEAKING' : 'JARVIS ONLINE');
  write($('connection'), state.armed && state.phase === 'idle' ? 'LISTENING' : state.phase === 'idle' ? 'STANDBY' : 'ONLINE');
  write($('displayCount'), String(state.screenCount).padStart(2, '0'));
  $('swapDisplays').hidden = !(state.canSwapDisplays ?? state.screenCount >= 3);
  const t = Math.floor(state.elapsed || 0);
  write($('coreCounter'), [Math.floor(t / 60), t % 60].map(x => String(x).padStart(2, '0')).join(' : '));
  write($('nativeStatus'), native ? `${state.screenCount} экр. · ${state.filming ? 'съёмка' : 'готов к работе'}` : 'Локальный предпросмотр');
  write($('armButton'), state.armed ? 'Выключить хлопки' : 'Включить хлопки');
  $('armButton').setAttribute('aria-pressed', String(Boolean(state.armed)));
  write($('micStatus'), state.micStatus || 'Микрофон выключен');
  $('micMeter').style.width = `${clamp((state.micLevel || 0) * 8) * 100}%`;
  if (state.audioError) write($('appStatus'), state.audioError);
  const reporting = ['boot', 'report'].includes(state.phase) || state.preparing;
  $('askButton').disabled = busy || conversationActive || reporting;
  $('listenButton').disabled = conversationActive || (busy && assistantState !== 'listening') || reporting;
  $('liveConversation').disabled = assistantState === 'closing' || (!conversationActive && (busy || reporting));
  $('assistantVoiceSettings').disabled = busy || conversationActive || reporting;
};

const form = $('settingsForm');
const fields = form.elements;
const wizard = $('settings');
const steps = [...form.querySelectorAll('fieldset')];

function setStep(index) {
  setupStep = clamp(index, 0, steps.length - 1);
  steps.forEach((step, i) => { step.hidden = i !== setupStep; });
  const legend = steps[setupStep].querySelector('legend');
  legend.id = `legend-${setupStep}`;
  wizard.setAttribute('aria-labelledby', legend.id);
  write($('stepNumber'), `НАСТРОЙКА · ШАГ ${setupStep} ИЗ 3`);
  $('backStep').hidden = setupStep === 0 || settingsShortcut;
  write($('nextStep'), settingsShortcut ? 'Сохранить' : setupStep === 3 ? 'Готово' : 'Дальше');
  write($('settingsError'), '');
  const focus = steps[setupStep].querySelector('input, textarea, select');
  if (wizard.open) focus?.focus();
}

function syncFields() {
  for (const key of ['name', 'niche', 'audience', 'goal', 'telegram_chat_id', 'youtube_channel_id']) {
    fields.namedItem(key).value = profile[key] || '';
  }
  for (const key of Object.keys(platformNames)) fields.namedItem(key).checked = profile.platforms?.[key] === true;
  fields.namedItem('format').value = profile.format || 'mixed';
  fields.namedItem('provider').value = profile.voice?.provider || 'system';
  fields.namedItem('voice_id').value = profile.voice?.provider === 'elevenlabs' ? profile.voice.voice_id || '' : '';
  fields.namedItem('local_voice_id').value = profile.voice?.provider === 'voicestudio' ? profile.voice.voice_id || '' : '';
  fields.namedItem('assistant_provider').value = profile.assistant_provider || 'auto';
  fields.namedItem('conversation_mode').value = profile.conversation_mode || 'turns';
  fields.namedItem('api_key').value = '';
  fields.namedItem('live_api_key').value = '';
  updateVoiceFields();
  updateFormat();
}

function updateVoiceFields() {
  const provider = fields.namedItem('provider').value;
  $('voiceFields').hidden = provider !== 'elevenlabs';
  $('localVoiceFields').hidden = provider !== 'voicestudio';
  $('clearKey').hidden = !profile.voice?.has_api_key;
  write($('keyStatus'), profile.voice?.has_api_key ? 'Ключ сохранён в Связке ключей Mac.' : 'Ключ хранится в Связке ключей Mac.');
  $('openAIFields').hidden = fields.namedItem('conversation_mode').value !== 'gpt-live-1';
  $('clearOpenAIKey').hidden = !profile.has_openai_key;
  write($('openAIKeyStatus'), profile.has_openai_key ? 'Ключ сохранён в Связке ключей Mac.' : 'Нужен ключ от OpenAI API. Jarvis сохранит его в Связке ключей Mac.');
}

function updateFormat() {
  write($('formatHint'), formatDescriptions[fields.namedItem('format').value]);
}

function openSettings(initialStep = 0) {
  settingsShortcut = initialStep === 2;
  syncFields();
  setStep(initialStep);
  if (!wizard.open) wizard.showModal();
}

window.jarvisProfile = data => {
  profile = data;
  if (role === 'right') renderPlan($('sidePlan'));
  if (role === 'combined') renderPlan($('combinedPlan'));
  if (role !== 'core') return;
  renderPlan($('dockPlan'));
  write($('operatorName'), profile.name || 'НОВЫЙ АВТОР');
  write($('voiceProvider'), voiceNames[profile.voice?.provider] || voiceNames.system);
  write($('assistantProvider'), assistantNames[profile.assistant_provider] || assistantNames.auto);
  updateConversationMode();
  updateVoiceFields();
  if (firstProfile) {
    firstProfile = false;
    if (!profile.onboarded) openSettings();
  }
  if (!pendingSave) return;
  if (data.error) {
    write($('settingsError'), data.error);
    pendingSave = null;
    $('nextStep').disabled = false;
    return;
  }
  if (!data.saved) return;
  const next = pendingSave.next;
  pendingSave = null;
  $('nextStep').disabled = false;
  if (next === steps.length) {
    wizard.close();
    write($('appStatus'), settingsShortcut ? 'Настройки голоса сохранены.' : 'Профиль готов. Запусти утренний отчёт или открой статистику.');
  } else {
    setStep(next);
  }
};

form.addEventListener('submit', event => {
  event.preventDefault();
  if (pendingSave) return;
  const value = key => fields.namedItem(key).value.trim();
  let update;
  if (setupStep === 0) {
    if (!value('name')) {
      write($('settingsError'), 'Введи имя или обращение.');
      return;
    }
    update = {name: value('name')};
  } else if (setupStep === 1) {
    update = {platforms: Object.fromEntries(Object.keys(platformNames).map(p => [p, fields.namedItem(p).checked])),
              telegram_chat_id: value('telegram_chat_id'), youtube_channel_id: value('youtube_channel_id')};
  } else if (setupStep === 2) {
    const provider = value('provider');
    const apiKey = value('api_key');
    const voiceID = provider === 'voicestudio' ? value('local_voice_id') : value('voice_id');
    if (provider === 'elevenlabs' && (!voiceID || (!apiKey && !profile.voice?.has_api_key))) {
      write($('settingsError'), 'Введи ключ и Voice ID или выбери системный голос Mac.');
      return;
    }
    if (provider === 'voicestudio' && voiceID && !/^[mf][1-5]$/i.test(voiceID)) {
      write($('settingsError'), 'Выбери голос VoiceStudio от M1 до M5 или от F1 до F5.');
      return;
    }
    update = {voice: {provider, voice_id: voiceID}, assistant_provider: value('assistant_provider'),
              conversation_mode: value('conversation_mode')};
    if (provider === 'elevenlabs' && apiKey) update.voice.api_key = apiKey;
    const liveKey = value('live_api_key');
    if (update.conversation_mode === 'gpt-live-1' && liveKey) update.live_api_key = liveKey;
  } else {
    update = {niche: value('niche'), audience: value('audience'), goal: value('goal'), format: value('format'), onboarded: true};
  }
  if (!native) return;
  fields.namedItem('api_key').value = '';
  fields.namedItem('live_api_key').value = '';
  pendingSave = {next: settingsShortcut ? steps.length : setupStep + 1};
  $('nextStep').disabled = true;
  send('profile-save', update);
});

function addMetric(metrics, label, value) {
  if (!Number.isSafeInteger(value) || value < 0) return;
  const metric = element('div');
  metric.append(element('dt', label), element('dd', number.format(value)));
  metrics.appendChild(metric);
}

function renderStats(target) {
  const grid = element('div', '', 'data-grid');
  for (const [platform, name] of Object.entries(platformNames)) {
    const row = snapshot.stats.find(item => item.platform === platform);
    const disabled = row?.state === 'disabled' || (!row && !profile.platforms?.[platform]);
    if (target !== $('detailBody') && disabled) continue;
    const card = element('article', '', 'platform-card');
    const title = element('h2', '', 'platform-title');
    const icon = document.createElement('img');
    icon.src = `assets/icons/${platform}.svg`;
    icon.alt = '';
    title.append(icon, document.createTextNode(name));
    card.appendChild(title);
    if (row?.connected) {
      if (row.account) card.appendChild(element('p', row.account, 'account'));
      const metrics = element('dl', '', 'metrics');
      const viewPeriod = {lifetime: ' · за всё время', '7d': ' · за 7 дней', '24h': ' · за сутки'};
      addMetric(metrics, 'Просмотры' + (viewPeriod[row.views_period] || ''), row.views);
      addMetric(metrics, platform === 'telegram' ? 'Участники' : 'Подписчики', row.subscribers);
      addMetric(metrics, platform === 'youtube' ? 'Видео' : 'Публикации', row.published);
      card.appendChild(metrics.children.length ? metrics : element('p', 'Площадка не вернула показатели.', 'muted'));
    } else {
      card.appendChild(element('p', disabled ? 'Выключено в настройках' : row?.error || 'Аккаунт ещё не подключён', 'muted'));
    }
    grid.appendChild(card);
  }
  target.replaceChildren(grid.children.length ? grid : element('p', 'Подключи площадки в настройках Jarvis.', 'muted'));
}

function statsTime() {
  const date = new Date(snapshot.as_of || '');
  return Number.isFinite(date.getTime()) ? 'Данные на ' + date.toLocaleString('ru-RU') : '';
}

function renderPlan(target) {
  const format = formatDescriptions[profile.format] || formatDescriptions.mixed;
  const items = [
    ['Сценарист', 'Разложи одну историю на восемь разных углов. Начни со скилла jarvis-script.'],
    ['Монтаж', 'Передай отснятый материал скиллу jarvis-edit и посмотри черновик.'],
    ['Анимация', 'Опиши тему и формат скиллу jarvis-animate. Он предложит подходящий инструмент.'],
    ['Публикация', 'Собери черновик через jarvis-post и подтверди площадку, аккаунт и финальный файл.'],
  ];
  const list = element('dl', '', 'plan-steps');
  for (const [name, description] of items) {
    const item = element('div');
    item.append(element('dt', name), element('dd', description));
    list.appendChild(item);
  }
  target.replaceChildren(element('p', format, 'plan-lead'), list);
  if (target === $('detailBody')) {
    const resource = element('p', 'Автоответы для воронок · ', 'hint');
    resource.appendChild(mhsLabsLink());
    const threads = element('details');
    const setup = element('p', 'В исходной папке Jarvis выполни команды по порядку. Upload-Post выдаст ссылку для входа в свой аккаунт Threads.');
    const commands = element('pre');
    commands.appendChild(element('code', './jarvis threads install\n./jarvis threads setup\n./jarvis threads run\n# В другом терминале\n./jarvis threads chat'));
    threads.append(element('summary', 'Автопостинг в Threads'), setup, commands);
    target.append(resource, threads);
  }
}

window.jarvisStats = data => {
  snapshot = {stats: [], ...data};
  if (role === 'left') {
    renderStats($('sideStats'));
    write($('sideStatsTime'), statsTime());
  }
  if (role === 'combined') {
    renderStats($('combinedStats'));
    write($('combinedTime'), statsTime());
  }
  if (role === 'core') renderStats($('dockStats'));
  if ($('details').open && $('details').dataset.mode === 'stats') renderStats($('detailBody'));
  $('refreshStats').disabled = Boolean(snapshot.refreshing);
  write($('refreshStatus'), snapshot.error || (snapshot.refreshing ? 'Читаю подключённые аккаунты…' : statsTime()));
};

window.jarvisPrepared = data => {
  const status = {preparing: 'Готовлю озвучку отчёта…', ready: 'Озвучка готова.'};
  write($('appStatus'), data.error || data.fallbackReason || status[data.state] || '');
  if (data.provider) write($('voiceProvider'), voiceNames[data.provider] || voiceNames.system);
};

function openDetails(mode) {
  $('details').dataset.mode = mode;
  const statsMode = mode === 'stats';
  write($('detailsTitle'), statsMode ? 'Статистика' : 'План контента');
  $('detailActions').hidden = !statsMode;
  $('refreshStatus').hidden = !statsMode;
  if (statsMode) renderStats($('detailBody'));
  else renderPlan($('detailBody'));
  $('details').showModal();
}

function showConversation() {
  const turns = [...history];
  if (currentQuestion) turns.push({role: 'user', content: currentQuestion});
  if (currentReply) turns.push({role: 'assistant', content: currentReply, recommendation: currentRecommendation});
  $('conversation').replaceChildren(...turns.slice(-8).map(turn => {
    const line = element('p');
    line.append(element('strong', turn.role === 'user' ? 'Ты · ' : 'Jarvis · '), document.createTextNode(turn.content));
    if (turn.recommendation === 'mhs-labs') line.append(element('br'), mhsLabsLink());
    return line;
  }));
  $('conversation').scrollTop = $('conversation').scrollHeight;
}

function updateConversationMode() {
  const usesLive = profile.conversation_mode === 'gpt-live-1';
  $('turnInfo').hidden = usesLive;
  $('liveInfo').hidden = !usesLive;
  $('listenButton').hidden = usesLive;
  $('conversation').hidden = usesLive && conversationActive;
  $('liveTurns').hidden = !usesLive || !liveTurns.length;
  $('liveMhsLink').hidden = !usesLive || !liveRecommendation;
}

window.jarvisLiveTranscript = data => {
  if (role !== 'core') return;
  liveTurns = Array.isArray(data.turns) ? data.turns : [];
  liveRecommendation = data.recommendation === 'mhs-labs';
  const pane = $('liveTurns');
  pane.replaceChildren(...liveTurns.map(turn => {
    const line = element('p');
    line.append(element('strong', turn.role === 'user' ? 'Ты · ' : 'Jarvis · '), document.createTextNode(turn.content));
    return line;
  }));
  pane.scrollTop = pane.scrollHeight;
  updateConversationMode();
};

window.jarvisAssistant = data => {
  assistantState = data.state;
  if (typeof data.conversationActive === 'boolean') conversationActive = data.conversationActive;
  if (role !== 'core') return;
  const status = {
    connecting: 'Подключаю GPT-Live…', closing: 'Завершаю разговор…',
    listening: data.liveMode ? 'GPT-Live слушает.' : conversationActive ? 'Слушаю. Сделай паузу, когда закончишь.' : 'Слушаю. Нажми «Готово», когда закончишь.',
    transcribing: 'Распознаю речь…', thinking: 'Помощник готовит ответ…', streaming: 'Поступает текст ответа…',
    voicing: 'Готовлю озвучку…', speaking: 'Jarvis отвечает…',
  };
  if (data.voiceProvider && Object.hasOwn(voiceNames, data.voiceProvider)) {
    write($('voiceProvider'), voiceNames[data.voiceProvider]);
  }
  write($('askStatus'), data.error || voiceFallbackMessages[data.voiceFallbackReason] ||
    (data.voiceStreaming && data.state === 'speaking' ? 'Jarvis отвечает · ElevenLabs в потоке' : status[data.state]) || '');
  write($('listenButton'), data.state === 'listening' && !conversationActive ? 'Готово' : 'Одна реплика');
  write($('liveConversation'), conversationActive ? 'Закончить разговор' : 'Начать разговор');
  $('liveConversation').setAttribute('aria-pressed', String(conversationActive));
  $('listenButton').setAttribute('aria-pressed', String(data.state === 'listening'));
  updateConversationMode();
  if (data.state === 'listening' && data.transcript) $('question').value = data.transcript;
  if (data.state === 'thinking') {
    currentQuestion = data.transcript || currentQuestion;
    $('question').value = '';
  }
  if (data.reply) currentReply = data.reply;
  if (data.recommendation === 'mhs-labs') currentRecommendation = data.recommendation;
  if (data.state === 'ready' || data.state === 'error') {
    if (currentQuestion) history.push({role: 'user', content: currentQuestion});
    if (currentReply) history.push({role: 'assistant', content: currentReply, recommendation: currentRecommendation});
    history = history.slice(-8);
    currentQuestion = '';
    currentReply = '';
    currentRecommendation = '';
  }
  showConversation();
  window.jarvisNative(state);
};

document.querySelectorAll('[data-action]').forEach(button => {
  button.addEventListener('click', () => send(button.dataset.action));
});
document.querySelectorAll('[data-close]').forEach(button => {
  button.addEventListener('click', () => $(button.dataset.close).close());
});
$('sensitivity').addEventListener('input', event => send('sensitivity', Number(event.target.value)));
$('hideControls').onclick = () => setControls(false);
$('showControls').onclick = () => setControls(true);
$('showSettings').onclick = () => openSettings();
$('closeSettings').onclick = () => wizard.close();
wizard.addEventListener('close', () => {
  fields.namedItem('api_key').value = '';
  fields.namedItem('live_api_key').value = '';
});
$('backStep').onclick = () => setStep(setupStep - 1);
$('clearKey').onclick = () => send('profile-clear-voice-key');
$('clearOpenAIKey').onclick = () => send('profile-clear-openai-key');
fields.namedItem('provider').onchange = updateVoiceFields;
fields.namedItem('conversation_mode').onchange = updateVoiceFields;
fields.namedItem('format').onchange = updateFormat;
$('showStats').onclick = () => openDetails('stats');
$('showPlan').onclick = () => openDetails('plan');
$('refreshStats').onclick = () => send('stats-refresh');
$('showAssistant').onclick = () => $('assistant').showModal();
$('assistantVoiceSettings').onclick = () => {
  $('assistant').close();
  openSettings(2);
};
$('liveMhsLink').appendChild(mhsLabsLink());
$('assistant').addEventListener('close', () => {
  if (conversationActive || !['ready', 'error'].includes(assistantState)) send('conversation-stop');
});
$('listenButton').onclick = () => send(assistantState === 'listening' ? 'listen-stop' : 'listen-start');
$('liveConversation').onclick = () => {
  const action = conversationActive ? 'conversation-stop' : 'conversation-start';
  if (native && !conversationActive) conversationActive = true;
  send(action);
};
$('askForm').addEventListener('submit', event => {
  event.preventDefault();
  const question = $('question').value.trim();
  if (question) send('ask', {question, history});
});

document.addEventListener('keydown', event => {
  if (event.defaultPrevented || event.repeat || event.metaKey || event.ctrlKey || event.altKey) return;
  if (event.target.closest('input, textarea, select, button, [contenteditable]') || document.querySelector('dialog[open]')) return;
  const key = event.key.toLowerCase();
  const actions = {' ': 'start', r: 'reset', f: 'film'};
  if (actions[key]) {
    event.preventDefault();
    send(actions[key]);
  } else if (key === 'c') {
    setControls(!controlsVisible);
  } else if (key === 'escape') {
    if (state.filming) send('film');
    else send('reset');
  }
});

function renderClock() {
  write($('clock'), new Intl.DateTimeFormat('ru-RU', {hour: '2-digit', minute: '2-digit'}).format(new Date()));
}
renderClock();
setInterval(renderClock, 30000);
if (role === 'left') renderStats($('sideStats'));
if (role === 'right') renderPlan($('sidePlan'));
if (role === 'combined') { renderStats($('combinedStats')); renderPlan($('combinedPlan')); }
if (role === 'core') { renderStats($('dockStats')); renderPlan($('dockPlan')); }
if (native && role === 'core') send('profile-get');
if (!native && role === 'core') {
  window.jarvisNative(state);
  if (params.has('setup')) openSettings();
}
