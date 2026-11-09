# Serves this folder at http://localhost:8000 using only built-in Windows PowerShell.
# Run from the repository root:
#   powershell -ExecutionPolicy Bypass -File app\serve.ps1
# Press Ctrl+C to stop.

param([int]$Port = 8000)

$ErrorActionPreference = "Stop"

$root = [System.IO.Path]::GetFullPath($PSScriptRoot)
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
  $stream.Write($body, 0, $body.Length)
}

try {
  while ($true) {
    # Polling keeps Ctrl+C working; a blocking accept would ignore it.
    if (-not $listener.Pending()) { Start-Sleep -Milliseconds 100; continue }
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      # Browsers open spare connections that may never send a request; don't wait on them forever.
      $stream.ReadTimeout = 2000
      $reader = [System.IO.StreamReader]::new($stream)
      $requestLine = $reader.ReadLine()
      $path = "/"
      if ($requestLine -match "^GET\s+([^\s?]+)") { $path = [Uri]::UnescapeDataString($Matches[1]) }
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
