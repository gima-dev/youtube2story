async function postProcess(url, canShare){
  const res = await fetch('/process', {
    method: 'POST',
    headers: {'Content-Type':'application/json'},
    body: JSON.stringify({url, can_share: !!canShare})
  })
  return res.json()
}

// Если WebApp доступен — сообщаем Telegram, что страница готова.
let _readyCalled = false
function callTelegramReady(){
  try{
    if(window.Telegram && window.Telegram.WebApp && typeof window.Telegram.WebApp.ready === 'function'){
      window.Telegram.WebApp.ready()
      if(typeof window.Telegram.WebApp.expand === 'function'){
        try{ window.Telegram.WebApp.expand() }catch(e){}
      }
      _readyCalled = true
        return true
      return true
    }
  }catch(e){
    // игнорируем
  }
  return false
}

// Пытаемся несколько раз — иногда Telegram объект появляется позже в WebView.
callTelegramReady()
const __tgInterval = setInterval(()=>{
  if(callTelegramReady()) clearInterval(__tgInterval)
}, 150)
  setTimeout(()=>{ clearInterval(__tgInterval); }, 4000)

// Отметим, что клиентский скрипт запустился
document.addEventListener('DOMContentLoaded', ()=>{
  document.addEventListener('DOMContentLoaded', ()=>{})
})

// Отправляем пинг на сервер, чтобы зафиксировать, что JS выполнился внутри WebView
;(async ()=>{
  try{
     await fetch('/__ping', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({ts:Date.now(), ua: navigator.userAgent})})
  }catch(e){
     // ignore ping errors
  }
})()

window.addEventListener('error', function(ev){
  try{ fetch('/__error', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({message: ev.message, filename: ev.filename, lineno: ev.lineno, stack: (ev.error && ev.error.stack)||null, ts: Date.now()})}) }catch(e){}
})

window.addEventListener('unhandledrejection', function(ev){
  try{ fetch('/__error', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({message: 'unhandledrejection', reason: String(ev.reason), ts: Date.now()})}) }catch(e){}
})

document.getElementById('paste').addEventListener('click', async ()=>{
  const status = document.getElementById('status')
  status.textContent = 'Чтение буфера...' 
  try{
    const text = await navigator.clipboard.readText()
    document.getElementById('url').value = text
    status.textContent = 'Вставлено из буфера.'
  }catch(e){
    const text = prompt('Вставьте ссылку из буфера сюда:')
    if(text) document.getElementById('url').value = text
    status.textContent = ''
  }
})

document.getElementById('process').addEventListener('click', async ()=>{
  const url = document.getElementById('url').value.trim()
  const status = document.getElementById('status')
  status.textContent = 'Отправка на обработку...'

  try{
    const canShare = !!(window.Telegram && window.Telegram.WebApp && typeof window.Telegram.WebApp.shareToStory === 'function')
    if(!canShare){
      status.textContent = 'Публикация историй недоступна для этого аккаунта.'
      return
    }

    const data = await postProcess(url, canShare)
    if(data.error){ status.textContent = 'Ошибка: ' + data.error; return }
    // If server returned video title, show it in eyebrow (same style as before)
    try{
      if(data.title){
        const brow = document.querySelector('.eyebrow')
        if(brow) brow.innerText = data.title
        // also update document title
        try{ document.title = data.title }catch(e){}
      }
    }catch(e){}
    // если сервер вернул прямой processed_url — используем его сразу
    if(data.processed_url){
      const processed = data.processed_url
      status.innerHTML = 'Готово. Попробовать опубликовать: <a href="'+processed+'">файл</a>'
      if(window.Telegram && window.Telegram.WebApp && window.Telegram.WebApp.shareToStory){
        try{
          await window.Telegram.WebApp.shareToStory({url: processed})
          status.textContent = 'Открылся редактор историй.'
        }catch(e){
          status.textContent = 'Не удалось вызвать shareToStory: ' + e.message
        }
      } else {
        status.textContent += ' — откройте эту страницу в Telegram и нажмите кнопку снова.'
      }
      return
    }

    // иначе ожидаем job_id и показываем UX кнопку для открытия редактора
    const jobId = data.job_id || data.id || null
    if(jobId){
      const publishUrl = '/publish?job_id=' + encodeURIComponent(jobId)
      status.innerHTML = 'Задача поставлена в очередь. <button id="openPub">Открыть редактор историй</button>'
      document.getElementById('openPub').addEventListener('click', ()=>{
        // открываем страницу редактора в текущем окне
        window.location.href = publishUrl
      })
      // если мы внутри Telegram, попробуем открыть страницу в WebView (замена действия)
      try{
        if(window.Telegram && window.Telegram.WebApp){
          // просто навигация должна работать в WebView
        }
      }catch(e){}
      return
    }

    status.textContent = 'Сервер вернул неожиданный ответ.'
  }catch(e){
    status.textContent = 'Ошибка запроса: ' + e.message
  }
})
