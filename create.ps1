#region Config
$Config = $Configuration | ConvertFrom-Json
# $Config = Get-Content -Raw -Path '../Target-Azure-MFASettings.json' | ConvertFrom-Json

$Azure = $Config.Azure
$Managables = $Config.Fields

$enableSMSSignIn = $Config.enableSMSSignIn
#endregion Config

#region default properties
$p = $Person | ConvertFrom-Json
#$m = $Manager | ConvertFrom-Json

$aRef = New-Guid
#$mRef = $ManagerAccountReference | ConvertFrom-Json

$AuditLogs = [Collections.Generic.List[PSCustomObject]]::new()
$Success = $False
#endregion default properties

# Set TLS to accept TLS, TLS 1.1 and TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = @(
    [Net.SecurityProtocolType]::Tls
    [Net.SecurityProtocolType]::Tls11
    [Net.SecurityProtocolType]::Tls12
)

#region Functions
Function Format-PhoneNumber {
    [cmdletbinding()]
    Param(
        [parameter(ValueFromPipeline)]
        [string]
        $PhoneNumber
    )

    if ([string]::IsNullOrWhiteSpace($PhoneNumber)) {
        return $null
    }

    $Phone = $PhoneNumber -Replace '[^\d]', ''

    if (
        ($Phone -match '^(0031|31)*' -and $phone.Length -ge 11 -and $phone.Length -le 14) -or
        ($Phone.StartsWith('0') -and $Phone.Length -eq 10)
    ) {
        return '+31 ' + $phone.Substring($phone.Length - 9)
    }

    return $PhoneNumber
}
#endregion Functions

# Build the Final Account object
$Account = [PSCustomObject]@{
    email           = $p.Contact.Personal.Email
    mobile          = $p.Contact.Business.Phone.Mobile | Format-PhoneNumber
    alternateMobile = $p.Contact.Personal.Phone.Mobile | Format-PhoneNumber
    office          = $p.Contact.Business.Phone.Fixed | Format-PhoneNumber
}

$UserPrincipalName = $p.Accounts.MicrosoftActiveDirectory.userPrincipalName

# Start Script
try {
    $EndpointGuids = [PSCustomObject]@{
        email           = '3ddfcfc8-9383-446f-83cc-3ab9be4be18f'
        mobile          = '3179e48a-750b-4051-897c-87b9720928f7'
        alternateMobile = 'b6332ec1-7057-4abe-9331-3d72feddfe41'
        office          = 'e37fc753-ff3b-4958-9484-eaa9425c82bc'
    }

    # Generating Microsoft Graph API Access Token..
    $RestMethod = @{
        Method      = 'Post'
        Uri         = "https://login.microsoftonline.com/$($Azure.tenant_id)/oauth2/token"
        ContentType = 'application/x-www-form-urlencoded'
        Body        = @{
            grant_type    = "client_credentials"
            client_id     = $Azure.client_id
            client_secret = $Azure.client_secret
            resource      = "https://graph.microsoft.com"
        }
    }

    $AccessToken = (Invoke-RestMethod @RestMethod).access_token

    # Create the base for all restmethods
    $AADMethod = @{
        ContentType = 'application/x-www-form-urlencoded'
        Headers     = @{
            Authorization = "Bearer $AccessToken"
            Accept        = "application/json"
        }
    }

    # Get the user guid for the reference
    Try {
        $Uri = "https://graph.microsoft.com/v1.0/users/$($userPrincipalName)"
        $aRef = (Invoke-RestMethod @AADMethod -Method 'Get' -Uri $Uri).id
    }
    catch {
        throw "Couldn't get Azure User with UPN: $($userPrincipalName)"
    }

    #Gathering current Authentication Methods for the user..
    $BaseUri = "https://graph.microsoft.com/beta/users/$($aRef)/authentication"

    $Uri = $BaseUri + "/methods"

    $AuthenticationMethods = (Invoke-RestMethod @AADMethod -Method 'Get' -Uri $Uri).value

    # Build the PreviousAccount
    $PreviousAccount = [PSCustomObject]@{
        email           = ($AuthenticationMethods | Where-Object { $_.id -eq $EndpointGuids.email }).emailAddress
        mobile          = ($AuthenticationMethods | Where-Object { $_.id -eq $EndpointGuids.mobile }).phoneNumber
        alternateMobile = ($AuthenticationMethods | Where-Object { $_.id -eq $EndpointGuids.alternateMobile }).phoneNumber
        office          = ($AuthenticationMethods | Where-Object { $_.id -eq $EndpointGuids.office }).phoneNumber
    }

    <#
    Alternate Phone cannot be set when there is no primary phone configured,
    So for this case, we will edit the account a bit to accomodate
    #>
    if ($Managables.alternateMobile.Create) {
        if (
            -Not [string]::IsNullOrWhiteSpace($Account.mobile) -and
            -Not [string]::IsNullOrWhiteSpace($Account.alternateMobile) -and
            [string]::IsNullOrWhiteSpace($PreviousAccount.alternateMobile) -and
            $Account.alternateMobile -eq $PreviousAccount.mobile
        ) {
            # we want to shift the mobile phone to the alternate mobile phone,
            # so we force this field to be updatable
            # The alternate mobile is empty, but to be sure, we set it updateable
            $Managables.mobile.Update = $True
            $Managables.alternateMobile.Update = $True
        }

        elseif (
            [string]::IsNullOrWhiteSpace($Account.mobile) -and
            -Not [string]::IsNullOrWhiteSpace($Account.alternateMobile)
        ) {
            # Only the alternate mobile is provided, so we will set it to the mobile field
            $Account.mobile = $Account.alternateMobile
            $Account.alternateMobile = $null
        }
    }

    $AuthMethods = @(
        [PSCustomObject]@{
            Key     = "email"
            BaseUrl = $BaseUri + "/emailMethods"
            Body    = [PSCustomObject]@{
                emailAddress = $Account.email
            }
        }
        [PSCustomObject]@{
            Key     = "mobile"
            BaseUrl = $BaseUri + "/phoneMethods"
            Body    = [PSCustomObject]@{
                phoneNumber = $Account.mobile
                phoneType   = "mobile"
            }
        }
        [PSCustomObject]@{
            Key     = "alternateMobile"
            BaseUrl = $BaseUri + "/phoneMethods"
            Body    = [PSCustomObject]@{
                phoneNumber = $Account.alternateMobile
                phoneType   = "alternateMobile"
            }
        }
        [PSCustomObject]@{
            Key     = "office"
            BaseUrl = $BaseUri + "/phoneMethods"
            Body    = [PSCustomObject]@{
                phoneNumber = $Account.office
                phoneType   = "office"
            }
        }
    )

    $AuthMethods | Where-Object {
        $Managables.$($_.Key).Create -eq $True
    } | ForEach-Object {

        if ($Account.$($_.Key) -eq $PreviousAccount.$($_.Key)) {
            Write-Verbose -Verbose "Authentication Method '$($_.Key)' is already up to date, skipping..."
        }

        # Delete Method
        elseif ([string]::IsNullOrWhiteSpace($Account.$($_.Key))) {

            if ($Managables.$($_.Key).Delete -eq $True) {
                Write-Verbose -Verbose "Deleting Authentication Method '$($_.Key)': $($PreviousAccount.$($_.Key))."

                $Uri = $_.BaseUrl + "/" + $EndpointGuids.$($_.Key)

                if ($dryRun -eq $False) {
                    [void] (Invoke-RestMethod @AADMethod -Uri $Uri -Method 'Delete')
                }

                $AuditLogs.Add([PSCustomObject]@{
                        Action  = "DeleteAccount"
                        Message = "Deleted Authentication Method '$($_.Key)' with value '$($PreviousAccount.$($_.Key))'"
                        IsError = $False
                    })

                Write-Verbose -Verbose "Successfully deleted Authentication Method '$($_.Key)': $($account.$($_.Key))"
            }
            else {
                Write-Verbose -Verbose "Authentication Method '$($_.Key)' is set to not delete when empty. The value stays '$($PreviousAccount.$($_.Key))'."

                $Account.$($_.Key) = $PreviousAccount.$($_.Key)
            }
        }

        # Create Method
        elseif ($EndpointGuids.$($_.Key) -notin $AuthenticationMethods.id) {
            Write-Verbose -Verbose "Adding Authentication Method '$($_.Key)': $($Account.$($_.Key))."

            $Uri = $_.BaseUrl

            if ($dryRun -eq $False) {
                [void] (Invoke-RestMethod @AADMethod -Uri $Uri -Method 'Post' -Body ($_.Body | ConvertTo-Json -Compress))
            }
            else {
                Write-Verbose -Verbose ($_.Body | ConvertTo-Json)
            }

            $AuditLogs.Add([PSCustomObject]@{
                    Action  = "CreateAccount"
                    Message = "Created Authentication Method '$($_.Key)' with value '$($account.$($_.Key))'"
                    IsError = $False
                })

            Write-Verbose -Verbose "Successfully created Authentication Method '$($_.Key)': $($account.$($_.Key))"
        }

        # Update Method
        elseif ($Managables.$($_.Key).Update -eq $True) {
            Write-Verbose -Verbose "Updating Authentication Method '$($_.Key)' from '$($PreviousAccount.$($_.Key))' to '$($Account.$($_.Key))'"

            $Uri = $_.BaseUrl + "/" + $EndpointGuids.$($_.Key)

            if ($dryRun -eq $False) {
                [void] (Invoke-RestMethod @AADMethod -Uri $Uri -Method 'Put' -Body ($_.Body | ConvertTo-Json -Compress))
            }
            else {
                Write-Verbose -Verbose ($_.Body | ConvertTo-Json)
            }

            $AuditLogs.Add([PSCustomObject]@{
                    Action  = "UpdateAccount"
                    Message = "Updated Authentication Method '$($_.Key)' from '$($PreviousAccount.$($_.Key))' to '$($Account.$($_.Key))'"
                    IsError = $False
                })

            Write-Verbose -Verbose "Successfully updated Authentication Method '$($_.Key)' from '$($PreviousAccount.$($_.Key))' to '$($Account.$($_.Key))'"
        }

        else {
            $Account.$($_.Key) = $PreviousAccount.$($_.Key)
            Write-Verbose -Verbose "Authentication Method '$($_.Key)' is set to only update when empty. The value stays '$($PreviousAccount.$($_.Key))'."
        }
    }

    # Enable SMS SignIn
    if ($Managables.mobile.Create -and -not [string]::IsNullOrWhiteSpace($Account.mobile) -and $enableSMSSignIn -eq $True) {
        Write-Verbose -Verbose "Enabling Mobile SMS Sign-in."

        $Uri = $BaseUri + "/phoneMethods/$($EndpointGuids.mobile)"
        $MobileAuthMethod = Invoke-RestMethod @AADMethod -Uri $Uri -Method 'Get'

        if ($MobileAuthMethod.smsSignInState -eq 'ready') {
            Write-Verbose -Verbose "Mobile SMS Sign-in is already enabled."
        }
        elseif ($MobileAuthMethod.smsSignInState -eq 'notEnabled') {
            $Uri = $BaseUri + "/phoneMethods/$($EndpointGuids.mobile)/enableSmsSignIn"

            if ($dryRun -eq $False) {
                [void] (Invoke-RestMethod @AADMethod -Uri $Uri -Method 'Post')
            }

            $MobileAuthMethod.smsSignInState = 'ready'

            Write-Verbose -Verbose "Successfully enabled mobile SMS Sign-in"
        }
        else {
            Write-Warning "SMS signin is not enabled because the sms signin state is '$($MobileAuthMethod.smsSignInState)'"
        }
    }

    # remove unmanaged props
    $ManagableFields = $Managables.PsObject.Properties | Where-Object {
        $_.Value.Create -eq $True
    } | Select-Object -ExpandProperty 'Name'

    $Account = $Account | Select-Object -Property $ManagableFields
    $PreviousAccount = $PreviousAccount | Select-Object -Property $ManagableFields

    if ($AuditLogs.Count -eq 0) {
        $AuditLogs.Add([PSCustomObject]@{
                Action  = "CreateAccount"
                Message = "Correlated user."
                IsError = $False
            })
    }

    # if we reached the end of the Try, we can asume the script has done its job succesfully
    $Success = $True
}
catch {
    $AuditLogs.Add([PSCustomObject]@{
            Action  = "CreateAccount"
            Message = "Error creating account with ID $($aRef): $($_)"
            IsError = $True
        })

    Write-Warning $_
}

# Send results
$Result = [PSCustomObject]@{
    Success          = $Success
    AccountReference = $aRef
    AuditLogs        = $AuditLogs
    Account          = $Account
    PreviousAccount  = $previousAccount

    # Optionally return data for use in other systems
    ExportData       = [PSCustomObject]@{
        Email           = $Account.email
        Mobile          = $Account.mobile
        AlternateMobile = $Account.alternateMobile
        Office          = $Account.office
        SMSSignInState  = $MobileAuthMethod.smsSignInState
    }
}

Write-Output $Result | ConvertTo-Json -Depth 10
