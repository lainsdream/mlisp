(() => {
  const form = document.querySelector('#test-form');
  const input = document.querySelector('#url');
  const run = document.querySelector('#run');
  const status = document.querySelector('#status');
  const body = document.querySelector('#results');
  const rows = [];

  function copy(text, button) {
    navigator.clipboard.writeText(text).then(() => {
      const old = button.textContent;
      button.textContent = 'Скопировано';
      setTimeout(() => button.textContent = old, 1000);
    }).catch(() => {
      const area = document.createElement('textarea');
      area.value = text; document.body.append(area); area.select();
      document.execCommand('copy'); area.remove();
    });
  }

  function addResult(result) {
    rows.push(result);
    rows.sort((a, b) => Number(b.mbps) - Number(a.mbps));
    body.replaceChildren();
    for (const item of rows) {
      const tr = document.createElement('tr');
      const exitLabel = item.exitCountry
        ? item.exitCountry + (item.multihop ? ' 🔀' : '')
        : '—';
      const values = [
        [item.mbps + ' Mbps', 'speed'],
        [item.tag || '—', 'tag'],
        [item.kind, ''],
        [item.host + ':' + item.port, ''],
        [exitLabel, 'exit'],
        [item.uri, 'config']
      ];
      for (const [value, className] of values) {
        const td = document.createElement('td'); td.textContent = value; td.className = className;
        if (className === 'exit' && item.multihop) td.title = `Exit IP: ${item.exitIp} (отличается от IP сервера — трафик уходит через доп. хоп)`;
        tr.append(td);
      }
      const action = document.createElement('td');
      const button = document.createElement('button');
      button.className = 'copy'; button.type = 'button'; button.textContent = 'Копировать';
      button.addEventListener('click', () => copy(item.uri, button));
      action.append(button); tr.append(action); body.append(tr);
    }
  }

  // Разбирает один "сырой" SSE-блок (текст между \n\n) на {type, payload}.
  function parseSseEvent(rawEvent) {
    const lines = rawEvent.split('\n');
    const eventLine = lines.find(l => l.startsWith('event:'));
    const dataLine = lines.find(l => l.startsWith('data:'));
    if (!eventLine || !dataLine) return null;

    const type = eventLine.slice('event:'.length).trim();
    const jsonText = dataLine.slice('data:'.length).trim();

    try {
      return { type, payload: JSON.parse(jsonText) };
    } catch (error) {
      console.error('Bad SSE payload:', jsonText, error);
      return null;
    }
  }

  function handleEvent(type, payload) {
    if (type === 'result') {
      addResult(payload);
    } else if (type === 'progress') {
      status.textContent = `Проверено ${payload.done} из ${payload.total}; валидных: ${rows.length}.`;
    } else if (type === 'status' || type === 'error') {
      status.textContent = payload.message;
    }
  }

  form.addEventListener('submit', async event => {
    event.preventDefault();
    let url;
    try {
      url = new URL(input.value);
      if (!['http:', 'https:'].includes(url.protocol)) throw new Error();
    } catch (_) {
      status.textContent = 'Нужна корректная ссылка http:// или https://.';
      input.focus(); return;
    }

    rows.length = 0;
    body.replaceChildren();
    run.disabled = true;
    status.textContent = 'Загружаю список…';

    // Буфер нужен, т.к. один read() может вернуть неполное событие
    // или сразу несколько событий подряд.
    let buffer = '';

    try {
      const response = await fetch('/speedtest', {
        method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: new URLSearchParams({url: url.href})
      });
      if (!response.ok || !response.body) throw new Error('HTTP ' + response.status);

      const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();

      while (true) {
        const { value, done } = await reader.read();
        if (value) buffer += value;

        let sep;
        while ((sep = buffer.indexOf('\n\n')) !== -1) {
          const rawEvent = buffer.slice(0, sep);
          buffer = buffer.slice(sep + 2);
          const parsed = parseSseEvent(rawEvent);
          if (parsed) handleEvent(parsed.type, parsed.payload);
        }

        if (done) break;
      }
    } catch (error) {
      status.textContent = 'Не удалось выполнить тест: ' + error.message;
    } finally {
      run.disabled = false;
    }
  });
})();
