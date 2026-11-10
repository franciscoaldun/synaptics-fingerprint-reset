# Synaptics Match-On-Chip Fingerprint Flash Reset (Windows 10 / 11)

[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011-0078D6?logo=windows)](https://github.com/franciscoaldun/synaptics-fingerprint-reset)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

> **Solves / Soluciona:**
> - **ES:** *"Se produjo un error. Esa huella dactilar es demasiado parecida a una que ya se configuró. Prueba con otro dedo."* (cuando no tienes ninguna huella registrada en Windows Hello).
> - **EN:** *"Something went wrong. That fingerprint is too similar to one that's already set up. Try another finger."* (even when all fingerprints have been deleted or after reinstalling Windows).
> - **Windows Event Log (`Microsoft-Windows-Biometrics/Operational`):** Event ID `1014` — Error `0x8009801B` (`WINBIO_E_DATABASE_NO_RESULTS` / `WINBIO_E_DATABASE_NO_SUCH_RECORD`).

---

## 🇪🇸 Español

### ¿Por qué ocurre este problema?
Los lectores de huellas modernos **Synaptics Match-On-Chip (MOC)** (como los modelos **FS7604, FS7605, FS7606, FS7614** con PurePrint™, presentes en portátiles HP, Dell, Lenovo, etc.) utilizan su propio adaptador de almacenamiento (`synaFpAdapter110.dll`) que **guarda las plantillas de las huellas directamente dentro de la memoria flash interna del chip del sensor**, además de la base de datos de Windows (`WinBioDatabase`).

Cuando se reinstala Windows, se restablece el equipo, cambia el `SID` del usuario o falla una eliminación en **Virtual Secure Mode (Enhanced Sign-in Security / `BioIso.exe`)**:
1. Para tu usuario actual de Windows apareces con **0 huellas configuradas**.
2. Sin embargo, **el chip físico del lector sigue teniendo tus huellas guardadas en su memoria interna** bajo un identificador (`SID` / `Secure ID`) antiguo.
3. Al intentar registrar tu dedo nuevamente, el chip detecta que la huella ya existe en su memoria flash (`CEisMisEIV::EnrollmentCheckForDuplicate`) y la rechaza diciendo *"Esa huella dactilar es demasiado parecida a una que ya se configuró"*.
4. Ni borrar la carpeta `C:\Windows\System32\WinBioDatabase` ni reinstalar el driver desde el Administrador de dispositivos borra la memoria flash interna del chip.

### ¿Cómo lo soluciona esta herramienta?
Mediante ingeniería inversa del adaptador oficial `synaFpAdapter110.dll` y del controlador UMDF `synaWudfBioUsb110.dll`, esta herramienta:
1. Detecta automáticamente la ruta de interfaz WBDI (`{e2b5183a-99ea-4cc3-ad6b-80ca8d715b80}`) de cualquier sensor Synaptics (`VID_06CB`).
2. Detiene temporalmente el Servicio Biométrico de Windows (`WbioSrvc` y `BioIso.exe`) para liberar el bloqueo exclusivo del dispositivo USB.
3. Abre comunicación directa con el controlador del sensor y envía el código de control de hardware **`IOCTL 0x00442028`** (`StorageAdapterEraseDatabase` / `CBiometricDevice::OnEraseDatabase` -> `stiTudorDatabaseErase`), que **formatea y limpia por completo la base de datos en la memoria flash interna del chip Synaptics**, sin afectar el reconocimiento facial de Windows Hello.
4. Reinicia `WbioSrvc` y abre **Opciones de inicio de sesión** listo para registrar tus huellas desde cero.

### Uso rápido (1 clic)
1. Descarga o clona este repositorio.
2. Haz doble clic en **`Solucionar_Huellas.bat`** (o ejecuta `Reset-SynapticsFingerprint.ps1` en PowerShell) y acepta los permisos de **Administrador**.
3. ¡Listo! Se abrirá la ventana de Configuración de Windows Hello y podrás registrar todos tus dedos sin error.

---

## 🇺🇸 English

### Why does this happen?
Modern **Synaptics Match-On-Chip (MOC)** fingerprint sensors (such as **FS7604, FS7605, FS7606, FS7614** with PurePrint™, `USB\VID_06CB&PID_00F0`, `00C0`, `00C4`, `00D8`, `00DF`, `00E9`, `0103`, `0104`, `0106`) store fingerprint templates **inside the sensor's internal hardware flash memory** via `synaFpAdapter110.dll`.

If Windows is reinstalled/reset, a user profile `SID` changes, or the host Virtual Secure Mode (`BioIso.exe`) database gets out of sync with the sensor chip:
- Windows Settings shows **no fingerprints set up** for your account.
- When you try to enroll your finger, the sensor checks its internal flash memory (`CEisMisEIV::EnrollmentCheckForDuplicate`) and blocks enrollment with *"That fingerprint is too similar to one that's already set up. Try another finger."*
- Windows Biometric Service logs **Event ID 1014** with error **`0x8009801B`** because the template on the chip belongs to an orphaned `SID` that Windows cannot delete through standard UI actions, and deleting `C:\Windows\System32\WinBioDatabase\*.DAT` does not wipe the sensor's on-chip flash.

### How this tool fixes it
By inspecting `synaFpAdapter110.dll` (`WbioQueryStorageInterface`) and `synaWudfBioUsb110.dll`, we identified the exact WBDI vendor IOCTLs used to wipe the sensor's on-chip storage:
- **`IOCTL 0x00442034`** (`CBiometricDevice::OnDeleteFinger`) with `WINBIO_ID_TYPE_WILDCARD` (`Type = 2`, `Wildcard = 0x25066282`, `SubFactor = 0xFF`).
- **`IOCTL 0x00442028`** (`StorageAdapterEraseDatabase` / `CBiometricDevice::OnEraseDatabase`), which triggers `CEisMisEIV::RemoveAllEnrolledFingerFromDatabase` / `stiTudorDatabaseErase` on the hardware sensor.

### Quick Start
1. Clone or download this repository.
2. Double-click **`Solucionar_Huellas.bat`** (or run `Reset-SynapticsFingerprint.ps1` with PowerShell) and accept the **UAC Administrator prompt**.
3. The script will wipe the sensor's internal flash database, restart `WbioSrvc`, and open Windows Hello Sign-in Options so you can immediately enroll your fingerprints.
