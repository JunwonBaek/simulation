# PowerShell 5.1-compatible helpers. No COM server is started when dot-sourced.
function Quote-ST([string]$Text) {
    if ($Text.Contains("`n") -or $Text.Contains("`r")) { throw 'Only single-line SimTalk literals are supported; use Method.load for source.' }
    return '"' + $Text.Replace('\','\\').Replace('"','\"') + '"'
}
function Read-Config([string]$BasePath) {
    $cfg = Get-Content -Raw -Encoding UTF8 (Join-Path $BasePath 'model.json') | ConvertFrom-Json
    foreach ($entry in $cfg.methods.PSObject.Properties) {
        $file = Join-Path $BasePath ([string]$entry.Value)
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing method source: $file" }
        $bytes = [IO.File]::ReadAllBytes($file)
        if ($bytes.Length -eq 0 -or @($bytes | Where-Object { $_ -gt 127 }).Count -gt 0) { throw "Method source must be nonempty ASCII: $file" }
    }
    return $cfg
}
function Log([string]$Message) {
    $line = (Get-Date -Format 'HH:mm:ss') + ' ' + $Message
    [IO.File]::AppendAllText($script:log, $line + [Environment]::NewLine, [Text.Encoding]::UTF8)
    Write-Host $line
}
function Save-Step([string]$Label, [string]$Code) {
    $script:lastLabel = $Label
    $script:lastCode = $Code
    [IO.File]::WriteAllText((Join-Path $script:dest 'last-step.txt'), $Label + "`r`n" + $Code, [Text.Encoding]::UTF8)
    Log $Label
}
function Check-RuntimeError {
    if ($script:handlerReady) {
        $errorText = [string]$script:sim.GetValue('.Models.Model.BK_RuntimeError')
        if ($errorText) { throw "Plant Simulation: $errorText" }
    }
}
function ST([string]$Code, [string]$Label = 'Model setup') {
    $script:step++
    $n = $script:step
    Save-Step $Label $Code
    $null = $script:sim.ExecuteSimTalk($Code + "`n.Models.Model.BuildStep := $n")
    Check-RuntimeError
    if ([int]$script:sim.GetValue('.Models.Model.BuildStep') -ne $n) { throw "Setup step $n did not finish: $Label" }
}
function Eval-ST([string]$Code, [string]$Label) {
    Save-Step $Label $Code
    $result = $script:sim.ExecuteSimTalk($Code)
    Check-RuntimeError
    return $result
}
function Exists([string]$Path) {
    # Avoid generating an error merely to test an optional object/class.
    $literal = Quote-ST $Path
    return [bool](Eval-ST "-> boolean`nreturn existsObject($literal)" "Find $Path")
}
function Add-Method([string]$Name, [int]$X, [int]$Y) {
    $code = "var m: object := .InformationFlow.&Method.createObject(.Models.Model, $X, $Y)`nm.Name := " + (Quote-ST $Name)
    ST $code "Create Method $Name"
    ST "&.Models.Model.$Name.UsingNewSyntax := true" "Select SimTalk 2.0: $Name"
}
function Load-Method([string]$Name, [string]$File) {
    $full = [IO.Path]::GetFullPath($File)
    if (-not (Test-Path -LiteralPath $full)) { throw "Source not found: $full" }
    $literal = Quote-ST $full
    $code = "-> boolean`nreturn &.Models.Model.$Name.load($literal)"
    if (-not [bool](Eval-ST $code "Load ASCII source: $Name")) { throw "Method.load returned false: $Name" }
}
function Check-Method([string]$Name) {
    $code = "-> string`nvar errorMessage: string`nif &.Models.Model.$Name.hasSyntaxError(errorMessage)`n    return errorMessage`nend`nreturn `"`""
    $problem = [string](Eval-ST $code "Compile-check Method: $Name")
    if ($problem) { throw "Method $Name has a syntax error: $problem" }
}
function Get-Result {
    $row = [ordered]@{}
    foreach ($key in @('B','K','UseCONWIP','TH','MeanWIP','MeanBuffer','MeanOutside','Completed','WIP','MaxWIP','NIn','NOut','MeasuredAdmissions','CohortCompleted','ResidenceSum','OutsideWaitSum','BlockSeconds','WaitSeconds')) {
        $row[$key] = $script:sim.GetValue('.Models.Model.' + $key)
    }
    return [pscustomobject]$row
}
function Run-Case([int]$B, [bool]$On, [int]$K) {
    Log "Checking B=$B CONWIP=$On K=$K"
    $null = $script:sim.ResetSimulation('.Models.Model.EventController')
    $flag = ([string]$On).ToLowerInvariant()
    $code = @"
.Models.Model.B := $B
.Models.Model.UseCONWIP := $flag
.Models.Model.K := $K
.Models.Model.Warmup := 3600
.Models.Model.MeasureTime := 7200
.Models.Model.EventController.EndTime := 10801
.Models.Model.RunFinished := false
.Models.Model.ValidationError := ""
"@
    ST $code 'Configure deterministic check'
    # false,false = no real-time throttling and no animation.
    ST '.Models.Model.EventController.start(false, false)' 'Start deterministic check at full speed'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not [bool]$script:sim.GetValue('.Models.Model.RunFinished')) {
        Check-RuntimeError
        $problem = [string]$script:sim.GetValue('.Models.Model.ValidationError')
        if ($problem) { throw $problem }
        if ($watch.Elapsed.TotalSeconds -gt 180) { throw 'Check exceeded 180 seconds; see last-step.txt and Plant Simulation.' }
        Start-Sleep -Milliseconds 100
    }
    $null = $script:sim.StopSimulation()
    Check-RuntimeError
    $r = Get-Result
    if ([int]$r.Completed -le 0) { throw "No completions for B=$B CONWIP=$On K=$K" }
    if ([int]$r.WIP -ne ([int]$r.NIn - [int]$r.NOut)) { throw 'WIP conservation failed.' }
    if ($On -and [int]$r.MaxWIP -gt $K) { throw 'WIP cap failed.' }
    $actualWIP = 0
    foreach ($node in $script:config.nodes) {
        $name = [string]$node[0]
        if ($name -notin @('Supply','OutsideQueue','Exit')) {
            $actualWIP += [int]$script:sim.GetValue(".Models.Model.$name.NumMU")
        }
    }
    if ($actualWIP -ne [int]$r.WIP) { throw "Actual MU count $actualWIP differs from WIP counter $($r.WIP)." }
    Log "PASS: completions=$($r.Completed), mean WIP=$($r.MeanWIP)"
    return $r
}
