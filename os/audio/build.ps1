# build.ps1 - build va test tren PC Windows (MSYS2 MinGW64), khong can make.
#   .\build.ps1                      : build sim_audio + test_cipher_vectors
#   .\build.ps1 -Test -RefModel D:\PBL5\chaos_refmodel_v1.0.0\chaos_project
param(
    [switch]$Test,
    [string]$RefModel = "D:\PBL5\chaos_refmodel_v1.0.0\chaos_project",
    [string]$MinGW = "C:\msys64\mingw64\bin"
)
$ErrorActionPreference = "Stop"
$env:PATH = "$MinGW;" + $env:PATH
Set-Location $PSScriptRoot
New-Item -ItemType Directory -Force build | Out-Null

$cflags = @("-std=gnu11", "-O2", "-Wall", "-Wextra", "-Icommon", "-Isim")
$common = @("common\chaos_cipher.c", "common\chau_block.c", "common\acore_drv.c", "common\ctr_store.c", "common\app_audio.c")

& gcc @cflags -o build\sim_audio.exe sim\sim_audio.c sim\fpga_model.c @common -pthread -lm
if ($LASTEXITCODE -ne 0) { throw "build sim_audio loi" }
& gcc @cflags -o build\test_cipher_vectors.exe tests\test_cipher_vectors.c common\chaos_cipher.c
if ($LASTEXITCODE -ne 0) { throw "build test_cipher_vectors loi" }
"build xong: build\sim_audio.exe, build\test_cipher_vectors.exe"

if ($Test) {
    & .\build\test_cipher_vectors.exe "$RefModel\vectors\out"
    if ($LASTEXITCODE -ne 0) { throw "C cipher khong khop vector golden" }
    & python tests\e2e_audio.py --refmodel $RefModel
    if ($LASTEXITCODE -ne 0) { throw "e2e_audio co muc sai" }
}
