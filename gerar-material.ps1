# ============================================================
#  GERADOR DE MATERIAL — Gabriel & Liza (Brazilian Zouk)
#  Gera, a partir do index.html e das fotos da pasta:
#    1) material-gabriel-liza-pagina-completa.png (prévia das folhas A4)
#    2) material-gabriel-liza-pagina-completa.jpg (a mesma, comprimida)
#    3) material-gabriel-liza-colorido.pdf      (PDF A4 colorido, igual ao site)
#    4) material-gabriel-liza.pdf               (PDF A4 institucional branco)
#    5) material-gabriel-liza-folhas-a4.pdf     (PDF A4 igual ao visual)
#
#  Como usar: dê dois cliques no arquivo "gerar-material.bat"
#  ou execute no PowerShell:  .\gerar-material.ps1
# ============================================================

$ErrorActionPreference = "Stop"

# ---- localiza o Chrome (ou Edge) instalado ----
function Find-Browser {
  $candidates = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c)) { return $c }
  }
  return $null
}

$projeto = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($projeto)) { $projeto = (Get-Location).Path }
$chrome = Find-Browser
if (-not $chrome) { Write-Host "ERRO: Chrome ou Edge nao encontrado no computador." -ForegroundColor Red; exit 1 }

$html  = Join-Path $projeto "index.html"
$css   = Join-Path $projeto "style.css"
$cssColor = Join-Path $projeto "print-site.css"
if (-not (Test-Path -LiteralPath $html)) {
  Write-Host "ERRO: index.html nao encontrado na pasta $projeto" -ForegroundColor Red; exit 1
}
if (-not (Test-Path -LiteralPath $css)) {
  Write-Host "ERRO: style.css nao encontrado na pasta $projeto" -ForegroundColor Red; exit 1
}

$pngFinal = Join-Path $projeto "material-gabriel-liza-pagina-completa.png"
$jpgFinal = Join-Path $projeto "material-gabriel-liza-pagina-completa.jpg"
$pdfColor = Join-Path $projeto "material-gabriel-liza-colorido.pdf"
$pdfWhite = Join-Path $projeto "material-gabriel-liza.pdf"
$pdfFolhas = Join-Path $projeto "material-gabriel-liza-folhas-a4.pdf"
$tmpDir   = Join-Path $env:TEMP "opencode\gerador-danca"
if (-not (Test-Path -LiteralPath $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }

# variante colorida (usa print-site.css) — necessaria para o PDF colorido
$colorHtml = Join-Path $projeto "_color.html"
try {
  $h = Get-Content -LiteralPath $html -Raw -Encoding UTF8
  $h = $h.Replace('href="style.css"', 'href="print-site.css"')
  Set-Content -LiteralPath $colorHtml -Value $h -Encoding UTF8

  # ============================================================
  #  CLIENTE CDP — fala diretamente com o Chrome headless
  # ============================================================
  function Invoke-Cdp([string]$fileUrl, [string]$action, [string]$outFile, [int]$width, [int]$height) {
    $port = Get-Random -Minimum 9400 -Maximum 9800
    $ud = Join-Path $tmpDir "profile-$action-$port"
    if (Test-Path -LiteralPath $ud) { Remove-Item -LiteralPath $ud -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $ud -Force | Out-Null

    $proc = Start-Process -FilePath $chrome -ArgumentList @(
      "--headless", "--disable-gpu", "--no-sandbox", "--enable-unsafe-swiftshader",
      "--remote-debugging-port=$port", "--user-data-dir=$ud", "about:blank"
    ) -PassThru -WindowStyle Hidden

    $ws = $null
    $bg = $null
    try {
      $ready = $false
      for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        try {
          $v = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/version" -TimeoutSec 2
          if ($v.webSocketDebuggerUrl) { $ready = $true; break }
        } catch { }
      }
      if (-not $ready) { throw "DevTools indisponivel" }

      $target = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/new?$fileUrl" -Method Put -TimeoutSec 5
      if (-not $target.webSocketDebuggerUrl) { throw "Sem pagina CDP" }

      $ws = [System.Net.WebSockets.ClientWebSocket]::new()
      [void]$ws.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()

      $script:cdpMsgId = 0
      $global:cdpQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[object]
      $global:cdpEvents = New-Object System.Collections.Concurrent.ConcurrentQueue[object]
      $global:cdpStop   = [Threading.CancellationTokenSource]::new()
      $global:cdpSocket = $ws

      $pumpCode = @'
param($socket, $queue, $events, $stop)
try {
  $sb = New-Object System.Text.StringBuilder
  $buffer = New-Object byte[] 1048576
  while (-not $stop.IsCancellationRequested) {
    $rev = $socket.ReceiveAsync([ArraySegment[byte]]::new($buffer), [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    if ($rev.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Text) {
      [void]$sb.Append([Text.Encoding]::UTF8.GetString($buffer, 0, $rev.Count))
    }
    if ($rev.EndOfMessage) {
      if ($sb.Length -gt 0) {
        try { $m = $sb.ToString() | ConvertFrom-Json } catch { $m = $null }
        if ($m) { if ($m.method) { $events.Enqueue($m) } else { $queue.Enqueue($m) } }
      }
      [void]$sb.Clear()
    }
  }
} catch { }
'@
      $bg = [PowerShell]::Create()
      [void]$bg.AddScript($pumpCode)
      [void]$bg.AddArgument($ws).AddArgument($global:cdpQueue).AddArgument($global:cdpEvents).AddArgument($global:cdpStop)
      [void]$bg.BeginInvoke()

      function Send-Cdp([string]$method, $params) {
        $script:cdpMsgId = $script:cdpMsgId + 1
        $id = $script:cdpMsgId
        $obj = @{ id = $id; method = $method }
        if ($params) { $obj.params = $params }
        $data = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Compress -Depth 6))
        $seg = [ArraySegment[byte]]::new($data)
        [void]$ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        return $id
      }
      function Wait-Response([int]$id, [int]$timeoutSec = 40) {
        $deadline = [Environment]::TickCount + ($timeoutSec * 1000)
        while ([Environment]::TickCount -lt $deadline) {
          $m = $null
          if ($global:cdpQueue.TryDequeue([ref]$m)) { if ($m.id -eq $id) { return $m } }
          Start-Sleep -Milliseconds 20
        }
        return $null
      }
      function Wait-Event([string]$name, [int]$timeoutSec = 20) {
        $deadline = [Environment]::TickCount + ($timeoutSec * 1000)
        while ([Environment]::TickCount -lt $deadline) {
          $m = $null
          if ($global:cdpEvents.TryDequeue([ref]$m)) { if ($m.method -eq $name) { return $m } }
          Start-Sleep -Milliseconds 20
        }
        return $null
      }

      [void](Send-Cdp "Page.enable" $null)
      [void](Wait-Response ($script:cdpMsgId) 5)

      if ($action -eq "shot") {
        [void](Send-Cdp "Emulation.setDeviceMetricsOverride" @{
          width = $width; height = $height; deviceScaleFactor = 1; mobile = $false
        })
        [void](Wait-Response ($script:cdpMsgId) 5)
      }

      [void](Send-Cdp "Page.navigate" @{ url = $fileUrl })
      $loaded = Wait-Event "Page.loadEventFired" 20
      if (-not $loaded) { throw "Pagina nao carregou" }

      if ($action -eq "shot") {
        $cid = Send-Cdp "Page.captureScreenshot" @{ format = "png"; captureBeyondViewport = $true; fromSurface = $true }
        $r = Wait-Response $cid 30
        if (-not $r -or -not $r.result.data) { throw "Falha no screenshot" }
        [IO.File]::WriteAllBytes($outFile, [Convert]::FromBase64String($r.result.data))
      }
      else {
        $pid_ = Send-Cdp "Page.printToPDF" @{
          printBackground = $true
          preferCSSPageSize = $false
          paperWidth = 210; paperHeight = 297
          scale = 1
          displayHeaderFooter = $false
          marginTop = 0; marginBottom = 0; marginLeft = 0; marginRight = 0
        }
        $r = Wait-Response $pid_ 45
        if (-not $r -or -not $r.result.data) { throw "Falha no printToPDF" }
        [IO.File]::WriteAllBytes($outFile, [Convert]::FromBase64String($r.result.data))
      }
    }
    finally {
      try { $global:cdpStop.Cancel() } catch { }
      if ($ws) { try { $ws.Dispose() } catch { } }
      if ($bg) { try { $bg.Runspace.Close() } catch { }; try { $bg.Dispose() } catch { } }
      if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    }
  }

  function Invoke-CdpRetry([string]$fileUrl, [string]$action, [string]$outFile, [int]$width, [int]$height) {
    for ($n = 1; $n -le 3; $n++) {
      try {
        Invoke-Cdp $fileUrl $action $outFile $width $height
        return
      } catch {
        Write-Host ("  tentativa {0} falhou ({1}) - tentando de novo..." -f $n, $_.Exception.Message) -ForegroundColor Yellow
        Start-Sleep -Seconds 3
      }
    }
    throw "Falhou apos 3 tentativas: $($_.Exception.Message)"
  }

  # ---------- 1) imagem completa (PNG) ----------
  $uriShot = [System.Uri]::new((Join-Path $projeto "index.html")).AbsoluteUri
  Write-Host "Gerando imagem completa (PNG)..." -ForegroundColor Cyan
  Invoke-CdpRetry $uriShot "shot" $pngFinal 850 900

  # ---------- 2) JPG comprimido ----------
  Write-Host "Gerando JPG comprimido..." -ForegroundColor Cyan
  Add-Type -AssemblyName System.Drawing
  $img = [System.Drawing.Image]::FromFile($pngFinal)
  $enc = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq "image/jpeg" }
  $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
  $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]88)
  $img.Save($jpgFinal, $enc, $ep)
  $img.Dispose()

  # ---------- 3) PDF colorido ----------
  $uriColor = [System.Uri]::new($colorHtml).AbsoluteUri
  Write-Host "Gerando PDF colorido (A4)..." -ForegroundColor Cyan
  $pdfColorTmp = Join-Path $tmpDir "color.pdf"
  $pro = Start-Process -FilePath $chrome -ArgumentList @(
    "--headless", "--disable-gpu", "--no-sandbox", "--no-pdf-header-footer",
    "--user-data-dir=$(Join-Path $tmpDir 'color-pro')",
    "--print-to-pdf=$pdfColorTmp", $uriColor
  ) -Wait -PassThru -WindowStyle Hidden
  Start-Sleep -Seconds 1
  if (Test-Path -LiteralPath $pdfColorTmp) { Move-Item -LiteralPath $pdfColorTmp -Destination $pdfColor -Force }

  # ---------- 4) PDF branco (institucional) ----------
  $brancoHtml = Join-Path $projeto "_branco.html"
  $bhContent = Get-Content -LiteralPath $html -Raw -Encoding UTF8
  $bhContent = $bhContent.Replace('</head>', '  <link rel="stylesheet" href="print-white.css">' + [Environment]::NewLine + '</head>')
  Set-Content -LiteralPath $brancoHtml -Value $bhContent -Encoding UTF8
  $uriWhite = [System.Uri]::new($brancoHtml).AbsoluteUri
  Write-Host "Gerando PDF A4 institucional (branco)..." -ForegroundColor Cyan
  $pdfWhiteTmp = Join-Path $tmpDir "white.pdf"
  $pro = Start-Process -FilePath $chrome -ArgumentList @(
    "--headless", "--disable-gpu", "--no-sandbox", "--no-pdf-header-footer",
    "--user-data-dir=$(Join-Path $tmpDir 'white-pro')",
    "--print-to-pdf=$pdfWhiteTmp", $uriWhite
  ) -Wait -PassThru -WindowStyle Hidden
  Start-Sleep -Seconds 1
  if (Test-Path -LiteralPath $pdfWhiteTmp) { Move-Item -LiteralPath $pdfWhiteTmp -Destination $pdfWhite -Force }

  # ---------- 5) PDF de folhas A4 (igual ao visual) ----------
  Write-Host "Gerando PDF de folhas A4 (igual ao visual)..." -ForegroundColor Cyan
  $pdfFolhasTmp = Join-Path $tmpDir "folhas.pdf"
  $pro3 = Start-Process -FilePath $chrome -ArgumentList @(
    "--headless", "--disable-gpu", "--no-sandbox", "--no-pdf-header-footer",
    "--user-data-dir=$(Join-Path $tmpDir 'folhas-pro')",
    "--print-to-pdf=$pdfFolhasTmp", $uriColor
  ) -Wait -PassThru -WindowStyle Hidden
  Start-Sleep -Seconds 1
  if (Test-Path -LiteralPath $pdfFolhasTmp) { Move-Item -LiteralPath $pdfFolhasTmp -Destination $pdfFolhas -Force }

  Write-Host ""
  Write-Host "Concluido! Arquivos gerados em:" -ForegroundColor Green
  Write-Host ("  " + $pngFinal) -ForegroundColor Green
  Write-Host ("  " + $jpgFinal) -ForegroundColor Green
  Write-Host ("  " + $pdfColor) -ForegroundColor Green
  Write-Host ("  " + $pdfWhite) -ForegroundColor Green
  Write-Host ("  " + $pdfFolhas) -ForegroundColor Green
}
finally {
  Remove-Item -LiteralPath $colorHtml -ErrorAction SilentlyContinue
  if ($brancoHtml) { Remove-Item -LiteralPath $brancoHtml -ErrorAction SilentlyContinue }
  Get-Process chrome -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($tmpDir) } | Stop-Process -Force -ErrorAction SilentlyContinue
}