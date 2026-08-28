<#
.SYNOPSIS
  Resume a finished run in its own session, with a new brief.

.DESCRIPTION
  When a read-only reviewer finishes and its findings ARE the follow-up work, resume that
  same session rather than briefing a fresh one: it already holds the whole branch in
  context. The invariant this preserves -- whoever changed the code is never the one who
  signs off on it -- still holds, because the review was written and harvested BEFORE the
  run gained write access. Relaying AGAIN to bless that fix is not sound; dispatch fresh.

  A relay that cannot find the session id MUST fail loudly. Starting a fresh session
  instead looks identical from the outside while carrying none of the context that
  justified relaying at all.

  cursor-agent has no session-resume lane here; dispatch fresh and restate the context.
#>
param(
    [Parameter(Mandatory=$true)][ValidateSet('codex','codebuddy','claude')][string]$Agent,
    [Parameter(Mandatory=$true)][string]$From,
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$Worktree,
    [Parameter(Mandatory=$true)][string]$Brief,
    [string]$Model,
    [string]$Effort = 'medium'
)
$ErrorActionPreference = 'Stop'
$FSLASH = [char]47

if (-not $Model) {
    $per = [Environment]::GetEnvironmentVariable("AGENT_MODEL_$($Agent.ToUpper())")
    if ($per) { $Model = $per } elseif ($env:AGENT_MODEL) { $Model = $env:AGENT_MODEL }
}
if (-not $Model) { throw "no model: pass -Model, or set AGENT_MODEL_$($Agent.ToUpper()) / AGENT_MODEL" }

if (-not (Test-Path $Worktree)) { throw "worktree does not exist: $Worktree" }
$wt  = (Resolve-Path $Worktree).Path
$raw = (& git -C $wt rev-parse --show-toplevel 2>&1)
$top = ([string]$raw).Replace($FSLASH, '\')
if ($top.TrimEnd('\') -ine $wt.TrimEnd('\')) { throw "preflight FAILED: '$wt' resolves to '$top' -- refusing" }
$common = ([string](& git -C $wt rev-parse --path-format=absolute --git-common-dir)).Replace($FSLASH, '\')
$main = Split-Path $common -Parent
if ($wt.TrimEnd('\') -ieq $main.TrimEnd('\')) { throw "preflight FAILED: target is the MAIN repository -- refusing" }
if (-not (Test-Path $Brief)) { throw "brief not found: $Brief" }
$briefPath = (Resolve-Path $Brief).Path

$runs = if ($env:AGENT_RUNS) { $env:AGENT_RUNS } else { Join-Path $main ".agent-runs\$Agent" }
$fromLog = Join-Path $runs "$From.log"
if (-not (Test-Path $fromLog)) { throw "no transcript for the previous run: $fromLog" }

# Session id shapes differ per CLI; a miss must throw rather than silently start fresh.
$text = Get-Content -Raw $fromLog
$sid = $null
foreach ($pat in @('session[_ -]?id[":\s]+([0-9a-fA-F-]{16,})',
                   '\b([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\b')) {
    $m = [regex]::Match($text, $pat)
    if ($m.Success) { $sid = $m.Groups[1].Value; break }
}
if (-not $sid) {
    throw "relay FAILED: no session id in $From.log -- refusing to degrade into a fresh session (that discards the entire reason to relay)"
}

New-Item -ItemType Directory -Force -Path $runs | Out-Null
$log = Join-Path $runs "$Name.log"; $out = Join-Path $runs "$Name.out"
$before = Join-Path $runs "$Name.before"; $exitf = Join-Path $runs "$Name.exit"
foreach ($f in @($log, $out, $before, $exitf)) { if ([IO.File]::Exists($f)) { [IO.File]::Delete($f) } }
& git -C $wt status --porcelain --ignored | Set-Content $before -Encoding UTF8

$tmp = if ($env:AGENT_TMP) { $env:AGENT_TMP } elseif ($env:TEMP) { $env:TEMP } else { $main }
$pointer = "Read the file $briefPath -- it is your complete brief for this run. Follow every requirement in it."
$pointerFile = Join-Path $tmp "agent-prompt-$Name.txt"
[IO.File]::WriteAllText($pointerFile, $pointer, (New-Object System.Text.UTF8Encoding($false)))

$lines = @("Set-Location '$wt'")
switch ($Agent) {
    'codex' {
        $lines += "`$p = Get-Content -Raw '$briefPath'"
        $lines += "`$p | codex exec resume $sid -m '$Model' -c model_reasoning_effort='`"$Effort`"' --dangerously-bypass-approvals-and-sandbox -o '$out' - *> '$log'"
        $lines += "`$code = `$LASTEXITCODE"
    }
    'codebuddy' {
        $lines += "`$prompt = [IO.File]::ReadAllText('$pointerFile')"
        $lines += "& codebuddy -p --output-format text --model '$Model' -y --resume $sid `$prompt *> '$log'"
        $lines += "`$code = `$LASTEXITCODE"
    }
    'claude' {
        $lines += "`$prompt = [IO.File]::ReadAllText('$pointerFile')"
        $lines += "& claude -p --model '$Model' --dangerously-skip-permissions -r $sid `$prompt *> '$log'"
        $lines += "`$code = `$LASTEXITCODE"
    }
}
if ($Agent -ne 'codex') {
    $lines += "if (Test-Path '$log') { Get-Content '$log' -Tail 400 | Set-Content '$out' -Encoding UTF8 }"
}
$lines += "`"`$code`" | Set-Content '$exitf' -Encoding UTF8"

$runner = Join-Path $tmp "agent-relay-$Agent-$Name.ps1"
[IO.File]::WriteAllText($runner, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
$proc = Start-Process pwsh -ArgumentList '-NoProfile','-NonInteractive','-File',$runner -WindowStyle Hidden -PassThru
Write-Output "preflight ok: $wt (relay $sid from $From)"
Write-Output "$Name PID=$($proc.Id) agent=$Agent worktree=$(Split-Path $wt -Leaf) relayed=$sid"
