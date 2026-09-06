param(
    [string]$GameRoot = "",
    [switch]$Uninstall
)
$ErrorActionPreference = "Stop"
$DataRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ManifestPath = Join-Path $DataRoot "manifest.json"

function Get-Sha256([string]$Path) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $hasher.ComputeHash($stream)
        return ([BitConverter]::ToString($digest)).Replace("-", "").ToLowerInvariant()
    } finally {
        $hasher.Dispose()
        $stream.Dispose()
    }
}

function Set-Writable([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $info = Get-Item -LiteralPath $Path -Force
        if ($info.IsReadOnly) { $info.IsReadOnly = $false }
    }
}

function Get-SafeTarget([string]$Root, [string]$Relative) {
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $target = [IO.Path]::GetFullPath((Join-Path $rootFull $Relative.Replace('/', [IO.Path]::DirectorySeparatorChar)))
    if (-not $target.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "안전하지 않은 대상 경로입니다: $Relative"
    }
    return $target
}

function Copy-Exact([IO.Stream]$SourceStream, [IO.Stream]$DestinationStream, [Int64]$Length) {
    $buffer = New-Object byte[] (1024 * 1024)
    $remaining = $Length
    while ($remaining -gt 0) {
        $want = [Math]::Min([Int64]$buffer.Length, $remaining)
        $read = $SourceStream.Read($buffer, 0, [int]$want)
        if ($read -le 0) { throw "패치 데이터가 예기치 않게 끝났습니다." }
        $DestinationStream.Write($buffer, 0, $read)
        $remaining -= $read
    }
}

function Apply-NfbDelta([string]$SourcePath, [string]$PatchPath, [string]$TempPath) {
    $source = [IO.File]::Open($SourcePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $packed = [IO.File]::OpenRead($PatchPath)
    $gzip = New-Object IO.Compression.GZipStream($packed, [IO.Compression.CompressionMode]::Decompress)
    $reader = New-Object IO.BinaryReader($gzip)
    $output = [IO.File]::Open($TempPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $magic = [Text.Encoding]::ASCII.GetString($reader.ReadBytes(8))
        if ($magic -ne "NFBP2`0`r`n") { throw "지원하지 않는 패치 형식입니다: $PatchPath" }
        [Int64]$sourceSize = $reader.ReadUInt64()
        [Int64]$targetSize = $reader.ReadUInt64()
        [UInt32]$opCount = $reader.ReadUInt32()
        if ($source.Length -ne $sourceSize) { throw "원본 파일 크기가 맞지 않습니다: $SourcePath" }
        for ($i = 0; $i -lt $opCount; $i++) {
            $opcode = [char]$reader.ReadByte()
            if ($opcode -eq 'C') {
                [Int64]$offset = $reader.ReadUInt64()
                [Int64]$length = $reader.ReadUInt64()
                if ($offset -lt 0 -or $length -lt 0 -or ($offset + $length) -gt $source.Length) {
                    throw "COPY 범위가 원본 파일을 벗어났습니다."
                }
                $null = $source.Seek($offset, [IO.SeekOrigin]::Begin)
                Copy-Exact $source $output $length
            } elseif ($opcode -eq 'A') {
                [Int64]$length = $reader.ReadUInt64()
                Copy-Exact $gzip $output $length
            } else {
                throw "알 수 없는 패치 명령입니다: $opcode"
            }
        }
        if ($output.Length -ne $targetSize) { throw "생성 파일 크기 검증에 실패했습니다." }
    } finally {
        $output.Dispose(); $reader.Dispose(); $gzip.Dispose(); $packed.Dispose(); $source.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "manifest.json을 찾지 못했습니다." }
$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($GameRoot) -or -not (Test-Path -LiteralPath (Join-Path $GameRoot "NotForBroadcast.exe") -PathType Leaf)) {
    Write-Host "Not For Broadcast 설치 폴더를 입력해 주세요."
    $GameRoot = Read-Host "게임 폴더"
}
$GameRoot = [IO.Path]::GetFullPath($GameRoot)
if (-not (Test-Path -LiteralPath (Join-Path $GameRoot "NotForBroadcast.exe") -PathType Leaf)) {
    throw "NotForBroadcast.exe를 찾지 못했습니다: $GameRoot"
}
$running = Get-Process -Name "NotForBroadcast" -ErrorAction SilentlyContinue
if ($running) { throw "게임을 종료한 뒤 다시 실행해 주세요." }

$buildFile = Join-Path $GameRoot "buildid.txt"
if (-not (Test-Path -LiteralPath $buildFile -PathType Leaf)) { throw "buildid.txt를 찾지 못했습니다." }
$build = (Get-Content -LiteralPath $buildFile -Raw).Trim()
if ($build -ne [string]$manifest.game_build) {
    throw "지원하지 않는 게임 빌드입니다. 필요: $($manifest.game_build), 현재: $build"
}

$backupRoot = Join-Path (Join-Path $GameRoot ".nfb-ko-backup") ([string]$manifest.version)
$backupManifestPath = Join-Path $backupRoot "backup_manifest.json"

# Recover a write interrupted after its verified backup was created.
if (-not $Uninstall -and (Test-Path -LiteralPath $backupManifestPath -PathType Leaf)) {
    $prior = Get-Content -LiteralPath $backupManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$prior.state -eq "installing") {
        foreach ($file in $prior.files) {
            if ($file.mode -ne "patch") { continue }
            $target = Get-SafeTarget $GameRoot ([string]$file.relative)
            $stored = Get-SafeTarget $backupRoot ([string]$file.relative)
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { continue }
            $current = Get-Sha256 $target
            if ($current -ne [string]$file.source_sha256 -and $current -ne [string]$file.target_sha256) {
                if ((Test-Path -LiteralPath $stored -PathType Leaf) -and (Get-Sha256 $stored) -eq [string]$file.source_sha256) {
                    Set-Writable $target
                    Copy-Item -LiteralPath $stored -Destination $target -Force
                }
            }
        }
    }
}

if ($Uninstall) {
    if (-not (Test-Path -LiteralPath $backupManifestPath -PathType Leaf)) {
        throw "이 버전의 복구 백업을 찾지 못했습니다: $backupManifestPath"
    }
    $backup = Get-Content -LiteralPath $backupManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($file in $backup.files) {
        $target = Get-SafeTarget $GameRoot ([string]$file.relative)
        if ($file.mode -eq "add") {
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                if ((Get-Sha256 $target) -ne [string]$file.target_sha256) { throw "변경된 파일은 자동 삭제하지 않습니다: $($file.relative)" }
            }
        } else {
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "복원 대상이 없습니다: $($file.relative)" }
            $current = Get-Sha256 $target
            if ($current -ne [string]$file.target_sha256 -and $current -ne [string]$file.source_sha256) {
                throw "설치 뒤 변경된 파일은 자동 복원하지 않습니다: $($file.relative)"
            }
        }
    }
    foreach ($file in $backup.files) {
        $target = Get-SafeTarget $GameRoot ([string]$file.relative)
        if ($file.mode -eq "add") {
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                Set-Writable $target
                Remove-Item -LiteralPath $target -Force
            }
        } else {
            if ((Get-Sha256 $target) -eq [string]$file.source_sha256) { continue }
            $stored = Get-SafeTarget $backupRoot ([string]$file.relative)
            if (-not (Test-Path -LiteralPath $stored -PathType Leaf)) { throw "백업 파일이 없습니다: $stored" }
            if ((Get-Sha256 $stored) -ne [string]$file.source_sha256) { throw "백업 해시가 맞지 않습니다: $stored" }
            [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
            Set-Writable $target
            Copy-Item -LiteralPath $stored -Destination $target -Force
            if ((Get-Sha256 $target) -ne [string]$file.source_sha256) { throw "복원 검증 실패: $($file.relative)" }
        }
    }
    Write-Host "한국어 패치를 제거하고 원본을 복원했습니다." -ForegroundColor Green
    exit 0
}

# Full preflight: do not touch the game unless every target is compatible.
foreach ($file in $manifest.files) {
    $target = Get-SafeTarget $GameRoot ([string]$file.relative)
    if ($file.mode -eq "add") {
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            if ((Get-Sha256 $target) -ne [string]$file.target_sha256) { throw "예상하지 못한 파일이 이미 있습니다: $($file.relative)" }
        }
    } else {
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "원본 파일이 없습니다: $($file.relative)" }
        $current = Get-Sha256 $target
        if ($current -ne [string]$file.source_sha256 -and $current -ne [string]$file.target_sha256) {
            throw "게임 파일 해시가 지원 범위와 다릅니다: $($file.relative)"
        }
    }
}

[IO.Directory]::CreateDirectory($backupRoot) | Out-Null
$backupParent = Split-Path -Parent $backupRoot
$backupInfo = Get-Item -LiteralPath $backupParent -Force
$backupInfo.Attributes = $backupInfo.Attributes -bor [IO.FileAttributes]::Hidden
$backupFiles = @()
foreach ($file in $manifest.files) {
    $backupFiles += [pscustomobject][ordered]@{
        relative = [string]$file.relative
        mode = [string]$file.mode
        source_sha256 = $file.source_sha256
        target_sha256 = [string]$file.target_sha256
    }
}
$backupDoc = [ordered]@{
    schema = "nfb.ko.backup.v1"
    state = "installing"
    version = [string]$manifest.version
    started_utc = [DateTime]::UtcNow.ToString("o")
    installed_utc = $null
    game_build = $build
    files = $backupFiles
}
$backupDoc | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $backupManifestPath -Encoding UTF8

$fileIndex = 0
foreach ($file in $manifest.files) {
    $fileIndex++
    Write-Host ("[{0}/{1}] {2}" -f $fileIndex, $manifest.files.Count, [string]$file.relative)
    $target = Get-SafeTarget $GameRoot ([string]$file.relative)
    if ($file.mode -eq "patch") {
        $current = Get-Sha256 $target
        if ($current -eq [string]$file.source_sha256) {
            $stored = Get-SafeTarget $backupRoot ([string]$file.relative)
            [IO.Directory]::CreateDirectory((Split-Path -Parent $stored)) | Out-Null
            if (-not (Test-Path -LiteralPath $stored -PathType Leaf)) { Copy-Item -LiteralPath $target -Destination $stored }
            if ((Get-Sha256 $stored) -ne [string]$file.source_sha256) { throw "백업 검증 실패: $($file.relative)" }
            $patchPath = Join-Path $DataRoot ([string]$file.payload)
            if ((Get-Sha256 $patchPath) -ne [string]$file.payload_sha256) { throw "패치 데이터 해시가 맞지 않습니다: $($file.payload)" }
            $temp = "$target.nfbko.$([Guid]::NewGuid().ToString('N')).tmp"
            try {
                Apply-NfbDelta $target $patchPath $temp
                if ((Get-Sha256 $temp) -ne [string]$file.target_sha256) { throw "생성 파일 해시 검증 실패: $($file.relative)" }
                Set-Writable $target
                [IO.File]::Copy($temp, $target, $true)
                if ((Get-Sha256 $target) -ne [string]$file.target_sha256) { throw "교체 파일 검증 실패: $($file.relative)" }
            } catch {
                if ((Test-Path -LiteralPath $stored -PathType Leaf) -and (Get-Sha256 $stored) -eq [string]$file.source_sha256) {
                    Set-Writable $target
                    Copy-Item -LiteralPath $stored -Destination $target -Force
                }
                throw
            } finally {
                if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
            }
        }
    } else {
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            $payloadPath = Join-Path $DataRoot ([string]$file.payload)
            if ((Get-Sha256 $payloadPath) -ne [string]$file.payload_sha256) { throw "추가 파일 해시가 맞지 않습니다: $($file.payload)" }
            [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
            Copy-Item -LiteralPath $payloadPath -Destination $target
        }
    }
    if ((Get-Sha256 $target) -ne [string]$file.target_sha256) { throw "설치 후 검증 실패: $($file.relative)" }
}

$backupDoc["state"] = "installed"
$backupDoc["installed_utc"] = [DateTime]::UtcNow.ToString("o")
$backupDoc | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $backupManifestPath -Encoding UTF8
Write-Host "Not For Broadcast 한국어 패치 설치가 완료되었습니다." -ForegroundColor Green
Write-Host "제거하려면 한국어패치.bat uninstall 을 실행하세요."
