<#
.Synopsis
   Icinga PowerShell Module - Powerfull PowerShell Framework for monitoring Windows Systems
.DESCRIPTION
   More Information on https://github.com/Icinga/icinga-powershell-framework
.EXAMPLE
   Install-Icinga
 .NOTES
#>

function Use-Icinga()
{
    param (
        [switch]$LibOnly   = $FALSE,
        [switch]$Daemon    = $FALSE,
        [switch]$DebugMode = $FALSE,
        [switch]$Minimal   = $FALSE
    );

    Disable-IcingaProgressPreference;

    if ($Minimal) {
        if ($null -eq $global:Icinga) {
            $global:Icinga = @{ };
        }

        if ($global:Icinga.ContainsKey('Minimal') -eq $FALSE) {
            $global:Icinga.Add('Minimal', $TRUE);
        }

        # If we load the minimal Framework files, we have to ensure our enums are loaded
        Import-Module ([string]::Format('{0}\lib\icinga\exception\Icinga_IcingaExceptionEnums.psm1', $PSScriptRoot)) -Global;
        Import-Module ([string]::Format('{0}\lib\icinga\enums\Icinga_IcingaEnums.psm1', $PSScriptRoot)) -Global;
        Import-Module ([string]::Format('{0}\lib\core\logging\Icinga_EventLog_Enums.psm1', $PSScriptRoot)) -Global;

        return;
    }

    # Ensure we autoload the Icinga Plugin collection, provided by the external
    # module 'icinga-powershell-plugins'
    if (Get-Command 'Use-IcingaPlugins' -ErrorAction SilentlyContinue) {
        Use-IcingaPlugins;
    }

    if ((Test-Path (Get-IcingaFrameworkCodeCacheFile)) -eq $FALSE -And (Get-IcingaFrameworkCodeCache)) {
        Write-IcingaFrameworkCodeCache;
    }

    # This function will allow us to load this entire module including possible
    # actions, making it available within our shell environment
    # First load our custom modules
    Import-IcingaLib '\' -Init -Custom;
    Import-IcingaLib '\' -Init;

    if ($LibOnly -eq $FALSE) {
        $global:IcingaThreads       = [hashtable]::Synchronized(@{});
        $global:IcingaThreadContent = [hashtable]::Synchronized(@{});
        $global:IcingaThreadPool    = [hashtable]::Synchronized(@{});
        $global:IcingaTimers        = [hashtable]::Synchronized(@{});
        $global:IcingaDaemonData    = [hashtable]::Synchronized(
            @{
                'IcingaThreads'            = $global:IcingaThreads;
                'IcingaThreadContent'      = $global:IcingaThreadContent;
                'IcingaThreadPool'         = $global:IcingaThreadPool;
                'IcingaTimers'             = $global:IcingaTimers;
                'FrameworkRunningAsDaemon' = $Daemon;
                'DebugMode'                = $DebugMode;
            }
        );
    } else {
        # This will fix the debug mode in case we are only using Libs
        # without any other variable content and daemon handling
        if ($null -eq $global:IcingaDaemonData) {
            $global:IcingaDaemonData = [hashtable]::Synchronized(@{});
        }
        if ($global:IcingaDaemonData.ContainsKey('DebugMode') -eq $FALSE) {
            $global:IcingaDaemonData.DebugMode = $DebugMode;
        }
        if ($global:IcingaDaemonData.ContainsKey('FrameworkRunningAsDaemon') -eq $FALSE) {
            $global:IcingaDaemonData.FrameworkRunningAsDaemon = $Daemon;
        }
    }
    New-IcingaPerformanceCounterCache;

    # Enable DebugMode in case it is enabled in our config
    if (Get-IcingaFrameworkDebugMode) {
        Enable-IcingaFrameworkDebugMode;
        $DebugMode = $TRUE;
    }

    $EventLogMessages = Invoke-IcingaNamespaceCmdlets -Command 'Register-IcingaEventLogMessages*';
    foreach ($entry in $EventLogMessages.Values) {
        foreach ($event in $entry.Keys) {
            Add-IcingaHashtableItem -Hashtable $global:IcingaEventLogEnums `
                -Key $event `
                -Value $entry[$event] | Out-Null;
        }
    }

    if ($LibOnly -eq $FALSE) {
        Register-IcingaEventLog;
    }
}

function Get-IcingaFrameworkCodeCacheFile()
{
    return (Join-Path -Path (Get-IcingaCacheDir) -ChildPath 'framework_cache.psm1');
}

function Write-IcingaFrameworkCodeCache()
{
    if (Get-IcingaFrameworkCodeCache) {
        Import-IcingaLib '\' -Init -CompileCache;
    } else {
        Write-IcingaConsoleNotice 'The code caching feature is currently not enabled. You can enable it with "Enable-IcingaFrameworkCodeCache"';
    }
}

function Import-IcingaLib()
{
    param(
        [String]$Lib,
        # The Force Reload will remove the module in case it's loaded and reload it to track
        # possible development changes without having to create new PowerShell environments
        [Switch]$ForceReload,
        [switch]$Init,
        [switch]$Custom,
        [switch]$WriteManifests,
        [switch]$CompileCache
    );

    
    # This is just to only allow a global loading of the module. Import-IcingaLib is ignored on every other
    # location. It is just there to give a basic idea within commands, of which functions are used
    if ($Init -eq $FALSE) {
        return;
    }
    
    $CacheFile = Get-IcingaFrameworkCodeCacheFile;

    if ($Custom -eq $FALSE -And $CompileCache -eq $FALSE -And (Test-Path $CacheFile) -And (Get-IcingaFrameworkCodeCache)) {
        Import-Module $CacheFile -Global;
        return;
    }

    [array]$ImportModules = @();
    [array]$RemoveModules = @();

    if ($Custom) {
        [string]$directory  = Join-Path -Path $PSScriptRoot -ChildPath 'custom\';
    } else {
        [string]$directory  = Join-Path -Path $PSScriptRoot -ChildPath 'lib\';
    }
    [string]$module     = Join-Path -Path $directory -ChildPath $Lib;
    [string]$moduleName = '';

    $ListOfLoadedModules = Get-Module | Select-Object Name;

    # Load modules from directory
    if ((Test-Path $module -PathType Container)) {

        Get-ChildItem -Path $module -Recurse -Filter *.psm1 |
            ForEach-Object {
                [string]$modulePath = $_.FullName;
                $moduleName = $_.Name.Replace('.psm1', '');

                if ($ListOfLoadedModules -like "*$moduleName*") {
                    if ($ForceReload) {
                        $RemoveModules += $moduleName;
                    }
                    $ImportModules += $modulePath;
                } else {
                    $ImportModules += $modulePath;
                    if ($WriteManifests) {
                        Publish-IcingaModuleManifest -Module $moduleName;
                    }
                }
            }
    } else {
        $module = $module.Replace('.psm1', ''); # Cut possible .psm1 ending
        $moduleName = $module.Split('\')[-1]; # Get the last element

        if ($ForceReload) {
            if ($ListOfLoadedModules -Like "*$moduleName*") {
                $RemoveModules += $moduleName;
            }
        }

        $ImportModules += ([string]::Format('{0}.psm1', $module));
        if ($WriteManifests) {
            Publish-IcingaModuleManifest -Module $moduleName;
        }
    }

    if ($RemoveModules.Count -ne 0) {
        Remove-Module $RemoveModules;
    }

    if ($ImportModules.Count -ne 0) {

        if ($CompileCache) {
            $CacheContent = '';
            foreach ($module in $ImportModules) {
                $Content      = Get-Content $module -Raw;
                $CacheContent += $Content + "`r`n";
            }

            $CacheContent += $Content + "Export-ModuleMember -Function @( '*' )";
            Set-Content -Path $CacheFile -Value $CacheContent;
        } else {
            Import-Module $ImportModules -Global;
        }
    }
}

function Publish-IcingaModuleManifest()
{
    param(
        [string]$Module
    );

    [string]$ManifestDir = Join-Path -Path $PSScriptRoot -ChildPath 'manifests';
    [string]$ModuleFile  = [string]::Format('{0}.psd1', $Module);
    [string]$PSDFile     = Join-Path -Path $ManifestDir -ChildPath $ModuleFile;

    if (Test-Path $PSDFile) {
        return;
    }

    New-ModuleManifest -Path $PSDFile -ModuleVersion 1.0 -Author $env:USERNAME -CompanyName 'Icinga GmbH' -Copyright '(c) 2019 Icinga GmbH. All rights reserved.' -PowerShellVersion 4.0;
    $Content    = Get-Content $PSDFile;
    $NewContent = @();

    foreach ($line in $Content) {
        if ([string]::IsNullOrEmpty($line)) {
            continue;
        }

        if ($line[0] -eq '#') {
            continue;
        }

        if ($line.Contains('#')) {
            $line = $line.Substring(0, $line.IndexOf('#'));
        }

        $tmpLine = $line;
        while ($tmpLine.Contains(' ')) {
            $tmpLine = $tmpLine.Replace(' ', '');
        }
        if ([string]::IsNullOrEmpty($tmpLine)) {
            continue;
        }

        $NewContent += $line;
    }

    Set-Content -Path $PSDFile -Value $NewContent;
}

function Publish-IcingaEventlogDocumentation()
{
    param(
        [string]$Namespace,
        [string]$OutFile
    );

    [string]$DocContent = [string]::Format(
        '# {0} Eventlog Documentation',
        $Namespace
    );
    $DocContent += New-IcingaNewLine;
    $DocContent += New-IcingaNewLine;
    $DocContent += "Below you will find a list of EventId's which are exported by this module. The short and detailed message are both written directly into the eventlog. This documentation shall simply provide a summary of available EventId's";

    $SortedArray = $IcingaEventLogEnums[$Namespace].Keys.GetEnumerator() | Sort-Object;

    foreach ($entry in $SortedArray) {
        $entry = $IcingaEventLogEnums[$Namespace][$entry];

        $DocContent = [string]::Format(
            '{0}{2}{2}## Event Id {1}{2}{2}| Category | Short Message | Detailed Message |{2}| --- | --- | --- |{2}| {3} | {4} | {5} |',
            $DocContent,
            $entry.EventId,
            (New-IcingaNewLine),
            $entry.EntryType,
            $entry.Message,
            $entry.Details
        );
    }

    if ([string]::IsNullOrEmpty($OutFile)) {
        Write-Output $DocContent;
    } else {
        Set-Content -Path $OutFile -Value $DocContent;
    }
}

function Get-IcingaPluginDir()
{
    return (Join-Path -Path $PSScriptRoot -ChildPath 'lib\plugins\');
}

function Get-IcingaCustomPluginDir()
{
    return (Join-Path -Path $PSScriptRoot -ChildPath 'custom\plugins\');
}

function Get-IcingaCacheDir()
{
    return (Join-Path -Path $PSScriptRoot -ChildPath 'cache');
}

function Get-IcingaPowerShellConfigDir()
{
    return (Join-Path -Path $PSScriptRoot -ChildPath 'config');
}

function Get-IcingaFrameworkRootPath()
{
    [string]$Path = $PSScriptRoot;
    [int]$Index   = $Path.LastIndexOf('\') + 1;
    $Path         = $Path.Substring(0, $Index);
    return $Path;
}

function Get-IcingaPowerShellModuleFile()
{
    return (Join-Path -Path $PSScriptRoot -ChildPath 'icinga-powershell-framework.psm1');
}

function Invoke-IcingaCommand()
{
    [CmdletBinding()]
    param (
        $ScriptBlock,
        [switch]$SkipHeader  = $FALSE,
        [switch]$Manage      = $FALSE,
        [array]$ArgumentList = @()
    );

    Import-LocalizedData `
        -BaseDirectory (Join-Path -Path (Get-IcingaFrameworkRootPath) -ChildPath 'icinga-powershell-framework') `
        -FileName 'icinga-powershell-framework.psd1' `
        -BindingVariable IcingaFrameworkData;

    # Print a header informing our user that loaded the Icinga Framework with a specific
    # version. We can also skip the header by using $SKipHeader
    if ([string]::IsNullOrEmpty($ScriptBlock) -And $SkipHeader -eq $FALSE -And $Manage -eq $FALSE) {
        [array]$Headers = @(
            'Icinga for Windows $FrameworkVersion',
            'Copyright $Copyright',
            'User environment $UserDomain\$Username'
        );

        if (Get-IcingaFrameworkCodeCache) {
            $Headers += [string]::Format('Note: Icinga Framework Code Caching is enabled');
        }

        Write-IcingaConsoleHeader -HeaderLines $Headers;
    }

    powershell.exe -NoExit -Command {
        $Script          = $args[0];
        $RootPath        = $args[1];
        $Version         = $args[2];
        $Manage          = $args[3];
        $IcingaShellArgs = $args[4];

        # Load our Icinga Framework
        Use-Icinga;

        $Host.UI.RawUI.WindowTitle = ([string]::Format('Icinga for Windows {0}', $Version));

        # Set the location to the Icinga Framework module folder
        Set-Location $RootPath;

        if ($Manage) {
            Install-Icinga;
            exit $LASTEXITCODE;
        }

        # If we added a block to execute, do it right here and exit the shell
        # with the last exit code of the command
        if ([string]::IsNullOrEmpty($Script) -eq $FALSE) {
            Invoke-Command -ScriptBlock ([Scriptblock]::Create($Script));
            exit $LASTEXITCODE;
        }

        # Set our "path" to something different so we know that we loaded the Framework
        function prompt {
            Write-Host -Object "icinga" -NoNewline;
            return "> "
        }

    } -Args $ScriptBlock, $PSScriptRoot, $IcingaFrameworkData.PrivateData.Version, ([bool]$Manage), $ArgumentList;
}

function Start-IcingaShellAsUser()
{
    param (
        [string]$User = ''
    );

    Start-Process `
        -WorkingDirectory $PSHOME `
        -FilePath 'powershell.exe' `
        -Verb RunAs `
        -ArgumentList (
            [string]::Format(
                "-Command `"Start-Process -FilePath `"powershell.exe`" -WorkingDirectory `"{0}`" -Credential (Get-Credential -UserName '{1}' -Message 'Please enter your credentials to open an Icinga Shell with') -ArgumentList icinga`"",
                $PSHOME,
                $User
            )
        );
}

Set-Alias icinga Invoke-IcingaCommand -Description "Execute Icinga Framework commands in a new PowerShell instance for testing or quick access to data";
Export-ModuleMember -Alias * -Function *;
