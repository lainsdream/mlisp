(() => {
  const form = document.querySelector('#test-form');
  const input = document.querySelector('#url');
  const run = document.querySelector('#run');
  const status = document.querySelector('#status');
  const body = document.querySelector('#results');
  const unstableBody = document.querySelector('#unstable-results');
  const rows = [];
  const unstableRows = [];

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

  function buildRow(item, showJitter) {
    const tr = document.createElement('tr');
    const exitLabel = item.exitCountry
      ? item.exitCountry + (item.multihop ? ' 🔀' : '')
      : '—';
    const serverLabel = item.host + ':' + item.port
      + (item.hostCountry ? ` (${item.hostCountry})` : '');
    const values = [
      [Math.floor(Number(item.mbps)) + ' Mbps', 'speed'],
      [item.tag || '—', 'tag'],
      [item.kind, ''],
      [serverLabel, ''],
      [exitLabel, 'exit'],
    ];
    if (showJitter) {
      values.push([`${item.jitterMs} ms (${item.failedProbes}/${item.totalProbes} fail)`, 'jitter']);
    }
    for (const [value, className] of values) {
      const td = document.createElement('td'); td.textContent = value; td.className = className;
      if (className === 'exit' && item.multihop) td.title = `Exit IP: ${item.exitIp} (отличается от IP сервера — трафик уходит через доп. хоп)`;
      tr.append(td);
    }
    const action = document.createElement('td');
    const button = document.createElement('button');
    button.className = 'copy'; button.type = 'button'; button.textContent = 'Копировать';
    button.addEventListener('click', () => copy(item.uri, button));
    action.append(button); tr.append(action);
    return tr;
  }

  function renderTable(bodyEl, list, emptyText, showJitter) {
    bodyEl.replaceChildren();
    if (list.length === 0) {
      const tr = document.createElement('tr');
      const td = document.createElement('td');
      td.className = 'empty'; td.colSpan = showJitter ? 7 : 6; td.textContent = emptyText;
      tr.append(td); bodyEl.append(tr);
      return;
    }
    for (const item of list) bodyEl.append(buildRow(item, showJitter));
  }

  function addResult(result) {
    rows.push(result);
    rows.sort((a, b) => Number(b.mbps) - Number(a.mbps));
    renderTable(body, rows, 'Валидные конфиги появятся здесь.', false);
  }

  function addUnstableResult(result) {
    unstableRows.push(result);
    unstableRows.sort((a, b) => Number(b.mbps) - Number(a.mbps));
    renderTable(unstableBody, unstableRows, 'Нестабильных конфигов пока нет.', true);
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
    } else if (type === 'unstable-result') {
      addUnstableResult(payload);
    } else if (type === 'progress') {
      status.textContent = `Проверено ${payload.done} из ${payload.total}; стабильных: ${rows.length}, нестабильных: ${unstableRows.length}.`;
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
    unstableRows.length = 0;
    renderTable(body, rows, 'Валидные конфиги появятся здесь.', false);
    renderTable(unstableBody, unstableRows, 'Нестабильных конфигов пока нет.', true);
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
