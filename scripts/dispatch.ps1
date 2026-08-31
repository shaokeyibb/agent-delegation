<#
.SYNOPSIS
  Dispatch a coding-agent CLI as a detached background worker on a git worktree.

.DESCRIPTION
  One entry point for codex / cursor / codebuddy / claude. Each writes the same sentinel
  quartet, so a run's state is answerable from disk rather than from the agent's account:
    <runs>\<name>.before  tree snapshot at dispatch (--ignored, so vendored writes show)
    <runs>\<name>.log     streaming transcript
    <runs>\<name>.out     the deliverable (final message)
    <runs>\<name>.exit    written LAST -- its existence IS the completion signal

  The model is REQUIRED: pass -Model, or set AGENT_MODEL (or AGENT_MODEL_<AGENT>).
  This skill deliberately hard-codes no model id -- ids change, and a stale default
  fails late in a way that looks like a task problem rather than a config one.

.EXAMPLE
  .\dispatch.ps1 -Agent codex -Name fixfoo -Worktree C:\wt\foo -Brief .\brief.md -Model <id>
  .\dispatch.ps1 -Agent cursor -Name probe -Worktree C:\wt\bar -Brief .\b.md -ReadOnly
#>
param(
    [Parameter(Mandatory=$true)][ValidateSet('codex','cursor','codebuddy','claude')][string]$Agent,
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$Worktree,
    [Parameter(Mandatory=$true)][string]$Brief,
    [string]$Model,
    [string]$Effort = 'medium',
    [switch]$ReadOnly
)
$ErrorActionPreference = 'Stop'
$FSLASH = [char]47

$exeFor = @{ codex = 'codex'; cursor = 'cursor-agent'; codebuddy = 'codebuddy'; claude = 'claude' }
$exe = $exeFor[$Agent]
if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { throw "$Agent CLI not on PATH: $exe" }

if (-not $Model) {
    $per = [Environment]::GetEnvironmentVariable("AGENT_MODEL_$($Agent.ToUpper())")
    if ($per) { $Model = $per } elseif ($env:AGENT_MODEL) { $Model = $env:AGENT_MODEL }
}
if (-not $Model) { throw "no model: pass -Model, or set AGENT_MODEL_$($Agent.ToUpper()) / AGENT_MODEL" }

# ---- preflight ---------------------------------------------------------------
# A half-removed worktree keeps its files but loses its .git pointer, so git walks UP and
# resolves it to the MAIN repository. Test-Path cannot see this; only git's resolution can.
if (-not (Test-Path $Worktree)) { throw "worktree does not exist: $Worktree" }
$wt  = (Resolve-Path $Worktree).Path
$raw = (& git -C $wt rev-parse --show-toplevel 2>&1)
$top = ([string]$raw).Replace($FSLASH, '\')
if ($top.TrimEnd('\') -ine $wt.TrimEnd('\')) {
    throw "preflight FAILED: '$wt' resolves to '$top' -- refusing (likely a half-removed worktree)"
}
# The check above cannot catch the main repo being passed in: a repo resolves to itself.
$common = ([string](& git -C $wt rev-parse --path-format=absolute --git-common-dir)).Replace($FSLASH, '\')
$main = Split-Path $common -Parent
if ($wt.TrimEnd('\') -ieq $main.TrimEnd('\')) {
    throw "preflight FAILED: target is the MAIN repository -- refusing. Workers go in worktrees, read-only included."
}
if (-not (Test-Path $Brief)) { throw "brief not found: $Brief" }
$briefPath = (Resolve-Path $Brief).Path

# ---- sentinel ----------------------------------------------------------------
$runs = if ($env:AGENT_RUNS) { $env:AGENT_RUNS } else { Join-Path $main ".agent-runs\$Agent" }
New-Item -ItemType Directory -Force -Path $runs | Out-Null
$log = Join-Path $runs "$Name.log"
$out = Join-Path $runs "$Name.out"
$before = Join-Path $runs "$Name.before"
$exitf = Join-Path $runs "$Name.exit"
foreach ($f in @($log, $out, $before, $exitf)) { if ([IO.File]::Exists($f)) { [IO.File]::Delete($f) } }
# --ignored is required: plain --porcelain hides ignored paths, so a run that wrote a
# large dependency tree shows a clean status and the snapshot proves nothing.
& git -C $wt status --porcelain --ignored | Set-Content $before -Encoding UTF8

$tmp = if ($env:AGENT_TMP) { $env:AGENT_TMP } elseif ($env:TEMP) { $env:TEMP } else { $main }

# How the brief reaches the agent differs, and getting it wrong fails SILENTLY:
#   codex  -- stdin, so multi-line quoting never has to survive a shell.
#   others -- measured: passing a large brief as an argv element makes the CLI return
#             immediately with a few-byte log and exit code 0, which a monitor reports
#             as DONE. So they get the PATH only and read the file themselves.
$pointer = "Read the file $briefPath -- it is your complete brief for this run. Follow every requirement in it. When done, answer in the form its delivery section asks for; your final message IS the deliverable."
$pointerFile = Join-Path $tmp "agent-prompt-$Name.txt"
[IO.File]::WriteAllText($pointerFile, $pointer, (New-Object System.Text.UTF8Encoding($false)))

$lines = @("Set-Location '$wt'")
switch ($Agent) {
    'codex' {
        $lines += "`$p = Get-Content -Raw '$briefPath'"
        $lines += "`$p | codex exec -m '$Model' -c model_reasoning_effort='`"$Effort`"' --dangerously-bypass-approvals-and-sandbox -o '$out' - *> '$log'"
        $lines += "`$code = `$LASTEXITCODE"
    }
    'cursor' {
        # Workspace Trust is required even for the read-only plan lane; --trust grants no exec.
        $mode = if ($ReadOnly) { "@('--plan','--trust')" } else { "@('--force')" }
        $lines += "`$prompt = [IO.File]::ReadAllText('$pointerFile')"
        $lines += "`$a = @('-p','--output-format','text','--model','$Model') + $mode"
        $lines += "& cursor-agent @a `$prompt *> '$log'"
        $lines += "`$code = `$LASTEXITCODE"
    }
    'codebuddy' {
        # -y alone is not enough: its own help says HIGH/CRITICAL still prompt, and under -p
        # there is nobody to answer, so those operations are silently denied and the run looks
        # read-only. bypassPermissions is the CLI's own full-pass mode.
        $perm = if ($ReadOnly) { "" } else { "`$a += @('-y','--permission-mode','bypassPermissions'); " }
        $lines += "`$prompt = [IO.File]::ReadAllText('$pointerFile')"
        $lines += "`$a = @('-p','--output-format','text','--model','$Model')"
        $lines += "$perm& codebuddy @a `$prompt *> '$log'"
        $lines += "`$code = `$LASTEXITCODE"
    }
    'claude' {
        $perm = if ($ReadOnly) { "" } else { "`$a += '--dangerously-skip-permissions'; " }
        $lines += "`$prompt = [IO.File]::ReadAllText('$pointerFile')"
        $lines += "`$a = @('-p','--model','$Model')"
        $lines += "$perm& claude @a `$prompt *> '$log'"
        $lines += "`$code = `$LASTEXITCODE"
    }
}
# codex writes .out itself via -o; the others get it from the tail of the transcript.
if ($Agent -ne 'codex') {
    $lines += "if (Test-Path '$log') { Get-Content '$log' -Tail 400 | Set-Content '$out' -Encoding UTF8 }"
}
# .exit is written LAST on purpose: its existence is the completion signal.
$lines += "`"`$code`" | Set-Content '$exitf' -Encoding UTF8"

$runner = Join-Path $tmp "agent-runner-$Agent-$Name.ps1"
[IO.File]::WriteAllText($runner, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
$proc = Start-Process pwsh -ArgumentList '-NoProfile','-NonInteractive','-File',$runner -WindowStyle Hidden -PassThru

Write-Output "preflight ok: $wt"
Write-Output "$Name PID=$($proc.Id) agent=$Agent worktree=$(Split-Path $wt -Leaf) model=$Model mode=$(if($ReadOnly){'readonly'}else{'write'})"
Write-Output "sentinel: $runs\$Name.{log,out,before,exit}"
