function Get-IcingaJEAConfiguration()
{
    param (
        [switch]$RebuildFramework  = $FALSE,
        [switch]$AllowScriptBlocks = $FALSE
    );

    # Prepare all variables and content we require for building the profile
    $CommandList            = Get-Command;
    $PowerShellModules      = Get-ChildItem -Path (Get-IcingaForWindowsRootPath) -Filter 'icinga-powershell-*';
    [array]$BlockedModules  = @();
    $DependencyList         = New-Object PSCustomObject;
    [hashtable]$UsedCmdlets = @{
        'Alias'    = @{ };
        'Cmdlet'   = @{ };
        'Function' = @{ };
        'Modules'  = ([System.Collections.ArrayList]@());
    };
    $ModuleContent          = '';
    [bool]$DependencyCache  = $FALSE;

    if ((Test-Path (Join-Path -Path (Get-IcingaCacheDir) -ChildPath 'framework_dependencies.json')) -And $RebuildFramework -eq $FALSE) {
        $DependencyList  = ConvertFrom-Json -InputObject (Read-IcingaFileSecure -File (Join-Path -Path (Get-IcingaCacheDir) -ChildPath 'framework_dependencies.json'));
        $DependencyCache = $TRUE;
    }

    # Lookup all PowerShell modules installed for Icinga for Windows inside the same folder as the Framework
    # and fetch each single module file to list the used Cmdlets and Functions
    # Add each file content to a big string file for better parsing
    foreach ($module in $PowerShellModules) {
        $Progress = Write-IcingaProgressStatus -Message 'Fetching Icinga for Windows Components' -CurrentValue $Progress -MaxValue $PowerShellModules.Count -Details;
        if ($module.Name.ToLower() -eq 'icinga-powershell-framework') {
            continue;
        }

        if ($UsedCmdlets.Modules -NotContains $module.Name) {
            $UsedCmdlets.Modules.Add($module.Name) | Out-Null;
        }

        $ModuleFiles       = Get-ChildItem -Path $module.FullName -Recurse -Include '*.psm1';
        $ModuleFileContent = '';

        foreach ($PSFile in $ModuleFiles) {
            $DeserializedFile = Read-IcingaPowerShellModuleFile -File $PSFile.FullName;
            $RawModuleContent = $DeserializedFile.NormalisedContent;

            if ([string]::IsNullOrEmpty($RawModuleContent)) {
                continue;
            }

            $ModuleFileContent += $RawModuleContent;
            $ModuleFileContent += "`r`n";
            $ModuleFileContent += "`r`n";

            $SourceCode         = $RawModuleContent.ToLower().Replace(' ', '');
            $SourceCode         = $SourceCode.Replace("`r`n", '');
            $SourceCode         = $SourceCode.Replace("`n", '');

            # Lookup the entire command list and compare the source code behind if it contains any [ScriptBlocks] or Add-Types
            # [ScriptBlocks] are forbidden and modules containing them will not be added, while Add-Type will print a warning
            if ($null -ne (Select-String -InputObject $ModuleFileContent -Pattern '[scriptblock]' -SimpleMatch) -Or $null -ne (Select-String -InputObject $SourceCode -Pattern '={' -SimpleMatch) -Or $null -ne (Select-String -InputObject $SourceCode -Pattern 'return{' -SimpleMatch) -Or $null -ne (Select-String -InputObject $SourceCode -Pattern ';{' -SimpleMatch)) {
                if ($AllowScriptBlocks -eq $FALSE) {
                    Write-IcingaConsoleError 'Unable to include module "{0}" into JEA profile. The file "{1}" is using one or more [ScriptBlock] variables which are forbidden in JEA context.' -Objects $module.Name, $PSFile.FullName;
                    $UsedCmdlets.Modules.RemoveAt($UsedCmdlets.Modules.IndexOf($module.Name));
                    $BlockedModules    += $module.Name;
                    $ModuleFileContent  = '';
                    break;
                } else {
                    Write-IcingaConsoleWarning 'Module "{0}" is containing [ScriptBlock] like content inside file "{1}". Please validate the file before running it inside JEA context.' -Objects $module.Name, $PSFile.FullName;
                }
            }

            if ($null -ne (Select-String -InputObject $SourceCode -Pattern 'add-type' -SimpleMatch) -Or $null -ne (Select-String -InputObject $SourceCode -Pattern 'typedefinition@"' -SimpleMatch) -Or $null -ne (Select-String -InputObject $SourceCode -Pattern '@"' -SimpleMatch)) {
                Write-IcingaConsoleWarning 'The module "{0}" is using "Add-Type" definitions for file "{1}". Ensure you validate the code before trusting this publisher.' -Objects $module.Name, $PSFile.FullName;
            }
        }

        $ModuleContent += $ModuleFileContent;
    }

    if ($DependencyCache -eq $FALSE) {
        # Now lets lookup every single Framework file and get all used Cmdlets and Functions so we know our dependencies
        $FrameworkFiles = Get-ChildItem -Path (Get-IcingaFrameworkRootPath) -Recurse -Filter '*.psm1';

        foreach ($ModuleFile in $FrameworkFiles) {
            $Progress = Write-IcingaProgressStatus -Message 'Compiling Icinga PowerShell Framework Dependency List' -CurrentValue $Progress -MaxValue $FrameworkFiles.Count -Details;

            # Just ignore our cache file
            if ($ModuleFile.FullName -eq (Get-IcingaFrameworkCodeCacheFile)) {
                continue;
            }

            $DeserializedFile = Read-IcingaPowerShellModuleFile -File $ModuleFile.FullName;

            foreach ($FoundFunction in $DeserializedFile.FunctionList) {
                $DependencyList = Get-IcingaFrameworkDependency `
                    -Command $FoundFunction `
                    -DependencyList $DependencyList;
            }
        }

        Write-IcingaFileSecure -File (Join-Path -Path (Get-IcingaCacheDir) -ChildPath 'framework_dependencies.json') -Value $DependencyList;
    }

    $UsedCmdlets.Modules.Add('icinga-powershell-framework') | Out-Null;

    # Check all our configured background daemons and ensure we get all Cmdlets and Functions including the dependency list
    $BackgroundDaemons = (Get-IcingaBackgroundDaemons).Keys;

    foreach ($daemon in $BackgroundDaemons) {
        $Progress = Write-IcingaProgressStatus -Message 'Compiling Background Daemon Dependency List' -CurrentValue $Progress -MaxValue $BackgroundDaemons.Count -Details;

        $DaemonCmd = (Get-Command $daemon);

        if ($BlockedModules -Contains $DaemonCmd.Source) {
            continue;
        }

        $ModuleContent += [string]::Format('function {0} {{{1}{2}{1}}}', $daemon, "`r`n", $DaemonCmd.ScriptBlock.ToString());

        [string]$CommandType = ([string]$DaemonCmd.CommandType).Replace(' ', '');

        $UsedCmdlets = Get-IcingaCommandDependency `
            -DependencyList $DependencyList `
            -CompiledList $UsedCmdlets `
            -CmdName $DaemonCmd.Name `
            -CmdType $CommandType;
    }

    # We need to add this function which is not used anywhere else and should still add the entire dependency tree
    $UsedCmdlets = Get-IcingaCommandDependency `
        -DependencyList $DependencyList `
        -CompiledList $UsedCmdlets `
        -CmdName 'Exit-IcingaExecutePlugin' `
        -CmdType 'Function';

    # We need to add this function for our background daemon we start with 'Start-IcingaForWindowsDaemon',
    # as this function is called outside the JEA context
    $UsedCmdlets = Get-IcingaCommandDependency `
        -DependencyList $DependencyList `
        -CompiledList $UsedCmdlets `
        -CmdName 'Add-IcingaForWindowsDaemon' `
        -CmdType 'Function';

    # Finally loop through all commands again and build our JEA command list
    $DeserializedFile = Read-IcingaPowerShellModuleFile -FileContent $ModuleContent;
    [array]$JeaCmds   = $DeserializedFile.CommandList + $DeserializedFile.FunctionList;

    foreach ($cmd in $JeaCmds) {
        $Progress = Write-IcingaProgressStatus -Message 'Compiling JEA Profile Catalog' -CurrentValue $Progress -MaxValue $JeaCmds.Count -Details;
        $CmdData  = Get-Command $cmd -ErrorAction SilentlyContinue;

        if ($null -eq $CmdData) {
            continue;
        }

        $CommandType = ([string]$CmdData.CommandType).Replace(' ', '');

        $UsedCmdlets = Get-IcingaCommandDependency `
            -DependencyList $DependencyList `
            -CompiledList $UsedCmdlets `
            -CmdName $cmd `
            -CmdType $CommandType;
    }

    Disable-IcingaProgressPreference;

    return $UsedCmdlets;
}
