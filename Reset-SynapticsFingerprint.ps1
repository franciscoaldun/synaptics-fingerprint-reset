# =============================================================================
# Reset-SynapticsFingerprint.ps1
# Hardware Flash Database Wiper for Synaptics WBDI Match-On-Chip Sensors
# Supports: Synaptics FS7604, FS7605, FS7606, FS7614 (VID_06CB) on Windows 10/11
# =============================================================================

$ErrorActionPreference = "Continue"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Requesting Administrator privileges / Solicitando permisos de Administrador..." -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$Host.UI.RawUI.WindowTitle = "Synaptics Match-On-Chip Fingerprint Flash Reset"
Clear-Host
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  SYNAPTICS MATCH-ON-CHIP FINGERPRINT FLASH DATABASE RESET" -ForegroundColor Cyan
Write-Host "  BORRADO DE MEMORIA FLASH INTERNA - LECTOR DE HUELLAS SYNAPTICS" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

# 1. Discover Synaptics WBDI Biometric Device Interface Path dynamically
$wbdiClassKey = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\{e2b5183a-99ea-4cc3-ad6b-80ca8d715b80}"
$synaInterfaces = @()

if (Test-Path $wbdiClassKey) {
    Get-ChildItem $wbdiClassKey -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($props.DeviceInstance -and $props.DeviceInstance -match "VID_06CB") {
            # Convert registry key name ##?#USB#VID_06CB... to Win32 path \\?\USB#VID_06CB...
            $win32Path = $_.PSChildName -replace "^##\?#", "\\?\"
            $synaInterfaces += [PSCustomObject]@{
                DeviceInstance = $props.DeviceInstance
                DevicePath     = $win32Path
            }
        }
    }
}

if ($synaInterfaces.Count -eq 0) {
    Write-Host "[ERROR] No Synaptics WBDI fingerprint sensor (VID_06CB) found." -ForegroundColor Red
    Write-Host "[ERROR] No se detecto un lector de huellas Synaptics (VID_06CB)." -ForegroundColor Red
    Read-Host "Press ENTER to exit / Presiona ENTER para salir"
    exit 1
}

foreach ($sensor in $synaInterfaces) {
    Write-Host "[+] Detected sensor / Sensor detectado: $($sensor.DeviceInstance)" -ForegroundColor Green
}
Write-Host ""

# 2. Close Windows Hello enrollment hosts and stop Windows Biometric Service
Write-Host "[1/4] Closing Windows Settings & Enrollment Host..." -ForegroundColor Yellow
Stop-Process -Name "SystemSettings" -Force -ErrorAction SilentlyContinue
Stop-Process -Name "BioEnrollmentHost" -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

Write-Host "[2/4] Stopping Windows Biometric Service (WbioSrvc & BioIso)..." -ForegroundColor Yellow
Stop-Service -Name "WbioSrvc" -Force -ErrorAction SilentlyContinue
Stop-Process -Name "BioIso" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# 3. Compile P/Invoke helper for direct WBDI IOCTL communication
$code = @"
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public class SynaChipWiper {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern SafeFileHandle CreateFile(
        string lpFileName,
        int dwDesiredAccess,
        uint dwShareMode,
        IntPtr lpSecurityAttributes,
        uint dwCreationDisposition,
        uint dwFlagsAndAttributes,
        IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool DeviceIoControl(
        SafeFileHandle hDevice,
        uint dwIoControlCode,
        IntPtr lpInBuffer,
        uint nInBufferSize,
        IntPtr lpOutBuffer,
        uint nOutBufferSize,
        out uint lpBytesReturned,
        IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool DeviceIoControl(
        SafeFileHandle hDevice,
        uint dwIoControlCode,
        byte[] lpInBuffer,
        uint nInBufferSize,
        byte[] lpOutBuffer,
        uint nOutBufferSize,
        out uint lpBytesReturned,
        IntPtr lpOverlapped);
}
"@

Add-Type -TypeDefinition $code

Write-Host "[3/4] Sending hardware flash wipe IOCTLs to Synaptics sensor..." -ForegroundColor Yellow

foreach ($sensor in $synaInterfaces) {
    $devPath = $sensor.DevicePath
    $hDev = $null

    for ($try = 1; $try -le 5; $try++) {
        # GENERIC_READ | GENERIC_WRITE = 0xC0000000, FILE_SHARE_READ | FILE_SHARE_WRITE = 3, OPEN_EXISTING = 3
        $hDev = [SynaChipWiper]::CreateFile($devPath, 0xC0000000, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
        if (-not $hDev.IsInvalid) {
            break
        }
        Stop-Service -Name "WbioSrvc" -Force -ErrorAction SilentlyContinue
        Stop-Process -Name "BioIso" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }

    if (-not $hDev.IsInvalid) {
        Write-Host "  -> Connected to $($sensor.DeviceInstance)" -ForegroundColor Green
        $bytesRet = [uint32]0

        # A) Wildcard template deletion via IOCTL 0x00442034 (OnDeleteFinger)
        #    WINBIO_IDENTITY: Type = 2 (WINBIO_ID_TYPE_WILDCARD), Wildcard = 0x25066282, SubFactor = 0xFF
        $inBuf = New-Object byte[] 80
        [BitConverter]::GetBytes([uint32]2).CopyTo($inBuf, 0)
        [BitConverter]::GetBytes([uint32]0x25066282).CopyTo($inBuf, 4)
        $inBuf[76] = 0xFF
        $outBuf = New-Object byte[] 8

        $okDel = [SynaChipWiper]::DeviceIoControl($hDev, 0x00442034, $inBuf, 80, $outBuf, 8, [ref]$bytesRet, [IntPtr]::Zero)
        $delCount = [BitConverter]::ToUInt64($outBuf, 0)
        Write-Host "  -> [IOCTL 0x00442034] OnDeleteFinger (Wildcard): OK=$okDel (Records removed: $delCount)" -ForegroundColor Gray

        # B) Full on-chip database erase via IOCTL 0x00442028 (StorageAdapterEraseDatabase / OnEraseDatabase)
        $okErase = [SynaChipWiper]::DeviceIoControl($hDev, 0x00442028, [IntPtr]::Zero, 0, [IntPtr]::Zero, 0, [ref]$bytesRet, [IntPtr]::Zero)
        $errErase = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($okErase) {
            Write-Host "  -> [IOCTL 0x00442028] OnEraseDatabase: SUCCESS! Internal flash database wiped." -ForegroundColor Green
        } else {
            Write-Host "  -> [IOCTL 0x00442028] OnEraseDatabase returned FALSE (Win32Error=$errErase)" -ForegroundColor Red
        }

        $hDev.Close()
    } else {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Host "  -> [ERROR] Could not open sensor handle (Win32Error=$err)." -ForegroundColor Red
    }
}

# 4. Restart Windows Biometric Service and open Sign-in Options
Write-Host "[4/4] Restarting Windows Biometric Service (WbioSrvc)..." -ForegroundColor Yellow
Start-Service -Name "WbfPolicyService110" -ErrorAction SilentlyContinue
Start-Service -Name "WbioSrvc" -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Start-Process "ms-settings:signinoptions"

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Green
Write-Host "  DONE! / PROCESO COMPLETADO CON EXITO!" -ForegroundColor Green
Write-Host "  You can now enroll your fingerprints in Windows Hello." -ForegroundColor Green
Write-Host "  Ya puedes registrar tus huellas normalmente en Windows Hello." -ForegroundColor Green
Write-Host "======================================================================" -ForegroundColor Green
Read-Host "Press ENTER to close / Presiona ENTER para cerrar"
