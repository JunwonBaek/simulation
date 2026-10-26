# Creates a NEW model in a NEW COM instance. Does not open or overwrite existing models.
$ErrorActionPreference = 'Stop'
$base = $PSScriptRoot
$dest = Join-Path ([Environment]::GetFolderPath('Desktop')) ('Line6_BK_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $dest | Out-Null
$log = Join-Path $dest 'build.log'
$script:sim = $null
$script:step = 0
function Log([string]$s) { $s | Tee-Object -FilePath $log -Append | Write-Host }
function Quote-ST([string]$s) { return '"' + $s.Replace('\','\\').Replace('"','\"') + '"' }
function Exists([string]$path) {
    try { $name = $script:sim.GetValue($path + '.Name'); return ($null -ne $name -and [string]$name -ne '') } catch { return $false }
}
function ST([string]$code) {
    $script:step++
    $n = $script:step
    $null = $script:sim.ExecuteSimTalk($code + "`n.Models.Model.BuildStep := $n")
    $seen = $script:sim.GetValue('.Models.Model.BuildStep')
    if ([int]$seen -ne $n) { throw "SimTalk setup did not complete at step $n. Code: $code" }
}
function Get-Result {
    $row = [ordered]@{}
    foreach ($key in @('B','K','UseCONWIP','TH','MeanWIP','MeanBuffer','MeanOutside','Completed','WIP','NIn','NOut','MeasuredAdmissions','CohortCompleted','ResidenceSum','OutsideWaitSum','BlockSeconds','WaitSeconds')) {
        $row[$key] = $script:sim.GetValue('.Models.Model.' + $key)
    }
    return [pscustomobject]$row
}
function Run-Case([int]$b, [bool]$on, [int]$k) {
    $null = $script:sim.ResetSimulation('.Models.Model.EventController')
    $v = if ($on) {'true'} else {'false'}
    ST ".Models.Model.B := $b; .Models.Model.UseCONWIP := $v; .Models.Model.K := $k; .Models.Model.Warmup := 3600; .Models.Model.MeasureTime := 7200; .Models.Model.EventController.End := 10801; .Models.Model.RunFinished := false"
    $null = $script:sim.StartSimulation('.Models.Model.EventController')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not [bool]$script:sim.GetValue('.Models.Model.RunFinished')) {
        $err = [string]$script:sim.GetValue('.Models.Model.ValidationError')
        if ($err) { throw $err }
        if ($watch.Elapsed.TotalSeconds -gt 180) { throw 'Simulation did not finish within 180 seconds. See Plant Simulation error window and build.log.' }
        Start-Sleep -Milliseconds 200
    }
    $result = Get-Result
    if ([int]$result.Completed -le 0) { throw 'No completed products: readiness check failed.' }
    if ([int]$result.WIP -ne ([int]$result.NIn - [int]$result.NOut)) { throw 'Conservation failed.' }
    return $result
}
try {
    Log 'Creating Plant Simulation 2201 model. Original open models are not used.'
    $progIds = @('Tecnomatix.PlantSimulation.RemoteControl.22.1','Tecnomatix.PlantSimulation.RemoteControl.22.0')
    foreach ($id in $progIds) {
        try {
            $script:sim = New-Object -ComObject $id
            Log "COM server: $id"
            break
        } catch { Log "Could not start $id : $($_.Exception.Message)" }
    }
    if ($null -eq $script:sim) { throw 'Plant Simulation 22.x COM server is unavailable. Installation, COM registration or license must be resolved.' }
    $null = $script:sim.SetVisible($true)
    try { $null = $script:sim.SetSuppressStartOf3D($true) } catch { Log '3D suppression option unavailable; continuing.' }
    $null = $script:sim.NewModel()
    if (-not (Exists '.Models.Model')) { throw 'NewModel did not create .Models.Model; refusing to modify another model.' }
    $config = Get-Content -Raw -Encoding UTF8 (Join-Path $base 'model.json') | ConvertFrom-Json
    $null = $script:sim.ExecuteSimTalk('.Models.Model.createAttr("BuildStep", "integer")')
    $null = $script:sim.GetValue('.Models.Model.BuildStep')
    foreach ($entry in $config.attributes.PSObject.Properties) {
        $name = $entry.Name
        if ($name -eq 'BuildStep') { continue }
        $kind = $entry.Value[0]
        $value = $entry.Value[1]
        $literal = if ($kind -eq 'string') { Quote-ST ([string]$value) } elseif ($kind -eq 'boolean') { ([string]$value).ToLowerInvariant() } else { [string]$value }
        ST ".Models.Model.createAttr(`"$name`", `"$kind`"); .Models.Model.$name := $literal"
    }
    $stationClass = '.MaterialFlow.Station'
    if (-not (Exists $stationClass)) { $stationClass = '.MaterialFlow.SingleProc' }
    if (-not (Exists $stationClass)) { throw 'Neither Station nor SingleProc class exists.' }
    if (-not (Exists '.Models.Model.EventController')) {
        ST 'var o: object := .MaterialFlow.EventController.createObject(.Models.Model, 80, 50); o.Name := "EventController"'
    }
    $index = 0
    foreach ($node in $config.nodes) {
        $name = [string]$node[0]
        $kind = [string]$node[1]
        $seconds = [int]$node[2]
        $class = if ($kind -eq 'Station') {$stationClass} else {'.MaterialFlow.' + $kind}
        $x = 70 + ($index % 8) * 110
        $y = 180 + [math]::Floor($index / 8) * 140
        ST "var o: object := $class.createObject(.Models.Model, $x, $y); o.Name := `"$name`""
        if ($kind -in @('Station','Buffer')) { ST ".Models.Model.$name.ProcTime := $seconds" }
        if ($kind -eq 'Buffer') { ST ".Models.Model.$name.Capacity := 1" }
        $index++
    }
    # Five physical slot objects; LiftRoute chooses the last B slots.
    for ($i=0; $i -lt $config.nodes.Count-1; $i++) {
        $from = [string]$config.nodes[$i][0]
        $to = [string]$config.nodes[$i+1][0]
        ST ".MaterialFlow.Connector.connect(.Models.Model.$from, .Models.Model.$to)"
    }
    ST '.Models.Model.Supply.Interval := 1'
    # Reset begins only after successful departure, not at processing start.
    ST '.Models.Model.Lift.RecoveryTime := 35; .Models.Model.Lift.RecoveryTimeMode := "When part exits"'
    ST '.Models.Model.Lower.RecoveryTime := 64; .Models.Model.Lower.RecoveryTimeMode := "When part exits"'
    $index = 0
    foreach ($method in $config.methods.PSObject.Properties) {
        $name = $method.Name
        $x = 70 + ($index % 8) * 110
        $y = 650 + [math]::Floor($index/8)*90
        ST "var m: object := .InformationFlow.&Method.createObject(.Models.Model, $x, $y); m.Name := `"$name`""
        $null = $script:sim.SetValue(('&.Models.Model.' + $name + '.Program'), [string]$method.Value)
        $index++
    }
    foreach ($control in $config.controls) {
        $obj = [string]$control[0]; $attr = [string]$control[1]; $method = [string]$control[2]
        ST ".Models.Model.$obj.$attr := &.Models.Model.$method"
    }
    $draft = Join-Path $dest 'Line6_BK_UNVERIFIED.spp'
    $null = $script:sim.SaveModel($draft)
    Log 'Model created. Running deterministic admission/conservation and nonbinding-K checks.'
    $results = @()
    foreach ($b in 2..5) {
        $baseline = Run-Case $b $false 1
        $wide = Run-Case $b $true (16+$b)
        if ([int]$baseline.Completed -ne [int]$wide.Completed -or [math]::Abs([double]$baseline.MeanWIP - [double]$wide.MeanWIP) -gt 0.00000001) {
            throw "Nonbinding K does not match uncontrolled case for B=$b."
        }
        $results += $baseline
        $results += $wide
    }
    $limited = Run-Case 2 $true 1
    $results += $limited
    if ([int]$limited.WIP -gt 1) { throw 'K=1 test failed.' }
    $results | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $dest 'deterministic_checks.csv')
    $null = $script:sim.ResetSimulation('.Models.Model.EventController')
    ST '.Models.Model.B := 2; .Models.Model.K := 18; .Models.Model.UseCONWIP := false; .Models.Model.Warmup := 86400; .Models.Model.MeasureTime := 1278000; .Models.Model.EventController.End := 1364401'
    $final = Join-Path $dest 'Line6_BK_DETERMINISTIC.spp'
    $null = $script:sim.SaveModel($final)
    if (-not (Test-Path $final)) { throw 'COM SaveModel returned but model file was not found.' }
    Copy-Item (Join-Path $base 'README_KO.md') $dest
    Log "SAVED: $final"
    Log '9 deterministic checks passed. This is NOT validation of stochastic/paper results.'
    Log 'Plant Simulation remains open. B/K/UseCONWIP are Frame attributes. Change them only after Reset.'
    Start-Process explorer.exe -ArgumentList ('"' + $dest + '"')
} catch {
    Log ('FAILED: ' + $_.Exception.Message)
    Log 'No validated final model is claimed. Send build.log; no manual SimTalk editing is required.'
    Log "Output folder: $dest"
    exit 1
}
