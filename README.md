# HelloID-Conn-Prov-Target-Azure-MFASettings


config object looks like this

```powershell
$Config = [PSCustomObject]@{
    Azure = [PSCustomObject]@{
        tenant_id     = ''
        client_id     = ''
        client_secret = ''
    }
    Fields = [PSCustomObject]@{
        email = [PSCustomObject]@{
            Create = $True
            Update = $False
            Delete = $False
        }
        mobile = [PSCustomObject]@{
            Create = $True
            Update = $False
            Delete = $False
        }
        alternateMobile = [PSCustomObject]@{
            Create = $False
            Update = $False
            Delete = $False
        }
        office = [PSCustomObject]@{
            Create = $False
            Update = $False
            Delete = $False
        }
    }
    enableSMSSignIn = $False
}
```
