import os
import re
import subprocess
import winreg

# Subset of Customer Specific Setup

def install_or_uninstall_office():
    print('Checking for pre-installed Microsoft Office installations...')
    reg_path = r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"

    reg_key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, reg_path)

    num_subkeys = winreg.QueryInfoKey(reg_key)[0]

    uninstall_commands = []

    for i in range(num_subkeys):
        subkey_name = winreg.EnumKey(reg_key, i)
        subkey_path = os.path.join(reg_path, subkey_name)
        subkey = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, subkey_path)

        try:
            display_name = winreg.QueryValueEx(subkey, "DisplayName")[0]
            if re.search(r"Microsoft Office|Microsoft 365|Microsoft OneNote", display_name):
                if re.search(r"en-us", display_name, re.IGNORECASE):
                    print(f'Keeping pre-installed Microsoft Office (en-us): {display_name}')
                else:
                    uninstall_command = winreg.QueryValueEx(subkey, "UninstallString")[0]
                    uninstall_commands.append(uninstall_command + " DisplayLevel=False")
        except FileNotFoundError:
            continue

    winreg.CloseKey(reg_key)

    if not uninstall_commands:
        print('No removable pre-installed Microsoft Office installations found.')
        return

    for command in uninstall_commands:
        print(f'Uninstalling {command}')
        subprocess.call(command, shell=True)

install_or_uninstall_office()
input("Press Enter to close...")
