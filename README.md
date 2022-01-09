# HelloID-Conn-Prov-Target-Azure-MFASettings


config object looks like this

```powershell
$Config = [PSCustomObject]@{
    Azure         = [PSCustomObject]@{
        tenant_id     = ''
        client_id     = ''
        client_secret = ''
    }
    Updatables    = [PSCustomObject]@{
        email           = $False
        mobile          = $False
        alternateMobile = $False
        office          = $False
    }
    Managables    = [PSCustomObject]@{
        email           = $False
        mobile          = $False
        alternateMobile = $False
        office          = $False
    }
    enableSMSSignIn = $False
}
```
