#region Config
$Azure = $actionContext.Configuration.Azure
$Managables = $actionContext.Configuration.Fields
$enableSMSSignIn = $actionContext.Configuration.enableSMSSignIn
#endregion Config

# Start Script
try {
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

    $EndpointGuids = [PSCustomObject]@{
        email           = '3ddfcfc8-9383-446f-83cc-3ab9be4be18f'
        mobile          = '3179e48a-750b-4051-897c-87b9720928f7'
        alternateMobile = 'b6332ec1-7057-4abe-9331-3d72feddfe41'
        office          = 'e37fc753-ff3b-4958-9484-eaa9425c82bc'
    }

    #Gathering current Authentication Methods for the user..
    $BaseUri = "https://graph.microsoft.com/beta/users/$($ActionContext.References.Account)/authentication"

    $Uri = $BaseUri + "/methods"

    $AuthenticationMethods = (Invoke-RestMethod @AADMethod -Method 'Get' -Uri $Uri).value
    
    # Retrieve preferred authentication methods for the user
    $BaseUri = "https://graph.microsoft.com/beta/users/$($ActionContext.References.Account)/authentication"

    $Uri = $BaseUri + '/signInPreferences'

    $PrefferedAuthenticationMethods = (Invoke-RestMethod @AADMethod -Method 'Get' -Uri $Uri)

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
            -Not [string]::IsNullOrWhiteSpace($ActionContext.Data.mobile) -and
            -Not [string]::IsNullOrWhiteSpace($ActionContext.Data.alternateMobile) -and
            [string]::IsNullOrWhiteSpace($PreviousAccount.alternateMobile) -and
            $ActionContext.Data.alternateMobile -eq $PreviousAccount.mobile
        ) {
            # we want to shift the mobile phone to the alternate mobile phone,
            # so we force this field to be updatable
            # The alternate mobile is empty, but to be sure, we set it updateable
            $Managables.mobile.Update = $True
            $Managables.alternateMobile.Update = $True
        }

        elseif (
            [string]::IsNullOrWhiteSpace($ActionContext.Data.mobile) -and
            -Not [string]::IsNullOrWhiteSpace($ActionContext.Data.alternateMobile)
        ) {
            # Only the alternate mobile is provided, so we will set it to the mobile field
            $ActionContext.Data.mobile = $ActionContext.Data.alternateMobile
            $ActionContext.Data.alternateMobile = $null
        }
    }

    $AuthMethods = @(
        [PSCustomObject]@{
            Key     = "email"
            BaseUrl = $BaseUri + "/emailMethods"
            Body    = [PSCustomObject]@{
                emailAddress = $ActionContext.Data.email
            }
        }
        [PSCustomObject]@{
            Key     = "mobile"
            BaseUrl = $BaseUri + "/phoneMethods"
            Body    = [PSCustomObject]@{
                phoneNumber = $ActionContext.Data.mobile
                phoneType   = "mobile"
            }
        }
        [PSCustomObject]@{
            Key     = "alternateMobile"
            BaseUrl = $BaseUri + "/phoneMethods"
            Body    = [PSCustomObject]@{
                phoneNumber = $ActionContext.Data.alternateMobile
                phoneType   = "alternateMobile"
            }
        }
        [PSCustomObject]@{
            Key     = "office"
            BaseUrl = $BaseUri + "/phoneMethods"
            Body    = [PSCustomObject]@{
                phoneNumber = $ActionContext.Data.office
                phoneType   = "office"
            }
        }
    )

    $AuthMethods | Where-Object {
        $Managables.$($_.Key).Create -eq $True
    } | ForEach-Object {

        if ($ActionContext.Data.$($_.Key) -eq $PreviousAccount.$($_.Key)) {
            Write-Verbose -Verbose "Authentication Method '$($_.Key)' is already up to date, skipping..."
        }

        # Delete Method
        elseif ([string]::IsNullOrWhiteSpace($ActionContext.Data.$($_.Key))) {

            if ($Managables.$($_.Key).Delete -eq $True) {
                Write-Verbose -Verbose "Deleting Authentication Method '$($_.Key)': $($PreviousAccount.$($_.Key))."

                # When deleting mobile and primaryauth method is set to mobile, set primary auth method to push
                if (
                    $_.Key -eq 'mobile' -and 
                    $PrefferedAuthenticationMethods.userPreferredMethodForSecondaryAuthentication -eq 'sms' -and
                    $AuthenticationMethods.'@odata.type' -contains '#microsoft.graph.microsoftAuthenticatorAuthenticationMethod'
                ) {
                    $BaseUri = "https://graph.microsoft.com/beta/users/$($ActionContext.References.Account)/authentication"
                    $Uri = $BaseUri + '/signInPreferences'

                    $Body = @{
                        userPreferredMethodForSecondaryAuthentication = 'push'
                    } | ConvertTo-Json

                    $AADMethod.ContentType = 'application/json'

                    [void] (Invoke-RestMethod @AADMethod -Method 'PATCH' -Uri $Uri -Body $Body)

                    $AADMethod.ContentType = 'application/x-www-form-urlencoded'

                    $OutputContext.AuditLogs.Add([PSCustomObject]@{
                        Action  = "UpdateAccount"
                        Message = "Set prefferd Authentication Method to 'push'"
                        IsError = $False
                    })
                }

                $Uri = $_.BaseUrl + "/" + $EndpointGuids.$($_.Key)

                if ($ActionContext.DryRun -eq $False -and $ActionContext.Configuration.Mode.Preview -eq $False) {
                    [void] (Invoke-RestMethod @AADMethod -Uri $Uri -Method 'Delete')
                }

                $OutputContext.AuditLogs.Add([PSCustomObject]@{
                        Action  = "DeleteAccount"
                        Message = "Deleted Authentication Method '$($_.Key)' with value '$($PreviousAccount.$($_.Key))'"
                        IsError = $False
                    })

                Write-Verbose -Verbose "Successfully deleted Authentication Method '$($_.Key)': $($ActionContext.Data.$($_.Key))"
            }
            else {
                Write-Verbose -Verbose "Authentication Method '$($_.Key)' is set to not delete when empty. The value stays '$($PreviousAccount.$($_.Key))'."

                $ActionContext.Data.$($_.Key) = $PreviousAccount.$($_.Key)
            }
        }

        # Create Method
        elseif ($EndpointGuids.$($_.Key) -notin $AuthenticationMethods.id) {
            Write-Verbose -Verbose "Adding Authentication Method '$($_.Key)': $($ActionContext.Data.$($_.Key))."

            $Uri = $_.BaseUrl

            if ($ActionContext.DryRun -eq $False -and $ActionContext.Configuration.Mode.Preview -eq $False) {
                [void] (Invoke-RestMethod @AADMethod -Uri $Uri -Method 'Post' -Body ($_.Body | ConvertTo-Json -Compress))
            }
            else {
                Write-Verbose -Verbose "Body: $($_.Body | ConvertTo-Json)"
            }

            $OutputContext.AuditLogs.Add([PSCustomObject]@{
                    Action  = "CreateAccount"
                    Message = "Created Authentication Method '$($_.Key)' with value '$($ActionContext.Data.$($_.Key))'"
                    IsError = $False
                })

            Write-Verbose -Verbose "Successfully created Authentication Method '$($_.Key)': $($ActionContext.Data.$($_.Key))"
        }

        # Update Method
        elseif ($Managables.$($_.Key).Update -eq $True) {
            Write-Verbose -Verbose "Updating Authentication Method '$($_.Key)' from '$($PreviousAccount.$($_.Key))' to '$($ActionContext.Data.$($_.Key))'"

            $Uri = $_.BaseUrl + "/" + $EndpointGuids.$($_.Key)

            if ($ActionContext.DryRun -eq $False -and $ActionContext.Configuration.Mode.Preview -eq $False) {
                [void] (Invoke-RestMethod @AADMethod -Uri $Uri -Method 'Put' -Body ($_.Body | ConvertTo-Json -Compress))
            }
            else {
                Write-Verbose -Verbose "Body: $($_.Body | ConvertTo-Json)"
            }

            $OutputContext.AuditLogs.Add([PSCustomObject]@{
                    Action  = "UpdateAccount"
                    Message = "Updated Authentication Method '$($_.Key)' from '$($PreviousAccount.$($_.Key))' to '$($ActionContext.Data.$($_.Key))'"
                    IsError = $False
                })

            Write-Verbose -Verbose "Successfully updated Authentication Method '$($_.Key)' from '$($PreviousAccount.$($_.Key))' to '$($ActionContext.Data.$($_.Key))'"
        }

        else {
            $ActionContext.Data.$($_.Key) = $PreviousAccount.$($_.Key)
            Write-Verbose -Verbose "Authentication Method '$($_.Key)' is set to only update when empty. The value stays '$($PreviousAccount.$($_.Key))'."
        }
    }

    # Enable SMS SignIn
    if ($Managables.mobile.Create -and -not [string]::IsNullOrWhiteSpace($ActionContext.Data.mobile) -and $enableSMSSignIn -eq $True) {
        Write-Verbose -Verbose "Enabling Mobile SMS Sign-in."

        $Uri = $BaseUri + "/phoneMethods/$($EndpointGuids.mobile)"
        $MobileAuthMethod = Invoke-RestMethod @AADMethod -Uri $Uri -Method 'Get'

        if ($MobileAuthMethod.smsSignInState -eq 'ready') {
            Write-Verbose -Verbose "Mobile SMS Sign-in is already enabled."
        }
        elseif ($MobileAuthMethod.smsSignInState -eq 'notEnabled') {
            $Uri = $BaseUri + "/phoneMethods/$($EndpointGuids.mobile)/enableSmsSignIn"

            if ($ActionContext.DryRun -eq $False -and $ActionContext.Configuration.Mode.Preview -eq $False) {
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
    $ManagableFields = $Managables.PSObject.Properties | Where-Object {
        $_.value.Create -eq $True
    } | Select-Object -ExpandProperty 'Name'

    $OutputContext.Data = $ActionContext.Data | Select-Object -Property $ManagableFields
    $OutputContext.PreviousData = $PreviousAccount | Select-Object -Property $ManagableFields

    if ($OutputContext.AuditLogs.Count -eq 0) {
        $OutputContext.AuditLogs.Add([PSCustomObject]@{
                Action  = "UpdateAccount"
                Message = "Nothing to update."
                IsError = $False
            })
    }

    # if we reached the end of the Try, we can asume the script has done its job succesfully
    $OutputContext.Success = $True
}
catch {
    $OutputContext.AuditLogs.Add([PSCustomObject]@{
            Action  = "UpdateAccount"
            Message = "Error updating fields of account with Id $($aRef): $($_)"
            IsError = $True
        })
    Write-Warning $_
}
