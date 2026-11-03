; MK Studio installer (NSIS).  Built on Linux in CI:
;   makensis -DVERSION=1.0.0-rc.1 -DVIVERSION=1.0.0.0 -DEXE=mkstudio-windows-x86_64.exe -DICON=mkstudio.ico -DLICENSE=LICENSE -DNOTICES=THIRD_PARTY_NOTICES -DOUTFILE=out.exe installer.nsi
;
; Per-user install (no administrator rights): %LOCALAPPDATA%\Programs\MK Studio.  That folder is writable by the user, so
; "Help > Check for Updates" can replace the program in place.  Nothing is written outside the user's profile.
Unicode true
!include "MUI2.nsh"

Name "MK Studio"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\Programs\MK Studio"
InstallDirRegKey HKCU "Software\MKStudio" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
ShowInstDetails show

VIProductVersion "${VIVERSION}"
VIAddVersionKey "ProductName" "MK Studio"
VIAddVersionKey "FileDescription" "MK Studio installer"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"

!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\mkstudio.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Start MK Studio"

!define MUI_LICENSEPAGE_TEXT_TOP "MK Studio is free software under the MIT license."
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${LICENSE}"
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Section "MK Studio (required)" SecMain
  SectionIn RO
  SetOutPath "$INSTDIR"
  ; a running copy cannot be overwritten but can be renamed (this is also how the in-app updater works)
  Delete "$INSTDIR\mkstudio.exe.old"
  IfFileExists "$INSTDIR\mkstudio.exe" 0 +2
    Rename "$INSTDIR\mkstudio.exe" "$INSTDIR\mkstudio.exe.old"
  File "/oname=mkstudio.exe" "${EXE}"
  File "/oname=mkstudio.ico" "${ICON}"
  File "/oname=LICENSE.txt" "${LICENSE}"
  File "/oname=THIRD_PARTY_NOTICES.txt" "${NOTICES}"
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  CreateDirectory "$SMPROGRAMS\MK Studio"
  CreateShortcut "$SMPROGRAMS\MK Studio\MK Studio.lnk" "$INSTDIR\mkstudio.exe" "" "$INSTDIR\mkstudio.ico"
  CreateShortcut "$SMPROGRAMS\MK Studio\Uninstall MK Studio.lnk" "$INSTDIR\Uninstall.exe"

  WriteRegStr HKCU "Software\MKStudio" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\MKStudio" "DisplayName" "MK Studio"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\MKStudio" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\MKStudio" "DisplayIcon" "$INSTDIR\mkstudio.ico"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\MKStudio" "URLInfoAbout" "https://github.com/atyr647/mkstudio"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\MKStudio" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\MKStudio" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\MKStudio" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\MKStudio" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\MKStudio" "NoRepair" 1
SectionEnd

Section "Desktop shortcut" SecDesktop
  CreateShortcut "$DESKTOP\MK Studio.lnk" "$INSTDIR\mkstudio.exe" "" "$INSTDIR\mkstudio.ico"
SectionEnd

; ".mk" is also used by makefile fragments, so MK Studio is offered under "Open with" instead of taking the file type over.
Section "Offer MK Studio under 'Open with' for .mk and .mk4 files" SecAssoc
  WriteRegStr HKCU "Software\Classes\MKStudio.Database" "" "Metakit database"
  WriteRegStr HKCU "Software\Classes\MKStudio.Database\DefaultIcon" "" "$INSTDIR\mkstudio.ico"
  WriteRegStr HKCU "Software\Classes\MKStudio.Database\shell\open\command" "" '"$INSTDIR\mkstudio.exe" "%1"'
  WriteRegStr HKCU "Software\Classes\.mk\OpenWithProgids" "MKStudio.Database" ""
  WriteRegStr HKCU "Software\Classes\.mk4\OpenWithProgids" "MKStudio.Database" ""
  ; (no SHChangeNotify here: it waits for every shell window to answer, and hung a silent install on a CI runner)
SectionEnd

Section "Uninstall"
  Delete "$INSTDIR\mkstudio.exe"
  Delete "$INSTDIR\mkstudio.exe.old"
  Delete "$INSTDIR\mkstudio.exe.new"
  Delete "$INSTDIR\mkstudio.ico"
  Delete "$INSTDIR\LICENSE.txt"
  Delete "$INSTDIR\THIRD_PARTY_NOTICES.txt"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\MK Studio\MK Studio.lnk"
  Delete "$SMPROGRAMS\MK Studio\Uninstall MK Studio.lnk"
  RMDir "$SMPROGRAMS\MK Studio"
  Delete "$DESKTOP\MK Studio.lnk"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\MKStudio"
  DeleteRegKey HKCU "Software\Classes\MKStudio.Database"
  DeleteRegValue HKCU "Software\Classes\.mk\OpenWithProgids" "MKStudio.Database"
  DeleteRegValue HKCU "Software\Classes\.mk4\OpenWithProgids" "MKStudio.Database"
  DeleteRegKey HKCU "Software\MKStudio"
  ; your settings (%APPDATA%\MKStudio) and databases are never touched
SectionEnd
