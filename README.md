# Uninstall-Cygwin.ps1

A comprehensive PowerShell script to **reliably and cleanly uninstall Cygwin** from Windows.

The script automates the manual steps normally required to remove Cygwin, including:

- Stopping and removing Cygwin-related Windows services  
- Terminating Cygwin processes  
- Deleting Cygwin installation directories and package caches  
- Cleaning `PATH` and `CYGWIN` environment variables (User + Machine)  
- Removing relevant registry keys  
- Deleting Cygwin shortcuts from the Desktop and Start Menu  

It is designed to be **safe, conservative, and idempotent**: you can run it multiple times without causing additional damage or unwanted side effects.

---

## Features

The script performs the following actions:

1. **Elevation check**

   - Verifies that PowerShell is running with Administrator privileges.
   - Exits with an error message if not elevated.

2. **Cygwin service cleanup**

   - Scans all Windows services using WMI.
   - Identifies services whose `PathName` contains `cygwin` (case-insensitive).
   - Attempts to stop each matching service.
   - Removes each matching service with `sc.exe delete`.

3. **Cygwin process termination**

   - Attempts to stop common Cygwin-related processes by name:
     - `bash`, `sh`, `mintty`, `XWin`, `xterm`, `rxvt`, `cygserver`
   - Additionally scans all running processes and terminates any whose executable `Path` contains `cygwin`.

4. **Detection of Cygwin installation directories**

   - Reads from the following registry locations (if present):

     - `HKLM:\SOFTWARE\Cygwin\setup`  
     - `HKLM:\SOFTWARE\WOW6432Node\Cygwin\setup`  
     - `HKCU:\Software\Cygwin\setup`  

   - Uses the `rootdir` value (when available) to determine the Cygwin installation directory.
   - Also checks standard default install paths:
     - `C:\cygwin64`
     - `C:\cygwin`

5. **Detection of Cygwin package cache directories**

   - Reads the `last-cache` value (if present) from the same registry keys.
   - Treats these as candidate Cygwin package cache locations.

6. **Safe deletion of installation directories**

   For each discovered install root:

   - Ensures the path:
     - Exists
     - Is **not** a drive root (e.g. not `C:\`)
     - Contains `cygwin` (case-insensitive) in its path string
   - Takes ownership using `takeown.exe`.
   - Grants full control to `Administrators` and the current user via `icacls.exe`.
   - Deletes the directory recursively with `Remove-Item`.

7. **Safe deletion of package cache directories (optional)**

   For each discovered cache directory:

   - Ensures the path:
     - Exists
     - Is not a drive root
     - Contains `cygwin` in the path
   - Takes ownership and resets permissions (as above).
   - Deletes the directory recursively.

8. **Environment variable cleanup**

   - For both **Machine** and **User** scopes:
     - Retrieves the `PATH` value.
     - Splits it into entries and removes any that contain `cygwin` (case-insensitive).
     - Writes back the cleaned `PATH` value if changes were made.
     - Removes the `CYGWIN` environment variable if it exists.

9. **Registry key cleanup**

   Removes the following keys if present:

   - `HKLM:\SOFTWARE\Cygwin`
   - `HKCU:\Software\Cygwin`
   - `HKLM:\SOFTWARE\WOW6432Node\Cygwin`
   - `HKCU:\Software\Cygnus Solutions`
   - `HKLM:\SOFTWARE\Cygnus Solutions`
   - `HKLM:\SOFTWARE\WOW6432Node\Cygnus Solutions`

   These cover both newer Cygwin installs and some older naming (`Cygnus Solutions`).

10. **Shortcut and Start Menu cleanup**

    Searches common Desktop and Start Menu locations:

    - Public desktop: `%PUBLIC%\Desktop`
    - Current user desktop
    - Start Menu (all users): `%ProgramData%\Microsoft\Windows\Start Menu\Programs`
    - Start Menu (current user): `%APPDATA%\Microsoft\Windows\Start Menu\Programs`

    For each location:

    - Deletes any shortcuts matching:
      - `Cygwin*.lnk`
      - `Cygwin*Terminal*.lnk`
    - Removes any subfolders whose name starts with `Cygwin`.

---

## Requirements

- **Operating system**: Windows (tested on Windows 10 / Windows 11)
- **PowerShell**: Windows PowerShell 5.x or PowerShell 7+
- **Permissions**: Must be run from an **elevated** (Administrator) PowerShell session

---

## Usage

1. **Download or clone the repository**

   ```powershell
   git clone https://github.com/<your-username>/<your-repo-name>.git
   cd <your-repo-name>
   ```

2. **Open PowerShell as Administrator**

   - Start Menu → search for “PowerShell”  
   - Right-click → “Run as administrator”

3. **Run the script**

   If your execution policy blocks the script, you can temporarily bypass it:

   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   .\Uninstall-Cygwin.ps1
   ```

4. **Reboot**

   After the script completes, it is recommended to **reboot** Windows to ensure:

   - Any remaining `cygwin1.dll` instances are unloaded
   - Any open handles into previously deleted directories are released

---

## Idempotence & Safety

The script is designed to be **idempotent**:

- If Cygwin has already been removed:
  - No services will match the Cygwin filter.
  - No Cygwin directories will be found.
  - PATH will already be cleaned.
  - Registry keys and shortcuts will not exist.

In that state, running the script again results in harmless “nothing to do” behaviour.

### Safety measures

The script includes several safeguards:

- **No deletion of drive roots**

  Any path where `Path == drive root` (e.g. `C:\`) is explicitly skipped.

- **Cygwin-only path deletion**

  Directories are only eligible for deletion if their path contains the word `cygwin` (case-insensitive).

- **Conservative cache deletion**

  Package cache directories are only removed if:
  - They are discovered via Cygwin’s own registry entries, and
  - Their paths contain `cygwin`.

- **Scoped environment cleaning**

  Only PATH entries containing `cygwin` are removed. Other entries are preserved.

---

## What This Script Does *Not* Do

- It does **not** attempt to uninstall or modify:
  - WSL (Windows Subsystem for Linux)
  - MSYS / MSYS2
  - Git for Windows
  - Any non-Cygwin POSIX-like environment

- It does **not** remove:
  - Non-Cygwin directories that happen to contain other toolchains
  - Any files outside those explicitly matching Cygwin-related registry, path, or shortcut patterns

---

## Troubleshooting

### “This script must be run as Administrator”

You need to start PowerShell with elevated rights:

1. Close the current PowerShell window.
2. Start Menu → type `powershell`.
3. Right-click → **Run as administrator**.
4. Run the script again.

---

### “Access denied” / permission errors when deleting directories

The script attempts to take ownership and reset permissions using `takeown.exe` and `icacls.exe`.  
If these still fail:

- Check if you have locked files in those directories (for example, a third-party antivirus or backup agent).
- Temporarily disable security tools that may be keeping handles open on the Cygwin directory.
- Reboot and re-run the script as Administrator.

---

### Cygwin still appears in PATH in a new shell

Environment variable changes apply to **future** shells:

- Close and reopen PowerShell / Command Prompt.
- For GUI applications, log off and back on (or reboot) to ensure all processes see the updated PATH.

You can inspect current PATH variables with:

```powershell
[Environment]::GetEnvironmentVariable('PATH', 'Machine')
[Environment]::GetEnvironmentVariable('PATH', 'User')
```

You should not see any segments containing `cygwin` after the script has run.

---

## Extending or Modifying the Script

You may wish to:

- Tighten or relax the matching rules for:
  - PATH entries (e.g. only match `C:\cygwin64\bin`)
  - Directory deletions (e.g. include additional known Cygwin install paths)
- Add logging to a file instead of console output
- Integrate with configuration management or automation tools

The script is structured into logical sections and helper functions to make such changes straightforward.

---

## Licence

You are free to use, modify, and distribute this script.

A simple option is to license the repository under the **MIT Licence**.  
For example:

```text
MIT License

Copyright (c) 2025 VibeCoder01

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:
...
```
