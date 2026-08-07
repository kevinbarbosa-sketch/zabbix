# Execute como Administrador no PowerShell
# Instalacao STANDALONE: sem MSI (um MSI faria upgrade de um "Zabbix Agent 2"
# que o cliente ja tenha). Extrai o ZIP oficial openssl-static (sem dependencia
# de DLL, com TLS PSK) em C:\skyone e registra instancia propria via
# --multiple-agents. Porta propria: 10055.

param(
    [string]$Version      = "7.0.27",
    [string]$Server       = "skyonecloud03-proxy02.skyone.guru",
    [string]$Metadata     = "[OPER]-OPERACAO AUTOSKY|Windows|57abcbfa2e196a13e0630a1a000accc7",
    [string]$PSKIdentity  = "Skyone-MSP-AutoReg",
    [string]$PSK          = "4d96f2974343338bdc5d19bbce3852cac70c97c132da6976091327dd83316940",
	[string]$DownloadBase = "https://cdn.zabbix.com/zabbix/binaries/stable/7.0",
    [int]$ListenPort      = 10055
	[int]$Timeout = 15
)

$isAdmin = (
    [Security.Principal.WindowsPrincipal]
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    Write-Error "Este script precisa ser executado como Administrador."
    exit 1
}

# 2. Download do ZIP (forca TLS 1.2 p/ Windows Server 2012 R2 / 2016)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$url = "$DownloadBase/$Version/zabbix_agent2-$Version-windows-amd64-openssl-static.zip"
Write-Host "Baixando Zabbix Agent 2..." -ForegroundColor Cyan
(New-Object Net.WebClient).DownloadFile($url, $ZIP)

# 3. Para o servico Skyone se ja existir (re-run). Colchetes sao curinga no
#    parametro -Name, entao o match e por igualdade via Where-Object
$existing = Get-Service | Where-Object { $_.Name -eq $SVC_NAME }
if ($existing) { $existing | Stop-Service -Force; Start-Sleep -Seconds 2 }

# 4. Extrai o ZIP em pasta temporaria e copia o binario
if (Test-Path $EXTRACT) { Remove-Item -Recurse -Force $EXTRACT }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($ZIP, $EXTRACT)
New-Item -ItemType Directory -Force -Path "$ZBX_DIR\bin" | Out-Null
Copy-Item -Force "$EXTRACT\bin\zabbix_agent2.exe" "$ZBX_DIR\bin\zabbix_agent2.exe"
Remove-Item -Recurse -Force $EXTRACT

# 5. PSK + conf. O Hostname fica fixo no conf: com --multiple-agents o nome do
#    servico deriva dele
[System.IO.File]::WriteAllText($ZBX_PSK, $PSK, [System.Text.Encoding]::ASCII)
$conf = @"
LogType=file
LogFile=$ZBX_DIR\zabbix_agent2.log
LogFileSize=10
ControlSocket=\\.\pipe\zabbix-skyone-agent
ListenPort=$ListenPort
Server=$Server
ServerActive=$Server
Hostname=$env:COMPUTERNAME
HostMetadata=$Metadata
TLSConnect=psk
TLSAccept=psk
TLSPSKIdentity=$PSKIdentity
TLSPSKFile=$ZBX_PSK
Timeout=$Timeout
Include=$ZBX_DIR\zabbix_agent2.d\*.conf
"@
$conf | Out-File -FilePath $ZBX_CONF -Encoding ASCII

# 5b. Coletor Top Processes (template "MSP Windows - Top Processes"):
#     drop-in UserParameter + script PowerShell no zabbix_agent2.d.
#     Sem system.run; key sem argumento. Duas amostras de 1s do Get-Process
#     (delta de TotalProcessorTime = %CPU instantaneo, 0..100*nucleos - o
#     template normaliza pelo NCPU); memoria = WorkingSet64 / RAM fisica.
#     Cultura invariante (pt-BR imprimiria virgula e quebraria o parse).
New-Item -ItemType Directory -Force -Path "$ZBX_DIR\zabbix_agent2.d" | Out-Null
$TOP_PS1 = "$ZBX_DIR\zabbix_agent2.d\skyone-top-processes.ps1"
$collector = @"
# Skyone - coletor Top 5 processos (CPU/memoria) - template "MSP Windows - Top Processes"
`$ErrorActionPreference = "Stop"
`$inv = [System.Globalization.CultureInfo]::InvariantCulture
`$nl = [char]10
`$ncpu = [Environment]::ProcessorCount
`$totalMem = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
`$cpu0 = @{}
`$t0 = Get-Date
Get-Process | ForEach-Object { if (`$_.Id -gt 0) { `$cpu0[`$_.Id] = `$_.CPU } }
Start-Sleep -Seconds 1
`$snap = Get-Process | Where-Object { `$_.Id -gt 0 }
`$dt = ((Get-Date) - `$t0).TotalSeconds
`$cpu = @{}
`$mem = @{}
foreach (`$p in `$snap) {
    `$name = `$p.ProcessName
    if (-not `$cpu.ContainsKey(`$name)) { `$cpu[`$name] = 0.0; `$mem[`$name] = 0.0 }
    `$c0 = `$cpu0[`$p.Id]
    if (`$null -ne `$p.CPU -and `$null -ne `$c0 -and `$p.CPU -ge `$c0) {
        `$cpu[`$name] = `$cpu[`$name] + 100.0 * (`$p.CPU - `$c0) / `$dt
    }
    `$mem[`$name] = `$mem[`$name] + 100.0 * `$p.WorkingSet64 / `$totalMem
}
`$out = "NCPU " + `$ncpu + `$nl
foreach (`$n in `$cpu.Keys) {
    `$out = `$out + [string]::Format(`$inv, "{0} {1:F2} {2:F2}", `$n, `$cpu[`$n], `$mem[`$n]) + `$nl
}
`$out
"@
[System.IO.File]::WriteAllText($TOP_PS1, $collector, [System.Text.Encoding]::ASCII)
[System.IO.File]::WriteAllText("$ZBX_DIR\zabbix_agent2.d\skyone-top-processes.conf", "UserParameter=skyone.top.procs,powershell.exe -NoProfile -ExecutionPolicy Bypass -File $TOP_PS1", [System.Text.Encoding]::ASCII)

# 6. Registra a instancia propria (--multiple-agents): o servico vira
#    "Zabbix Agent 2 [HOSTNAME]" e nao conflita com um "Zabbix Agent 2" existente
if (-not $existing) {
    & "$ZBX_DIR\bin\zabbix_agent2.exe" --config $ZBX_CONF --multiple-agents --install
    if ($LASTEXITCODE -ne 0) { Write-Error "Falha ao registrar o servico (codigo $LASTEXITCODE)"; exit 1 }
}
# 7. Nome exibido fixo: o nome INTERNO do servico e "Zabbix Agent 2 [HOSTNAME]"
#    (o agent nao aceita nome arbitrario), mas o services.msc mostra o
#    DisplayName — fixado em zabbix-skyone, igual ao servico do Linux
& sc.exe config "$SVC_NAME" displayname= "Zabbix-Skyone" | Out-Null
& sc.exe description "$SVC_NAME" "Skyone Zabbix Agent 2 (standalone)" | Out-Null
Get-Service | Where-Object { $_.Name -eq $SVC_NAME } | Start-Service

Write-Host "=== Config aplicada ===" -ForegroundColor Cyan
Select-String -Path $ZBX_CONF -Pattern "^(Server|ServerActive|Hostname|HostMetadata|ListenPort)=" | ForEach-Object { $_.Line }
Start-Sleep -Seconds 2
$svc = Get-Service | Where-Object { $_.Name -eq $SVC_NAME }
if ($svc -and $svc.Status -eq "Running") {
    Write-Host "OK: Zabbix Agent 2 Skyone instalado (servico: $SVC_NAME, porta 10055)." -ForegroundColor Green
} else {
    Write-Error "Servico nao esta rodando - veja o log em $ZBX_DIR\zabbix_agent2.log"
    exit 1
}