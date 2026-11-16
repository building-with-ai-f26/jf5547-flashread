# Serves this folder at http://localhost:8000 using only built-in Windows PowerShell.
# Run from the repository root:
#   powershell -ExecutionPolicy Bypass -File app\serve.ps1
# Press Ctrl+C to stop.
#
# Optional: POST /api/summarize reads OPENROUTER_API_KEY from the repository .env
# file and asks OpenRouter for a short summary. The key is never sent to the browser.

param([int]$Port = 8000)

$ErrorActionPreference = "Stop"

$root = [System.IO.Path]::GetFullPath($PSScriptRoot)
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $root ".."))
$envFile = Join-Path $repoRoot ".env"
$summaryModel = "openai/gpt-4o-mini"
$maxSummaryChars = 6000

$types = @{
  ".html" = "text/html; charset=utf-8"
  ".css"  = "text/css"
  ".js"   = "text/javascript"
  ".png"  = "image/png"
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Host "FlashRead is running at http://localhost:$Port"
Write-Host "Press Ctrl+C to stop."
Start-Process "http://localhost:$Port"

function Send($stream, [string]$status, [string]$type, [byte[]]$body) {
  $head = "HTTP/1.1 $status`r`nContent-Type: $type`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
  $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
  $stream.Write($headBytes, 0, $headBytes.Length)
  if ($body.Length -gt 0) {
    $stream.Write($body, 0, $body.Length)
  }
}

function Send-Json($stream, [string]$status, $obj) {
  $json = $obj | ConvertTo-Json -Compress -Depth 6
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

function Receive-Request($stream) {
  $stream.ReadTimeout = 3000
  $data = New-Object System.Collections.Generic.List[byte]
  $tmp = New-Object byte[] 4096
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

    if ($headerLength -ge 0 -and $contentLength -gt 80000) {
      return @{ TooLarge = $true }
    }
    if ($headerLength -ge 0 -and $data.Count -ge ($headerLength + $contentLength)) {
      break
    }
    if ($data.Count -gt 120000) {
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

function Handle-Summarize($stream, [string]$body) {
  $payload = $null
  try {
    $payload = $body | ConvertFrom-Json
  } catch {
    Send-Json $stream "400 Bad Request" @{ error = "Upload a text-based PDF before asking for a summary." }
    return
  }

  $text = [string]$payload.text
  if (-not $text -or $text.Trim().Length -eq 0) {
    Send-Json $stream "400 Bad Request" @{ error = "Upload a text-based PDF before asking for a summary." }
    return
  }

  $apiKey = Read-EnvValue $envFile "OPENROUTER_API_KEY"
  if (-not $apiKey) {
    Send-Json $stream "503 Service Unavailable" @{
      error = "The AI summary needs an OpenRouter key in the .env file in the project folder. Add the key, restart the server, and click the button again."
    }
    return
  }

  $truncated = $false
  $excerpt = $text
  if ($excerpt.Length -gt $maxSummaryChars) {
    $excerpt = $excerpt.Substring(0, $maxSummaryChars)
    $truncated = $true
  }

  $systemPrompt = "You summarize academic readings for a student. Write one short paragraph in plain English. Use only the text given. Do not add citations, headings, or a bullet list."
  $requestJson = @{
    model      = $summaryModel
    max_tokens = 180
    messages   = @(
      @{ role = "system"; content = $systemPrompt }
      @{ role = "user"; content = $excerpt }
    )
  } | ConvertTo-Json -Compress -Depth 6

  try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    $response = Invoke-RestMethod -Method Post -Uri "https://openrouter.ai/api/v1/chat/completions" -Headers @{
      Authorization    = "Bearer $apiKey"
      "HTTP-Referer"   = "http://localhost:$Port"
      "X-Title"        = "FlashRead"
    } -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($requestJson))
  } catch {
    Write-Host "Summary request failed."
    Send-Json $stream "502 Bad Gateway" @{
      error = "The AI service did not return a summary. Check the OpenRouter key and try again."
    }
    return
  }

  $summary = [string]$response.choices[0].message.content
  if (-not $summary -or $summary.Trim().Length -eq 0) {
    Send-Json $stream "502 Bad Gateway" @{
      error = "The AI service did not return a summary. Check the OpenRouter key and try again."
    }
    return
  }

  Write-Host "Summarized $($excerpt.Length) characters."
  Send-Json $stream "200 OK" @{
    summary          = $summary.Trim()
    model            = $summaryModel
    characters_sent  = $excerpt.Length
    truncated        = $truncated
  }
}

try {
  while ($true) {
    # Polling keeps Ctrl+C working; a blocking accept would ignore it.
    if (-not $listener.Pending()) { Start-Sleep -Milliseconds 100; continue }
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      $request = Receive-Request $stream
      if (-not $request) { continue }

      if ($request.TooLarge) {
        Send-Json $stream "413 Payload Too Large" @{ error = "That reading is too large to summarize in one request." }
        continue
      }

      if ($request.Method -eq "POST" -and $request.Path -eq "/api/summarize") {
        Handle-Summarize $stream $request.Body
        continue
      }

      if ($request.Method -ne "GET") {
        Send $stream "405 Method Not Allowed" "text/plain" ([System.Text.Encoding]::ASCII.GetBytes("Method not allowed"))
        continue
      }

      $path = $request.Path
      if ($path -eq "/") { $path = "/index.html" }
      $file = [System.IO.Path]::GetFullPath((Join-Path $root $path.TrimStart("/")))

      if ($file.StartsWith($root) -and (Test-Path -LiteralPath $file -PathType Leaf)) {
        $type = $types[[System.IO.Path]::GetExtension($file).ToLower()]
        if (-not $type) { $type = "application/octet-stream" }
        Send $stream "200 OK" $type ([System.IO.File]::ReadAllBytes($file))
      } else {
        Send $stream "404 Not Found" "text/plain" ([System.Text.Encoding]::ASCII.GetBytes("Not found"))
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
