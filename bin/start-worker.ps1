# Start the Solid Queue worker (processes the :claude queue)
$env:PATH = "C:\Ruby33-x64\bin;$env:PATH"
Set-Location $PSScriptRoot\..
ruby bin\jobs start
