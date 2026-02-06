async function postProcess(url){
  const res = await fetch('/process', {
    method: 'POST',
    headers: {'Content-Type':'application/json'},
    body: JSON.stringify({url})
  })
  return res.json()
}

document.getElementById('process').addEventListener('click', async ()=>{
  const url = document.getElementById('url').value.trim()
  const status = document.getElementById('status')
  status.textContent = 'Отправка на обработку...'

  try{
    const data = await postProcess(url)
    if(data.error){ status.textContent = 'Ошибка: ' + data.error; return }
    const processed = data.processed_url
    status.innerHTML = 'Готово. Попробовать опубликовать: <a href="'+processed+'">файл</a>'

    // Если WebApp API доступен — используем shareToStory
    if(window.Telegram && Telegram.WebApp && Telegram.WebApp.shareToStory){
      try{
        await Telegram.WebApp.shareToStory({url: processed})
        status.textContent = 'Открылся редактор историй.'
      }catch(e){
        status.textContent = 'Не удалось вызвать shareToStory: ' + e.message
      }
    } else {
      status.textContent += ' — откройте эту страницу в Telegram и нажмите кнопку снова.'
    }
  }catch(e){
    status.textContent = 'Ошибка запроса: ' + e.message
  }
})
