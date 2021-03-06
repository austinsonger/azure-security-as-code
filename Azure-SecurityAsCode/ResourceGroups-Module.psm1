#Import Helpers
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here/SecurityAsCode-Helpers.ps1"


function Get-Asac-ResourceGroup
{
    param
    (
        [string] $resourcegroup,
        [string] $outputPath
    )

    $outputPath = _Get-Asac-OutputPath -outputPath $outputPath


    $rg = Invoke-Asac-AzCommandLine -azCommandLine "az group show --name $($resourcegroup) --output json"

    $roleassignment = "$(az role assignment list -g "$($resourcegroup)")" 
    $roleassignment = ConvertFrom-Json $roleassignment
    $roleassignment | Sort-Object -Property $_.roleDefinitionName

    $rbacArray = @()
    foreach($role in $roleassignment)
    {
        $rbacDict = [ordered]@{userPrincipal = $role.principalName
                               principalId = $role.principalId
                               role = $role.roleDefinitionName}
        $rbacArray += $rbacDict

    }
    
    $rgDict = [ordered]@{}
    $rgDict.Add('resourcegroup',$rg.name)
    $rgDict.Add('rbac',$rbacArray)

    $path = Join-Path $outputPath -ChildPath "rg"
    New-Item $path -Force -ItemType Directory | Out-Null
    $filePath = Join-Path $path -ChildPath "rg.$($resourcegroup).yml"
    ConvertTo-YAML $rgDict > $filePath
}


function Get-Asac-AllResourceGroups
{ 
    param
    (
        [string] $outputPath
    )
    $outputPath = _Get-Asac-OutputPath -outputPath $outputPath

    $rgs = Invoke-Asac-AzCommandLine -azCommandLine "az group list --output json"


    foreach ($rg in $rgs) {
        Get-Asac-ResourceGroup -resourcegroup $rg.name -outputPath $outputPath
    }
}

function Process-Asac-ResourceGroup
{
    param
    (
        [string] $resourcegroup,
        [string] $basePath
        
    )

    $basePath = _Get-Asac-OutputPath -outputPath $basePath

    $path = Join-Path $basePath -ChildPath "rg"
    $file = Join-Path $path -ChildPath "rg.$($resourcegroup).yml"
    $yamlContent = Get-Content -Path $file -Raw
    $rgConfigured = ConvertFrom-Yaml $yamlContent

    #First get all the UPN that are currently assigned to the resource group
    $rgRoles = Invoke-Asac-AzCommandLine -azCommandLine "az role assignment list --resource-group $($resourcegroup) --output json"

    foreach($upn in $rgConfigured.rbac){
        
        #try and find the upn in the current resource group 
        #if this is found, check if the role is still the same
        #add / remove or update UPN
        
        #check if there is an object id in the file.. If not. Get the Object ID first
        $principalID = ""

        if ($upn.principalId -ne $null -and $upn.principalId -ne "")
        {       
            $principalID = $upn.principalId
        }
        else 
        {
            $user = Invoke-Asac-AzCommandLine -azCommandLine "az ad user show --upn-or-object-id $($upn.principalName) --output json"
            $principalID = $user.objectid
        }

        $foundUser = $rgRoles | Where-Object {$_.principalId -eq $principalID -and $_.roleDefinitionName -eq $($upn.role)}
        
        if ($foundUser -eq $null)
        {
            #member not found with name and same role
            #add role assignment
            Write-Host "[$($upn.userPrincipal)] not found in role [$($upn.role)]. Add user" -ForegroundColor Yellow
            Invoke-Asac-AzCommandLine -azCommandLine "az role assignment create --role ""$($upn.role)"" --assignee $($principalID) --resource-group $($resourcegroup)"
        }
        else 
        {
            #member found with name and same role
            #nothing to do
            Write-Host "Found [$($upn.userPrincipal)] in role [$($upn.role)] as configured. No action" -ForegroundColor Green
            Add-Member -InputObject $foundUser -type NoteProperty -Name 'Processed' -Value $true
        }
    }

    #No Delete all users that have not been processed by file

    $nonProcessed = $rgRoles | Where-Object {$_.Processed -eq $null -or $_.Processed -eq $false}
    foreach ($as in $nonProcessed)
    {
        Write-Host "Deleting [$($as.principalName)] from role [$($as.roleDefinitionName)]. Not configured in file" -ForegroundColor DarkMagenta
        Invoke-Asac-AzCommandLine -azCommandLine "az role assignment delete --role ""$($as.roleDefinitionName)"" --assignee $($as.principalId) --resource-group $($resourcegroup)"
    }
}

function Process-Asac-AllResourceGroups{
    param
    (
        [string] $basePath
    )

    $basePath = _Get-Asac-OutputPath -outputPath $basePath
    $path = Join-Path $basePath -ChildPath "rg"


    $rgs = Get-ChildItem -Path $path

    foreach($rg in $rgs)
    {
        $rgName = $rg.ToString().remove(0,3)
        $rgName = $rgName.Substring(0,$rgName.IndexOf('.yml'))
        
        Process-Asac-ResourceGroup -resourcegroup $rgName -basePath $basePath
    }
}



Export-ModuleMember -Function Get-Asac-ResourceGroup, Get-Asac-AllResourceGroups, Process-Asac-ResourceGroup, Process-Asac-AllResourceGroups