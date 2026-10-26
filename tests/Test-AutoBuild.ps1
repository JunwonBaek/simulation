# Tests the PowerShell automation protocol only, NOT Plant Simulation behavior.
$ErrorActionPreference = 'Stop'
$base = Join-Path $PSScriptRoot '../Line6_AutoBuild'
. (Join-Path $base 'Build-Core.ps1')
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch { if ($_.Exception.Message -match $Pattern) { return }; throw }
    throw "Expected failure matching $Pattern"
}
$cfg = Read-Config $base
Assert ($cfg.methods.PSObject.Properties.Name.Count -eq 11) 'Expected all 11 model methods'
Assert ((Quote-ST 'a"b') -ceq '"a\"b"') 'Quote escaping failed'
Assert ((Quote-ST 'C:\temp\a.st') -ceq '"C:\\temp\\a.st"') 'Path escaping failed'
Assert-Throws { Quote-ST "two`nlines" } 'single-line'
class FakePlantSim {
    [string] $LastCode = ''
    [int] $Counter = 0
    [bool] $Acknowledge = $true
    [bool] $LoadOK = $true
    [string] $SyntaxError = ''
    [string] $RuntimeError = ''
    [object] ExecuteSimTalk([string]$code) {
        $this.LastCode = $code
        if ($code -match '\.load\(') { return $this.LoadOK }
        if ($code -match '\.hasSyntaxError\(') { return $this.SyntaxError }
        $m = [regex]::Match($code, '\.BuildStep := (\d+)')
        if ($m.Success -and $this.Acknowledge) { $this.Counter = [int]$m.Groups[1].Value }
        return $null
    }
    [object] GetValue([string]$path) {
        if ($path -eq '.Models.Model.BuildStep') { return $this.Counter }
        if ($path -eq '.Models.Model.BK_RuntimeError') { return $this.RuntimeError }
        throw "Unexpected GetValue: $path"
    }
}
$script:dest = Join-Path ([IO.Path]::GetTempPath()) ('line6-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $script:dest | Out-Null
$script:log = Join-Path $script:dest 'build.log'
$script:step = 0
$script:handlerReady = $false
$script:sim = [FakePlantSim]::new()
# Documented SimTalk rule: & belongs directly before the Method's leaf name.
foreach ($file in @('Build-Core.ps1','Build-Line6.ps1')) {
    $text = Get-Content -Raw (Join-Path $base $file)
    Assert (-not $text.Contains('&.Models.')) 'Invalid leading ampersand in absolute Method path'
}
Add-Method 'BK_Probe' 60 70
Assert ($script:sim.LastCode.Contains('.Models.Model.&BK_Probe.UsingNewSyntax := true')) 'Wrong syntax-setting Method reference'
Load-Method 'BK_Probe' (Join-Path $base 'methods/BK_Probe.st')
Assert ($script:sim.LastCode.Contains('return .Models.Model.&BK_Probe.load(')) 'Wrong source-load Method reference'
Check-Method 'BK_Probe'
Assert ($script:sim.LastCode.Contains('if .Models.Model.&BK_Probe.hasSyntaxError(')) 'Wrong syntax-check Method reference'

ST 'print 1' 'Successful acknowledgement'
$script:sim.Acknowledge = $false
Assert-Throws { ST 'print 2' 'Missing acknowledgement' } 'did not finish'
$script:sim.Acknowledge = $true
Load-Method 'Probe' (Join-Path $base 'methods/BK_Probe.st')
$script:sim.LoadOK = $false
Assert-Throws { Load-Method 'Probe' (Join-Path $base 'methods/BK_Probe.st') } 'returned false'
$script:sim.LoadOK = $true
Check-Method 'Probe'
$script:sim.SyntaxError = 'Injected syntax error'
Assert-Throws { Check-Method 'Probe' } 'Injected syntax error'
$script:handlerReady = $true
$script:sim.RuntimeError = 'Injected runtime error'
Assert-Throws { ST 'print 3' 'Runtime fault' } 'Injected runtime error'
Assert (Test-Path (Join-Path $script:dest 'last-step.txt')) 'Last-step diagnostic missing'
Assert ((Get-Content -Raw (Join-Path $script:dest 'last-step.txt')) -match 'print 3') 'Wrong last command captured'
Write-Host 'PASS: absolute Method references, config/ASCII, quoting, source-load rejection, syntax-error rejection, step acknowledgement, runtime-error propagation, last-step capture.'
Write-Host 'Plant Simulation engine was NOT tested; failure paths used a test double.'
