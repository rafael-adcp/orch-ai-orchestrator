# Start the Solid Queue worker (processes the :claude queue).
# --mode async runs workers as threads inside one process; required on
# Windows because Solid Queue's default fork mode uses fork() which is
# unimplemented on Windows. macOS/Linux can use plain `bin/jobs start`.
$env:PATH = "C:\Ruby33-x64\bin;$env:PATH"
Set-Location $PSScriptRoot\..
ruby bin\jobs start --mode async
