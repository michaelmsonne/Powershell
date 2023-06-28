<#
    .SYNOPSIS
     Extend Active Directory to support both Legacy LAPS and Windows LAPS
    
    .DESCRIPTION
     To extend Active Directory the user running the script needs to be a member of both Enterprise and Schema Admins, please remember to remove the membership again.

     Requires internet access to Download the Legacy LAPS files, unless they are provided in the directory provided on the LAPSFiles parameter.
     
     There will be created 4 GPO's and 2 WMI filters to support both Windows and Legacy LAPS.

         1. GPO "Manage LAPS Version"
            Will handle the LAPS installation on ALL clients where the GPO is linked, and will make sure that the best LAPS option is selected.

         2. GPO Legacy LAPS Settings"
            Will configure clients to save Local Administrator password in the Legacy LAPS properties.

         3. GPO "Windows LAPS Settings (Active Directory)"
            Will configure clients to save Local Administrator password in the Active Directory Windows LAPS properties.

         4. GPO "Windows LAPS Settings (Azure Active Directory)"
            Will configure clients to save Local Administrator password in the Azure Active Directory Windows LAPS properties.


    .NOTES
     Needs Enterprise and Schema Admins, please remember to remove the membership again   

    .LINK
    https://learn.microsoft.com/en-us/windows-server/identity/laps/laps-overview
    https://www.microsoft.com/en-us/download/details.aspx?id=46899


    .PARAMETER GPOPrefix 
     Defines the prefix of the GPO's and WMI filters that will be created.
     Defaults to Domain

    .PARAMETER LAPSFiles
     If the server where the script is executed, the Legacy LAPS file(s) need to be provided at the path specified.
     Can be downloaded at the following URI : https://www.microsoft.com/en-us/download/details.aspx?id=46899

     The x86 file is optional, and only required if there is member machines that requires it.


    .EXAMPLE
    Setup-ActiveDirectroy-Laps.ps1 -GPOPrefix "MyDomain"
    Setup-ActiveDirectroy-Laps.ps1 -GPOPrefix "MyDomain" -LAPSFiles "C:\_Install\LAPS"


#>
#requires -RunAsAdministrator
#requires -Modules ActiveDirectory, GroupPolicy

[CmdletBinding()]
Param(
  [Parameter(ValueFromPipelineByPropertyName=$true,Position=0)][string]$GPOPrefix = "Domain",
  [Parameter(ValueFromPipelineByPropertyName=$true,Position=0)][string]$LAPSFiles
)


##################################################################################
# DISCLAIMER [ Start ]
##################################################################################

clear
Write-Output "*******************************************************************************************************************"
Write-Output ""
Write-Output "DISCLAIMER: "
Write-Output ""
Write-Output ""
Write-Output "THE FOLLOWING POWERSHELL SCRIPT IS PROVIDED AS-IS, WITHOUT WARRANTY OF ANY KIND. USE AT YOUR OWN RISK."
Write-Output ""
Write-Output ""
Write-Output "By running this script, you acknowledge that you have read and understood the disclaimer below, and you agree to"
Write-Output "assume all responsibility for any failures, damages, or issues that may arise as a result of executing this script."
Write-Output ""
Write-Output ""
Write-Output "Please note the following"
Write-Output ""
Write-Output "1. The script makes changes to the Active Directory Schema, which can have significant impacts on your environment."
Write-Output "2. It is strongly recommended that you run this script in a test or lab environment before executing it in production."
#Write-Output "   "
Write-Output "3. Performing changes in production without proper testing can lead to data loss, service disruptions,"
Write-Output "   or other unintended consequences."
Write-Output ""
Write-Output "Take appropriate precautions and ensure you have a backup of your Active Directory before running this script."
Write-Output ""
Write-Output ""
Write-Output "*******************************************************************************************************************"

$title = "Update Active Directory"
$message = "Do you want to run this script and prepare you domain for LAPS ?"
$yes = New-Object System.Management.Automation.Host.ChoiceDescription "&Yes", "Yes Install."
$no = New-Object System.Management.Automation.Host.ChoiceDescription "&No", "Just quit"
$options = [System.Management.Automation.Host.ChoiceDescription[]]($yes, $no)

if (($host.ui.PromptForChoice($title, $message, $options, 0)) -eq 1) {
    Write-Output ""
    break
} else {
    Clear
    Write-Output "Verifying Prerequisites"
}

##################################################################################
# DISCLAIMER [ End ]
##################################################################################



##################################################################################
# Prerequisites check [ Start ]
##################################################################################


# --------------------------------------------------------------------------------
# Check the GPO prefix
# --------------------------------------------------------------------------------
Write-Output "Verify selected GPO prifix is valid"
if ($GPOPrefix -Notmatch "^[a-zA-Z]+$") {
    throw "The GPO name prefix contains invalid characters, unable to continue"
    #break
}

# --------------------------------------------------------------------------------
# Verify required files are avalible
# --------------------------------------------------------------------------------
Write-Output "Verify required GPO files are avalible"
if ( (!(Test-Path -Path "$PSScriptRoot\GPO")) -AND (((Get-ChildItem -Path $PSScriptRoot -Recurse).FullName).Count -ne 59) ) {
    Throw "Required files and folders missing, unable to continue"
    break
}
if (!(Test-Path -Path "$PSScriptRoot\GPO\Policy Dependencies\Manage-Laps-Version.ps1")) {
    Throw "Manage LAPS version script not found, unable to continue"
    break
}


# --------------------------------------------------------------------------------
# Read Registry for Installed Windows version
# --------------------------------------------------------------------------------
Write-Output "Get Windows version and Architecture"
$WindowsVersion = Get-ItemProperty -Path "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion"


# --------------------------------------------------------------------------------
# Check for Windows version
# --------------------------------------------------------------------------------
Write-Output "Detect which version of LAPS current server can support"
if ($WindowsVersion.CurrentMajorVersionNumber -ne "10") {
    throw "Not running on a supported Windows version, unable to continue"
    #break
} else {

    Switch ($($WindowsVersion.CurrentBuild)) {
        "17763" { if ($($WindowsVersion.UBR) -gt "4252") { $Laps = "Windows" } }
        "19042" { if ($($WindowsVersion.UBR) -gt "2846") { $Laps = "Windows" } }
        "19044" { if ($($WindowsVersion.UBR) -gt "2846") { $Laps = "Windows" } }
        "19045" { if ($($WindowsVersion.UBR) -gt "2846") { $Laps = "Windows" } }
        "20348" { if ($($WindowsVersion.UBR) -gt "1668") { $Laps = "Windows" } }
        "22000" { if ($($WindowsVersion.UBR) -gt "1817") { $Laps = "Windows" } }
        "22621" { if ($($WindowsVersion.UBR) -gt "1555") { $Laps = "Windows" } }
        default { $Laps = "Legacy" }
    }
}

# --------------------------------------------------------------------------------
# Quit if April patch not installed or running on x86.
# --------------------------------------------------------------------------------
if ( ($Laps -eq "Legacy") -AND ($($env:PROCESSOR_ARCHITECTURE) -ne "AMD64") ) {
    Throw "Windows LAPS not installed and supported, unable to continue"
    break
}


# --------------------------------------------------------------------------------
# Connect to Domain and Make sure all AD commands use the PDC
# --------------------------------------------------------------------------------
Write-Output "Connecting to PDC, and setting default server for *AD* commands"
$CurrentDomain = Get-ADDomain
if ($($CurrentDomain.PDCEmulator) -eq $null) {
    throw "Failed to connect to Active Directory, unable to continue"
    break
} else {
    $PSDefaultParameterValues = @{
        "*AD*:Server" = $CurrentDomain.PDCEmulator
    }
}


# --------------------------------------------------------------------------------
# Verify Current user is Domain User and member of Schema and Enterprise Admins.
# --------------------------------------------------------------------------------
Write-Output "Verify Current user is a member of Enterprise and Schema Admins"
$CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
try {
    $ADUser = Get-AdUser -Identity ($CurrentUser -split("\\"))[-1]
}
Catch {
    throw "Script is running in local user context, unable to continue"
    break
}

if (!(Get-ADGroupMember -Identity "Enterprise Admins" | Where {$_.distinguishedName -eq $ADUser.DistinguishedName})) { 
    throw "User is NOT a member of Enterprise Admins, unable to continue"
    break
}

if (!(Get-ADGroupMember -Identity "Schema Admins" | Where {$_.distinguishedName -eq $ADUser.DistinguishedName})) { 
    throw "User is NOT a member of Schema Admins, unable to continue"
    break
}

# --------------------------------------------------------------------------------
# Verify Domain Functional Level
# --------------------------------------------------------------------------------
If ($CurrentDomain.DomainMode -ne "Windows2016Domain") {
    throw "To fully support Windows LAPS, the Domain functional level needs to be 2016, please upgrade prior to configuring Windows LAPS Password encryption"
}


##################################################################################
# Prerequisites check [ End ]
##################################################################################


##################################################################################
# Main script [ Start ]
##################################################################################


# --------------------------------------------------------------------------------
# Download Legacy LAPS installation files.
# --------------------------------------------------------------------------------
if ($LAPSFiles -ne $null) {
    if (!(Test-Path -Path "$LAPSFiles\LAPS.x64.msi")) {
        Throw "Missing the LAPS.x64.msi, unable to continue"
        break
    }
    if (!(Test-Path -Path "$LAPSFiles\LAPS.x64.msi")) {
        Write-Output "Missing the LAPS.x86.msi, please copy it to sysvol if there is x86 machines in the Company"
        Write-Output "where you need to support Legacy LAPS"
    }
} else {
    Write-Output "Download LAPS install files"
    if (!(Test-Path -Path "$($env:windir)\temp\LAPS.x64.msi")) {
        try {
            Invoke-WebRequest -Uri "https://download.microsoft.com/download/C/7/A/C7AAD914-A8A6-4904-88A1-29E657445D03/LAPS.x64.msi" -OutFile "$($env:windir)\temp\LAPS.x64.msi"
        } catch {
            Throw "Failed to download the LAPS.x64.msi, unable to continue"
            break
        }
    }
    if (!(Test-Path -Path "$($env:windir)\temp\LAPS.x86.msi")) {
        try {
            Invoke-WebRequest -Uri "https://download.microsoft.com/download/C/7/A/C7AAD914-A8A6-4904-88A1-29E657445D03/LAPS.x86.msi1" -OutFile "$($env:windir)\temp\LAPS.x86.msi"
        } catch {
            Write-Output "Failed to download the LAPS.x86.msi, please copy it to sysvol if there is x86 machines in the Company"
            Write-Output "where you need to support Legacy LAPS"
        }
    }
}


# --------------------------------------------------------------------------------
# Check if Legacy LAPS is installed
# --------------------------------------------------------------------------------
$LegacyLAPS = Test-Path -Path "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{97E2CA7B-B657-4FF7-A6DB-30ECC73E1E28}"
if (!($LegacyLAPS)) {
    Start-Process -FilePath "C:\Windows\System32\MsiExec.exe" -ArgumentList "/i `"$($env:windir)\temp\LAPS.x64.msi`" ADDLOCAL=Management.PS,Management.ADMX ALLUSERS=1 /qn /quiet" -Wait
}


# --------------------------------------------------------------------------------
# Load Legacy LAPS powershell module.
# --------------------------------------------------------------------------------
If ( ($LegacyLAPS) -AND (Test-Path -Path "$(($env:PSModulePath -split(";"))[-1])\admpwd.ps\AdmPwd.PS.dll") ) {
    Import-Module "$(($env:PSModulePath -split(";"))[-1])\admpwd.ps\AdmPwd.PS.dll"
} else {
    Write-Verbose "Legacy Laps is installed, but missing the Powershell Module, updating the install"
    Start-Process -FilePath "C:\Windows\System32\MsiExec.exe" -ArgumentList "/i {97E2CA7B-B657-4FF7-A6DB-30ECC73E1E28} ADDLOCAL=Management.PS /quiet" -Wait

    if (Test-Path -Path "$(($env:PSModulePath -split(";"))[-1])\admpwd.ps\AdmPwd.PS.dll") {
        Import-Module "$(($env:PSModulePath -split(";"))[-1])\admpwd.ps\AdmPwd.PS.dll" -Force
    } else {
        Throw "Failed to install Legacy LAPS powershell module, unable to continue"
        #break
    }
}


# --------------------------------------------------------------------------------
# Verify Legacy LAPS Policy Definitions is installed.
# --------------------------------------------------------------------------------
$PolicyDefinitions = @("AdmPwd.admx","en-US\AdmPwd.adml")
If (!(Test-Path -Path "C:\Windows\PolicyDefinitions\$($PolicyDefinitions[0])")) {
    Start-Process -FilePath "C:\Windows\System32\MsiExec.exe" -ArgumentList "/i {97E2CA7B-B657-4FF7-A6DB-30ECC73E1E28} ADDLOCAL=Management.ADMX /quiet" -Wait
}


# --------------------------------------------------------------------------------
# Add Windows LAPS Policy Definitions.
# --------------------------------------------------------------------------------
if ($Laps -eq "Windows") {
    $PolicyDefinitions += @("LAPS.admx","en-US\LAPS.adml")
}


# --------------------------------------------------------------------------------
# Copy selected Policy Definitions
# --------------------------------------------------------------------------------
Write-Verbose "Copy Local Policy Definitions SYSVOL"
Foreach ($File in $PolicyDefinitions) {
    $SourceFilePath = "C:\Windows\PolicyDefinitions\$File"
    $TargetFilePath = "\\$($CurrentDomain.DNSRoot)\SYSVOL\$($CurrentDomain.DNSRoot)\Policies\PolicyDefinitions\$File"

    If ( (Test-Path -Path $SourceFilePath) -AND (!(Test-Path -Path $TargetFilePath)) ) {
        Copy-Item -Path $SourceFilePath -Destination $TargetFilePath
    }
    if (!($TargetFilePath)) {
        Write-Host "Unable to copy $File to SYSVOL" -ForegroundColor Red
    }
}


# --------------------------------------------------------------------------------
# Update AD Schema to hold Legacy LAPS properties
# --------------------------------------------------------------------------------
Try {
    Write-Verbose "Check Legacy LAPS schema properties"
    $msmcsadmpwd = Get-AdObject -Identity "CN=ms-mcs-admpwd,CN=Schema,$($CurrentDomain.SubordinateReferences | Where {$_ -like '*Config*'})"
} Catch {
    Write-Verbose "Updating Schema to suport Legacy LAPS"
    Update-AdmPwdADSchema
}


# --------------------------------------------------------------------------------
# Update AD Schema to hold Windows LAPS properties
# --------------------------------------------------------------------------------
Try {
    Write-Verbose "Check Windows LAPS schema properties"
    $msLAPSPassword = Get-AdObject -Identity "CN=ms-LAPS-Password,CN=Schema,$($CurrentDomain.SubordinateReferences | Where {$_ -like '*Config*'})"
} Catch {
    Write-Verbose "Updating Schema to suport Windows LAPS"
    Update-LapsADSchema
}


# --------------------------------------------------------------------------------
# Create WMI filters
# --------------------------------------------------------------------------------
$WMIFilters = @()
$WMIFilters += "Detect Legacy LAPS; Select * From CIM_Datafile Where Name = `"C:\\Program Files\\LAPS\\CSE\\AdmPwd.dll`""
$WMIFilters += "Detect Windows LAPS; Select * From CIM_Datafile Where Name = `"C:\\Windows\\System32\\lapscsp.dll`""

# Build the date field in required format
$now = (Get-Date).ToUniversalTime()
$msWMICreationDate = ($now.Year).ToString("0000") + ($now.Month).ToString("00") + ($now.Day).ToString("00") + ($now.Hour).ToString("00") + ($now.Minute).ToString("00") + ($now.Second).ToString("00") + "." + ($now.Millisecond * 1000).ToString("000000") + "-000"


# Create WMI filters
foreach ($Line in $WMIFilters) {
    $Name = "$GPOPrefix - $($($Line -Split("; "))[0])"
    $Query = $($Line -Split("; "))[1]

    $NewWMIGUID = [string]"{" + ([System.Guid]::NewGuid()) + "}"

    $Attr = @{
        "msWMI-Name" = $Name;
        "msWMI-Parm1" = "Created by LAPS configuration script";
        "msWMI-Parm2" = "1;3;10;$($Query.Length.ToString());WQL;root\CIMv2;$Query;"
        "msWMI-Author" = "Administrator@" + $($CurrentDomain.DNSRoot);
        "msWMI-ID" = $NewWMIGUID;
        "instanceType" = 4;
        "showInAdvancedViewOnly" = "TRUE";
        "distinguishedname" = "CN=" + $NewWMIGUID + ",CN=SOM,CN=WMIPolicy,CN=System," + $($CurrentDomain.DistinguishedName);
        "msWMI-ChangeDate" = $msWMICreationDate;
        "msWMI-CreationDate" = $msWMICreationDate
        }

    if (!(Get-ADObject -Filter { msWMI-Name -eq $Name })) {
        New-ADObject -name $NewWMIGUID -type "msWMI-Som" -Path "CN=SOM,CN=WMIPolicy,CN=System,$($CurrentDomain.DistinguishedName)" -OtherAttributes $Attr | Out-Null
    }
}


# --------------------------------------------------------------------------------
# Create / Import GroupPolicy (Update scheduled task, and copy required LAPS files)
# --------------------------------------------------------------------------------
$GPOImport = Get-ChildItem -Path "$PSScriptRoot\GPO" -Recurse -Depth 1 | WHere {$_.FullName -Like "*{*}*"}
Foreach ($GPO in $GPOimport) {
    $GPOProperty = New-Object -Type PSObject -Property @{
        'Guid'  = $($GPO.Name)
        'Name' = $(([XML](Get-Content -Path "$($GPO.FullName)\backup.xml")).GroupPolicyBackupScheme.GroupPolicyObject.GroupPolicyCoreSettings.DisplayName.InnerText) -replace("Domain",$GPOPrefix)
    }

    # Change scheduled task prior to import.
    If (Test-Path -Path "$($GPO.FullName)\DomainSysvol\GPO\Machine\Preferences\ScheduledTasks") {
        
        # Read Scheduled task from GPO
        [XML]$ScheduleXML = Get-Content -Path "$($GPO.FullName)\DomainSysvol\GPO\Machine\Preferences\ScheduledTasks\ScheduledTasks.xml"
        $CurrentArguemnts = $ScheduleXML.ScheduledTasks.TaskV2.Properties.Task.Actions.Exec.Arguments -split(" ")
        $NewArguemnts = ($CurrentArguemnts | Select-Object -SkipLast 1) -Join(" ")
        $ScriptName = Split-Path ($CurrentArguemnts[-1]) -Leaf

        # --
        # Create empty GPO (need the ID for the Path)
        # --
        $NewGPO = Get-GPO -Name $($GPOProperty.Name) -ErrorAction SilentlyContinue
        if ($NewGPO -eq $null) {
             $NewGPO = New-GPO -Name $($GPOProperty.Name)
        }
        $NewGPOPath = "\\$($CurrentDomain.DNSRoot)\SYSVOL\$($CurrentDomain.DNSRoot)\Policies\{$($NewGPO.ID)}\Machine\Scripts\Startup"
        $ScheduleXML.ScheduledTasks.TaskV2.Properties.Task.Actions.Exec.Arguments = $($NewArguemnts + " `"$NewGPOPath\$ScriptName")
        $ScheduleXML.save("$($GPO.FullName)\DomainSysvol\GPO\Machine\Preferences\ScheduledTasks\ScheduledTasks.xml")
        
        Import-GPO -BackupId $GPOProperty.Guid -Path $(Split-Path $($GPO.FullName) -Parent) -TargetName $($GPOProperty.Name) -CreateIfNeeded | Out-Null

        # Copy Legacy Laps installation files
        if (!(Test-Path $NewGPOPath)) {
            New-Item -Path $NewGPOPath -ItemType Directory | Out-Null
        }
        if (Test-Path $NewGPOPath) {
            Copy-Item -Path "$PSScriptRoot\GPO\Policy Dependencies\Manage-Laps-Version.ps1" -Destination $NewGPOPath
            Copy-Item -Path "$($env:windir)\temp\LAPS.x64.msi" -Destination $NewGPOPath
            Copy-Item -Path "$($env:windir)\temp\LAPS.x86.msi" -Destination $NewGPOPath
        }

    } else {
        Import-GPO -BackupId $GPOProperty.Guid -Path $(Split-Path $($GPO.FullName) -Parent) -TargetName $($GPOProperty.Name) -CreateIfNeeded | Out-Null

        $WMIFilter = $(New-Object Microsoft.GroupPolicy.GPDomain).SearchWmiFilters($(New-Object Microsoft.GroupPolicy.GPSearchCriteria)) | Where {$_.Name -like "$GPOPrefix - *$(($($GPOProperty.Name) -split(" "))[2])*"}

        if (($WMIFilter).Name -ne $null) {
            $FilterGPO = Get-GPO -Name $($GPOProperty.Name) -ErrorAction SilentlyContinue
            $FilterGPO.WmiFilter = $WMIFilter
        }
    }
}


# --------------------------------------------------------------------------------
#
# --------------------------------------------------------------------------------
Write-Output "Domain is now prepared to Support Legacy and Windows LAPS"


# --------------------------------------------------------------------------------
# Prompt for cleanup
# --------------------------------------------------------------------------------
$title = "Delete Files"
$message = "Do you want to cleanup the downloaded files and installaion ?"
$yes = New-Object System.Management.Automation.Host.ChoiceDescription "&Yes", "Do cleanup."
$no = New-Object System.Management.Automation.Host.ChoiceDescription "&No", "Just quit"
$options = [System.Management.Automation.Host.ChoiceDescription[]]($yes, $no)
$Cleanup = $host.ui.PromptForChoice($title, $message, $options, 0)


# --------------------------------------------------------------------------------
# Cleanup and Remove Legacy LAPS
# --------------------------------------------------------------------------------
if ($Cleanup -eq 0) {
    Write-Host "Cleanup" -ForegroundColor Red
    Start-Process -FilePath "C:\Windows\System32\MsiExec.exe" -ArgumentList "/x {97E2CA7B-B657-4FF7-A6DB-30ECC73E1E28} /quiet" -Wait
    if ( ($LAPSFiles -ne $null) -AND (Test-Path -Path "$($env:windir)\temp\LAPS.x64.msi")) {
        Remove-Item -Path "$($env:windir)\temp\LAPS.x64.msi" -Force
    }
    if ( ($LAPSFiles -ne $null) -AND (Test-Path -Path "$($env:windir)\temp\LAPS.x86.msi")) {
        Remove-Item -Path "$($env:windir)\temp\LAPS.x86.msi" -Force
    }

    Write-Output "Cleanup done";
}

Write-Output 'Press any key to continue...';
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown');
