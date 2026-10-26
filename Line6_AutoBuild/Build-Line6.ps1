param([string]$OutputDirectory = '')
$ErrorActionPreference = 'Stop'
$base = $PSScriptRoot
. (Join-Path $base 'Build-Core.ps1')
$script:sim = $null
$script:step = 0
$script:handlerReady = $false
$script:lastLabel = 'Startup'
$script:lastCode = ''
$desktop = [Environment]::GetFolderPath('Desktop')
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $desktop ('Line6_BK_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff')) }
$script:dest = $OutputDirectory
New-Item -ItemType Directory -Path $script:dest -Force | Out-Null
$script:log = Join-Path $script:dest 'build.log'
$success = $false
try {
    Log 'Line6 AutoBuild v0.3 - file-based method loading and preflight'
    $script:config = Read-Config $base
    foreach ($id in @('Tecnomatix.PlantSimulation.RemoteControl.22.1','Tecnomatix.PlantSimulation.RemoteControl.22.0')) {
        try {
            $script:sim = New-Object -ComObject $id
            Log "COM server: $id"
            break
        } catch { Log "Could not start $id : $($_.Exception.Message)" }
    }
    if ($null -eq $script:sim) { throw 'Plant Simulation 22.x COM server/license is unavailable.' }
    $null = $script:sim.SetVisible($true)
    try { $null = $script:sim.SetSuppressStartOf3D($true) } catch { Log '3D suppression option unavailable.' }
    Save-Step 'Create a NEW model; existing models are not touched' 'COM NewModel'
    $null = $script:sim.NewModel()
    if (-not (Exists '.Models.Model')) { throw 'The new .Models.Model Frame was not found.' }
    $bootstrap = @'
.Models.Model.createAttr("BuildStep", "integer")
.Models.Model.createAttr("BK_ProbeValue", "integer")
.Models.Model.createAttr("BK_RuntimeError", "string")
'@
    Save-Step 'Create build diagnostic attributes' $bootstrap
    $null = $script:sim.ExecuteSimTalk($bootstrap)
    $null = $script:sim.GetValue('.Models.Model.BuildStep')

    # Probe the source loading/compiling/executing workflow BEFORE building the line.
    Add-Method 'BK_Probe' 60 70
    Load-Method 'BK_Probe' (Join-Path $base 'methods/BK_Probe.st')
    Check-Method 'BK_Probe'
    ST '.Models.Model.BK_Probe' 'Execute tiny method preflight'
    if ([int]$script:sim.GetValue('.Models.Model.BK_ProbeValue') -ne 12345) { throw 'Method preflight did not execute.' }
    Log 'PASS: ASCII source loading, syntax checking and method execution.'

    # Capture subsequent SimTalk errors into a Frame attribute and build.log.
    Add-Method 'BK_ErrorHandler' 180 70
    Load-Method 'BK_ErrorHandler' (Join-Path $base 'methods/BK_ErrorHandler.st')
    Check-Method 'BK_ErrorHandler'
    ST 'setErrorHandler(&.Models.Model.BK_ErrorHandler)' 'Register model error logger'
    $script:handlerReady = $true

    foreach ($entry in $script:config.attributes.PSObject.Properties) {
        $name = $entry.Name
        if ($name -eq 'BuildStep') { continue }
        $kind = [string]$entry.Value[0]
        $value = $entry.Value[1]
        $literal = if ($kind -eq 'string') { Quote-ST ([string]$value) } elseif ($kind -eq 'boolean') { ([string]$value).ToLowerInvariant() } else { [string]$value }
        ST ".Models.Model.createAttr(`"$name`", `"$kind`")`n.Models.Model.$name := $literal" "Create Frame attribute: $name"
    }
    $stationClass = '.MaterialFlow.Station'
    if (-not (Exists $stationClass)) { $stationClass = '.MaterialFlow.SingleProc' }
    if (-not (Exists $stationClass)) { throw 'Neither Station nor SingleProc is available.' }
    if (-not (Exists '.Models.Model.EventController')) {
        ST 'var o: object := .MaterialFlow.EventController.createObject(.Models.Model, 300, 70)
o.Name := "EventController"' 'Create EventController'
    }
    $index = 0
    foreach ($node in $script:config.nodes) {
        $name = [string]$node[0]; $kind = [string]$node[1]; $seconds = [int]$node[2]
        $class = if ($kind -eq 'Station') {$stationClass} else {'.MaterialFlow.' + $kind}
        $x = 70 + ($index % 8) * 110
        $y = 210 + [math]::Floor($index / 8) * 140
        ST "var o: object := $class.createObject(.Models.Model, $x, $y)`no.Name := `"$name`"" "Create $name"
        if ($kind -in @('Station','Buffer')) { ST ".Models.Model.$name.ProcTime := $seconds" "Processing time: $name" }
        if ($kind -eq 'Buffer') { ST ".Models.Model.$name.Capacity := 1" "Capacity: $name" }
        $index++
    }
    for ($i = 0; $i -lt $script:config.nodes.Count-1; $i++) {
        $from = [string]$script:config.nodes[$i][0]; $to = [string]$script:config.nodes[$i+1][0]
        ST ".MaterialFlow.Connector.connect(.Models.Model.$from, .Models.Model.$to)" "Connect $from -> $to"
    }
    ST '.Models.Model.Supply.Number := -1' 'Unlimited supply'
    ST '.Models.Model.Supply.Interval := 1' 'Supply interval'
    ST '.Models.Model.Lift.RecoveryTime := 35' 'Lift return duration'
    ST '.Models.Model.Lift.RecoveryTimeMode := "When part exits"' 'Lift return starts after departure'
    ST '.Models.Model.Lower.RecoveryTime := 64' 'Lower return duration'
    ST '.Models.Model.Lower.RecoveryTimeMode := "When part exits"' 'Lower return starts after departure'

    # Create every referenced Method before loading or compiling any model source.
    $index = 0
    foreach ($entry in $script:config.methods.PSObject.Properties) {
        Add-Method $entry.Name (70 + ($index % 8) * 110) (670 + [math]::Floor($index / 8)*90)
        $index++
    }
    foreach ($entry in $script:config.methods.PSObject.Properties) { Load-Method $entry.Name (Join-Path $base ([string]$entry.Value)) }
    foreach ($entry in $script:config.methods.PSObject.Properties) { Check-Method $entry.Name }
    foreach ($control in $script:config.controls) {
        $obj = [string]$control[0]; $attr = [string]$control[1]; $method = [string]$control[2]
        ST ".Models.Model.$obj.$attr := &.Models.Model.$method" "Connect control: $obj.$attr -> $method"
    }
    $draft = Join-Path $script:dest 'Line6_BK_UNVERIFIED.spp'
    Save-Step 'Save compiled model before validation' 'COM SaveModel'
    $null = $script:sim.SaveModel($draft)
    $results = @()
    foreach ($b in 2..5) {
        $baseline = Run-Case $b $false 1
        $wide = Run-Case $b $true (16+$b)
        if ([int]$baseline.Completed -ne [int]$wide.Completed -or [math]::Abs([double]$baseline.MeanWIP - [double]$wide.MeanWIP) -gt 0.00000001) {
            throw "Nonbinding K did not match uncontrolled case for B=$b."
        }
        $results += $baseline
        $results += $wide
    }
    $results += Run-Case 2 $true 1
    $results | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $script:dest 'deterministic_checks.csv')
    $null = $script:sim.ResetSimulation('.Models.Model.EventController')
    ST @'
.Models.Model.B := 2
.Models.Model.K := 18
.Models.Model.UseCONWIP := false
.Models.Model.Warmup := 86400
.Models.Model.MeasureTime := 1278000
.Models.Model.EventController.EndTime := 1364401
'@ 'Restore default study settings'
    $final = Join-Path $script:dest 'Line6_BK_DETERMINISTIC.spp'
    Save-Step 'Save validated deterministic model' 'COM SaveModel'
    $null = $script:sim.SaveModel($final)
    if (-not (Test-Path -LiteralPath $final)) { throw 'Saved model file was not found.' }
    Copy-Item (Join-Path $base 'README_KO.md') $script:dest
    Copy-Item (Join-Path $base 'VERSION.txt') $script:dest
    Log "SAVED: $final"
    Log '9 deterministic checks passed on this PC. Stochastic/paper validation remains outstanding.'
    $success = $true
} catch {
    Log ('FAILED: ' + $_.Exception.Message)
    if ($null -ne $script:sim) {
        try { $null = $script:sim.StopSimulation() } catch { Log ('Could not stop the new simulation: ' + $_.Exception.Message) }
    }
    Log ('Stage: ' + $script:lastLabel)
    Log ('Last SimTalk command: ' + $script:lastCode)
    Log 'Send build.log and last-step.txt. No manual SimTalk edits are required.'
} finally {
    Log "Output folder: $script:dest"
    try { Start-Process explorer.exe -ArgumentList ('"' + $script:dest + '"') } catch { Write-Host 'Open the output folder shown above.' }
}
if (-not $success) { exit 1 }
