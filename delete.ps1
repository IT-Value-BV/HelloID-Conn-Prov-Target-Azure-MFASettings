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

    # Build the PreviousAccount
    $PreviousAccount = [PSCustomObject]@{
        email           = ($AuthenticationMethods | Where-Object { $_.id -eq $EndpointGuids.email }).emailAddress
        mobile          = ($AuthenticationMethods | Where-Object { $_.id -eq $EndpointGuids.mobile }).phoneNumber
        alternateMobile = ($AuthenticationMethods | Where-Object { $_.id -eq $EndpointGuids.alternateMobile }).phoneNumber
        office          = ($AuthenticationMethods | Where-Object { $_.id -eq $EndpointGuids.office }).phoneNumber
    }

    $AuthMethods = @(
        [PSCustomObject]@{
            Key     = "email"
            BaseUrl = $BaseUri + "/emailMethods"
        }
        [PSCustomObject]@{
            Key     = "mobile"
            BaseUrl = $BaseUri + "/phoneMethods"
        }
        [PSCustomObject]@{
            Key     = "alternateMobile"
            BaseUrl = $BaseUri + "/phoneMethods"
        }
        [PSCustomObject]@{
            Key     = "office"
            BaseUrl = $BaseUri + "/phoneMethods"
        }
    )

    $AuthMethods | Where-Object {
        $Managables.$($_.Key).Create -eq $True -and
        $Managables.$($_.Key).Delete -eq $True
    } | ForEach-Object {

        if (-Not [string]::IsNullOrWhiteSpace($PreviousAccount.$($_.Key))) {

            Write-Verbose -Verbose "Deleting Authentication Method '$($_.Key)': $($PreviousAccount.$($_.Key))."

            $Uri = $_.BaseUrl + "/" + $EndpointGuids.$($_.Key)

            if ($ActionContext.DryRun -eq $False -and $Config.Mode.Preview -eq $False) {
                [void] (Invoke-RestMethod @AADMethod -Uri $Uri -Method 'Delete')
            }

            $OutputContext.AuditLogs.Add([PSCustomObject]@{
                    Action  = "DeleteAccount"
                    Message = "Deleted Authentication Method '$($_.Key)' with value '$($PreviousAccount.$($_.Key))'"
                    IsError = $False
                })

            Write-Verbose -Verbose "Successfully deleted Authentication Method '$($_.Key)': $($account.$($_.Key))"
        }
    }

    # remove unmanaged props
    $ManagableFields = $Managables.PSObject.Properties | Where-Object {
        $_.value.Create -eq $True
    } | Select-Object -ExpandProperty 'Name'

    $PreviousAccount = $PreviousAccount | Select-Object -Property $ManagableFields

    if ($OutputContext.AuditLogs.Count -eq 0) {
        $OutputContext.AuditLogs.Add([PSCustomObject]@{
                Action  = "DeleteAccount"
                Message = "Nothing to delete, uncorrelated account."
                IsError = $False
            })
    }

    # if we reached the end of the Try, we can asume the script has done its job succesfully
    $OutputContext.Success = $True
}
catch {
    $AuditLogs.Add([PSCustomObject]@{
            Action  = "DeleteAccount" # Optionally specify a different action for this audit log
            Message = "Error deleting account with ID $($aRef): $($_)"
            IsError = $True
        })

    Write-Warning $_
}
