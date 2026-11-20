# Serves this folder at http://localhost:8000 using only built-in Windows PowerShell.
# Run from the repository root:
#   powershell -ExecutionPolicy Bypass -File app\serve.ps1
# Press Ctrl+C to stop.
#
# AI routes read OPENROUTER_API_KEY from the repository .env file (or from the
# process environment) and call OpenRouter. The key is never sent to the browser.
#   POST /api/summarize   short summary of extracted text
#   POST /api/quiz        five multiple-choice questions as JSON
#   POST /api/podcast     narration script, then a local WAV from Windows speech
# Podcast audio is written under app/narration/ and is not a cloud voice.

param([int]$Port = 8000)

$ErrorActionPreference = "Stop"

$root = [System.IO.Path]::GetFullPath($PSScriptRoot)
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $root ".."))
$envFile = Join-Path $repoRoot ".env"
$narrationDir = Join-Path $root "narration"
$summaryModel = "openai/gpt-4o-mini"
$speechModel = "elevenlabs/eleven-v3-conversational"
$speechVoice = "sarah"
$maxBodyBytes = 500000
$chunkChars = 8000
$maxChunks = 3
$quizChars = 12000
$podcastChars = 12000
$maxScriptChars = 2800

$types = @{
  ".html" = "text/html; charset=utf-8"
  ".css"  = "text/css"
  ".js"   = "text/javascript"
  ".png"  = "image/png"
  ".jpg"  = "image/jpeg"
  ".mp4"  = "video/mp4"
  ".wav"  = "audio/wav"
  ".mp3"  = "audio/mpeg"
  ".pdf"  = "application/pdf"
}

New-Item -ItemType Directory -Force -Path $narrationDir | Out-Null

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
try {
  $listener.Start()
} catch {
  Write-Host "FlashRead could not use port $Port. If it is already running, use that window or press Ctrl+C there first."
  throw
}
Write-Host "FlashRead is running at http://localhost:$Port"
Write-Host "Press Ctrl+C to stop."
Start-Process "http://localhost:$Port"

function Send($stream, [string]$status, [string]$type, [byte[]]$body) {
  $head = "HTTP/1.1 $status`r`nContent-Type: $type`r`nContent-Length: $($body.Length)`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n"
  $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
  $stream.Write($headBytes, 0, $headBytes.Length)
  if ($body.Length -gt 0) {
    $stream.Write($body, 0, $body.Length)
  }
}

function Send-Json($stream, [string]$status, $obj) {
  $json = $obj | ConvertTo-Json -Compress -Depth 8
  Send $stream $status "application/json; charset=utf-8" ([System.Text.Encoding]::UTF8.GetBytes($json))
}

function Read-EnvValue([string]$path, [string]$name) {
  if (-not (Test-Path -LiteralPath $path)) {
    return $null
  }
  foreach ($line in [System.IO.File]::ReadAllLines($path)) {
    if ($line -match '^\s*#' -or $line -notmatch '=') {
      continue
    }
    $parts = $line.Split("=", 2)
    if ($parts[0].Trim() -ne $name) {
      continue
    }
    $value = $parts[1].Trim().Trim('"').Trim("'")
    if (-not $value -or $value -match "replace-with") {
      return $null
    }
    return $value
  }
  return $null
}

function Get-OpenRouterKey {
  $key = Read-EnvValue $envFile "OPENROUTER_API_KEY"
  if ($key) {
    return $key
  }
  $fromProcess = [Environment]::GetEnvironmentVariable("OPENROUTER_API_KEY")
  if ($fromProcess -and $fromProcess -notmatch "replace-with") {
    return $fromProcess.Trim()
  }
  return $null
}

function Receive-Request($stream) {
  $stream.ReadTimeout = 3000
  $data = New-Object System.Collections.Generic.List[byte]
  $tmp = New-Object byte[] 8192
  $headerLength = -1
  $contentLength = 0

  while ($true) {
    $n = 0
    try {
      $n = $stream.Read($tmp, 0, $tmp.Length)
    } catch {
      break
    }
    if ($n -le 0) { break }
    for ($i = 0; $i -lt $n; $i++) { $data.Add($tmp[$i]) }

    if ($headerLength -lt 0 -and $data.Count -ge 4) {
      $limit = $data.Count - 4
      for ($i = 0; $i -le $limit; $i++) {
        if ($data[$i] -eq 13 -and $data[$i + 1] -eq 10 -and $data[$i + 2] -eq 13 -and $data[$i + 3] -eq 10) {
          $headerLength = $i + 4
          $headerText = [System.Text.Encoding]::ASCII.GetString($data.ToArray(), 0, $headerLength)
          if ($headerText -match "(?im)^Content-Length:\s*(\d+)") {
            $contentLength = [int]$Matches[1]
          }
          break
        }
      }
    }

    if ($headerLength -ge 0 -and $contentLength -gt $maxBodyBytes) {
      return @{ TooLarge = $true }
    }
    if ($headerLength -ge 0 -and $data.Count -ge ($headerLength + $contentLength)) {
      break
    }
    if ($data.Count -gt ($maxBodyBytes + 20000)) {
      return @{ TooLarge = $true }
    }
  }

  if ($headerLength -lt 0) {
    return $null
  }

  $headerText = [System.Text.Encoding]::ASCII.GetString($data.ToArray(), 0, $headerLength)
  $requestLine = ($headerText -split "`r`n")[0]
  $method = "GET"
  $target = "/"
  if ($requestLine -match "^(GET|POST)\s+(\S+)") {
    $method = $Matches[1]
    $target = $Matches[2]
  }
  $path = ($target -split "\?")[0]
  $path = [Uri]::UnescapeDataString($path)

  $body = ""
  if ($contentLength -gt 0 -and $data.Count -gt $headerLength) {
    $count = [Math]::Min($contentLength, $data.Count - $headerLength)
    $bodyBytes = New-Object byte[] $count
    for ($i = 0; $i -lt $count; $i++) { $bodyBytes[$i] = $data[$headerLength + $i] }
    $body = [System.Text.Encoding]::UTF8.GetString($bodyBytes)
  }

  return @{
    TooLarge = $false
    Method   = $method
    Path     = $path
    Body     = $body
  }
}

function Get-RequestText([string]$body) {
  try {
    $payload = $body | ConvertFrom-Json
  } catch {
    return $null
  }
  return ([string]$payload.text)
}

function Get-MessageText($response) {
  $content = $response.choices[0].message.content
  if ($content -is [string]) {
    return $content
  }
  if ($null -eq $content) {
    return ""
  }
  $parts = @()
  foreach ($part in @($content)) {
    if ($part -is [string]) {
      $parts += $part
    } elseif ($part.text) {
      $parts += [string]$part.text
    }
  }
  return ($parts -join "")
}

function Invoke-OpenRouter([string]$ApiKey, [string]$System, [string]$UserText, [int]$MaxTokens) {
  $requestJson = @{
    model      = $summaryModel
    max_tokens = $MaxTokens
    messages   = @(
      @{ role = "system"; content = $System }
      @{ role = "user"; content = $UserText }
    )
  } | ConvertTo-Json -Compress -Depth 8

  [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
  $response = Invoke-RestMethod -Method Post -Uri "https://openrouter.ai/api/v1/chat/completions" -Headers @{
    Authorization  = "Bearer $ApiKey"
    "HTTP-Referer" = "http://localhost:$Port"
    "X-Title"      = "FlashRead"
  } -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($requestJson)) -TimeoutSec 90

  return (Get-MessageText $response)
}

function Split-ForModel([string]$text, [int]$size, [int]$maxCount) {
  $chunks = New-Object System.Collections.Generic.List[string]
  $start = 0
  while ($start -lt $text.Length -and $chunks.Count -lt $maxCount) {
    $len = [Math]::Min($size, $text.Length - $start)
    if (($start + $len) -lt $text.Length) {
      $window = $text.Substring($start, $len)
      $breakAt = $window.LastIndexOf(" ")
      if ($breakAt -gt [int]($len * 0.6)) {
        $len = $breakAt
      }
    }
    $piece = $text.Substring($start, $len).Trim()
    if ($piece.Length -gt 0) {
      $chunks.Add($piece)
    }
    $start += [Math]::Max($len, 1)
  }
  $result = @{
    Chunks    = $chunks.ToArray()
    Truncated = ($start -lt $text.Length)
  }
  return ,$result
}

function Require-Key($stream) {
  $apiKey = Get-OpenRouterKey
  if (-not $apiKey) {
    Send-Json $stream "503 Service Unavailable" @{
      error = "This action needs an OpenRouter key. Copy .env.example to .env, set OPENROUTER_API_KEY, restart the server, and try again."
    }
    return $null
  }
  return $apiKey
}

function Handle-Summarize($stream, [string]$body) {
  $text = Get-RequestText $body
  if (-not $text -or $text.Trim().Length -eq 0) {
    Send-Json $stream "400 Bad Request" @{ error = "Upload a text-based PDF before asking for a summary." }
    return
  }

  $apiKey = Require-Key $stream
  if (-not $apiKey) { return }

  $text = $text.Trim()
  $parts = Split-ForModel $text $chunkChars $maxChunks
  $clean = New-Object System.Collections.Generic.List[string]
  foreach ($piece in @($parts.Chunks)) {
    $value = ([string]$piece).Trim()
    if ($value.Length -gt 0) { $clean.Add($value) }
  }
  if ($clean.Count -eq 0) {
    Send-Json $stream "400 Bad Request" @{ error = "Upload a text-based PDF before asking for a summary." }
    return
  }
  $quality = "You summarize academic readings for a student. Write two to four short paragraphs in plain English. Cover the main points, important terms, and the conclusion. Keep important nuance. Use only the text given. Do not invent facts, citations, or examples. Do not use a title or a bullet list."
  $condense = "Condense this passage from an academic reading into one short paragraph. Use only these words. Do not invent facts."
  $requests = 0

  try {
    if ($clean.Count -eq 1) {
      $excerpt = $clean[0]
      $summary = Invoke-OpenRouter $apiKey $quality $excerpt 500
      $requests = 1
      $sent = $excerpt.Length
    } else {
      $notes = @()
      $sent = 0
      foreach ($chunk in $clean) {
        $note = Invoke-OpenRouter $apiKey $condense ([string]$chunk) 180
        $requests += 1
        $sent += ([string]$chunk).Length
        if (-not $note -or $note.Trim().Length -eq 0) {
          throw "Empty chunk summary"
        }
        $notes += $note.Trim()
      }
      $combine = "You are combining partial notes from one academic reading into a single summary. Write two to four short paragraphs in plain English. Cover the main points, important terms, and the conclusion. Use only these notes. Do not invent facts. The notes may stop before the end of the document.`n`n" + ($notes -join "`n`n")
      $summary = Invoke-OpenRouter $apiKey $quality $combine 500
      $requests += 1
    }
  } catch {
    Write-Host "Summary request failed."
    Send-Json $stream "502 Bad Gateway" @{
      error = "The AI service did not return a summary. Check the OpenRouter key and try again."
    }
    return
  }

  if (-not $summary -or $summary.Trim().Length -eq 0) {
    Send-Json $stream "502 Bad Gateway" @{
      error = "The AI service did not return a summary. Check the OpenRouter key and try again."
    }
    return
  }

  Write-Host "Summarized $sent characters in $requests request(s)."
  Send-Json $stream "200 OK" @{
    summary         = $summary.Trim()
    model           = $summaryModel
    characters_sent = $sent
    truncated       = [bool]$parts.Truncated
    requests        = $requests
  }
}

function Convert-QuizPayload([string]$raw) {
  $clean = $raw.Trim()
  if ($clean.StartsWith('```')) {
    $clean = [regex]::Replace($clean, '(?s)^```(?:json)?\s*', '')
    $clean = [regex]::Replace($clean, '\s*```$', '')
  }
  $start = $clean.IndexOf("{")
  $end = $clean.LastIndexOf("}")
  if ($start -ge 0 -and $end -gt $start) {
    $clean = $clean.Substring($start, $end - $start + 1)
  }
  $obj = $clean | ConvertFrom-Json
  $questions = @()
  foreach ($item in @($obj.questions)) {
    $choices = @()
    foreach ($choice in @($item.choices)) {
      $choices += ([string]$choice).Trim()
    }
    $answer = -1
    if ($null -ne $item.answer) {
      $answer = [int]$item.answer
    }
    $prompt = ([string]$item.question).Trim()
    $explanation = ([string]$item.explanation).Trim()
    if ($prompt.Length -eq 0 -or $choices.Count -ne 4) {
      continue
    }
    $blank = $false
    foreach ($choice in $choices) {
      if (-not $choice) { $blank = $true }
    }
    if ($blank -or $answer -lt 0 -or $answer -gt 3) {
      continue
    }
    $questions += @{
      question    = $prompt
      choices     = $choices
      answer      = $answer
      explanation = $explanation
    }
  }
  return @($questions)
}

function Handle-Quiz($stream, [string]$body) {
  $text = Get-RequestText $body
  if (-not $text -or $text.Trim().Length -eq 0) {
    Send-Json $stream "400 Bad Request" @{ error = "Upload a text-based PDF before asking for a quiz." }
    return
  }

  $apiKey = Require-Key $stream
  if (-not $apiKey) { return }

  $text = $text.Trim()
  $truncated = $false
  if ($text.Length -gt $quizChars) {
    $text = $text.Substring(0, $quizChars)
    $breakAt = $text.LastIndexOf(" ")
    if ($breakAt -gt [int]($quizChars * 0.8)) {
      $text = $text.Substring(0, $breakAt)
    }
    $truncated = $true
  }

  $system = "You write comprehension checks for a student who read the passage. Return only JSON with this shape: {""questions"":[{""question"":""..."",""choices"":[""..."",""..."",""..."",""...""],""answer"":0,""explanation"":""...""}]}. Produce exactly 5 questions. Each question has exactly 4 choices and one correct answer. answer is the index of the correct choice, from 0 to 3. Ask about ideas, relationships, and conclusions. Do not ask for a trivial single-word lookup. Use only the passage. Do not invent facts. The explanation must say why the correct choice matches the passage. No markdown."

  try {
    $raw = Invoke-OpenRouter $apiKey $system $text 900
    $questions = Convert-QuizPayload $raw
  } catch {
    Write-Host "Quiz request failed."
    Send-Json $stream "502 Bad Gateway" @{
      error = "The AI service did not return a usable quiz. Try again."
    }
    return
  }

  if ($questions.Count -lt 5) {
    Write-Host "Quiz JSON was incomplete."
    Send-Json $stream "502 Bad Gateway" @{
      error = "The AI service did not return five usable questions. Try again."
    }
    return
  }

  $selected = @($questions[0], $questions[1], $questions[2], $questions[3], $questions[4])
  Write-Host "Quiz ready. truncated=$truncated"
  Send-Json $stream "200 OK" @{
    questions       = $selected
    model           = $summaryModel
    characters_sent = $text.Length
    truncated       = $truncated
  }
}

function Remove-OldNarration {
  Get-ChildItem -LiteralPath $narrationDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -match '^\.(wav|mp3)$' -and $_.LastWriteTime -lt (Get-Date).AddHours(-12) } |
    Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-CloudNarration([string]$ApiKey, [string]$text, [string]$destination) {
  $requestJson = @{
    model           = $speechModel
    input           = $text
    voice           = $speechVoice
    response_format = "mp3"
  } | ConvertTo-Json -Compress

  [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Method Post -Uri "https://openrouter.ai/api/v1/audio/speech" -Headers @{
    Authorization  = "Bearer $ApiKey"
    "HTTP-Referer" = "http://localhost:$Port"
    "X-Title"      = "FlashRead"
  } -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($requestJson)) -OutFile $destination -TimeoutSec 120 | Out-Null
}

function Write-NarrationWav([string]$text, [string]$destination) {
  Add-Type -AssemblyName System.Speech
  $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
  $synth.Rate = -1
  try {
    $synth.SetOutputToWaveFile($destination)
    $synth.Speak($text)
  } finally {
    $synth.Dispose()
  }
}

function Handle-Podcast($stream, [string]$body) {
  $text = Get-RequestText $body
  if (-not $text -or $text.Trim().Length -eq 0) {
    Send-Json $stream "400 Bad Request" @{ error = "Upload a text-based PDF before creating a narration." }
    return
  }

  $apiKey = Require-Key $stream
  if (-not $apiKey) { return }

  $text = $text.Trim()
  $truncated = $false
  if ($text.Length -gt $podcastChars) {
    $text = $text.Substring(0, $podcastChars)
    $breakAt = $text.LastIndexOf(" ")
    if ($breakAt -gt [int]($podcastChars * 0.8)) {
      $text = $text.Substring(0, $breakAt)
    }
    $truncated = $true
  }

  $system = "You write a spoken educational narration of one document for a university student. Use one narrator. Open with the topic, explain the major ideas in order, and close with the key takeaways. Use only the source text. Do not invent studies, quotes, or facts. If the source is short, keep the narration short. Write plain sentences that can be read aloud. No titles, bullets, speaker labels, or stage directions. Aim for 250 to 400 words when the source is long enough."

  try {
    $script = Invoke-OpenRouter $apiKey $system $text 700
  } catch {
    Write-Host "Podcast script request failed."
    Send-Json $stream "502 Bad Gateway" @{
      error = "The AI service did not return a narration script. Check the OpenRouter key and try again."
    }
    return
  }

  if (-not $script -or $script.Trim().Length -eq 0) {
    Send-Json $stream "502 Bad Gateway" @{
      error = "The AI service did not return a narration script. Check the OpenRouter key and try again."
    }
    return
  }

  $script = $script.Trim() -replace '\*\*', '' -replace '`', ''
  if ($script.Length -gt $maxScriptChars) {
    $cut = $script.LastIndexOf(".", [Math]::Min($maxScriptChars, $script.Length - 1))
    if ($cut -lt [int]($maxScriptChars * 0.5)) {
      $cut = $maxScriptChars - 1
    }
    $script = $script.Substring(0, $cut + 1).Trim()
    $truncated = $true
  }

  Remove-OldNarration
  $id = [guid]::NewGuid().ToString("n")
  $mp3Path = Join-Path $narrationDir "$id.mp3"
  $wavPath = Join-Path $narrationDir "$id.wav"
  $audioPath = $mp3Path
  $audioUrl = "/narration/$id.mp3"
  $voiceName = "elevenlabs-sarah"
  try {
    Write-CloudNarration $apiKey $script $mp3Path
  } catch {
    Write-Host "Cloud narration failed. Using the Windows voice."
    if (Test-Path -LiteralPath $mp3Path) {
      Remove-Item -LiteralPath $mp3Path -Force -ErrorAction SilentlyContinue
    }
    try {
      Write-NarrationWav $script $wavPath
      $audioPath = $wavPath
      $audioUrl = "/narration/$id.wav"
      $voiceName = "windows-local"
    } catch {
      Write-Host "Local narration failed."
      if (Test-Path -LiteralPath $wavPath) {
        Remove-Item -LiteralPath $wavPath -Force -ErrorAction SilentlyContinue
      }
      Send-Json $stream "500 Internal Server Error" @{
        error = "The script was written, but this computer could not create the audio file."
      }
      return
    }
  }

  $audioBytes = 0
  if (Test-Path -LiteralPath $audioPath) {
    $audioBytes = (Get-Item -LiteralPath $audioPath).Length
  }
  if ($audioBytes -lt 1000) {
    if (Test-Path -LiteralPath $audioPath) {
      Remove-Item -LiteralPath $audioPath -Force -ErrorAction SilentlyContinue
    }
    Send-Json $stream "500 Internal Server Error" @{
      error = "This computer could not create a playable audio file."
    }
    return
  }

  Write-Host "Narration audio ready. voice=$voiceName bytes=$audioBytes"
  Send-Json $stream "200 OK" @{
    audio_url         = $audioUrl
    model             = $summaryModel
    characters_sent   = $text.Length
    script_characters = $script.Length
    audio_bytes       = $audioBytes
    truncated         = $truncated
    voice             = $voiceName
  }
}

function Send-File($stream, [string]$file) {
  $type = $types[[System.IO.Path]::GetExtension($file).ToLower()]
  if (-not $type) { $type = "application/octet-stream" }
  Send $stream "200 OK" $type ([System.IO.File]::ReadAllBytes($file))
}

try {
  while ($true) {
    if (-not $listener.Pending()) { Start-Sleep -Milliseconds 100; continue }
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      $request = Receive-Request $stream
      if (-not $request) { continue }

      if ($request.TooLarge) {
        Send-Json $stream "413 Payload Too Large" @{ error = "That document is too large to send in one request." }
        continue
      }

      if ($request.Method -eq "POST" -and $request.Path -eq "/api/summarize") {
        Handle-Summarize $stream $request.Body
        continue
      }
      if ($request.Method -eq "POST" -and $request.Path -eq "/api/quiz") {
        Handle-Quiz $stream $request.Body
        continue
      }
      if ($request.Method -eq "POST" -and $request.Path -eq "/api/podcast") {
        Handle-Podcast $stream $request.Body
        continue
      }

      if ($request.Method -ne "GET") {
        Send $stream "405 Method Not Allowed" "text/plain; charset=utf-8" ([System.Text.Encoding]::ASCII.GetBytes("Method not allowed"))
        continue
      }

      $path = $request.Path
      if ($path -eq "/") { $path = "/index.html" }
      $relative = $path.TrimStart("/").Replace("/", [System.IO.Path]::DirectorySeparatorChar)
      $file = [System.IO.Path]::GetFullPath((Join-Path $root $relative))
      $rootPrefix = $root.TrimEnd("\") + "\"

      if ($file.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $file -PathType Leaf)) {
        Send-File $stream $file
      } else {
        Send $stream "404 Not Found" "text/plain; charset=utf-8" ([System.Text.Encoding]::ASCII.GetBytes("Not found"))
      }
    } catch {
      # Usually an idle browser connection timing out; safe to ignore.
    } finally {
      $client.Close()
    }
  }
} finally {
  $listener.Stop()
}
