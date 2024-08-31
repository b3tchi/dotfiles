module ak {
  
    def vaults [] {
        ["kv-personal-jb","kv-shared-devs"]
      }

    def secrets [] {
      let subscription = "LEGO-DT-OMP-LRMP-Prod"
      let vault = "kv-personal-jb"

      az keyvault secret list --subscription $subscription --vault-name $vault | from json | get name
    }

    #show secret in keyvault
    export def show [
      vault: string@vaults #keyvault name
      name: string@secrets #secret name
    ] {

      let subscription = "LEGO-DT-OMP-LRMP-Prod"

      mut args = [
      --subscription $subscription
      --vault-name $vault
      --name $name
      --output tsv
      --query value
      ]

      az keyvault secret show ...$args

    }

    #create new secret/update value of existing
    export def set [
      vault: string@vaults #keyvault name
      name: string@secrets #secret name
      value?: string #value is optional if empty it's prompted
    ] {

      if $value == null {
        let value = ( input -s 'please enter secret value: ' )
      }

      print --no-newline $"\nvalue: ($value)"
      
      let subscription = "LEGO-DT-OMP-LRMP-Prod"

      mut args = [
        --subscription $subscription
        --vault-name $vault
        --name $name
        --value $value
      ]

      az keyvault secret set ...$args

    }

    #delete secret from vault
    export def delete [
      vault: string@vaults #keyvault name
      name: string@secrets #secret name
    ] {


      mut confirmation = ( [ok cancel] | input list $"delete ($name) from ($vault)?" ) 

      if $confirmation == cancel { 
        return
      }

      let subscription = "LEGO-DT-OMP-LRMP-Prod"

      mut args = [
        --subscription $subscription
        --vault-name $vault
        --name $name
      ]

      az keyvault secret delete ...$args
      az keyvault secret purge ...$args

    }

  }
